// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { FeePolicy } from "./lib/FeePolicy.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";

import { VolumeDecayLib } from "./lib/VolumeDecayLib.sol";
import { TickLib } from "./lib/TickLib.sol";
import { PulseV4HookErrors } from "./lib/PulseV4HookErrors.sol";
import { PulseV4HookEvents } from "./lib/PulseV4HookEvents.sol";
import { HookConstants } from "./lib/HookConstants.sol";
import { HookBase } from "./HookBase.sol";

/// @title FeeModule
/// @notice Dynamic LP fee computation and volume tracking for PulseV4Hook.
abstract contract FeeModule is HookBase {
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    // Fee state
    mapping(PoolId => uint24) public cachedFee;
    /// @notice EVM block.number at the last refresh. On chains exposing an estimated L1
    ///         number, several L2 blocks can share this cache. Volume decay uses timestamps.
    mapping(PoolId => uint256) public lastFeeRefreshBlock;

    // Amount and its decay anchor share one storage slot. Each swap writes just two buckets.
    struct VolumeState {
        uint128 amount;
        uint48 timestamp;
    }

    mapping(PoolId => VolumeState) internal _globalVolume;
    mapping(PoolId => mapping(int24 => VolumeState)) internal _tickVolume;

    // Immutables from main
    uint24 public immutable MIN_FEE;
    uint24 public immutable MAX_FEE;
    uint256 public immutable FEE_CONSTANT_C;

    // =========================================================================
    //                         EXTERNAL FUNCTIONS
    // =========================================================================

    /// @notice Stored volume at its decay anchor (not automatically decayed by this getter).
    function globalVolume(PoolId id) public view returns (uint128) {
        return _globalVolume[id].amount;
    }

    /// @notice Start of the UTC hour in which global volume was last updated.
    function globalVolumeTimestamp(PoolId id) public view returns (uint48) {
        return _globalVolume[id].timestamp;
    }

    /// @notice Stored volume attributed to this post-swap usable tick only.
    function tickVolume(PoolId id, int24 tick) public view returns (uint128) {
        return _tickVolume[id][tick].amount;
    }

    /// @notice Start of the UTC hour in which this tick bucket was last updated.
    function tickVolumeTimestamp(PoolId id, int24 tick) public view returns (uint48) {
        return _tickVolume[id][tick].timestamp;
    }

    /// @notice Compute fee for a pool.
    function computeFee(PoolKey calldata key) public view returns (uint24) {
        PoolId id = key.toId();
        return _computeFee(id, key.tickSpacing);
    }

    /// @dev Recompute when the EVM-visible block.number changes, then reuse the cached fee.
    ///      This prevents volume changes within that interval from immediately changing fees;
    ///      cross-interval manipulation requires separate economic analysis.
    function _feeForSwap(PoolId id, int24 tickSpacing) internal returns (uint24 fee) {
        // Redundant with beforeSwap's own check today, kept so no future caller can cache a fee
        // for a pool this hook was never initialised on.
        if (!initialized[id]) revert PulseV4HookErrors.NotInitialized();
        if (lastFeeRefreshBlock[id] == block.number) return cachedFee[id];
        fee = _computeFee(id, tickSpacing);
        cachedFee[id] = fee;
        lastFeeRefreshBlock[id] = block.number;
        emit PulseV4HookEvents.FeeRefreshed(id, fee);
    }

    function _computeFee(PoolId id, int24 tickSpacing) internal view returns (uint24) {
        if (!initialized[id]) return MIN_FEE;

        uint48 now_ = uint48(block.timestamp);
        (, int24 currentTick,,) = POOL_MANAGER.getSlot0(id);
        int24 center = TickLib.toUsableTick(currentTick, tickSpacing);

        // No recent trading anywhere (fresh pool, or genuinely quiet for longer than the decay
        // window) carries no adverse-selection signal — charge the floor, not the ceiling.
        // MAX_FEE is reserved for when trading IS happening but has moved away from here (below).
        VolumeState memory global = _globalVolume[id];
        uint128 L = VolumeDecayLib.applyDecay(global.amount, global.timestamp, now_);
        if (L == 0) return MIN_FEE;

        // Sum volume for ±2 tick-spacing range
        uint256 localSum = 0;
        for (int24 i = -2; i <= 2; i++) {
            int24 tick = center + int24(int24(tickSpacing) * i);
            VolumeState memory local = _tickVolume[id][tick];
            uint128 decayed = VolumeDecayLib.applyDecay(local.amount, local.timestamp, now_);
            if (i == 0) localSum += uint256(decayed) * 3;
            else localSum += uint256(decayed);
        }

        return FeePolicy.dynamicFee(L, localSum, FEE_CONSTANT_C, MIN_FEE, MAX_FEE);
    }

    function _collectProtocolFee(
        PoolId id,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) internal returns (uint128) {
        // --- Protocol Fee ---
        // Unspecified currency = output side (for exact-in) or input side (for exact-out).
        // Per IPoolManager.SwapParams: amountSpecified is negative for exact-in, positive for exact-out.
        bool isExactIn = params.amountSpecified < 0;
        Currency unspecifiedCurrency;
        int128 unspecifiedDelta;

        if (isExactIn) {
            if (params.zeroForOne) {
                unspecifiedCurrency = key.currency1;
                unspecifiedDelta = delta.amount1();
            } else {
                unspecifiedCurrency = key.currency0;
                unspecifiedDelta = delta.amount0();
            }
        } else {
            if (params.zeroForOne) {
                unspecifiedCurrency = key.currency0;
                unspecifiedDelta = delta.amount0();
            } else {
                unspecifiedCurrency = key.currency1;
                unspecifiedDelta = delta.amount1();
            }
        }

        uint128 absUnspecified = FeePolicy.absolute(unspecifiedDelta);

        // Paused: collect nothing, but let the swap itself proceed untouched.
        uint128 hookFee =
            paused ? 0 : FeePolicy.protocolFee(absUnspecified, tx.gasprice, block.basefee);

        if (hookFee > 0) {
            // Keep the underlying funds in PoolManager and accrue persistent ERC-6909 claims.
            // Mint's negative delta is offset by the positive hookDeltaUnspecified we return.
            POOL_MANAGER.mint(address(this), unspecifiedCurrency.toId(), hookFee);

            if (unspecifiedCurrency == key.currency0) {
                protocolRevenue0[id] += hookFee;
            } else {
                protocolRevenue1[id] += hookFee;
            }
            emit PulseV4HookEvents.ProtocolFeeCollected(
                id, unspecifiedCurrency == key.currency0, hookFee
            );
        }

        return hookFee;
    }

    function _updateVolume(PoolId id, int24 usableTick, uint128 newVolume) internal {
        // Fixed hour boundaries prevent frequent sub-hour updates from postponing decay.
        uint48 hourStart = uint48(block.timestamp / 1 hours * 1 hours);
        _recordVolume(_globalVolume[id], newVolume, hourStart);
        _recordVolume(_tickVolume[id][usableTick], newVolume, hourStart);

        emit PulseV4HookEvents.VolumeUpdated(id, usableTick, newVolume);
    }

    function _recordVolume(VolumeState storage state, uint128 newVolume, uint48 hourStart)
        private
    {
        uint256 updated = uint256(
            VolumeDecayLib.applyDecay(state.amount, state.timestamp, hourStart)
        ) + newVolume;
        // Volume is a fee signal, not a financial balance. Saturate at its representable limit
        // rather than letting an overflowing counter deny otherwise valid swaps.
        state.amount = updated > type(uint128).max ? type(uint128).max : uint128(updated);
        state.timestamp = hourStart;
    }
}

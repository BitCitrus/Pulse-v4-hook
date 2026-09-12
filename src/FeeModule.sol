// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";

import { VolumeDecayLib } from "./lib/VolumeDecayLib.sol";
import { TickLib } from "./lib/TickLib.sol";
import { PulseV4HookErrors } from "./lib/PulseV4HookErrors.sol";
import { PulseV4HookEvents } from "./lib/PulseV4HookEvents.sol";
import { HookConstants } from "./lib/HookConstants.sol";

/// @title FeeModule
/// @notice Fee computation logic for PulseV4Hook. Designed to be called via delegatecall.
/// @dev Storage must match the main hook's storage layout for state variables it accesses.
contract FeeModule {
    // Events (re-export for fee module)
    using PulseV4HookEvents for bytes32;
    using StateLibrary for IPoolManager;

    using HookConstants for *;

    // These must match the main hook's storage layout exactly!
    IPoolManager public poolManager;

    // Fee state
    mapping(PoolId => uint24) public cachedFee;
    mapping(PoolId => uint48) public lastFeeRefreshTime;

    // Volume state
    mapping(PoolId => uint128) public globalVolume;
    mapping(PoolId => uint48) public globalVolumeTimestamp;
    mapping(PoolId => mapping(int24 => uint128)) public tickVolume;
    mapping(PoolId => mapping(int24 => uint48)) public tickVolumeTimestamp;

    // Immutables from main
    uint24 public immutable MIN_FEE;
    uint24 public immutable MAX_FEE;
    uint256 public immutable FEE_CONSTANT_C;

    // =========================================================================
    //                         EXTERNAL FUNCTIONS
    // =========================================================================

    /// @notice Compute fee for a pool (called via delegatecall)
    function computeFee(PoolKey calldata key) public view returns (uint24) {
        PoolId id = key.toId();
        return _computeFee(id, key.tickSpacing);
    }

    /// @notice Update volume for a pool (called via delegatecall)
    function updateVolume(PoolKey calldata key, uint128 volumeAmount) public {
        PoolId id = key.toId();
        _updateVolume(id, key.tickSpacing, volumeAmount);
    }

    /// @notice Refresh cached fee (called via delegatecall)
    function refreshFee(PoolKey calldata key) public returns (uint24) {
        PoolId id = key.toId();
        if (uint48(block.timestamp) < lastFeeRefreshTime[id] + HookConstants.FEE_REFRESH_COOLDOWN) {
            revert PulseV4HookErrors.FeeRefreshTooSoon();
        }

        uint24 newFee = _computeFee(id, key.tickSpacing);
        cachedFee[id] = newFee;
        lastFeeRefreshTime[id] = uint48(block.timestamp);

        emit PulseV4HookEvents.FeeRefreshed(msg.sender, newFee);
        return newFee;
    }

    // =========================================================================
    //                         INTERNAL FUNCTIONS
    // =========================================================================

    function _computeFee(PoolId id, int24 tickSpacing) internal view returns (uint24) {
        if (cachedFee[id] == 0) return MIN_FEE; // Not initialized

        uint48 now_ = uint48(block.timestamp);
        (, int24 currentTick,,) = poolManager.getSlot0(id);
        int24 center = TickLib.toUsableTick(currentTick, tickSpacing);

        uint128 L =
            VolumeDecayLib.applyDecay(globalVolume[id], globalVolumeTimestamp[id], now_);
        if (L == 0) return MAX_FEE;

        // Sum volume for ±7 tick range
        uint256 localSum = 0;
        for (int24 i = -2; i <= 2; i++) {
            int24 tick = center + int24(int24(tickSpacing) * i);
            uint128 decayed = VolumeDecayLib.applyDecay(
                tickVolume[id][tick], tickVolumeTimestamp[id][tick], now_
            );
            if (i == 0) localSum += uint256(decayed) * 2;
            else localSum += uint256(decayed);
        }

        if (localSum == 0) return MAX_FEE;

        uint256 rawFee = FullMath.mulDiv(uint256(L), FEE_CONSTANT_C, localSum);
        if (rawFee < MIN_FEE) return MIN_FEE;
        if (rawFee > MAX_FEE) return MAX_FEE;
        return uint24(rawFee);
    }

    function _updateVolume(PoolId id, int24 tickSpacing, uint128 newVolume) internal {
        uint48 now_ = uint48(block.timestamp);

        globalVolume[id] = VolumeDecayLib.applyDecay(
            globalVolume[id], globalVolumeTimestamp[id], now_
        ) + newVolume;
        globalVolumeTimestamp[id] = now_;

        (, int24 currentTick,,) = poolManager.getSlot0(id);
        int24 center = TickLib.toUsableTick(currentTick, tickSpacing);

        for (int24 i = -7; i <= 7; i++) {
            int24 tick = center + int24(int24(tickSpacing) * i);
            tickVolume[id][tick] = VolumeDecayLib.applyDecay(
                tickVolume[id][tick], tickVolumeTimestamp[id][tick], now_
            ) + newVolume;
            tickVolumeTimestamp[id][tick] = now_;
        }

        emit PulseV4HookEvents.VolumeUpdated(msg.sender, newVolume);
    }
}

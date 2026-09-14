// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { Ownable } from "v4-core/lib/openzeppelin-contracts/contracts/access/Ownable.sol";

import { TickLib } from "./lib/TickLib.sol";
import { PulseV4HookErrors } from "./lib/PulseV4HookErrors.sol";
import { PulseV4HookEvents } from "./lib/PulseV4HookEvents.sol";
import { HookConstants } from "./lib/HookConstants.sol";
import { FeeModule } from "./FeeModule.sol";
import { FeePolicy } from "./lib/FeePolicy.sol";

/// @notice Dynamic LP fee driven by decayed local trading activity, plus a protocol fee on
///         external swaps. This hook holds no user funds and takes no position: it only
///         overrides the pool's LP fee and accrues protocol revenue it has itself collected.
/// @dev Required address flags: 0x10C4. There is no keeper and no maintenance: the fee is
///      recomputed by the first swap of each block, so the hook needs nothing done to it.
contract PulseV4Hook is IHooks, IUnlockCallback, Ownable, FeeModule {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    /// @notice If true, volume is measured in token0; otherwise token1.
    bool public immutable BASE_TOKEN_IS_TOKEN0;

    constructor(
        IPoolManager _poolManager,
        address _admin,
        bool _baseTokenIsToken0,
        uint24 _minFee,
        uint24 _maxFee,
        uint256 _feeConstantC
    ) Ownable(_admin) {
        if (address(_poolManager).code.length == 0) {
            revert PulseV4HookErrors.InvalidPoolManager();
        }
        // A 100% LP fee cannot support exact-output swaps. Bounding C also guarantees that
        // uint128 volume * C fits uint256 before the fee is clamped.
        if (
            _minFee > _maxFee || _maxFee >= HookConstants.PIPS_DENOMINATOR
                || _feeConstantC > type(uint128).max
        ) revert PulseV4HookErrors.InvalidFeeParameters();
        POOL_MANAGER = _poolManager;
        BASE_TOKEN_IS_TOKEN0 = _baseTokenIsToken0;
        MIN_FEE = _minFee;
        MAX_FEE = _maxFee;
        FEE_CONSTANT_C = _feeConstantC;

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // HOOK PERMISSIONS
    /// @notice Returns hook permission flags.
    ///         The hook's deployed address MUST have 0x10C4 set in its lower 14 bits — enforced
    ///         at deploy time via Hooks.validateHookPermissions in the constructor.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =========================================================================
    //                         IHooks — CALLBACKS
    // =========================================================================

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Initialize pool state on pool creation.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        returns (bytes4)
    {
        if (msg.sender != address(POOL_MANAGER)) {
            revert PulseV4HookErrors.NotPoolManager();
        }
        if (key.fee != HookConstants.DYNAMIC_FEE_FLAG) {
            revert PulseV4HookErrors.DynamicFeeRequired();
        }
        PoolId id = key.toId();
        if (initialized[id]) revert PulseV4HookErrors.AlreadyInitialized();
        initialized[id] = true;
        cachedFee[id] = MIN_FEE;
        lastFeeRefreshBlock[id] = block.number;
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Override the pool-wide LP fee with the dynamic fee, recomputed on the first
    ///         swap of each block and reused by later swaps in the same block.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(POOL_MANAGER)) {
            revert PulseV4HookErrors.NotPoolManager();
        }
        PoolId id = key.toId();
        if (!initialized[id]) revert PulseV4HookErrors.NotInitialized();

        uint24 fee = _feeForSwap(id, key.tickSpacing);

        // Override LP fee with dynamic fee
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | HookConstants.OVERRIDE_FEE_FLAG
        );
    }

    /// @notice Collect the protocol fee and record volume. Positive hookDeltaUnspecified
    ///         charges the output of exact-input swaps or the input of exact-output swaps.
    /// @dev Deliberately NOT revert-on-pause. Reverting this callback would make every swap in
    ///      the pool revert, locking out ordinary traders and plain Uniswap LPs. Pausing instead
    ///      makes the hook collect nothing (see FeeModule._collectProtocolFee).
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        if (msg.sender != address(POOL_MANAGER)) {
            revert PulseV4HookErrors.NotPoolManager();
        }
        PoolId id = key.toId();
        if (!initialized[id]) revert PulseV4HookErrors.NotInitialized();

        uint128 hookFee = _collectProtocolFee(id, key, params, delta);

        // --- Volume Accounting ---
        (, int24 currentTick,,) = POOL_MANAGER.getSlot0(id);
        uint128 volumeInBase = _computeVolumeInBase(delta);
        if (volumeInBase > 0) {
            _updateVolume(id, TickLib.toUsableTick(currentTick, key.tickSpacing), volumeInBase);
        }
        // Return positive hookDeltaUnspecified: hook took its fee from the unspecified side
        return (IHooks.afterSwap.selector, hookFee > 0 ? int128(hookFee) : int128(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // =========================================================================
    //                               ADMIN
    // =========================================================================

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PulseV4HookEvents.Paused(_paused);
    }

    /// @notice Redeem a pool's accumulated ERC-6909 revenue directly to `recipient`.
    /// @param key       Pool to withdraw revenue for
    /// @param recipient Receives the collected token0/token1 revenue
    function withdrawProtocolRevenue(PoolKey calldata key, address recipient)
        external
        onlyOwner
    {
        if (recipient == address(0)) revert PulseV4HookErrors.InvalidRecipient();
        PoolId id = key.toId();
        uint256 amount0 = protocolRevenue0[id];
        uint256 amount1 = protocolRevenue1[id];
        protocolRevenue0[id] = 0;
        protocolRevenue1[id] = 0;
        if (amount0 > 0 || amount1 > 0) {
            POOL_MANAGER.unlock(
                abi.encode(key.currency0, key.currency1, recipient, amount0, amount1)
            );
        }
        emit PulseV4HookEvents.ProtocolRevenueWithdrawn(id, recipient, amount0, amount1);
    }

    /// @dev PoolManager calls back only its unlock caller. The only unlock entry above is
    ///      owner-only and clears the pool's revenue before any recipient interaction.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert PulseV4HookErrors.NotPoolManager();
        (
            Currency currency0,
            Currency currency1,
            address recipient,
            uint256 amount0,
            uint256 amount1
        ) = abi.decode(data, (Currency, Currency, address, uint256, uint256));
        _redeemRevenue(currency0, recipient, amount0);
        _redeemRevenue(currency1, recipient, amount1);
        return "";
    }

    function _redeemRevenue(Currency currency, address recipient, uint256 amount) private {
        // Revenue accumulates in uint256, but each PoolManager delta is limited to int128.
        // Resolve each burn/take pair before redeeming the next chunk.
        uint256 maxChunk = uint256(uint128(type(int128).max));
        while (amount > 0) {
            uint256 chunk = amount > maxChunk ? maxChunk : amount;
            POOL_MANAGER.burn(address(this), currency.toId(), chunk);
            POOL_MANAGER.take(currency, recipient, chunk);
            amount -= chunk;
        }
    }

    // =========================================================================
    //                           VIEW HELPERS
    // =========================================================================

    function getFeeInfo(PoolKey calldata key)
        external
        view
        returns (uint24 cached, uint24 computed)
    {
        computed = computeFee(key);
        return (cachedFee[key.toId()], computed);
    }

    // =========================================================================
    //                      INTERNAL — VOLUME / HELPERS
    // =========================================================================

    function _computeVolumeInBase(BalanceDelta delta) internal view returns (uint128) {
        int128 a = BASE_TOKEN_IS_TOKEN0 ? delta.amount0() : delta.amount1();
        return FeePolicy.absolute(a);
    }
}

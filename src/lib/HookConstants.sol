// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookConstants
/// @notice Minimal constant definitions extracted from Uniswap v4 libraries.
///         Used to avoid importing full LPFeeLibrary and Hooks libraries.
library HookConstants {
    /// @notice 1bp protocol fee on external user swaps (100 / 1_000_000 = 0.01%)
    uint24 public constant HOOK_FEE_BPS = 100;

    /// @notice 100% in fee units
    uint24 public constant FEE_DENOMINATOR = 1_000_000;

    /// @notice Minimum seconds between keeper fee refreshes (spam guard)
    uint48 public constant FEE_REFRESH_COOLDOWN = 60;

    /// @notice Fee stale threshold: if cached fee is older than this, recompute on-the-fly
    uint48 public constant FEE_STALE_THRESHOLD = 120;

    /// @notice Keeper reward: 10% of accumulated protocol revenue per call
    uint256 public constant KEEPER_REWARD_BPS = 100_000;

    /// @notice hookData sentinel that marks an internal rebalance/deposit-ratio swap.
    bytes32 public constant INTERNAL_SWAP_SENTINEL =
        0x0101010101010101010101010101010101010101010101010101010101010101;

    /// @notice Required flags for PulseV4Hook:
    uint160 public constant REQUIRED = 0x10C4;

    uint256 public constant BEFORE_INITIALIZE_FLAG = 1 << 0;
    uint256 public constant AFTER_INITIALIZE_FLAG = 1 << 12;
    uint256 public constant BEFORE_SWAP_FLAG = 1 << 7;
    uint256 public constant AFTER_SWAP_FLAG = 1 << 6;
    uint256 public constant AFTER_SWAP_RETURNS_DELTA_FLAG = 1 << 2;

    /// @notice Fee override flag: tells PoolManager to use hook-returned fee instead of pool fee.
    uint24 public constant OVERRIDE_FEE_FLAG = 0x400000;

    /// @notice Dynamic fee flag: indicates pool uses dynamic LP fee (not static).
    uint24 public constant DYNAMIC_FEE_FLAG = 0x800000;

    /// @notice Zero delta for BeforeSwapDelta (no hook delta modification).
    int128 public constant BEFORE_SWAP_ZERO_DELTA = 0;

    /// @notice Zero delta for BalanceDelta (no amount).
    int128 public constant BALANCE_DELTA_ZERO = 0;

    /// @title Permissions
    /// @notice Hooks.Permissions struct
    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta;
    }
}

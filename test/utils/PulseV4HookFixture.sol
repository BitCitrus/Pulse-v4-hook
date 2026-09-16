// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

// v4-core test utilities (installed via forge install uniswap/v4-core)
import { Deployers } from "v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TestERC20 } from "../TestToken.sol";

import { PulseV4Hook } from "../../src/PulseV4Hook.sol";
import { PulseV4HookErrors } from "../../src/lib/PulseV4HookErrors.sol";
import { HookConstants } from "../../src/lib/HookConstants.sol";
import { HookMiner } from "../../script/HookMiner.sol";

/// @notice Integration tests for PulseV4Hook.
///         Inherits Deployers to get a fresh PoolManager and helper utilities.
abstract contract PulseV4HookFixture is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // --- Hook address flags ---
    uint160 constant FLAGS = 0x10C4;

    // --- Constants ---
    int24 constant TICK_SPACING = 30;
    /// @dev Matches .env.example: 100 pips = 1bp = 0.01%. Note this floor only binds in the
    ///      degenerate `L == 0` case (no recent volume anywhere). While trading is happening the
    ///      formula cannot produce less than FEE_C / 3, so the effective floor is
    ///      max(MIN_FEE, FEE_C / 3) — here 1000 pips, not 100.
    uint24 constant MIN_FEE = 100;
    uint24 constant MAX_FEE = 3_000;
    uint256 constant FEE_C = 300;

    // --- State ---
    PulseV4Hook hook;
    PoolKey poolKey;
    TestERC20 token0;
    TestERC20 token1;

    /// @dev For a currency used only by this pool in a test, claims must exactly back revenue.
    function _assertClaimRevenue(PoolKey memory key) internal view {
        PoolId id = key.toId();
        assertEq(
            manager.balanceOf(address(hook), key.currency0.toId()), hook.protocolRevenue0(id)
        );
        assertEq(
            manager.balanceOf(address(hook), key.currency1.toId()), hook.protocolRevenue1(id)
        );
        assertEq(key.currency0.balanceOf(address(hook)), 0);
        assertEq(key.currency1.balanceOf(address(hook)), 0);
    }

    /// @dev The hook holds no liquidity of its own any more, so tests that need swap depth
    ///      add a plain Uniswap position through the standard router.
    function _addLiquidity(PoolKey memory key, int24 lower, int24 upper, uint256 liquidity)
        internal
    {
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(liquidity), salt: 0
            }),
            ""
        );
    }

    function _addLiquidity(uint256 liquidity) internal {
        _addLiquidity(poolKey, -6000, 6000, liquidity);
    }

    /// @dev Wide background depth, so a swap can travel without hitting the pool price limit.
    function _background(PoolKey memory key, uint256 liquidity) internal {
        _addLiquidity(key, -600_000, 600_000, liquidity);
    }

    /// @dev Redeploy the hook measuring volume in token1 instead of token0.
    function _token1Base() internal {
        bytes memory args = abi.encode(manager, address(this), false, MIN_FEE, MAX_FEE, FEE_C);
        (, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(PulseV4Hook).creationCode, args, 0);
        hook = new PulseV4Hook{ salt: salt }(
            manager, address(this), false, MIN_FEE, MAX_FEE, FEE_C
        );
        poolKey.hooks = hook;
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address trader = makeAddr("trader");

    function setUp() public virtual {
        // Use a valid EIP-1559 transaction with zero tip unless a test overrides the fees.
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);

        // Deploy PoolManager + swapRouter/modifyLiquidityRouter via Deployers helper
        deployFreshManagerAndRouters();

        // Deploy tokens (sorted)
        token0 = new TestERC20("Token0", "T0", 18, 1e24);
        token1 = new TestERC20("Token1", "T1", 18, 1e24);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // Mine hook address
        bytes memory creationCode = type(PulseV4Hook).creationCode;
        bytes memory constructorArgs = abi.encode(
            manager,
            address(this),
            true,
            /*baseIsToken0*/
            MIN_FEE,
            MAX_FEE,
            FEE_C
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, creationCode, constructorArgs, 0);

        // Deploy hook at mined address via CREATE2
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        address deployed;
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        assertEq(deployed, hookAddr, "CREATE2 address mismatch");

        hook = PulseV4Hook(payable(deployed));

        // Build pool poolKey (DYNAMIC_FEE_FLAG required for hook fee override)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        // Initialize pool at 1:1 price
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Fund alice and keeper
        token0.mint(alice, 1e24);
        token1.mint(alice, 1e24);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // Fund trader and approve the swap router
        token0.mint(trader, 1e24);
        token1.mint(trader, 1e24);
        vm.startPrank(trader);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
}

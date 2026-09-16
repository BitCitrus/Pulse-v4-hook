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

import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";

contract PulseV4HookTest is PulseV4HookFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // Basic pool setup

    function test_hookInitialized() public view {
        assertEq(address(hook.POOL_MANAGER()), address(manager));
        assertTrue(hook.initialized(poolKey.toId()));
        assertEq(hook.cachedFee(poolKey.toId()), MIN_FEE);
    }

    // =========================================================================
    // Vault deposit
    // =========================================================================

    // =========================================================================
    // Vault withdraw
    // =========================================================================

    // =========================================================================
    // Fee mechanics
    // =========================================================================

    /// @notice Nothing has to be poked: the first swap of a block recomputes and caches the
    ///         fee itself, so every swap pays a fee derived from that block's own state.
    function test_firstSwapOfBlockRefreshesTheCache() public {
        _addLiquidity(1e21);
        PoolId id = poolKey.toId();
        uint256 initBlock = hook.lastFeeRefreshBlock(id);

        vm.roll(block.number + 1);
        vm.prank(trader);
        swap(poolKey, false, -1e16, "");

        assertGt(hook.lastFeeRefreshBlock(id), initBlock, "swap must refresh the cache");
        assertEq(hook.lastFeeRefreshBlock(id), block.number);
        assertLe(hook.cachedFee(id), MAX_FEE);
        assertGe(hook.cachedFee(id), MIN_FEE);
    }

    /// @notice Within one block the fee is frozen after the first swap. That is what stops a
    ///         trader from reshaping the volume signal mid-block and then trading on the result.
    function test_feeIsFrozenForTheRestOfTheBlock() public {
        _addLiquidity(1e21);
        PoolId id = poolKey.toId();
        vm.roll(block.number + 1);

        vm.prank(trader);
        swap(poolKey, false, -1e16, "");
        uint24 firstFee = hook.cachedFee(id);

        // A large move in the same block shifts the volume signal...
        vm.prank(trader);
        swap(poolKey, false, -5e18, "");
        assertEq(hook.cachedFee(id), firstFee, "fee must not move within a block");

        // ...and is only picked up by the next block's first swap.
        vm.roll(block.number + 1);
        vm.prank(trader);
        swap(poolKey, true, -1e16, "");
        assertEq(hook.lastFeeRefreshBlock(id), block.number);
    }

    /// @notice Pausing stops the hook charging its protocol fee, but must never stop the swap:
    ///         a revert here would brick the pool for every trader and plain Uniswap LP.
    function test_pausedStopsProtocolFeeButNotSwaps() public {
        _addLiquidity(1e21);
        PoolId id = poolKey.toId();

        hook.setPaused(true);
        vm.roll(block.number + 1);
        vm.prank(trader);
        swap(poolKey, false, -1e16, "");
        assertEq(hook.protocolRevenue0(id), 0, "paused hook must collect nothing");
        assertEq(hook.protocolRevenue1(id), 0);
        assertGt(hook.globalVolume(id), 0, "volume accounting keeps running while paused");

        hook.setPaused(false);
        vm.roll(block.number + 1);
        vm.prank(trader);
        swap(poolKey, false, -1e16, "");
        assertGt(hook.protocolRevenue0(id), 0, "unpausing resumes collection");
    }

    /// @notice No trading anywhere (fresh pool, nothing has ever moved) carries no
    ///         adverse-selection signal for LPs and must float to the floor — MAX_FEE is
    ///         reserved for when trading IS happening but has moved away from the current price
    ///         (see the cross-range case below), not for silence.
    function test_computeFee_noVolumeAnywhere_isMinFee_notMaxFee() public view {
        assertEq(hook.computeFee(poolKey), MIN_FEE);
    }

    /// @notice A pool that sits idle before its first trade must refresh to the floor, not jump
    ///         to the ceiling, when beforeSwap recomputes the cache in a later block.
    function test_swap_afterProlongedInactivity_refreshesToMinFee_notMaxFee() public {
        PoolId id = poolKey.toId();
        _addLiquidity(1e21);

        vm.warp(block.timestamp + 121);
        vm.roll(block.number + 1); // new block forces beforeSwap to recompute; volume still 0

        vm.prank(trader);
        swap(poolKey, false, -1e16, "");

        assertEq(hook.cachedFee(id), MIN_FEE, "quiet pool should refresh to the floor");
    }

    // =========================================================================
    // Real swaps: fee collection + volume accounting
    // =========================================================================

    function test_swap_collectsProtocolFeeAndUpdatesVolume() public {
        _addLiquidity(1e21);

        PoolId id = poolKey.toId();
        assertEq(hook.protocolRevenue0(id), 0);
        assertEq(hook.globalVolume(id), 0);

        vm.prank(trader);
        swap(poolKey, false, -1e14, "");

        // Fee is taken from the unspecified (output) side, i.e. token0 for a oneForZero swap
        assertGt(hook.protocolRevenue0(id), 0);
        assertEq(hook.protocolRevenue1(id), 0);
        assertGt(hook.globalVolume(id), 0);
    }

    /// @notice hookData is entirely caller-controlled. There is no value a swapper can put in
    ///         it that buys an exemption from the protocol fee or from volume accounting — the
    ///         hook must never branch on it. (An earlier design carried a public "internal swap"
    ///         sentinel here; anyone could read the constant and replay it.)
    function test_swap_arbitraryHookDataBuysNoExemption() public {
        _addLiquidity(1e21);
        PoolId id = poolKey.toId();

        bytes[3] memory probes = [
            abi.encode(
                bytes32(
                    uint256(0x0101010101010101010101010101010101010101010101010101010101010101)
                )
            ),
            abi.encode(address(hook)),
            bytes(hex"")
        ];
        for (uint256 i; i < probes.length; i++) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(trader);
            swap(poolKey, false, -1e14, probes[i]);
            assertGt(hook.protocolRevenue0(id), 0, "hookData must not skip the protocol fee");
            assertGt(hook.globalVolume(id), 0, "hookData must not skip volume tracking");
            assertTrue(vm.revertToState(snapshot));
        }
    }

    function test_swap_noTipAndTipFees_settleInAllDirections() public {
        _addLiquidity(1e21);
        PoolId id = poolKey.toId();
        vm.fee(10 gwei);
        uint256[6] memory gasPrices =
            [uint256(10 gwei), 15 gwei, 20 gwei, 50 gwei, 300 gwei, 1000 gwei];
        uint256[6] memory expectedPips = [uint256(100), 150, 200, 500, 3000, 3000];

        for (uint256 i; i < gasPrices.length; i++) {
            for (uint256 direction; direction < 4; direction++) {
                uint256 snapshot = vm.snapshotState();
                vm.txGasPrice(gasPrices[i]);
                bool zeroForOne = direction < 2;
                bool exactInput = direction % 2 == 0;
                int256 specified = exactInput ? -int256(1e16) : int256(1e16);
                vm.prank(trader);
                BalanceDelta delta = swap(poolKey, zeroForOne, specified, "");

                int256 input = zeroForOne ? int256(delta.amount0()) : int256(delta.amount1());
                int256 output = zeroForOne ? int256(delta.amount1()) : int256(delta.amount0());
                assertLt(input, 0);
                assertGt(output, 0);
                assertEq(exactInput ? input : output, specified);
                bool feeInToken0 = zeroForOne != exactInput;
                uint256 fee = feeInToken0 ? hook.protocolRevenue0(id) : hook.protocolRevenue1(id);
                assertEq(feeInToken0 ? hook.protocolRevenue1(id) : hook.protocolRevenue0(id), 0);
                uint256 gross = exactInput ? uint256(output) + fee : uint256(-input) - fee;
                assertEq(fee, gross * expectedPips[i] / 1_000_000);
                _assertClaimRevenue(poolKey);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_swap_extraFee_cappedAtMax() public {
        _addLiquidity(1e21);
        PoolId id = poolKey.toId();

        // Even an extreme tip must cap the entire protocol fee, including the fixed 1bp.
        vm.fee(1 gwei);
        vm.txGasPrice(1000 gwei);
        vm.prank(trader);
        BalanceDelta delta = swap(poolKey, false, -1e17, "");

        uint256 output = uint256(uint128(delta.amount0()));
        uint256 maxTotalPips = 3000; // fixed 100 pips + at most 2900 extra pips
        uint256 maxExpectedFee = (output + hook.protocolRevenue0(id)) * maxTotalPips / 1_000_000;

        assertEq(hook.protocolRevenue0(id), maxExpectedFee);
    }

    function test_swap_noProtocolFeeWhenBaseFeeIsZero() public {
        // block.basefee == 0 means this isn't a real EIP-1559 fee market — skip the protocol
        // fee entirely (base 1bp + extra) rather than guess from a meaningless ratio.
        vm.fee(0);
        _addLiquidity(1e21);
        PoolId id = poolKey.toId();

        vm.prank(trader);
        swap(poolKey, false, -1e16, "");

        assertEq(hook.protocolRevenue0(id), 0);
        assertEq(hook.protocolRevenue1(id), 0);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function test_setPaused_onlyAdmin() public {
        // Non-owner cannot pause
        vm.prank(alice);
        vm.expectRevert();
        hook.setPaused(true);

        // Owner can pause
        hook.setPaused(true);
        assertTrue(hook.paused());

        hook.setPaused(false);
        assertFalse(hook.paused());
    }

    // =========================================================================
    // Protocol revenue
    // =========================================================================

    function test_protocolRevenue_initiallyZero() public view {
        assertEq(hook.protocolRevenue0(poolKey.toId()), 0);
        assertEq(hook.protocolRevenue1(poolKey.toId()), 0);
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    function test_getFeeInfo_returnsValues() public view {
        (uint24 cached, uint24 computed) = hook.getFeeInfo(poolKey);
        assertGe(cached, MIN_FEE);
        assertGe(computed, MIN_FEE);
        assertLe(cached, MAX_FEE);
        assertLe(computed, MAX_FEE);
    }

    // =========================================================================
    // Multi-pool: two pools on the same hook sharing a common token
    // =========================================================================

    /// @notice The hook is designed to serve many pools (everything is PoolId-keyed), and
    ///         nothing stops two different pools from sharing a token — e.g. one hook serving
    ///         both a USDC/WETH pool and a USDC/WBTC pool. All prior tests only ever exercised
    ///         a single pool, so this checks whether one pool's deposit sizing can accidentally
    ///         treat ANOTHER pool's reserved idle/protocolRevenue (in the shared token) as free
    ///         balance — the exact same class of bug fixed earlier for the single-pool case,
    ///         but across a pool boundary instead of within one pool.
    /// @notice Two pools sharing token0 each accrue protocol revenue in it. The hook holds a
    ///         single token0 balance covering both, so each pool's entry must stay physically
    ///         redeemable in full — one pool's withdrawal must never be funded by the other's.
    function test_multiPool_sharedToken_revenueStaysSeparatelyRedeemable() public {
        PoolId idA = poolKey.toId();
        TestERC20 token2 = new TestERC20("Token2", "T2", 18, 1e30);
        bool token0IsCurrency0InB = address(token0) < address(token2);
        PoolKey memory poolKeyB = PoolKey({
            currency0: token0IsCurrency0InB
                ? Currency.wrap(address(token0))
                : Currency.wrap(address(token2)),
            currency1: token0IsCurrency0InB
                ? Currency.wrap(address(token2))
                : Currency.wrap(address(token0)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
        manager.initialize(poolKeyB, SQRT_PRICE_1_1);
        PoolId idB = poolKeyB.toId();

        token2.mint(address(this), 1e24);
        token2.mint(trader, 1e24);
        token2.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.prank(trader);
        token2.approve(address(swapRouter), type(uint256).max);

        // Revenue in token0 on pool A.
        _addLiquidity(1e21);
        vm.prank(trader);
        swap(poolKey, false, -5e16, "");
        uint256 revenueA = hook.protocolRevenue0(idA);
        assertGt(revenueA, 0, "pool A must accrue token0 revenue");

        // Revenue in token0 on pool B as well.
        _addLiquidity(poolKeyB, -6000, 6000, 1e21);
        vm.prank(trader);
        swap(poolKeyB, !token0IsCurrency0InB, -5e16, "");
        uint256 revenueB0 = hook.protocolRevenue0(idB);
        uint256 revenueB1 = hook.protocolRevenue1(idB);
        assertGt(revenueB0 + revenueB1, 0, "pool B must accrue revenue");

        // The shared token0 claim balance must cover both entries at once.
        uint256 token0Owed = revenueA + (token0IsCurrency0InB ? revenueB0 : revenueB1);
        assertEq(manager.balanceOf(address(hook), poolKey.currency0.toId()), token0Owed);
        assertEq(token0.balanceOf(address(hook)), 0);

        // Draining pool B in full must leave pool A's entry intact and still payable.
        hook.withdrawProtocolRevenue(poolKeyB, address(this));
        assertEq(hook.protocolRevenue0(idA), revenueA, "pool A entry must survive");
        assertEq(manager.balanceOf(address(hook), poolKey.currency0.toId()), revenueA);
        uint256 before = token0.balanceOf(address(this));
        hook.withdrawProtocolRevenue(poolKey, address(this));
        assertEq(
            token0.balanceOf(address(this)) - before,
            revenueA,
            "pool A revenue must still be redeemable in full"
        );
        assertEq(hook.protocolRevenue0(idA), 0);
        assertEq(manager.balanceOf(address(hook), poolKey.currency0.toId()), 0);
    }

    // =========================================================================
    // Native ETH as currency0
    // =========================================================================
}

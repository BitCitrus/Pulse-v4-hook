// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";

/// @notice Full-scale revenue lifecycle: hundreds of swaps by many traders across three pools
///         that share currencies, then the owner withdraws everything. Verifies that the hook
///         never bricks a swap, that its ERC-6909 claim balance always backs the per-pool
///         ledger, and that a withdrawal pays out exactly what was accounted and nothing else.
contract EndToEndRevenueTest is PulseV4HookFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey erc20A; // token0 / token1, fixture spacing
    PoolKey erc20B; // token0 / token1, spacing 60 -- shares BOTH currencies with A
    PoolKey nativeC; // native ETH / token1 -- shares token1 with A and B

    address[] traders;
    uint256 swapsOk;
    uint256 swapsReverted;

    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 1_000 ether);

        erc20A = poolKey;
        erc20B = poolKey;
        erc20B.tickSpacing = 60;
        manager.initialize(erc20B, SQRT_PRICE_1_1);

        nativeC = poolKey;
        nativeC.currency0 = Currency.wrap(address(0));
        manager.initialize(nativeC, SQRT_PRICE_1_1);

        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        _liq(erc20A, TICK_SPACING, 5e22, 0);
        _liq(erc20B, 60, 5e22, 0);
        _liq(nativeC, TICK_SPACING, 100 ether, 200 ether);

        for (uint256 i; i < 8; i++) {
            address a = makeAddr(string(abi.encodePacked("t", i)));
            token0.mint(a, 1e24);
            token1.mint(a, 1e24);
            vm.deal(a, 500 ether);
            vm.startPrank(a);
            token0.approve(address(swapRouter), type(uint256).max);
            token1.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
            traders.push(a);
        }
    }

    function _liq(PoolKey memory k, int24 s, uint256 liq, uint256 value) internal {
        int24 lo = (-60_000 / s) * s;
        modifyLiquidityRouter.modifyLiquidity{ value: value }(
            k, IPoolManager.ModifyLiquidityParams(lo, -lo, int256(liq), 0), ""
        );
    }

    /// @dev The invariant that matters: for every currency the hook touches, its claim balance
    ///      inside PoolManager must equal the sum of every pool ledger entry for it, and the
    ///      hook must never hold the underlying asset itself.
    function _assertBacked(string memory when) internal view {
        uint256 owed0 =
            hook.protocolRevenue0(erc20A.toId()) + hook.protocolRevenue0(erc20B.toId());
        uint256 owed1 = hook.protocolRevenue1(erc20A.toId())
            + hook.protocolRevenue1(erc20B.toId()) + hook.protocolRevenue1(nativeC.toId());
        uint256 owedEth = hook.protocolRevenue0(nativeC.toId());

        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(token0)))),
            owed0,
            string.concat(when, ": token0 claims must equal the ledger")
        );
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(address(token1)))),
            owed1,
            string.concat(when, ": token1 claims must equal the ledger")
        );
        assertEq(
            manager.balanceOf(address(hook), 0),
            owedEth,
            string.concat(when, ": native claims must equal the ledger")
        );
        assertEq(token0.balanceOf(address(hook)), 0, string.concat(when, ": no token0 held"));
        assertEq(token1.balanceOf(address(hook)), 0, string.concat(when, ": no token1 held"));
        assertEq(address(hook).balance, 0, string.concat(when, ": no ETH held"));
    }

    function test_manySwapsThenOwnerWithdrawsEverything() public {
        uint256 seed = 0x5EED;
        for (uint256 i; i < 300; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            PoolKey memory k = (seed % 3 == 0) ? erc20A : (seed % 3 == 1) ? erc20B : nativeC;
            bool zeroForOne = ((seed >> 8) % 2) == 0;
            bool exactIn = ((seed >> 9) % 4) != 0; // ~25% exact-output
            uint256 size = 1e15 + ((seed >> 16) % 5e17);

            // Exercise the priority-fee curve, including zero tip and basefee == 0.
            uint256 base = (seed >> 40) % 5;
            vm.fee(base == 0 ? 0 : base * 1 gwei);
            vm.txGasPrice(block.basefee + ((seed >> 48) % 40) * 1 gwei);
            vm.roll(block.number + 1);
            if (i % 7 == 0) vm.warp(block.timestamp + 20 minutes);

            // The test router settles native input out of its own balance, so an ETH-paying
            // swap has to be funded through msg.value. Any excess is refunded by the router.
            uint256 value =
                (Currency.unwrap(k.currency0) == address(0) && zeroForOne) ? size + size / 2 : 0;

            vm.prank(traders[seed % traders.length]);
            try swapRouter.swap{ value: value }(
                k,
                IPoolManager.SwapParams(
                    zeroForOne,
                    exactIn ? -int256(size) : int256(size / 4),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                PoolSwapTest.TestSettings(false, false),
                ""
            ) {
                swapsOk++;
            } catch {
                swapsReverted++;
            }

            if (i % 25 == 0) _assertBacked("mid-run");
        }

        _assertBacked("after swaps");
        emit log_named_uint("swaps executed ", swapsOk);
        emit log_named_uint("swaps reverted ", swapsReverted);
        assertEq(swapsReverted, 0, "the hook must never brick a swap");

        uint256 a0 = hook.protocolRevenue0(erc20A.toId());
        uint256 a1 = hook.protocolRevenue1(erc20A.toId());
        uint256 b0 = hook.protocolRevenue0(erc20B.toId());
        uint256 b1 = hook.protocolRevenue1(erc20B.toId());
        uint256 cEth = hook.protocolRevenue0(nativeC.toId());
        uint256 c1 = hook.protocolRevenue1(nativeC.toId());
        emit log_named_uint("pool A token0  ", a0);
        emit log_named_uint("pool A token1  ", a1);
        emit log_named_uint("pool B token0  ", b0);
        emit log_named_uint("pool B token1  ", b1);
        emit log_named_uint("pool C native  ", cEth);
        emit log_named_uint("pool C token1  ", c1);
        assertGt(a0 + a1, 0, "pool A must have earned revenue");
        assertGt(b0 + b1, 0, "pool B must have earned revenue");
        assertGt(cEth + c1, 0, "pool C must have earned revenue");

        address treasury = makeAddr("treasury");
        hook.withdrawProtocolRevenue(erc20A, treasury);
        // Draining A must not disturb B or C, which share the same currencies.
        assertEq(hook.protocolRevenue0(erc20B.toId()), b0, "pool B token0 untouched");
        assertEq(hook.protocolRevenue1(nativeC.toId()), c1, "pool C token1 untouched");
        _assertBacked("after draining A");

        hook.withdrawProtocolRevenue(erc20B, treasury);
        _assertBacked("after draining B");
        hook.withdrawProtocolRevenue(nativeC, treasury);
        _assertBacked("after draining C");

        assertEq(token0.balanceOf(treasury), a0 + b0, "treasury token0");
        assertEq(token1.balanceOf(treasury), a1 + b1 + c1, "treasury token1");
        assertEq(treasury.balance, cEth, "treasury native ETH");

        assertEq(hook.protocolRevenue0(erc20A.toId()), 0);
        assertEq(hook.protocolRevenue1(erc20A.toId()), 0);
        assertEq(hook.protocolRevenue0(erc20B.toId()), 0);
        assertEq(hook.protocolRevenue1(erc20B.toId()), 0);
        assertEq(hook.protocolRevenue0(nativeC.toId()), 0);
        assertEq(hook.protocolRevenue1(nativeC.toId()), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token0)))), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token1)))), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);

        // The pools still work after the treasury is emptied.
        vm.roll(block.number + 1);
        vm.fee(1 gwei);
        vm.prank(traders[0]);
        swapRouter.swap(
            erc20A,
            IPoolManager.SwapParams(true, -1e16, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertGt(hook.protocolRevenue1(erc20A.toId()), 0, "accrual resumes after withdrawal");
        _assertBacked("after post-withdrawal swap");
    }
}

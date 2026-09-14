// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";
import { SplitSettlementRouter } from "../utils/SplitSettlementRouter.sol";
import { PulseV4HookErrors } from "../../src/lib/PulseV4HookErrors.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

contract ReviewBoundariesTest is PulseV4HookFixture {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    function test_review_int128MinimumToken0InputSettlesWithAndWithoutFee() public {
        _minimumModes(false);
    }

    function test_review_int128MinimumToken1InputSettlesWithAndWithoutFee() public {
        _minimumModes(true);
    }

    function _minimumModes(bool token1Base) internal {
        if (token1Base) _token1Base();
        PoolKey memory key = poolKey;
        // Distinct from the fixture pool's spacing, so this is a separate PoolId.
        key.tickSpacing = 60;
        manager.initialize(
            key, TickMath.getSqrtPriceAtTick(token1Base ? int24(220_000) : int24(-220_000))
        );
        token0.mint(address(this), 1e48);
        token1.mint(address(this), 1e48);
        token0.mint(trader, 1e48);
        token1.mint(trader, 1e48);
        _background(key, 1e32);
        SplitSettlementRouter router = new SplitSettlementRouter(manager);
        vm.startPrank(trader);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            vm.fee(i == 0 ? 0 : 1 gwei);
            vm.txGasPrice(1 gwei);
            uint256 before0 = token0.balanceOf(trader);
            uint256 before1 = token1.balanceOf(trader);
            vm.prank(trader);
            BalanceDelta delta = router.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: !token1Base,
                    amountSpecified: int256(type(int128).min),
                    sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(
                        token1Base ? int24(599_970) : int24(-599_970)
                    )
                })
            );
            assertEq(token1Base ? delta.amount1() : delta.amount0(), type(int128).min);
            assertEq(
                token1Base
                    ? before1 - token1.balanceOf(trader)
                    : before0 - token0.balanceOf(trader),
                uint256(1) << 127
            );
            assertEq(int256(token0.balanceOf(trader)) - int256(before0), int256(delta.amount0()));
            assertEq(int256(token1.balanceOf(trader)) - int256(before1), int256(delta.amount1()));
            assertEq(hook.globalVolume(key.toId()), uint256(1) << 127);
            assertEq(token0.balanceOf(address(router)), 0);
            assertEq(token1.balanceOf(address(router)), 0);
            uint256 revenue =
                hook.protocolRevenue0(key.toId()) + hook.protocolRevenue1(key.toId());
            if (i == 0) assertEq(revenue, 0);
            else assertGt(revenue, 0, "fee-enabled path must actually collect");
            _assertClaimRevenue(key);
            assertTrue(vm.revertToState(snapshot));
        }
    }
}

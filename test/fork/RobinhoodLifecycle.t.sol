// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { RobinhoodForkFixture } from "../utils/RobinhoodForkFixture.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @notice Low-level settlement coverage using local test routers on real mainnet core state.
contract RobinhoodLifecycleTest is RobinhoodForkFixture {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liquidityRouter;

    function setUp() public override {
        super.setUp();
        swapRouter = new PoolSwapTest(MANAGER);
        liquidityRouter = new PoolModifyLiquidityTest(MANAGER);
        USDG.approve(address(swapRouter), type(uint256).max);
        USDG.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{ value: 10 ether }(
            key,
            IPoolManager.ModifyLiquidityParams(LOWER, UPPER, int256(LIQUIDITY), bytes32(0)),
            ""
        );
    }

    function test_forkDeploySwapWithdrawAndExit() public {
        _swapAndCheck(true, true, 0.01 ether);
        _swapAndCheck(false, true, 30e6);
        _swapAndCheck(true, false, 30e6);
        _swapAndCheck(false, false, 0.01 ether);

        PoolId id = key.toId();
        uint256 revenue0 = hook.protocolRevenue0(id);
        uint256 revenue1 = hook.protocolRevenue1(id);
        assertGt(revenue0, 0);
        assertGt(revenue1, 0);
        address recipient = makeAddr("robinhood-fork-revenue");
        uint256 nativeBefore = recipient.balance;
        uint256 tokenBefore = USDG.balanceOf(recipient);
        hook.withdrawProtocolRevenue(key, recipient);
        assertEq(recipient.balance - nativeBefore, revenue0);
        assertEq(USDG.balanceOf(recipient) - tokenBefore, revenue1);
        assertEq(hook.protocolRevenue0(id), 0);
        assertEq(hook.protocolRevenue1(id), 0);
        _assertClaims();

        BalanceDelta removed = liquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(LOWER, UPPER, -int256(LIQUIDITY), bytes32(0)),
            ""
        );
        assertGt(removed.amount0(), 0);
        assertGt(removed.amount1(), 0);
        (uint128 remaining,,) =
            MANAGER.getPositionInfo(id, address(liquidityRouter), LOWER, UPPER, bytes32(0));
        assertEq(remaining, 0, "LP fully exits");
        assertEq(address(swapRouter).balance, 0);
        assertEq(address(liquidityRouter).balance, 0);
    }

    function _swapAndCheck(bool zeroForOne, bool exactInput, uint256 amount) internal {
        vm.roll(block.number + 1);
        PoolId id = key.toId();
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = USDG.balanceOf(address(this));
        uint256 revenue0Before = hook.protocolRevenue0(id);
        uint256 revenue1Before = hook.protocolRevenue1(id);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        BalanceDelta delta = swapRouter.swap{ value: zeroForOne ? 1 ether : 0 }(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: specified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(int256(address(this).balance) - int256(nativeBefore), int256(delta.amount0()));
        assertEq(
            int256(USDG.balanceOf(address(this))) - int256(tokenBefore), int256(delta.amount1())
        );
        int256 input = zeroForOne ? int256(delta.amount0()) : int256(delta.amount1());
        int256 output = zeroForOne ? int256(delta.amount1()) : int256(delta.amount0());
        assertLt(input, 0);
        assertGt(output, 0);
        assertEq(exactInput ? input : output, specified, "specified amount preserved");
        bool feeInNative = zeroForOne != exactInput;
        uint256 fee0 = hook.protocolRevenue0(id) - revenue0Before;
        uint256 fee1 = hook.protocolRevenue1(id) - revenue1Before;
        uint256 fee = feeInNative ? fee0 : fee1;
        assertGt(fee, 0);
        assertEq(feeInNative ? fee1 : fee0, 0);
        uint256 gross = exactInput ? uint256(output) + fee : uint256(-input) - fee;
        assertEq(fee, gross * 100 / 1_000_000, "1 bp at the observed gasprice/basefee ratio");
        _assertClaims();
    }
}

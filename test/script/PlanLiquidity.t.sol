// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { PlanLiquidityScript } from "../../script/PlanLiquidity.s.sol";
import { Deployers } from "v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { TestERC20 } from "../TestToken.sol";

contract PlanLiquidityTest is Test, Deployers {
    using BalanceDeltaLibrary for BalanceDelta;
    PlanLiquidityScript planner;

    function setUp() public {
        planner = new PlanLiquidityScript();
    }

    function test_plannedAmountsMatchActualPoolManagerMint() public {
        deployFreshManagerAndRouters();
        TestERC20 usd = new TestERC20("USDG fixture", "USDG", 6, 1_000_000e6);
        usd.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.deal(address(this), 2 ether);
        PlanLiquidityScript.PositionPlan memory p =
            planner.calculate(2620e18, 500, 30, 1 ether, 3000e6);
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(usd)), 100, 30, IHooks(address(0))
        );
        manager.initialize(key, p.sqrtPriceX96);
        uint256 beforeEth = address(this).balance;
        uint256 beforeUsd = usd.balanceOf(address(this));
        BalanceDelta delta = modifyLiquidityRouter.modifyLiquidity{ value: 1 ether }(
            key,
            IPoolManager.ModifyLiquidityParams(
                p.tickLower, p.tickUpper, int256(uint256(p.liquidity)), bytes32(0)
            ),
            ""
        );
        assertEq(uint128(-delta.amount0()), p.amount0);
        assertEq(uint128(-delta.amount1()), p.amount1);
        assertEq(beforeEth - address(this).balance, p.amount0);
        assertEq(beforeUsd - usd.balanceOf(address(this)), p.amount1);
        assertEq(p.amount0 + p.unused0, 1 ether);
        assertEq(p.amount1 + p.unused1, 3000e6);
    }

    function testFuzz_planStaysWithinBudgetAndRoundsRangeOutward(
        uint64 ethAmount,
        uint64 usdAmount,
        uint32 price,
        uint16 width
    ) public view {
        uint256 ethBudget = bound(ethAmount, 0.001 ether, 10 ether);
        uint256 usdBudget = bound(usdAmount, 1e6, 100_000e6);
        uint256 priceE18 = bound(price, 100, 100_000) * 1e18;
        uint256 widthBps = bound(width, 10, 5000);
        PlanLiquidityScript.PositionPlan memory p =
            planner.calculate(priceE18, widthBps, 30, ethBudget, usdBudget);
        assertEq(p.tickLower % 30, 0);
        assertEq(p.tickUpper % 30, 0);
        assertLe(p.lowerPriceE18, priceE18 * (10_000 - widthBps) / 10_000);
        assertGe(p.upperPriceE18, priceE18 * (10_000 + widthBps) / 10_000);
        assertLe(p.amount0, ethBudget);
        assertLe(p.amount1, usdBudget);
        assertGt(p.liquidity, 0);
    }

    function test_rejectsInvalidWidthAndSpacing() public {
        vm.expectRevert(bytes("Plan: invalid width"));
        planner.calculate(2620e18, 10_000, 30, 1 ether, 3000e6);
        vm.expectRevert(bytes("Plan: invalid spacing"));
        planner.calculate(2620e18, 500, (1 << 24) + 30, 1 ether, 3000e6);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { SqrtPriceMath } from "v4-core/src/libraries/SqrtPriceMath.sol";
import { LiquidityAmounts } from "v4-core/test/utils/LiquidityAmounts.sol";
import { PriceLib } from "./PriceLib.sol";
import { TickLib } from "../src/lib/TickLib.sol";

/// @notice Read-only first-position planner for native ETH (18 decimals) / USDG (6 decimals).
/// @dev Computes amounts at a supplied reference price, not a live quote or a mint transaction.
contract PlanLiquidityScript is Script {
    struct PositionPlan {
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint256 lowerPriceE18;
        uint256 upperPriceE18;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 unused0;
        uint256 unused1;
    }

    function run() external view returns (PositionPlan memory p) {
        p = calculate(
            vm.envUint("PRICE_E18"),
            vm.envUint("LP_WIDTH_BPS"),
            vm.envUint("TICK_SPACING"),
            vm.envUint("LP_AMOUNT0_MAX"),
            vm.envUint("LP_AMOUNT1_MAX")
        );
        console2.log("Read-only ETH/USDG position plan; refresh price before signing");
        console2.log("sqrtPriceX96:", p.sqrtPriceX96);
        console2.log("tickLower:", int256(p.tickLower));
        console2.log("tickUpper:", int256(p.tickUpper));
        console2.log("lower USDG/ETH (1e18):", p.lowerPriceE18);
        console2.log("upper USDG/ETH (1e18):", p.upperPriceE18);
        console2.log("liquidity:", p.liquidity);
        console2.log("ETH to mint (wei):", p.amount0);
        console2.log("USDG to mint (6 decimals):", p.amount1);
        console2.log("unused ETH budget (wei):", p.unused0);
        console2.log("unused USDG budget (6 decimals):", p.unused1);
    }

    /// @param widthBps Price distance on either side before ticks are rounded outward.
    function calculate(
        uint256 priceE18,
        uint256 widthBps,
        uint256 spacing,
        uint256 amount0Max,
        uint256 amount1Max
    ) public pure returns (PositionPlan memory p) {
        require(widthBps > 0 && widthBps < 10_000, "Plan: invalid width");
        require(
            spacing > 0 && spacing <= uint24(TickMath.MAX_TICK_SPACING), "Plan: invalid spacing"
        );
        require(amount0Max > 0 && amount1Max > 0, "Plan: both budgets required");
        require(
            amount0Max <= type(uint128).max && amount1Max <= type(uint128).max,
            "Plan: budget too large"
        );
        p.sqrtPriceX96 = PriceLib.sqrtPriceX96(priceE18, 18, 6);
        uint160 lower =
            PriceLib.sqrtPriceX96(FullMath.mulDiv(priceE18, 10_000 - widthBps, 10_000), 18, 6);
        uint160 upper =
            PriceLib.sqrtPriceX96(FullMath.mulDiv(priceE18, 10_000 + widthBps, 10_000), 18, 6);
        int24 tickSpacing = int24(int256(spacing));
        p.tickLower = TickLib.toUsableTick(TickMath.getTickAtSqrtPrice(lower), tickSpacing);
        p.tickUpper =
            TickLib.toUsableTick(TickMath.getTickAtSqrtPrice(upper), tickSpacing) + tickSpacing;
        require(
            p.tickLower >= TickMath.MIN_TICK && p.tickUpper <= TickMath.MAX_TICK,
            "Plan: range outside protocol bounds"
        );
        lower = TickMath.getSqrtPriceAtTick(p.tickLower);
        upper = TickMath.getSqrtPriceAtTick(p.tickUpper);
        require(
            lower < p.sqrtPriceX96 && p.sqrtPriceX96 < upper,
            "Plan: reference price outside range"
        );
        p.lowerPriceE18 = PriceLib.priceE18From(lower, 18, 6);
        p.upperPriceE18 = PriceLib.priceE18From(upper, 18, 6);
        p.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            p.sqrtPriceX96, lower, upper, amount0Max, amount1Max
        );
        require(
            p.liquidity > 0 && p.liquidity <= uint128(type(int128).max),
            "Plan: invalid liquidity"
        );
        // Match PoolManager's mint settlement: both owed amounts round UP.
        p.amount0 = SqrtPriceMath.getAmount0Delta(p.sqrtPriceX96, upper, p.liquidity, true);
        p.amount1 = SqrtPriceMath.getAmount1Delta(lower, p.sqrtPriceX96, p.liquidity, true);
        require(p.amount0 <= amount0Max && p.amount1 <= amount1Max, "Plan: exceeds budget");
        p.unused0 = amount0Max - p.amount0;
        p.unused1 = amount1Max - p.amount1;
    }
}

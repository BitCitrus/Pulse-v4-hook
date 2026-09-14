// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";
import { PulseV4Hook } from "../../src/PulseV4Hook.sol";
import { PulseV4HookErrors } from "../../src/lib/PulseV4HookErrors.sol";
import { TickLib } from "../../src/lib/TickLib.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

contract FeeSafetyRegressionTest is PulseV4HookFixture {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    function test_realSwapOnlyCreditsFinalUsableTick() public {
        vm.fee(0);
        _addLiquidity(1e21);
        vm.prank(trader);
        BalanceDelta delta = swap(poolKey, true, -1e14, "");
        PoolId id = poolKey.toId();
        (, int24 tick,,) = manager.getSlot0(id);
        int24 bucket = TickLib.toUsableTick(tick, TICK_SPACING);
        uint128 volume = uint128(-delta.amount0());
        assertGt(volume, 0);
        assertEq(hook.globalVolume(id), volume);
        assertEq(hook.tickVolume(id, bucket), volume);
        for (int24 i = -7; i <= 7; i++) {
            if (i != 0) assertEq(hook.tickVolume(id, bucket + i * TICK_SPACING), 0);
        }
    }

    function test_constructorRejectsInvalidFeeParameters() public {
        vm.expectRevert(PulseV4HookErrors.InvalidFeeParameters.selector);
        new PulseV4Hook(manager, address(this), true, 10_000, 500, 3_000);
        vm.expectRevert(PulseV4HookErrors.InvalidFeeParameters.selector);
        new PulseV4Hook(manager, address(this), true, 500, 1_000_000, 3_000);
        vm.expectRevert(PulseV4HookErrors.InvalidFeeParameters.selector);
        new PulseV4Hook(manager, address(this), true, 500, 10_000, type(uint256).max);
    }

    function test_constructorRejectsMissingPoolManager() public {
        vm.expectRevert(PulseV4HookErrors.InvalidPoolManager.selector);
        new PulseV4Hook(IPoolManager(address(0)), address(this), true, 500, 10_000, 3_000);
        vm.expectRevert(PulseV4HookErrors.InvalidPoolManager.selector);
        new PulseV4Hook(IPoolManager(alice), address(this), true, 500, 10_000, 3_000);
    }

    function test_staticFeePoolIsRejected() public {
        PoolKey memory staticKey = poolKey;
        staticKey.fee = 3_000;
        vm.prank(address(manager));
        vm.expectRevert(PulseV4HookErrors.DynamicFeeRequired.selector);
        hook.afterInitialize(address(this), staticKey, SQRT_PRICE_1_1, 0);
        // The real manager wraps callback errors and must roll back pool initialization too.
        vm.expectRevert();
        manager.initialize(staticKey, SQRT_PRICE_1_1);
        assertFalse(hook.initialized(staticKey.toId()));
        (uint160 price,,,) = manager.getSlot0(staticKey.toId());
        assertEq(price, 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { FeeModule } from "../../src/FeeModule.sol";
import { TickLib } from "../../src/lib/TickLib.sol";
import { PulseV4HookErrors } from "../../src/lib/PulseV4HookErrors.sol";

/// @dev Only the manager's slot0 tick is relevant to these isolated fee tests.
contract VolumeManagerStub {
    int24 public tick;

    function setTick(int24 next) external {
        tick = next;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(uint24(tick)) << 160);
    }
}

/// @dev Arbitrary writes exist only in this test harness, never in the deployed hook.
contract FeeModuleHarness is FeeModule {
    using PoolIdLibrary for PoolKey;

    constructor(address manager, uint24 minFee) {
        POOL_MANAGER = IPoolManager(manager);
        MIN_FEE = minFee;
        MAX_FEE = 3_000;
        FEE_CONSTANT_C = 300;
    }

    function initialize(PoolId id) external {
        initialized[id] = true;
        cachedFee[id] = MIN_FEE;
    }

    function record(PoolId id, int24 rawTick, uint128 amount) external {
        _updateVolume(id, TickLib.toUsableTick(rawTick, 60), amount);
    }

    /// @dev _feeForSwap is internal in production (only beforeSwap reaches it); expose it here
    ///      so the harness can exercise the per-block cache directly.
    function refreshFee(PoolKey calldata key) external returns (uint24) {
        return _feeForSwap(key.toId(), key.tickSpacing);
    }
}

contract FeeModuleTest is Test {
    using PoolIdLibrary for PoolKey;

    VolumeManagerStub manager;
    FeeModuleHarness fee;
    PoolKey key;
    PoolId id;

    function setUp() public {
        vm.warp(100 hours + 15 minutes);
        manager = new VolumeManagerStub();
        // Below C / 3 so the clamp never hides the raw formula output.
        fee = new FeeModuleHarness(address(manager), 10);
        key.tickSpacing = 60;
        key.hooks = IHooks(address(fee));
        id = key.toId();
        fee.initialize(id);
    }

    function test_onlyPostSwapBucketReceivesVolume() public {
        fee.record(id, -1, 1_000);
        assertEq(fee.globalVolume(id), 1_000);
        assertEq(fee.tickVolume(id, -60), 1_000);
        for (int24 i = -8; i <= 6; i++) {
            if (i != -1) assertEq(fee.tickVolume(id, i * 60), 0);
        }
        assertEq(fee.globalVolumeTimestamp(id), 100 hours);
        assertEq(fee.tickVolumeTimestamp(id, -60), 100 hours);
    }

    function test_frequentTradesCannotPostponeHourlyDecay() public {
        for (uint256 i; i < 7; i++) {
            vm.warp(100 hours + 15 minutes + i * 30 minutes);
            fee.record(id, 0, 1_000_000);
        }
        // Hourly recurrence at 0.5: 2m -> 2.5m -> 2.75m, allowing Q96 floor dust.
        assertApproxEqAbs(fee.globalVolume(id), 2_750_000, 4);
        assertEq(fee.tickVolume(id, 0), fee.globalVolume(id));
        assertEq(fee.globalVolumeTimestamp(id), 103 hours);
    }

    function test_tradeJustBeforeBoundaryDecaysAtBoundary() public {
        vm.warp(101 hours - 1);
        fee.record(id, 0, 1_000_000);
        vm.warp(101 hours);
        fee.record(id, 0, 1);
        assertApproxEqAbs(fee.globalVolume(id), 500_001, 1);
    }

    function test_localFeeWeightsAndWindow() public {
        uint128[7] memory amounts = [uint128(800), 100, 200, 300, 400, 500, 900];
        for (uint256 i; i < 7; i++) {
            fee.record(id, (int24(int256(i)) - 3) * 60, amounts[i]);
        }
        // Global=3200; local=100+200+3*300+400+500=2100; floor(3200*300/2100)=457.
        assertEq(fee.computeFee(key), 457);
        manager.setTick(59);
        assertEq(fee.computeFee(key), 457);
        // Window empty while volume exists outside it: the local == 0 branch pins MAX_FEE.
        manager.setTick(600);
        assertEq(fee.computeFee(key), 3_000);
    }

    function test_untouchedTicksDecayWhenReadAndDoNotReceiveOtherTrades() public {
        fee.record(id, 0, 1_000_000);
        vm.warp(101 hours + 15 minutes);
        fee.record(id, 600, 1_000_000);
        assertEq(fee.tickVolume(id, 0), 1_000_000, "raw getter retains stored value");
        assertEq(fee.tickVolumeTimestamp(id, 0), 100 hours);
        // Global ~=1.5m; center's decayed volume ~=0.5m, weighted three times.
        assertApproxEqAbs(fee.computeFee(key), 300, 1);
        vm.warp(191 hours);
        assertEq(fee.computeFee(key), 10, "everything decayed to zero falls back to MIN_FEE");
    }

    function test_zeroMinimumFeeStillComputesDynamicFee() public {
        FeeModuleHarness zeroFee = new FeeModuleHarness(address(manager), 0);
        key.hooks = IHooks(address(zeroFee));
        PoolId zeroId = key.toId();
        zeroFee.initialize(zeroId);
        zeroFee.record(zeroId, 0, 1_000);
        assertEq(zeroFee.computeFee(key), 100);
        assertEq(zeroFee.refreshFee(key), 100);
    }

    /// @notice The centre bucket's 3x weight caps `local` at 3x global, so the raw fee has a
    ///         hard floor at C / 3, reached only when every bit of recent volume sits in the
    ///         current tick bucket. Two consequences worth pinning:
    ///           - the floor is scale-invariant: more volume does not make the fee cheaper;
    ///           - a MIN_FEE below C / 3 is unreachable while trading is happening, it applies
    ///             only in the degenerate L == 0 case.
    ///         This test fails the moment the centre weight changes. That is intentional —
    ///         the weight sets the floor, so changing it must be a deliberate, visible decision.
    function test_rawFeeFloorIsCOverThreeAndScaleInvariant() public {
        // MIN_FEE deliberately far below the floor, so the clamp cannot mask the raw value.
        FeeModuleHarness floorFee = new FeeModuleHarness(address(manager), 1);
        key.hooks = IHooks(address(floorFee));
        PoolId floorId = key.toId();
        floorFee.initialize(floorId);
        uint256 c = floorFee.FEE_CONSTANT_C();

        floorFee.record(floorId, 0, 1_000);
        assertEq(floorFee.computeFee(key), c / 3, "all volume at centre bottoms out at C / 3");

        // 100x the volume, identical distribution: a ratio-based fee cannot move.
        floorFee.record(floorId, 0, 99_000);
        assertEq(floorFee.computeFee(key), c / 3, "floor is scale-invariant");
        assertGt(c / 3, floorFee.MIN_FEE(), "MIN_FEE below the floor is unreachable here");

        // Anything off-centre can only raise the fee.
        floorFee.record(floorId, 60, 100_000);
        assertGt(floorFee.computeFee(key), c / 3, "off-centre volume must raise the fee");
    }

    /// @notice No distribution across the five sampled buckets can push the fee under C / 3.
    function testFuzz_feeNeverFallsBelowCOverThree(uint96 centre, uint96 near, uint96 far)
        public
    {
        vm.assume(uint256(centre) + near + far > 0);
        FeeModuleHarness floorFee = new FeeModuleHarness(address(manager), 1);
        key.hooks = IHooks(address(floorFee));
        PoolId floorId = key.toId();
        floorFee.initialize(floorId);

        if (centre > 0) floorFee.record(floorId, 0, centre);
        if (near > 0) {
            floorFee.record(floorId, 60, near);
            floorFee.record(floorId, -60, near);
        }
        if (far > 0) {
            floorFee.record(floorId, 120, far);
            floorFee.record(floorId, -120, far);
        }
        assertGe(
            floorFee.computeFee(key),
            floorFee.FEE_CONSTANT_C() / 3,
            "no volume distribution may price below the floor"
        );
    }

    function test_refreshRejectsUninitializedPool() public {
        key.tickSpacing = 30;
        vm.expectRevert(PulseV4HookErrors.NotInitialized.selector);
        fee.refreshFee(key);
    }

    function test_volumeSaturatesInsteadOfRevertingAndCanDecayAgain() public {
        fee.record(id, 0, type(uint128).max);
        fee.record(id, 0, 1);
        assertEq(fee.globalVolume(id), type(uint128).max);
        assertEq(fee.tickVolume(id, 0), type(uint128).max);
        vm.warp(101 hours);
        fee.record(id, 0, 1);
        assertLt(fee.globalVolume(id), type(uint128).max);
        assertEq(fee.computeFee(key), 100);
    }

    function testFuzz_pointAccountingConservesVolume(uint128 a, uint128 b, int24 tick) public {
        a = uint128(bound(a, 1, type(uint128).max / 2));
        b = uint128(bound(b, 1, type(uint128).max / 2));
        tick = int24(bound(tick, -887272, 887272));
        int24 bucket = TickLib.toUsableTick(tick, 60);
        fee.record(id, tick, a);
        fee.record(id, tick, b);
        assertEq(fee.globalVolume(id), uint256(a) + b);
        assertEq(fee.tickVolume(id, bucket), uint256(a) + b);
        assertEq(fee.tickVolume(id, bucket + 60), 0);
        PoolId other = PoolId.wrap(bytes32(uint256(42)));
        fee.record(other, tick, a);
        assertEq(fee.globalVolume(id), uint256(a) + b);
        assertEq(fee.globalVolume(other), a);
    }
}

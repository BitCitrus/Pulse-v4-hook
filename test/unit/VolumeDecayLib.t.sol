// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { VolumeDecayLib } from "../../src/lib/VolumeDecayLib.sol";

contract VolumeDecayLibTest is Test {
    // ---- no-op cases -------------------------------------------------------

    function test_zeroValueReturnsZero() public pure {
        assertEq(VolumeDecayLib.applyDecay(0, 1000, 5000), 0);
    }

    function test_sameTimestampReturnsOriginal() public pure {
        assertEq(VolumeDecayLib.applyDecay(1000, 100, 100), 1000);
    }

    function test_futureTimestampSameAsNow() public pure {
        // currentTimestamp <= lastTimestamp → no decay
        assertEq(VolumeDecayLib.applyDecay(1000, 200, 150), 1000);
    }

    function test_lessThanOneHour_noDecay() public pure {
        // 3599 seconds = 0 full hours elapsed
        assertEq(VolumeDecayLib.applyDecay(1_000_000, 0, 3599), 1_000_000);
    }

    // ---- one-hour decay (multiply by 0.8) ----------------------------------

    function test_oneHourDecay() public pure {
        uint128 result = VolumeDecayLib.applyDecay(1_000_000, 0, 3600);
        // Expected: floor(1_000_000 * 0.8) = 800_000
        // Allow 1-unit rounding tolerance from Q96 fixed point
        assertApproxEqAbs(result, 500_000, 1);
    }

    function test_twoHourDecay() public pure {
        uint128 result = VolumeDecayLib.applyDecay(1_000_000, 0, 7200);
        // Expected: 1_000_000 * 0.64 = 640_000
        assertApproxEqAbs(result, 250_000, 2);
    }

    function test_tenHourDecay() public pure {
        uint128 result = VolumeDecayLib.applyDecay(1_000_000, 0, 36000);
        // 0.5^10 = 1/1024 = 0.0009765625 -> floor 976
        assertApproxEqAbs(result, 976, 5);
    }

    // ---- cap ---------------------------------------------------------------

    function test_ninetyOrMoreHoursReturnsZero() public pure {
        assertEq(VolumeDecayLib.applyDecay(1_000_000, 0, 90 * 3600), 0);
        assertEq(VolumeDecayLib.applyDecay(1_000_000, 0, 200 * 3600), 0);
    }

    // ---- elapsed hours are floor-divided -----------------------------------

    function test_partialHourNotCounted() public pure {
        // 1 hour and 59 minutes = 1 full hour of decay
        uint128 r1h = VolumeDecayLib.applyDecay(1_000_000, 0, 3600);
        uint128 r1h59m = VolumeDecayLib.applyDecay(1_000_000, 0, 3600 + 3540);
        assertEq(r1h, r1h59m);
    }

    // ---- fuzz --------------------------------------------------------------

    /// @dev Property: decay never increases value
    function testFuzz_decayMonotone(uint128 value, uint48 elapsed) public pure {
        if (value == 0) return;
        elapsed = uint48(bound(elapsed, 0, uint256(type(uint48).max)));
        uint128 result = VolumeDecayLib.applyDecay(value, 0, elapsed);
        assertLe(result, value);
    }
}

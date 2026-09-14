// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { TickLib } from "../../src/lib/TickLib.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

contract TickLibTest is Test {
    // ---- toUsableTick -------------------------------------------------------

    function test_positiveTickExactMultiple() public pure {
        assertEq(TickLib.toUsableTick(60, 60), 60);
        assertEq(TickLib.toUsableTick(120, 60), 120);
    }

    function test_positiveTickRoundsDown() public pure {
        assertEq(TickLib.toUsableTick(59, 60), 0);
        assertEq(TickLib.toUsableTick(119, 60), 60);
        assertEq(TickLib.toUsableTick(1, 60), 0);
    }

    function test_zeroTick() public pure {
        assertEq(TickLib.toUsableTick(0, 60), 0);
    }

    function test_negativeTickExactMultiple() public pure {
        assertEq(TickLib.toUsableTick(-60, 60), -60);
        assertEq(TickLib.toUsableTick(-120, 60), -120);
    }

    function test_negativeTickFloorDiv() public pure {
        // floor(-1 / 60) = -1  →  -1 * 60 = -60
        assertEq(TickLib.toUsableTick(-1, 60), -60);
        // floor(-59 / 60) = -1  →  -60
        assertEq(TickLib.toUsableTick(-59, 60), -60);
        // floor(-61 / 60) = -2  →  -120
        assertEq(TickLib.toUsableTick(-61, 60), -120);
    }

    function test_tickSpacingOne() public pure {
        assertEq(TickLib.toUsableTick(887272, 1), 887272);
        assertEq(TickLib.toUsableTick(-887272, 1), -887272);
    }

    // ---- localWeightedSum ---------------------------------------------------

    // ---- fuzz ---------------------------------------------------------------

    /// @dev Property: toUsableTick result is always a multiple of tickSpacing
    function testFuzz_usableTickIsMultiple(int24 tick, int24 spacing) public pure {
        spacing = int24(bound(spacing, 1, 100)); // limit to avoid output overflow
        // bound tick to avoid overflow on output
        tick = int24(bound(tick, -1000000, 1000000));
        int24 usable = TickLib.toUsableTick(tick, spacing);
        assertEq(usable % spacing, 0);
    }

    /// @dev Property: usable tick <= tick (floor behaviour)
    function testFuzz_usableTickLeRawTick(int24 tick, int24 spacing) public pure {
        spacing = int24(bound(spacing, 1, 100));
        tick = int24(bound(tick, -1000000, 1000000));
        int24 usable = TickLib.toUsableTick(tick, spacing);
        assertLe(usable, tick);
    }
}

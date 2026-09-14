// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TickLib
/// @notice Usable-tick normalization for volume bucketing.
library TickLib {
    /// @notice Convert a raw tick to the usable (tickSpacing-aligned) tick using floor division.
    ///         Solidity truncates toward zero, so negative ticks need manual correction.
    /// @param tick        Raw tick from pool state
    /// @param tickSpacing Pool tick spacing
    /// @return Usable tick (floor(tick / tickSpacing) * tickSpacing)
    function toUsableTick(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 q = tick / tickSpacing;
        // Floor correction: if tick is negative and not perfectly divisible, subtract 1
        if (tick < 0 && tick % tickSpacing != 0) q -= 1;
        return q * tickSpacing;
    }
}

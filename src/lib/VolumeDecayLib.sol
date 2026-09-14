// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title VolumeDecayLib
/// @notice Exponential decay for trading volume: 0.5x per full hour elapsed.
///         Decay is applied lazily (at read/write time) using binary exponentiation in Q96 fixed point.
library VolumeDecayLib {
    /// @dev Explicitly discard volume after 90 hours, even if a large counter would still
    ///      have a nonzero integer remainder under mathematical exponential decay.
    uint256 internal constant DECAY_HOURS_CAP = 90;

    /// @dev 0.5 * 2^96 = 2^95, exact in Q96. Half-life is therefore exactly one hour:
    ///      the fee reads roughly the last 3-6 hours of trading and little before that.
    uint256 internal constant DECAY_BASE_Q96 = 39614081257132168796771975168;

    /// @dev 2^96
    uint256 internal constant Q96 = 1 << 96;

    /// @notice Apply hourly exponential decay (0.5 per hour) to a volume value.
    /// @param value           Current stored volume
    /// @param lastTimestamp   Unix timestamp (seconds) of the last update
    /// @param currentTimestamp Current unix timestamp (seconds)
    /// @return Decayed volume
    function applyDecay(uint128 value, uint48 lastTimestamp, uint48 currentTimestamp)
        internal
        pure
        returns (uint128)
    {
        if (value == 0) return 0;
        if (currentTimestamp <= lastTimestamp) return value;

        uint256 hoursElapsed = (uint256(currentTimestamp) - uint256(lastTimestamp)) / 3600;
        if (hoursElapsed == 0) return value;
        if (hoursElapsed >= DECAY_HOURS_CAP) return 0;

        // Binary exponentiation: 0.5^hoursElapsed in Q96
        uint256 factor = _powQ96(DECAY_BASE_Q96, hoursElapsed);
        return uint128((uint256(value) * factor) >> 96);
    }

    /// @dev Compute base^exp in Q96 via binary exponentiation. base must be < 2^96.
    function _powQ96(uint256 base, uint256 exp) private pure returns (uint256 result) {
        result = Q96; // 1.0 in Q96
        while (exp > 0) {
            if (exp & 1 != 0) result = (result * base) >> 96;
            base = (base * base) >> 96;
            exp >>= 1;
        }
    }
}

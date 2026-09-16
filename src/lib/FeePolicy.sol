// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { HookConstants } from "./HookConstants.sol";

library FeePolicy {
    function absolute(int128 amount) internal pure returns (uint128) {
        return amount < 0 ? uint128(uint256(-int256(amount))) : uint128(amount);
    }

    /// @notice Relative spatial concentration; uniform volume scaling cancels out.
    function dynamicFee(uint128 global, uint256 local, uint256 c, uint24 floor, uint24 ceiling)
        internal
        pure
        returns (uint24)
    {
        if (global == 0) return floor;
        if (local == 0) return ceiling;
        uint256 raw = FullMath.mulDiv(global, c, local);
        if (raw < floor) return floor;
        if (raw > ceiling) return ceiling;
        return uint24(raw);
    }

    function protocolFee(uint128 amount, uint256 gasPrice, uint256 baseFee)
        internal
        pure
        returns (uint128)
    {
        if (baseFee == 0) return 0;
        // Clamp the ratio before multiplying so even extreme supplied values are safe.
        uint256 feePips = gasPrice / baseFee
            >= HookConstants.MAX_PROTOCOL_FEE_PIPS / HookConstants.HOOK_FEE_PIPS
            ? HookConstants.MAX_PROTOCOL_FEE_PIPS
            : FullMath.mulDiv(gasPrice, HookConstants.HOOK_FEE_PIPS, baseFee);
        return uint128(uint256(amount) * feePips / HookConstants.PIPS_DENOMINATOR);
    }
}

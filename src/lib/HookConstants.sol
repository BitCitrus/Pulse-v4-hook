// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookConstants
/// @notice Protocol policy constants and canonical v4 fee flags.
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";

library HookConstants {
    /// @notice Protocol fee coefficient, scaled by tx.gasprice / block.basefee.
    ///         Equal gas price and base fee charge 1bp (100 pips / 1_000_000 = 0.01%).
    ///         Collection is disabled when block.basefee == 0.
    uint24 public constant HOOK_FEE_PIPS = 100;

    /// @notice Total protocol fee cap: 30bp (0.3%).
    uint24 public constant MAX_PROTOCOL_FEE_PIPS = 3000;

    /// @notice 100% in fee units (Uniswap v4 fees are denominated in pips, i.e. hundredths of a bip)
    uint24 public constant PIPS_DENOMINATOR = 1_000_000;

    uint24 internal constant OVERRIDE_FEE_FLAG = LPFeeLibrary.OVERRIDE_FEE_FLAG;
    uint24 internal constant DYNAMIC_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { FeePolicy } from "../../src/lib/FeePolicy.sol";

contract FeePolicyTest is Test {
    function test_protocolFee_noTipChargesOnlyOneBasisPoint() public pure {
        assertEq(FeePolicy.protocolFee(1_000_000, 10, 10), 100);
    }

    function test_protocolFee_fractionalTipAndAmountRoundDown() public pure {
        assertEq(FeePolicy.protocolFee(1_000_000, 15, 10), 150);
        assertEq(FeePolicy.protocolFee(1_000_000, 1009, 1000), 100);
        assertEq(FeePolicy.protocolFee(1_000_000, 1010, 1000), 101);
        assertEq(FeePolicy.protocolFee(9_999, 10, 10), 0);
        assertEq(FeePolicy.protocolFee(10_000, 10, 10), 1);
    }

    function test_protocolFee_tipCapAndFullWidthGasValues() public pure {
        assertEq(FeePolicy.protocolFee(1_000_000, 29_999, 1000), 2999);
        assertEq(FeePolicy.protocolFee(1_000_000, 30_000, 1000), 3000);
        assertEq(FeePolicy.protocolFee(1_000_000, type(uint256).max, 1), 3000);
        assertEq(FeePolicy.protocolFee(1_000_000, type(uint256).max, type(uint256).max), 100);
        // Gas price below the cap may still overflow a naive gasPrice * 100 calculation.
        assertEq(FeePolicy.protocolFee(1_000_000, type(uint256).max, type(uint256).max / 2), 200);
    }

    function testFuzz_protocolFee_zeroBaseFeeSkipsCollection(uint128 amount, uint256 gasPrice)
        public
        pure
    {
        assertEq(FeePolicy.protocolFee(amount, gasPrice, 0), 0);
    }

    function testFuzz_protocolFee_isBoundedAndMonotoneInTip(
        uint128 amount,
        uint256 baseFee,
        uint256 lowerGasPrice,
        uint256 higherGasPrice
    ) public pure {
        if (baseFee == 0) baseFee = 1;
        // Valid transactions in an EIP-1559 block pay at least its base fee.
        if (lowerGasPrice < baseFee) lowerGasPrice = baseFee;
        if (higherGasPrice < baseFee) higherGasPrice = baseFee;
        if (lowerGasPrice > higherGasPrice) {
            (lowerGasPrice, higherGasPrice) = (higherGasPrice, lowerGasPrice);
        }
        uint128 lowerFee = FeePolicy.protocolFee(amount, lowerGasPrice, baseFee);
        uint128 higherFee = FeePolicy.protocolFee(amount, higherGasPrice, baseFee);
        assertGe(lowerFee, uint256(amount) * 100 / 1_000_000);
        assertLe(lowerFee, higherFee);
        assertLe(higherFee, uint256(amount) * 3000 / 1_000_000);
    }
}

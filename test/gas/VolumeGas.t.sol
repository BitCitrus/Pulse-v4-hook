// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";

/// @dev State is prepared in setUp so each measured swap starts a fresh test transaction.
///      Figures include the real router/manager/hook/token path, excluding intrinsic tx gas.
abstract contract VolumeGasFixture is PulseV4HookFixture {
    function setUp() public virtual override {
        super.setUp();
        vm.warp(100 hours + 15 minutes);
        _addLiquidity(1e21);
    }

    function _measureSwap() internal {
        vm.prank(trader);
        uint256 start = gasleft();
        swap(poolKey, false, -1e14, "");
        emit log_named_uint("swap execution gas", start - gasleft());
    }
}

contract VolumeGasFreshTest is VolumeGasFixture {
    function testGas_firstSwap() public {
        _measureSwap();
    }
}

contract VolumeGasExistingTest is VolumeGasFixture {
    function setUp() public override {
        super.setUp();
        vm.prank(trader);
        swap(poolKey, false, -1e14, "");
    }

    function testGas_sameTickSameHour() public {
        _measureSwap();
    }

    function testGas_sameTickNextHourAndFeeRefresh() public {
        vm.warp(block.timestamp + 1 hours);
        _measureSwap();
    }

    function testGas_computeFeeAfterOneHour() public {
        vm.warp(block.timestamp + 1 hours);
        uint256 start = gasleft();
        hook.computeFee(poolKey);
        emit log_named_uint("fee query gas", start - gasleft());
    }
}

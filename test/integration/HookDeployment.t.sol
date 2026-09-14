// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";
import { PulseV4Hook } from "../../src/PulseV4Hook.sol";
import { HookMiner } from "../../script/HookMiner.sol";

contract HookDeploymentTest is PulseV4HookFixture {
    function _factoryRuntime() internal pure returns (bytes memory) {
        // Canonical 0x4e59 runtime from the published deployment transaction:
        // https://github.com/Arachnid/deterministic-deployment-proxy#deployment-transaction
        return hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    }

    function test_miningAndDeployingUseSameFactoryWithDifferentCaller() public {
        vm.etch(CREATE2_FACTORY, _factoryRuntime());
        bytes memory args = abi.encode(manager, alice, true, MIN_FEE, MAX_FEE, FEE_C);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, FLAGS, type(PulseV4Hook).creationCode, args, 0);
        vm.prank(alice);
        address deployed = HookMiner.deploy(
            CREATE2_FACTORY, salt, abi.encodePacked(type(PulseV4Hook).creationCode, args)
        );
        assertEq(deployed, expected);
        assertEq(uint160(deployed) & 0x3fff, FLAGS);
        PulseV4Hook created = PulseV4Hook(payable(deployed));
        assertEq(created.owner(), alice);
        assertEq(address(created.POOL_MANAGER()), address(manager));
        assertEq(created.MIN_FEE(), MIN_FEE);
        assertEq(created.MAX_FEE(), MAX_FEE);
    }

    function test_missingFactoryFailsBeforeDeployment() public {
        vm.etch(CREATE2_FACTORY, "");
        vm.expectRevert("Deploy: CREATE2 factory missing");
        this.deployThroughMissingFactory();
    }

    function deployThroughMissingFactory() external {
        HookMiner.deploy(CREATE2_FACTORY, bytes32(0), hex"00");
    }
}

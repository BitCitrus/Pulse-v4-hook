// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console2 } from "forge-std/Script.sol";
import { DeploymentConfig } from "./DeploymentConfig.sol";

/// @notice Initialize a pool after Hook deployment, using the pool creator's local signer.
/// @dev Same build and constructor config as Deploy; refresh PRICE_E18 before running.
///      PRIVATE_KEY belongs to the executing wallet and never sets the Hook owner or LP owner.
contract InitializePoolScript is DeploymentConfig {
    function run() external returns (Plan memory p) {
        Config memory c = readConfig();
        p = prepareInitialization(c);
        uint256 initializerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(initializerKey);
        c.poolManager.initialize(p.key, p.sqrtPriceX96);
        vm.stopBroadcast();
        console2.log("Pool initialized for Hook:", p.hookAddress);
    }
}

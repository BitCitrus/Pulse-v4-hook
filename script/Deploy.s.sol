// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console2 } from "forge-std/Script.sol";
import { DeploymentConfig } from "./DeploymentConfig.sol";
import { HookMiner } from "./HookMiner.sol";

/// @notice Deploy PulseV4Hook, optionally initializing the pool with the same signer.
/// @dev Use --sig "deployHook()" to deploy only, then InitializePool with the creating wallet.
contract DeployScript is DeploymentConfig {
    function run() external returns (Plan memory p) {
        return _run(true);
    }

    function deployHook() external returns (Plan memory p) {
        return _run(false);
    }

    function _run(bool initializePool) private returns (Plan memory p) {
        Config memory c = initializePool ? readConfig() : readHookConfig();
        p = initializePool ? prepare(c) : prepareHook(c);
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        address deployed = HookMiner.deploy(CREATE2_FACTORY, p.salt, p.initcode);
        require(deployed == p.hookAddress, "Deploy: address mismatch");
        if (initializePool) c.poolManager.initialize(p.key, p.sqrtPriceX96);
        vm.stopBroadcast();
        console2.log("Hook deployed:", deployed);
        console2.log("Pool initialized by this script:", initializePool);
    }
}

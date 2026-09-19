// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { console2 } from "forge-std/Script.sol";
import { DeploymentConfig } from "./DeploymentConfig.sol";

/// @notice Read-only deployment rehearsal; no private key or broadcast is needed.
/// @dev PRICE_E18 quotes whole TOKEN1 per whole TOKEN0 in the supplied address order.
///      INITIAL_SQRT_PRICE, when supplied, always uses sorted currency order.
contract PreflightScript is DeploymentConfig {
    /// @notice Preflight for deployHook(): no pool, price or private key required.
    function hookOnly() external view returns (Plan memory p) {
        p = prepareHook(readHookConfig());
        console2.log("Hook preflight OK; pool configuration is not required for deployment");
    }

    function run() external view returns (Plan memory p) {
        p = prepare(readConfig());
        console2.log("preflight OK; verify the human price against the market before deploying");
    }
}

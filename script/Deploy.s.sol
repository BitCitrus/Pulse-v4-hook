// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

import { PulseV4Hook } from "../src/PulseV4Hook.sol";
import { HookMiner } from "./HookMiner.sol";

/// @notice Deploy PulseV4Hook and create the associated Uniswap v4 pool.
///
/// Step 1: Deploy hook
/// Step 2: Initialize pool
///
/// Deploys with rewards disconnected. DeployRewards.s.sol can attach a prefunded token pool
/// later; neither script enables a reward budget or issues a protocol token.
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
///
/// Environment variables (see .env.example):
///   PRIVATE_KEY, POOL_MANAGER_ADDRESS, ADMIN_ADDRESS, MIN_FEE, MAX_FEE, FEE_CONSTANT_C,
///   BASE_TOKEN_IS_TOKEN0, TOKEN0_ADDRESS, TOKEN1_ADDRESS, TICK_SPACING, INITIAL_SQRT_PRICE
contract DeployScript is Script {
    /// @dev Required hook address flags for PulseV4Hook:
    ///      AFTER_INITIALIZE(1<<12) | BEFORE_SWAP(1<<7) | AFTER_SWAP(1<<6) | AFTER_SWAP_RETURNS_DELTA(1<<2)
    uint160 public constant REQUIRED_FLAGS = 0x10C4;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        // --- Read configuration ---
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        address admin_ = vm.envAddress("ADMIN_ADDRESS");
        bool baseIsToken0 = vm.envBool("BASE_TOKEN_IS_TOKEN0");
        uint256 minFeeRaw = vm.envUint("MIN_FEE");
        uint256 maxFeeRaw = vm.envUint("MAX_FEE");
        require(minFeeRaw <= maxFeeRaw && maxFeeRaw < 1_000_000, "Deploy: invalid fees");
        uint24 minFee_ = uint24(minFeeRaw);
        uint24 maxFee_ = uint24(maxFeeRaw);
        uint256 feeC = vm.envUint("FEE_CONSTANT_C");
        require(feeC <= type(uint128).max, "Deploy: invalid fee constant");
        address token0 = vm.envAddress("TOKEN0_ADDRESS");
        address token1 = vm.envAddress("TOKEN1_ADDRESS");
        uint256 spacingRaw = vm.envUint("TICK_SPACING");
        require(
            spacingRaw > 0 && spacingRaw <= uint24(TickMath.MAX_TICK_SPACING),
            "Deploy: invalid spacing"
        );
        int24 tickSpacing_ = int24(int256(spacingRaw));
        uint256 priceRaw = vm.envUint("INITIAL_SQRT_PRICE");
        require(
            priceRaw >= TickMath.MIN_SQRT_PRICE && priceRaw < TickMath.MAX_SQRT_PRICE,
            "Deploy: invalid price"
        );
        uint160 initSqrtPrice = uint160(priceRaw);
        require(token0 != token1, "Deploy: identical tokens");
        require(
            address(poolManager).code.length != 0 && admin_ != address(0),
            "Deploy: invalid manager/admin"
        );
        require(CREATE2_FACTORY.code.length != 0, "Deploy: CREATE2 factory missing");

        // Ensure token0 < token1 (required by Uniswap)
        if (token0 > token1) (token0, token1) = (token1, token0);

        // --- Mine hook address ---
        bytes memory creationCode = type(PulseV4Hook).creationCode;
        bytes memory constructorArgs =
            abi.encode(poolManager, admin_, baseIsToken0, minFee_, maxFee_, feeC);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, REQUIRED_FLAGS, creationCode, constructorArgs, 0);
        console2.log("=== Deployment Summary ===");
        console2.log("Mined hook address:", hookAddress);
        console2.log("CREATE2 salt (hex):", vm.toString(salt));

        vm.startBroadcast(deployerKey);

        // --- Step 1: Deploy hook ---
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        address deployed = HookMiner.deploy(CREATE2_FACTORY, salt, bytecode);
        require(deployed == hookAddress, "Deploy: address mismatch");

        PulseV4Hook hook = PulseV4Hook(payable(deployed));

        console2.log("");
        console2.log("--- Step 1: Hook Deployed ---");
        console2.log("PulseV4Hook:", address(hook));

        // --- Step 2: Create pool ---
        // Pool fee MUST be DYNAMIC_FEE_FLAG so hook can override it
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing_,
            hooks: hook
        });

        poolManager.initialize(key, initSqrtPrice);
        console2.log("");
        console2.log("--- Step 2: Pool Created ---");
        console2.log("Pool initialized. tickSpacing:", tickSpacing_);
        console2.log("Pool currency0:", token0);
        console2.log("Pool currency1:", token1);

        vm.stopBroadcast();
        console2.log("");
        console2.log("=== Deployment Complete ===");
    }
}

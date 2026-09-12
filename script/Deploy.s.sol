// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";

import { PulseV4Hook } from "../src/PulseV4Hook.sol";
import { VaultReceiptNFT } from "../src/VaultReceiptNFT.sol";
import { KeeperRewardToken } from "../src/KeeperRewardToken.sol";
import { HookMiner } from "./HookMiner.sol";

/// @notice Deploy PulseV4Hook, KeeperRewardToken, and create the associated Uniswap v4 pool.
///
/// Step 1: Deploy hook + NFT
/// Step 2: Deploy KeeperRewardToken (minted to deployer)
/// Step 3: Transfer reward tokens to hook for keeper incentives
/// Step 4: Admin sets reward token on hook
/// Step 5: Initialize pool
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

    /// @dev Keeper reward amount per call (1 token = 1e18)
    uint256 public constant KEEPER_REWARD_AMOUNT = 1e18;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // --- Read configuration ---
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        address admin_ = vm.envAddress("ADMIN_ADDRESS");
        bool baseIsToken0 = vm.envBool("BASE_TOKEN_IS_TOKEN0");
        uint24 minFee_ = uint24(vm.envUint("MIN_FEE"));
        uint24 maxFee_ = uint24(vm.envUint("MAX_FEE"));
        uint256 feeC = vm.envUint("FEE_CONSTANT_C");
        address token0 = vm.envAddress("TOKEN0_ADDRESS");
        address token1 = vm.envAddress("TOKEN1_ADDRESS");
        int24 tickSpacing_ = int24(int256(vm.envUint("TICK_SPACING")));
        uint160 initSqrtPrice = uint160(vm.envUint("INITIAL_SQRT_PRICE"));
        uint256 keeperRewardAmount = vm.envOr("KEEPER_REWARD_SUPPLY", uint256(1e6) * 1e18); // default 1M tokens

        // Ensure token0 < token1 (required by Uniswap)
        if (token0 > token1) (token0, token1) = (token1, token0);

        // --- Mine hook address ---
        bytes memory creationCode = type(PulseV4Hook).creationCode;
        bytes memory constructorArgs =
            abi.encode(poolManager, admin_, baseIsToken0, minFee_, maxFee_, feeC);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(deployer, REQUIRED_FLAGS, creationCode, constructorArgs, 0);
        console2.log("=== Deployment Summary ===");
        console2.log("Mined hook address:", hookAddress);
        console2.log("CREATE2 salt (hex):", vm.toString(salt));

        vm.startBroadcast(deployerKey);

        // --- Step 1: Deploy hook (includes VaultReceiptNFT) ---
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        address deployed;
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(deployed == hookAddress, "Deploy: address mismatch");

        PulseV4Hook hook = PulseV4Hook(deployed);
        VaultReceiptNFT nft = hook.RECEIPT_NFT();

        console2.log("");
        console2.log("--- Step 1: Hook + NFT Deployed ---");
        console2.log("PulseV4Hook:", address(hook));
        console2.log("VaultReceiptNFT:", address(nft));

        // --- Step 2: Deploy KeeperRewardToken (minted to deployer) ---
        KeeperRewardToken rewardToken = new KeeperRewardToken();
        console2.log("");
        console2.log("--- Step 2: KeeperRewardToken Deployed ---");
        console2.log("KeeperRewardToken:", address(rewardToken));
        console2.log("Deployer balance:", rewardToken.balanceOf(deployer));

        // --- Step 3: Transfer reward tokens to hook ---
        rewardToken.transfer(address(hook), keeperRewardAmount);
        console2.log("");
        console2.log("--- Step 3: Reward Tokens Funded ---");
        console2.log("Transferred to hook:", keeperRewardAmount);
        console2.log("Hook reward balance:", rewardToken.balanceOf(address(hook)));

        // --- Step 4: Admin sets reward token on hook ---
        // Note: The deployer is also the admin in this setup, so we call setKeeperRewardToken
        hook.setKeeperRewardToken(address(rewardToken));
        console2.log("");
        console2.log("--- Step 4: Reward Token Configured ---");
        console2.log("Hook reward token set to:", address(rewardToken));

        // --- Step 5: Create pool ---
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
        console2.log("--- Step 5: Pool Created ---");
        console2.log("Pool initialized. tickSpacing:", tickSpacing_);
        console2.log("Pool currency0:", token0);
        console2.log("Pool currency1:", token1);

        vm.stopBroadcast();
        console2.log("");
        console2.log("=== Deployment Complete ===");
    }
}

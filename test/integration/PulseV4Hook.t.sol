// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

// v4-core test utilities (installed via forge install uniswap/v4-core)
import { Deployers } from "v4-core/test/utils/Deployers.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TestERC20 } from "../TestToken.sol";

import { PulseV4Hook } from "../../src/PulseV4Hook.sol";
import { PulseV4HookErrors } from "../../src/lib/PulseV4HookErrors.sol";
import { KeeperRewardToken } from "../../src/KeeperRewardToken.sol";
import { HookMiner } from "../../script/HookMiner.sol";

/// @notice Integration tests for PulseV4Hook.
///         Inherits Deployers to get a fresh PoolManager and helper utilities.
contract PulseV4HookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // --- Hook address flags ---
    uint160 constant FLAGS = 0x10C4;

    // --- Constants ---
    int24 constant TICK_SPACING = 60;
    uint24 constant MIN_FEE = 500;
    uint24 constant MAX_FEE = 10_000;
    uint256 constant FEE_C = 3_000;
    uint256 constant FEE_REFRESH_COOLDOWN_SECONDS = 60;

    // --- State ---
    PulseV4Hook hook;
    PoolKey poolKey;
    TestERC20 token0;
    TestERC20 token1;
    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");

    function setUp() public {
        // Deploy PoolManager via Deployers helper
        deployFreshManager();

        // Deploy tokens (sorted)
        token0 = new TestERC20("Token0", "T0", 18, 1e24);
        token1 = new TestERC20("Token1", "T1", 18, 1e24);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        // Mine hook address
        bytes memory creationCode = type(PulseV4Hook).creationCode;
        bytes memory constructorArgs = abi.encode(
            manager,
            address(this),
            true,
            /*baseIsToken0*/
            MIN_FEE,
            MAX_FEE,
            FEE_C
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, creationCode, constructorArgs, 0);

        // Deploy hook at mined address via CREATE2
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        address deployed;
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        assertEq(deployed, hookAddr, "CREATE2 address mismatch");

        hook = PulseV4Hook(deployed);

        // Deploy KeeperRewardToken and fund the hook
        KeeperRewardToken rewardToken = new KeeperRewardToken();
        rewardToken.transfer(address(hook), 1e24); // Give hook plenty of reward tokens
        hook.setKeeperRewardToken(address(rewardToken));

        // Build pool poolKey (DYNAMIC_FEE_FLAG required for hook fee override)
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        // Initialize pool at 1:1 price
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Fund alice and keeper
        token0.mint(alice, 1e24);
        token1.mint(alice, 1e24);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    // =========================================================================
    // Basic pool setup
    // =========================================================================

    function test_hookInitialized() public view {
        assertEq(address(hook.POOL_MANAGER()), address(manager));
        assertFalse(hook.needsRebalance(poolKey.toId()));
        assertEq(hook.cachedFee(poolKey.toId()), MIN_FEE);
    }

    function test_receiptNFTDeployed() public view {
        assertFalse(address(hook.RECEIPT_NFT()) == address(0));
    }

    // =========================================================================
    // Vault deposit
    // =========================================================================

    function test_deposit_mintsNFT() public {
        vm.prank(alice);
        uint256 tokenId = hook.deposit(poolKey, 1e18, 1e18, alice);

        assertEq(hook.RECEIPT_NFT().ownerOf(tokenId), alice);
        assertGt(hook.RECEIPT_NFT().shares(tokenId), 0);
        assertGt(hook.totalVaultShares(poolKey.toId()), 0);
        assertGt(hook.vaultActiveLiquidity(poolKey.toId()), 0);
    }

    function test_deposit_revertsWhenPaused() public {
        hook.setPaused(true);
        vm.expectRevert(PulseV4HookErrors.ContractPaused.selector);
        vm.prank(alice);
        hook.deposit(poolKey, 1e18, 1e18, alice);
    }

    function test_deposit_zeroAmountReverts() public {
        vm.expectRevert(PulseV4HookErrors.ZeroShares.selector);
        vm.prank(alice);
        hook.deposit(poolKey, 0, 0, alice);
    }

    function test_secondDeposit_sharesProportional() public {
        vm.prank(alice);
        uint256 id1 = hook.deposit(poolKey, 1e18, 1e18, alice);
        uint256 shares1 = hook.RECEIPT_NFT().shares(id1);

        vm.prank(alice);
        uint256 id2 = hook.deposit(poolKey, 1e18, 1e18, alice);
        uint256 shares2 = hook.RECEIPT_NFT().shares(id2);

        // Second deposit is roughly equal (same price, same range) — within 1%
        assertApproxEqRel(shares1, shares2, 0.01e18);
    }

    // =========================================================================
    // Vault withdraw
    // =========================================================================

    function test_withdraw_burnNFTAndReceiveTokens() public {
        vm.prank(alice);
        uint256 tokenId = hook.deposit(poolKey, 1e18, 1e18, alice);

        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);

        vm.prank(alice);
        hook.withdraw(poolKey, tokenId, alice);

        // Tokens returned (minus any trading fees/slippage)
        assertGt(token0.balanceOf(alice) + token1.balanceOf(alice), before0 + before1);
        // NFT burned - verify by checking balanceOf alice in NFT (should be 0)
        assertEq(hook.RECEIPT_NFT().balanceOf(alice), 0);
    }

    function test_withdraw_revertsIfNotOwner() public {
        vm.prank(alice);
        uint256 tokenId = hook.deposit(poolKey, 1e18, 1e18, alice);

        vm.expectRevert(PulseV4HookErrors.NotTokenOwner.selector);
        hook.withdraw(poolKey, tokenId, alice); // called by test contract, not alice
    }

    // =========================================================================
    // Fee mechanics
    // =========================================================================

    function test_pokeFee_updatesCache() public {
        // Ensure cooldown has passed
        skip(FEE_REFRESH_COOLDOWN_SECONDS + 1);

        vm.prank(keeper);
        hook.pokeFee(poolKey);

        // Fee refreshed (might equal minFee or maxFee depending on state)
        assertLe(hook.cachedFee(poolKey.toId()), MAX_FEE);
        assertGe(hook.cachedFee(poolKey.toId()), MIN_FEE);
        assertGt(hook.lastFeeRefreshTime(poolKey.toId()), 0);
    }

    function test_pokeFee_revertsIfTooSoon() public {
        skip(FEE_REFRESH_COOLDOWN_SECONDS + 1);
        vm.prank(keeper);
        hook.pokeFee(poolKey);

        vm.expectRevert(PulseV4HookErrors.FeeRefreshTooSoon.selector);
        vm.prank(keeper);
        hook.pokeFee(poolKey);
    }

    // =========================================================================
    // Rebalance flag
    // =========================================================================

    function test_needsRebalance_setAfterPriceMoves() public {
        // Deposit into vault
        vm.prank(alice);
        hook.deposit(poolKey, 1e18, 1e18, alice);

        // Initial state: no rebalance needed
        assertFalse(hook.needsRebalance(poolKey.toId()));

        // Do a large swap to move price out of the current tick
        // (This is a simplified check — actual swap requires router setup)
        // TODO: wire up a swap router and push price across tick boundary
    }

    function test_rebalance_noopWhenFresh() public {
        // rebalance() is a no-op when needsRebalance == false
        hook.rebalance(poolKey); // should not revert
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function test_setPaused_onlyAdmin() public {
        // Non-owner cannot pause
        vm.prank(alice);
        vm.expectRevert();
        hook.setPaused(true);

        // Owner can pause
        hook.setPaused(true);
        assertTrue(hook.paused());

        hook.setPaused(false);
        assertFalse(hook.paused());
    }

    // =========================================================================
    // Protocol revenue
    // =========================================================================

    function test_protocolRevenue_initiallyZero() public view {
        assertEq(hook.protocolRevenue0(poolKey.toId()), 0);
        assertEq(hook.protocolRevenue1(poolKey.toId()), 0);
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    function test_getFeeInfo_returnsValues() public view {
        (uint24 cached, uint24 computed) = hook.getFeeInfo(poolKey);
        assertGe(cached, MIN_FEE);
        assertGe(computed, MIN_FEE);
        assertLe(cached, MAX_FEE);
        assertLe(computed, MAX_FEE);
    }

    function test_getVaultInfo() public view {
        (, uint128 al, bool rn, uint256 ts,,) = hook.getVaultInfo(poolKey);
        // Initially all zero
        assertEq(al, 0);
        assertFalse(rn);
        assertEq(ts, 0);
    }
}

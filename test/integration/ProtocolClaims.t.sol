// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import { PulseV4HookErrors } from "../../src/lib/PulseV4HookErrors.sol";
import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";

contract ProtocolClaimsTest is PulseV4HookFixture {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using stdStorage for StdStorage;

    StdStorage private revenueStore;

    function setUp() public override {
        super.setUp();
        vm.txGasPrice(1 gwei);
        _addLiquidity(1e21);
    }

    function _accrueBothCurrencies() internal {
        vm.startPrank(trader);
        swap(poolKey, false, -1e16, "");
        swap(poolKey, true, -1e16, "");
        vm.stopPrank();
        assertGt(hook.protocolRevenue0(poolKey.toId()), 0);
        assertGt(hook.protocolRevenue1(poolKey.toId()), 0);
        _assertClaimRevenue(poolKey);
    }

    function test_accruesClaimsWithoutTransferringTokensToHook() public {
        // Fail any transfer to the Hook, while leaving trader/router settlement untouched.
        vm.mockCallRevert(
            address(token0),
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(hook)),
            "no transfer to hook"
        );
        vm.mockCallRevert(
            address(token1),
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, address(hook)),
            "no transfer to hook"
        );
        for (uint256 i; i < 5; i++) {
            _accrueBothCurrencies();
        }
        PoolId id = poolKey.toId();
        uint256 amount0 = hook.protocolRevenue0(id);
        uint256 amount1 = hook.protocolRevenue1(id);
        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);
        hook.withdrawProtocolRevenue(poolKey, alice);
        assertEq(token0.balanceOf(alice) - before0, amount0);
        assertEq(token1.balanceOf(alice) - before1, amount1);
        _assertClaimRevenue(poolKey);
        assertEq(hook.protocolRevenue0(id), 0);
        assertEq(hook.protocolRevenue1(id), 0);
    }

    function test_withdraw_onlyOwner() public {
        _accrueBothCurrencies();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        hook.withdrawProtocolRevenue(poolKey, alice);
        _assertClaimRevenue(poolKey);
    }

    function test_withdraw_rejectsZeroRecipient() public {
        _accrueBothCurrencies();
        vm.expectRevert(PulseV4HookErrors.InvalidRecipient.selector);
        hook.withdrawProtocolRevenue(poolKey, address(0));
        _assertClaimRevenue(poolKey);
    }

    function test_unlockCallback_rejectsForgedWithdrawal() public {
        _accrueBothCurrencies();
        bytes memory forged = abi.encode(
            poolKey.currency0,
            poolKey.currency1,
            alice,
            hook.protocolRevenue0(poolKey.toId()),
            hook.protocolRevenue1(poolKey.toId())
        );
        vm.prank(alice);
        vm.expectRevert(PulseV4HookErrors.NotPoolManager.selector);
        hook.unlockCallback(forged);
        _assertClaimRevenue(poolKey);
    }

    function test_secondTokenTransferFailure_restoresBothClaimsAndRevenue() public {
        _accrueBothCurrencies();
        PoolId id = poolKey.toId();
        uint256 amount0 = hook.protocolRevenue0(id);
        uint256 amount1 = hook.protocolRevenue1(id);
        uint256 before0 = token0.balanceOf(alice);
        uint256 before1 = token1.balanceOf(alice);
        vm.mockCallRevert(
            address(token1),
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, alice),
            "recipient rejected"
        );
        vm.expectRevert();
        hook.withdrawProtocolRevenue(poolKey, alice);
        assertEq(hook.protocolRevenue0(id), amount0);
        assertEq(hook.protocolRevenue1(id), amount1);
        assertEq(token0.balanceOf(alice), before0);
        assertEq(token1.balanceOf(alice), before1);
        _assertClaimRevenue(poolKey);

        vm.clearMockedCalls();
        hook.withdrawProtocolRevenue(poolKey, alice);
        assertEq(token0.balanceOf(alice) - before0, amount0);
        assertEq(token1.balanceOf(alice) - before1, amount1);
        _assertClaimRevenue(poolKey);
    }

    function test_withdrawAccumulatedRevenueAboveInt128Max() public {
        uint256 maxChunk = uint256(uint128(type(int128).max));
        uint256 amount = maxChunk + 7;
        token0.mint(address(this), amount);
        token0.approve(address(claimsRouter), amount);
        // Back the large balance with real deposits into PoolManager, then transfer claims.
        claimsRouter.deposit(poolKey.currency0, address(this), maxChunk);
        claimsRouter.deposit(poolKey.currency0, address(this), 7);
        manager.transfer(address(hook), poolKey.currency0.toId(), amount);
        // Simulate long-term per-pool accrual without requiring trillions of swaps.
        revenueStore.target(address(hook)).sig("protocolRevenue0(bytes32)")
            .with_key(PoolId.unwrap(poolKey.toId())).checked_write(amount);
        _assertClaimRevenue(poolKey);

        uint256 before0 = token0.balanceOf(alice);
        hook.withdrawProtocolRevenue(poolKey, alice);
        assertEq(token0.balanceOf(alice) - before0, amount);
        assertEq(hook.protocolRevenue0(poolKey.toId()), 0);
        _assertClaimRevenue(poolKey);
    }
}

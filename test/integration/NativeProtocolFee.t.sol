// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";

import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";
import { PulseV4Hook } from "../../src/PulseV4Hook.sol";

contract NativeProtocolFeeTest is PulseV4HookFixture {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    function setUp() public override {
        super.setUp();
        vm.txGasPrice(1 gwei);
        vm.deal(address(this), 100 ether);

        nativeKey = poolKey;
        nativeKey.currency0 = Currency.wrap(address(0));
        manager.initialize(nativeKey, SQRT_PRICE_1_1);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{ value: 10 ether }(
            nativeKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 10 ether, salt: 0
            }),
            ""
        );
    }

    function test_nativeOutputExactInput_collectsNativeFee() public {
        _swapAndCheck(false, true, true);
    }

    function test_nativeInputExactOutput_collectsNativeFee() public {
        _swapAndCheck(true, false, true);
    }

    function test_nativeInputExactInput_collectsTokenFee() public {
        _swapAndCheck(true, true, true);
    }

    function test_nativeOutputExactOutput_collectsTokenFee() public {
        _swapAndCheck(false, false, true);
    }

    function test_withdrawNativeAndTokenRevenue_clearsBothBalances() public {
        _swapAndCheck(false, true, true);
        _swapAndCheck(true, true, true);
        PoolId id = nativeKey.toId();
        uint256 nativeRevenue = hook.protocolRevenue0(id);
        uint256 tokenRevenue = hook.protocolRevenue1(id);
        uint256 recipientNativeBefore = alice.balance;
        uint256 recipientTokenBefore = token1.balanceOf(alice);

        hook.withdrawProtocolRevenue(nativeKey, alice);

        assertEq(alice.balance - recipientNativeBefore, nativeRevenue);
        assertEq(token1.balanceOf(alice) - recipientTokenBefore, tokenRevenue);
        assertEq(hook.protocolRevenue0(id), 0);
        assertEq(hook.protocolRevenue1(id), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token1.balanceOf(address(hook)), 0);
        _assertClaimRevenue(nativeKey);

        hook.withdrawProtocolRevenue(nativeKey, alice);
        assertEq(alice.balance - recipientNativeBefore, nativeRevenue);
        assertEq(token1.balanceOf(alice) - recipientTokenBefore, tokenRevenue);
    }

    function test_directNativeTransfer_isRejected() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(hook).call{ value: 1 ether }("");

        assertFalse(success);
        assertEq(alice.balance, 1 ether);
        assertEq(address(hook).balance, 0);
        assertEq(hook.protocolRevenue0(nativeKey.toId()), 0);
    }

    function test_rejectedNativeWithdrawal_restoresClaimsAndRevenue() public {
        _swapAndCheck(false, true, true);
        _swapAndCheck(true, true, true);
        PoolId id = nativeKey.toId();
        uint256 amount0 = hook.protocolRevenue0(id);
        uint256 amount1 = hook.protocolRevenue1(id);
        // The token contract has no receive function and cannot accept native currency.
        vm.expectRevert();
        hook.withdrawProtocolRevenue(nativeKey, address(token0));
        assertEq(hook.protocolRevenue0(id), amount0);
        assertEq(hook.protocolRevenue1(id), amount1);
        _assertClaimRevenue(nativeKey);
        hook.withdrawProtocolRevenue(nativeKey, alice);
        assertEq(hook.protocolRevenue0(id), 0);
        assertEq(hook.protocolRevenue1(id), 0);
        _assertClaimRevenue(nativeKey);
    }

    function test_nativeRecipientReentry_cannotWithdrawRevenueTwice() public {
        _swapAndCheck(false, true, true);
        _swapAndCheck(true, true, true);
        PoolId id = nativeKey.toId();
        uint256 amount0 = hook.protocolRevenue0(id);
        uint256 amount1 = hook.protocolRevenue1(id);
        ReenteringRevenueRecipient recipient = new ReenteringRevenueRecipient(hook, nativeKey);
        hook.transferOwnership(address(recipient));
        recipient.withdraw();
        assertTrue(recipient.reentered());
        assertEq(address(recipient).balance, amount0);
        assertEq(token1.balanceOf(address(recipient)), amount1);
        assertEq(hook.protocolRevenue0(id), 0);
        assertEq(hook.protocolRevenue1(id), 0);
        _assertClaimRevenue(nativeKey);
    }

    function test_paused_nativeFeePathsStillSettle() public {
        hook.setPaused(true);
        _swapAndCheck(false, true, false);
        _swapAndCheck(true, false, false);
    }

    function test_zeroBaseFee_nativeFeePathsStillSettle() public {
        vm.fee(0);
        _swapAndCheck(false, true, false);
        _swapAndCheck(true, false, false);
    }

    function _swapAndCheck(bool zeroForOne, bool exactInput, bool expectFee) internal {
        PoolId id = nativeKey.toId();
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = token1.balanceOf(address(this));
        uint256 revenue0Before = hook.protocolRevenue0(id);
        uint256 revenue1Before = hook.protocolRevenue1(id);
        int256 specified = exactInput ? -int256(0.01 ether) : int256(0.01 ether);

        BalanceDelta delta = zeroForOne && !exactInput
            ? swapNativeInput(nativeKey, true, specified, "", 1 ether)
            : swap(nativeKey, zeroForOne, specified, "");

        assertEq(int256(address(this).balance) - int256(nativeBefore), int256(delta.amount0()));
        assertEq(
            int256(token1.balanceOf(address(this))) - int256(tokenBefore),
            int256(delta.amount1())
        );
        int256 input = zeroForOne ? int256(delta.amount0()) : int256(delta.amount1());
        int256 output = zeroForOne ? int256(delta.amount1()) : int256(delta.amount0());
        assertLt(input, 0);
        assertGt(output, 0);
        assertEq(exactInput ? input : output, specified, "specified amount is preserved");

        bool feeInNative = zeroForOne != exactInput;
        uint256 fee0 = hook.protocolRevenue0(id) - revenue0Before;
        uint256 fee1 = hook.protocolRevenue1(id) - revenue1Before;
        uint256 fee = feeInNative ? fee0 : fee1;
        assertEq(feeInNative ? fee1 : fee0, 0, "only the unspecified currency pays a fee");
        if (expectFee) {
            assertGt(fee, 0);
            // At gasprice == basefee only the fixed 100 pips applies to the core swap's
            // unspecified amount, before deducting output fees or adding input fees.
            uint256 grossUnspecified = exactInput ? uint256(output) + fee : uint256(-input) - fee;
            assertEq(fee, grossUnspecified * 100 / 1_000_000);
        } else {
            assertEq(fee, 0);
        }
        _assertClaimRevenue(nativeKey);
    }
}

contract ReenteringRevenueRecipient {
    PulseV4Hook private immutable HOOK;
    PoolKey private pool;
    bool public reentered;

    constructor(PulseV4Hook hook_, PoolKey memory pool_) {
        HOOK = hook_;
        pool = pool_;
    }

    function withdraw() external {
        HOOK.withdrawProtocolRevenue(pool, address(this));
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            HOOK.withdrawProtocolRevenue(pool, address(this));
        }
    }
}

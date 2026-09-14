// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";
import { PulseV4Hook } from "../../src/PulseV4Hook.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import { HookMiner } from "../../script/HookMiner.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { LPFeeLibrary } from "v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";

/// @notice A token that refuses transfers to one blocked address, the way real permissioned
///         stablecoins do. USDC and USDT can both freeze an arbitrary account.
contract BlacklistingERC20 is IERC20Minimal {
    string public constant name = "Blacklist";
    string public constant symbol = "BL";
    uint8 public constant decimals = 18;
    address public immutable blocked;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(address blocked_) {
        blocked = blocked_;
        balanceOf[msg.sender] = 1e30;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blocked, "BLACKLISTED");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        external
        override
        returns (bool)
    {
        require(to != blocked, "BLACKLISTED");
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

    /// @notice Accruing the protocol fee as ERC-6909 claims means no token is moved during a swap.
    ///         A token that blacklists the hook therefore cannot brick trading in the pool — which
    ///         is exactly what a `take()`-based fee would have done, since `take` transfers the fee
    ///         out of the PoolManager to the hook on every single swap.
    contract BlacklistingTokenTest is PulseV4HookFixture {
        using PoolIdLibrary for PoolKey;

        function test_tokenThatBlacklistsTheHookCannotBrickSwaps() public {
            BlacklistingERC20 hostile = new BlacklistingERC20(address(hook));
            require(address(hostile) > address(token1), "need hostile as currency1");

            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(address(token1)),
                currency1: Currency.wrap(address(hostile)),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: TICK_SPACING,
                hooks: hook
            });
            manager.initialize(key, SQRT_PRICE_1_1);

            hostile.approve(address(modifyLiquidityRouter), type(uint256).max);
            token1.approve(address(modifyLiquidityRouter), type(uint256).max);
            modifyLiquidityRouter.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams(-6000, 6000, 1e21, 0), ""
            );

            hostile.transfer(trader, 1e24);
            vm.startPrank(trader);
            hostile.approve(address(swapRouter), type(uint256).max);
            token1.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();

            vm.fee(1 gwei);
            vm.txGasPrice(1 gwei);
            vm.roll(block.number + 1);

            // zeroForOne exact-in: the fee is charged on currency1 == the hostile token.
            vm.prank(trader);
            swapRouter.swap(
                key,
                IPoolManager.SwapParams(true, -1e16, TickMath.MIN_SQRT_PRICE + 1),
                PoolSwapTest.TestSettings(false, false),
                ""
            );

            uint256 accrued = hook.protocolRevenue1(key.toId());
            assertGt(accrued, 0, "fee must still accrue against a blacklisting token");
            assertEq(
                hostile.balanceOf(address(hook)), 0, "no token may move to the hook on a swap"
            );
            assertEq(
                manager.balanceOf(address(hook), uint256(uint160(address(hostile)))),
                accrued,
                "revenue is held as claims inside the manager"
            );

            // The claim is real: it is only unredeemable while the recipient is blocked, and the
            // owner can simply withdraw to an address the token does allow.
            vm.expectRevert();
            hook.withdrawProtocolRevenue(key, address(hook));
            hook.withdrawProtocolRevenue(key, alice);
            assertEq(hostile.balanceOf(alice), accrued, "withdrawal to an allowed address works");
            assertEq(hook.protocolRevenue1(key.toId()), 0);
        }
    }

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { RobinhoodForkFixture } from "../utils/RobinhoodForkFixture.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";

// Minimal ABI of the verified contracts deployed on Robinhood, not locally deployed mocks.
// Sources: https://developers.uniswap.org/docs/protocols/v4/deployments#robinhood-chain-4663
// The deployed router includes minHopPriceX36 in both single-swap parameter tuples.
interface IRobinhoodUniversalRouter {
    struct SingleSwapParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amount;
        uint128 limit;
        uint256 minHopPriceX36;
        bytes hookData;
    }
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
    function poolManager() external view returns (IPoolManager);
}

interface IRobinhoodPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function ownerOf(uint256 tokenId) external view returns (address);
    function poolManager() external view returns (IPoolManager);
}

interface IRobinhoodPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract RobinhoodPeripheryTest is RobinhoodForkFixture {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IRobinhoodUniversalRouter constant ROUTER = IRobinhoodUniversalRouter(
        address(bytes20(hex"8876789976decbfcbbbe364623c63652db8c0904"))
    );
    IRobinhoodPositionManager constant POSITIONS = IRobinhoodPositionManager(
        address(bytes20(hex"58daec3116aae6d93017baaea7749052e8a04fa7"))
    );
    IRobinhoodPermit2 constant PERMIT2 =
        IRobinhoodPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    uint256 tokenId;
    uint256 routerNativeBefore;
    uint256 routerTokenBefore;
    uint256 positionNativeBefore;
    uint256 positionTokenBefore;

    function setUp() public override {
        super.setUp();
        assertGt(address(ROUTER).code.length, 0);
        assertGt(address(POSITIONS).code.length, 0);
        assertGt(address(PERMIT2).code.length, 0);
        assertEq(address(ROUTER.poolManager()), address(MANAGER));
        assertEq(address(POSITIONS.poolManager()), address(MANAGER));
        routerNativeBefore = address(ROUTER).balance;
        routerTokenBefore = USDG.balanceOf(address(ROUTER));
        positionNativeBefore = address(POSITIONS).balance;
        positionTokenBefore = USDG.balanceOf(address(POSITIONS));
        // Public periphery contracts should be empty before and after the tested flow.
        assertEq(
            routerNativeBefore + routerTokenBefore + positionNativeBefore + positionTokenBefore,
            0
        );
        USDG.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(
            address(USDG), address(ROUTER), type(uint160).max, uint48(block.timestamp + 1 days)
        );
        PERMIT2.approve(
            address(USDG),
            address(POSITIONS),
            type(uint160).max,
            uint48(block.timestamp + 1 days)
        );
        tokenId = POSITIONS.nextTokenId();
        _addLiquidity(true);
        assertEq(POSITIONS.ownerOf(tokenId), address(this));
        assertEq(POSITIONS.getPositionLiquidity(tokenId), LIQUIDITY);
        _assertNoResidualFunds();
    }

    function test_officialRoutersSwapWithdrawAndBurnPosition() public {
        _addLiquidity(false);
        assertEq(POSITIONS.getPositionLiquidity(tokenId), LIQUIDITY * 2);
        _swapAndCheck(true, true, 0.01 ether);
        _swapAndCheck(false, true, 30e6);
        _swapAndCheck(true, false, 30e6);
        _swapAndCheck(false, false, 0.01 ether);

        PoolId id = key.toId();
        uint256 revenue0 = hook.protocolRevenue0(id);
        uint256 revenue1 = hook.protocolRevenue1(id);
        address recipient = makeAddr("official-router-revenue");
        hook.withdrawProtocolRevenue(key, recipient);
        assertEq(recipient.balance, revenue0);
        assertEq(USDG.balanceOf(recipient), revenue1);
        assertGt(revenue0, 0);
        assertGt(revenue1, 0);
        assertEq(hook.protocolRevenue0(id), 0);
        assertEq(hook.protocolRevenue1(id), 0);
        _assertClaims();

        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = USDG.balanceOf(address(this));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(1), uint128(1), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        // BURN_POSITION removes all remaining liquidity; TAKE_PAIR returns assets and LP fees.
        POSITIONS.modifyLiquidities(abi.encode(hex"0311", params), block.timestamp + 1);
        assertGt(address(this).balance, nativeBefore);
        assertGt(USDG.balanceOf(address(this)), tokenBefore);
        (uint128 remaining,,) =
            MANAGER.getPositionInfo(id, address(POSITIONS), LOWER, UPPER, bytes32(tokenId));
        assertEq(remaining, 0);
        vm.expectRevert();
        POSITIONS.ownerOf(tokenId);
        _assertNoResidualFunds();
    }

    function test_exactInputSlippageIncludesHookFeeAndRollsBack() public {
        _assertSlippageRollback(true);
    }

    function test_exactOutputSlippageIncludesHookFeeAndRollsBack() public {
        _assertSlippageRollback(false);
    }

    function _addLiquidity(bool mint) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = mint
            ? abi.encode(
                key,
                LOWER,
                UPPER,
                LIQUIDITY,
                uint128(10 ether),
                uint128(100_000e6),
                address(this),
                bytes("")
            )
            : abi.encode(tokenId, LIQUIDITY, uint128(10 ether), uint128(100_000e6), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(Currency.wrap(address(0)), address(this));
        // MINT_POSITION / INCREASE_LIQUIDITY, SETTLE_PAIR (Permit2 for USDG), SWEEP ETH refund.
        POSITIONS.modifyLiquidities{ value: 10 ether }(
            abi.encode(mint ? hex"020d14" : hex"000d14", params), block.timestamp + 1
        );
    }

    function _swapAndCheck(bool zeroForOne, bool exactInput, uint128 amount) internal {
        vm.roll(block.number + 1);
        PoolId id = key.toId();
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = USDG.balanceOf(address(this));
        uint256 revenue0Before = hook.protocolRevenue0(id);
        uint256 revenue1Before = hook.protocolRevenue1(id);
        uint128 maxInput = zeroForOne ? uint128(1 ether) : uint128(3000e6);
        _executeSwap(zeroForOne, exactInput, amount, exactInput ? 1 : maxInput);
        int256 nativeDelta = int256(address(this).balance) - int256(nativeBefore);
        int256 tokenDelta = int256(USDG.balanceOf(address(this))) - int256(tokenBefore);
        int256 input = zeroForOne ? nativeDelta : tokenDelta;
        int256 output = zeroForOne ? tokenDelta : nativeDelta;
        assertLt(input, 0);
        assertGt(output, 0);
        assertEq(exactInput ? uint256(-input) : uint256(output), amount);
        bool feeInNative = zeroForOne != exactInput;
        uint256 fee0 = hook.protocolRevenue0(id) - revenue0Before;
        uint256 fee1 = hook.protocolRevenue1(id) - revenue1Before;
        uint256 fee = feeInNative ? fee0 : fee1;
        assertGt(fee, 0);
        assertEq(feeInNative ? fee1 : fee0, 0);
        uint256 gross = exactInput ? uint256(output) + fee : uint256(-input) - fee;
        assertEq(fee, gross * 100 / 1_000_000);
        _assertClaims();
        _assertNoResidualFunds();
    }

    function _executeSwap(bool zeroForOne, bool exactInput, uint128 amount, uint128 limit)
        internal
    {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IRobinhoodUniversalRouter.SingleSwapParams(key, zeroForOne, amount, limit, 0, "")
        );
        params[1] = abi.encode(
            zeroForOne ? key.currency0 : key.currency1, uint256(exactInput ? amount : limit)
        );
        params[2] = abi.encode(
            zeroForOne ? key.currency1 : key.currency0, uint256(exactInput ? limit : amount)
        );
        bytes[] memory inputs = new bytes[](2);
        // SWAP_EXACT_IN_SINGLE / SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL.
        inputs[0] = abi.encode(exactInput ? hex"060c0f" : hex"080c0f", params);
        inputs[1] = abi.encode(address(0), address(this), uint256(0));
        uint256 value = zeroForOne ? (exactInput ? amount : limit) : 0;
        // Universal Router: V4_SWAP, then SWEEP unused native input back to the caller.
        ROUTER.execute{ value: value }(hex"1004", inputs, block.timestamp + 1);
    }

    function _assertSlippageRollback(bool exactInput) internal {
        // Quote the same state with collection paused, then demand that fee-free result with
        // collection enabled. Only the additional hook fee makes these limits fail.
        uint256 snapshot = vm.snapshotState();
        hook.setPaused(true);
        uint256 nativeBefore = address(this).balance;
        uint256 tokenBefore = USDG.balanceOf(address(this));
        uint128 amount = exactInput ? uint128(0.01 ether) : uint128(30e6);
        _executeSwap(true, exactInput, amount, exactInput ? 1 : uint128(1 ether));
        uint128 feeFreeLimit = uint128(
            exactInput
                ? USDG.balanceOf(address(this)) - tokenBefore
                : nativeBefore - address(this).balance
        );
        assertTrue(vm.revertToState(snapshot));
        PoolId id = key.toId();
        (uint160 priceBefore,,,) = MANAGER.getSlot0(id);
        bytes4 errorSelector = exactInput
            ? bytes4(keccak256("V4TooLittleReceived(uint256,uint256)"))
            : bytes4(keccak256("V4TooMuchRequested(uint256,uint256)"));
        vm.expectPartialRevert(errorSelector);
        _executeSwap(true, exactInput, amount, feeFreeLimit);
        (uint160 priceAfter,,,) = MANAGER.getSlot0(id);
        assertEq(priceAfter, priceBefore);
        assertEq(address(this).balance, nativeBefore);
        assertEq(USDG.balanceOf(address(this)), tokenBefore);
        assertEq(hook.protocolRevenue0(id), 0);
        assertEq(hook.protocolRevenue1(id), 0);
        assertEq(hook.globalVolume(id), 0);
        _assertClaims();
        _assertNoResidualFunds();
    }

    function _assertNoResidualFunds() internal view {
        assertEq(address(ROUTER).balance, routerNativeBefore);
        assertEq(USDG.balanceOf(address(ROUTER)), routerTokenBefore);
        assertEq(address(POSITIONS).balance, positionNativeBefore);
        assertEq(USDG.balanceOf(address(POSITIONS)), positionTokenBefore);
    }
}

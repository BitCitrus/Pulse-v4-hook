// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Vm } from "forge-std/Vm.sol";
import { PulseV4HookFixture } from "../utils/PulseV4HookFixture.sol";
import { PulseV4Hook } from "../../src/PulseV4Hook.sol";
import { HookMiner } from "../../script/HookMiner.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";

contract ReviewExpectedBehaviorTest is PulseV4HookFixture {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    function test_review_expectedSwapAccountingWithToken0Base() public {
        _checkSwapModes(true);
    }

    function test_review_expectedSwapAccountingWithToken1Base() public {
        bytes memory args = abi.encode(manager, address(this), false, MIN_FEE, MAX_FEE, FEE_C);
        (, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(PulseV4Hook).creationCode, args, 0);
        hook = new PulseV4Hook{ salt: salt }(
            manager, address(this), false, MIN_FEE, MAX_FEE, FEE_C
        );
        poolKey.hooks = hook;
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        vm.startPrank(alice);
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        vm.stopPrank();
        _checkSwapModes(false);
    }

    function _checkSwapModes(bool baseIsToken0) internal {
        vm.txGasPrice(1 gwei);
        _addLiquidity(1e21);
        for (uint256 i; i < 4; i++) {
            uint256 snapshot = vm.snapshotState();
            bool zeroForOne = i & 1 == 0;
            bool exactInput = i & 2 == 0;
            uint256 before0 = token0.balanceOf(trader);
            uint256 before1 = token1.balanceOf(trader);
            vm.recordLogs();
            vm.prank(trader);
            BalanceDelta userDelta =
                swap(poolKey, zeroForOne, exactInput ? -int256(1e14) : int256(1e14), "");
            assertEq(
                int256(token0.balanceOf(trader)) - int256(before0), int256(userDelta.amount0())
            );
            assertEq(
                int256(token1.balanceOf(trader)) - int256(before1), int256(userDelta.amount1())
            );
            this.checkRecordedSwap(
                vm.getRecordedLogs(),
                userDelta,
                baseIsToken0,
                exactInput ? !zeroForOne : zeroForOne
            );
            assertTrue(vm.revertToState(snapshot));
        }
    }

    // Separate test call frame keeps the non-memory-safe inherited fixture from causing
    // a via-IR compiler stack overflow when these event assertions are inlined into a loop.
    function checkRecordedSwap(
        Vm.Log[] calldata logs,
        BalanceDelta userDelta,
        bool baseIsToken0,
        bool chargedIn0
    ) external view {
        PoolId id = poolKey.toId();
        uint256 matchingEvents;
        for (uint256 j; j < logs.length; j++) {
            if (
                logs[j].emitter != address(manager) || logs[j].topics.length < 2
                    || logs[j].topics[0]
                        != keccak256(
                            "Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"
                        )
            ) continue;
            if (logs[j].topics[1] != PoolId.unwrap(id)) continue;
            (int128 pool0, int128 pool1,,,,) =
                abi.decode(logs[j].data, (int128, int128, uint160, uint128, int24, uint24));
            int256 baseAmount = baseIsToken0 ? int256(pool0) : int256(pool1);
            assertEq(hook.globalVolume(id), uint256(baseAmount < 0 ? -baseAmount : baseAmount));
            int256 unspecified = chargedIn0 ? int256(pool0) : int256(pool1);
            uint256 fee = uint256(unspecified < 0 ? -unspecified : unspecified) * 200 / 1_000_000;
            assertGt(fee, 0);
            assertEq(hook.protocolRevenue0(id), chargedIn0 ? fee : 0);
            assertEq(hook.protocolRevenue1(id), chargedIn0 ? 0 : fee);
            assertEq(
                int256(userDelta.amount0()),
                int256(pool0) - (chargedIn0 ? int256(fee) : int256(0))
            );
            assertEq(
                int256(userDelta.amount1()),
                int256(pool1) - (chargedIn0 ? int256(0) : int256(fee))
            );
            _assertClaimRevenue(poolKey);
            matchingEvents++;
        }
        assertEq(matchingEvents, 1, "exactly one real swap event for the tested pool required");
    }
}

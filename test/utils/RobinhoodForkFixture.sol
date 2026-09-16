// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PulseV4Hook } from "../../src/PulseV4Hook.sol";
import { DeployScript } from "../../script/Deploy.s.sol";
import { PreflightScript } from "../../script/Preflight.s.sol";
import { DeploymentConfig, IERC20Decimals } from "../../script/DeploymentConfig.sol";

/// @dev Fork state is pinned and all funding is simulated. Foundry does not emulate ArbOS;
///      block.number is advanced explicitly and gasprice is set to the observed basefee.
abstract contract RobinhoodForkFixture is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    uint256 constant LIQUIDITY = 1e14;
    int24 constant LOWER = -300_000;
    int24 constant UPPER = -90_000;

    PulseV4Hook hook;
    PoolKey key;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        // The public RPC prunes old state. Pin a block with an archive RPC for reproduction;
        // otherwise use its current state and record the selected block in the test output.
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        emit log_named_uint("Fork header block number (local EVM)", block.number);
        assertEq(block.chainid, 4663, "wrong target chain");
        assertGt(block.basefee, 0);
        vm.txGasPrice(block.basefee);
        assertEq(IERC20Decimals(address(USDG)).decimals(), 6);

        // Public test key 1 and 3000 USDG/ETH are test fixtures, never production settings.
        vm.deal(vm.addr(1), 100 ether);
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("POOL_MANAGER_ADDRESS", vm.toString(address(MANAGER)));
        vm.setEnv("ADMIN_ADDRESS", vm.toString(address(this)));
        vm.setEnv("TOKEN0_ADDRESS", vm.toString(address(0)));
        vm.setEnv("TOKEN1_ADDRESS", vm.toString(address(USDG)));
        vm.setEnv("TICK_SPACING", "30");
        vm.setEnv("MIN_FEE", "100");
        vm.setEnv("MAX_FEE", "3000");
        vm.setEnv("FEE_CONSTANT_C", "300");
        vm.setEnv("BASE_TOKEN_IS_TOKEN0", "true");
        vm.setEnv("INITIAL_SQRT_PRICE", "");
        vm.setEnv("PRICE_E18", "3000000000000000000000");
        DeploymentConfig.Plan memory predicted = new PreflightScript().run();
        DeploymentConfig.Plan memory deployed = new DeployScript().run();
        assertEq(deployed.hookAddress, predicted.hookAddress);
        assertEq(deployed.salt, predicted.salt);
        assertEq(deployed.sqrtPriceX96, predicted.sqrtPriceX96);
        assertEq(PoolId.unwrap(deployed.key.toId()), PoolId.unwrap(predicted.key.toId()));
        hook = PulseV4Hook(payable(deployed.hookAddress));
        key = deployed.key;
        assertEq(hook.owner(), address(this));
        assertEq(uint160(address(hook)) & 0x3fff, 0x10c4);
        (uint160 actualPrice,,,) = MANAGER.getSlot0(key.toId());
        assertEq(actualPrice, predicted.sqrtPriceX96);
        assertTrue(hook.initialized(key.toId()));
        vm.deal(address(this), 100 ether);
        deal(address(USDG), address(this), 1_000_000e6);
    }

    function _assertClaims() internal view {
        PoolId id = key.toId();
        assertEq(MANAGER.balanceOf(address(hook), 0), hook.protocolRevenue0(id));
        assertEq(
            MANAGER.balanceOf(address(hook), uint160(address(USDG))), hook.protocolRevenue1(id)
        );
        assertEq(address(hook).balance, 0);
        assertEq(USDG.balanceOf(address(hook)), 0);
    }

    receive() external payable { }
}

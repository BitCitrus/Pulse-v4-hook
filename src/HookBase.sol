// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PulseV4HookErrors } from "./lib/PulseV4HookErrors.sol";

/// @notice Shared state for the hook: the pool manager reference, per-pool initialisation, the
///         revenue kill-switch, and protocol revenue accrued per pool.
/// @dev This contract custodies no user funds. Protocol revenue is held as ERC-6909 claims
///      on PoolManager, attributed to individual pools in protocolRevenue0/1.
abstract contract HookBase {
    IPoolManager public immutable POOL_MANAGER;

    /// @notice When true the hook stops charging its protocol fee. It deliberately does NOT
    ///         stop swaps: reverting a swap callback would brick the whole pool for ordinary
    ///         traders and plain Uniswap LPs who have nothing to do with this hook's revenue.
    bool public paused;

    mapping(PoolId => bool) public initialized;
    mapping(PoolId => uint256) public protocolRevenue0;
    mapping(PoolId => uint256) public protocolRevenue1;
}

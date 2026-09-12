// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PulseV4HookErrors
/// @notice Error definitions for PulseV4Hook and related contracts.
library PulseV4HookErrors {
    error NotAdmin();
    error NotPoolManager();
    error NotTokenOwner();
    error AlreadyInitialized();
    error NotInitialized();
    error ContractPaused();
    error WrongPool();
    error RebalanceFailed();
    error ZeroShares();
    error FeeRefreshTooSoon();
    error InsufficientInventory();
}

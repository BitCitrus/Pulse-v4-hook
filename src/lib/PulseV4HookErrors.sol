// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PulseV4HookErrors
/// @notice Error definitions for PulseV4Hook and related contracts.
library PulseV4HookErrors {
    error NotPoolManager();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidRecipient();
    error InvalidPoolManager();
    error InvalidFeeParameters();
    error DynamicFeeRequired();
}

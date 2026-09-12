// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PulseV4HookEvents
/// @notice Event definitions for PulseV4Hook and related contracts.
library PulseV4HookEvents {
    event NeedsRebalanceSet(int24 oldTick, int24 newTick);
    event VaultDeposit(
        address indexed depositor,
        uint256 indexed tokenId,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );
    event VaultWithdraw(
        address indexed withdrawer,
        uint256 indexed tokenId,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );
    event VaultRebalanced(
        address indexed keeper, int24 newTickLower, uint128 newLiquidity
    );
    event ProtocolFeeCollected(bool isToken0, uint256 feeAmount);
    event VolumeUpdated(address indexed keeper, uint128 volumeAmount);
    event FeeRefreshed(address indexed keeper, uint24 newFee);
    event Paused(bool paused);
}

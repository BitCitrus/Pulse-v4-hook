// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "v4-core/src/types/PoolId.sol";

library PulseV4HookEvents {
    event ProtocolFeeCollected(PoolId indexed poolId, bool isToken0, uint256 feeAmount);
    event VolumeUpdated(PoolId indexed poolId, int24 indexed tick, uint128 volumeAmount);
    event FeeRefreshed(PoolId indexed poolId, uint24 newFee);
    event Paused(bool paused);
    event ProtocolRevenueWithdrawn(
        PoolId indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1
    );
}

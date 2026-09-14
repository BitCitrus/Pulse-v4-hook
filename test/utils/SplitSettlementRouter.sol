// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";

/// @dev Core can produce -2^127 deltas, but each settle payment must be <= int128.max.
///      Split settlement lets the extreme-delta regression complete a real transaction.
contract SplitSettlementRouter is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    IPoolManager immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params)
        external
        returns (BalanceDelta)
    {
        return abi.decode(manager.unlock(abi.encode(key, params, msg.sender)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, IPoolManager.SwapParams memory params, address payer) =
            abi.decode(data, (PoolKey, IPoolManager.SwapParams, address));
        BalanceDelta delta = manager.swap(key, params, "");
        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address payer) private {
        if (delta > 0) manager.take(currency, payer, uint128(delta));
        if (delta >= 0) return;
        uint256 amount = uint256(-int256(delta));
        while (amount > 0) {
            uint256 payment =
                amount > uint128(type(int128).max) ? uint128(type(int128).max) : amount;
            manager.sync(currency);
            require(
                IERC20Minimal(Currency.unwrap(currency))
                    .transferFrom(payer, address(manager), payment)
            );
            manager.settle();
            amount -= payment;
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/src/libraries/TransientStateLibrary.sol";

import { VaultReceiptNFT } from "./VaultReceiptNFT.sol";
import { TickLib } from "./lib/TickLib.sol";
import { LiquidityAmountsLib } from "./lib/LiquidityAmountsLib.sol";
import { PulseV4HookErrors } from "./lib/PulseV4HookErrors.sol";
import { PulseV4HookEvents } from "./lib/PulseV4HookEvents.sol";
import { HookConstants } from "./lib/HookConstants.sol";
import { Ownable } from "v4-core/lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { FeeModule } from "./FeeModule.sol";

/// @title PulseV4Hook
/// @notice Uniswap v4 hook with two intertwined features:
///
///         1. PULSEFEE — Dynamic LP fee driven by decayed local trading activity.
///            fee = clamp(MIN_FEE, MAX_FEE, L * C / localSum)
///            where L = global decayed volume, localSum = weighted sum over ±2 usable ticks.
///            Volume decays at 0.8× per hour (lazy, applied at access time).
///
///         2. NTICK — Hook-managed shared 1-tick vault that always provides liquidity
///            in the current usable tick space [floor(tick/spacing)*spacing, +spacing].
///            Strict deposit (rebalance first), lenient withdraw (proceed even if rebalance fails).
///
///         Extra 1bp protocol fee on every external user swap funds keeper incentives.
///         Internal rebalance swaps are exempt from fees and volume tracking via hookData sentinel.
///
/// @dev Required hook address flags (lower 14 bits):
///      AFTER_INITIALIZE (1<<12) | BEFORE_SWAP (1<<7) | AFTER_SWAP (1<<6) | AFTER_SWAP_RETURNS_DELTA (1<<2)
///      = 0x10C4
///      Deploy with CREATE2 using HookMiner to satisfy this constraint.
import { HookConstants } from "./lib/HookConstants.sol";

contract PulseV4Hook is IHooks, IUnlockCallback, Ownable, FeeModule {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    using HookConstants for *;

    // Unlock action type codes (first byte of unlock data)
    uint8 private constant ACTION_DEPOSIT = 1;
    uint8 private constant ACTION_WITHDRAW = 2;
    uint8 private constant ACTION_REBALANCE = 3;

    IPoolManager public immutable POOL_MANAGER;
    VaultReceiptNFT public immutable RECEIPT_NFT;

    /// @notice Keeper reward token contract (set by admin after deployment)
    IERC20Minimal public keeperRewardToken;

    /// @notice If true, volume is measured in token0; otherwise token1.
    bool public immutable BASE_TOKEN_IS_TOKEN0;

    // POOL STATES
    mapping(PoolId => bool) public initialized;

    // VAULT STATES
    mapping(PoolId => int24) public vaultTickLower; // lower tick of current active vault position
    mapping(PoolId => uint128) public vaultActiveLiquidity; // liquidity currently deployed by vault
    mapping(PoolId => bool) public needsRebalance; // true when vault is stale (price moved out of range)

    mapping(PoolId => uint256) public totalVaultShares;
    uint256 private _nextTokenId;

    // Track which pool each deposit belongs to (tokenId -> poolId)
    mapping(uint256 => PoolId) public depositPoolId;

    // Idle vault assets held as ERC20 in this contract (dust or post-rebalance remainder)
    mapping(PoolId => uint256) public idleToken0;
    mapping(PoolId => uint256) public idleToken1;


    // PROTOCOL REVENUE
    /// @notice 1bp fees collected (held as ERC20 in this contract's balance)
    mapping(PoolId => uint256) public protocolRevenue0;
    mapping(PoolId => uint256) public protocolRevenue1;

    // ADMIN
    bool public paused;

    modifier whenNotPaused() {
        if (paused) revert PulseV4HookErrors.ContractPaused();
        _;
    }

    //  EVENTS & ERRORS (using library)
    // Events are defined in PulseV4HookEvents library
    // Errors are defined in PulseV4HookErrors library

    constructor(
        IPoolManager _poolManager,
        address _admin,
        bool _baseTokenIsToken0,
        uint24 _minFee,
        uint24 _maxFee,
        uint256 _feeConstantC
    ) Ownable(_admin) {
        POOL_MANAGER = _poolManager;
        poolManager = _poolManager; // Initialize FeeModule's poolManager
        BASE_TOKEN_IS_TOKEN0 = _baseTokenIsToken0;
        MIN_FEE = _minFee;
        MAX_FEE = _maxFee;
        FEE_CONSTANT_C = _feeConstantC;
        RECEIPT_NFT = new VaultReceiptNFT(address(this));
    }


    // HOOK PERMISSIONS
    /// @notice Returns hook permission flags.
    ///         The hook's deployed address MUST have 0x10C4 set in its lower 14 bits.
    function getHookPermissions() public pure returns (HookConstants.Permissions memory) {
        return HookConstants.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =========================================================================
    //                         IHooks — CALLBACKS
    // =========================================================================

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Initialize pool state on pool creation.
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        returns (bytes4)
    {
        if (msg.sender != address(POOL_MANAGER)) {
            revert PulseV4HookErrors.NotPoolManager();
        }
        PoolId id = key.toId();
        if (initialized[id]) revert PulseV4HookErrors.AlreadyInitialized();
        initialized[id] = true;
        cachedFee[id] = MIN_FEE;
        lastFeeRefreshTime[id] = uint48(block.timestamp);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Override pool-wide LP fee with cachedFee.
    ///         Internal rebalance swaps receive zero fee (no-op return).
    ///         If cached fee is stale (>120s old), compute fresh fee on-the-fly.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(POOL_MANAGER)) {
            revert PulseV4HookErrors.NotPoolManager();
        }
        PoolId id = key.toId();
        if (!initialized[id]) revert PulseV4HookErrors.NotInitialized();

        // Internal rebalance: MIN_FEE to prevent fee manipulation, no hook delta
        if (_isInternalSwap(hookData)) {
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                MIN_FEE | HookConstants.OVERRIDE_FEE_FLAG
            );
        }

        // If cached fee is stale (>120s old), compute fresh on-the-fly
        uint24 fee = cachedFee[id];
        if (uint48(block.timestamp) > lastFeeRefreshTime[id] + HookConstants.FEE_STALE_THRESHOLD) {
            fee = refreshFee(key);
        }

        // Override LP fee with dynamic fee
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | HookConstants.OVERRIDE_FEE_FLAG
        );
    }

    /// @notice Collect 1bp protocol fee, update volume state, mark vault stale if needed.
    ///         Returns positive hookDeltaUnspecified = hook takes 1bp of unspecified (output) currency.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external whenNotPaused returns (bytes4, int128) {
        if (msg.sender != address(POOL_MANAGER)) {
            revert PulseV4HookErrors.NotPoolManager();
        }
        PoolId id = key.toId();
        if (!initialized[id]) revert PulseV4HookErrors.NotInitialized();

        // Skip for internal rebalance swaps
        if (_isInternalSwap(hookData)) {
            return (IHooks.afterSwap.selector, 0);
        }

        // --- 1bp Protocol Fee ---
        // Unspecified currency = output side (for exact-in) or input side (for exact-out)
        bool isExactIn = params.amountSpecified > 0;
        Currency unspecifiedCurrency;
        int128 unspecifiedDelta;

        if (isExactIn) {
            if (params.zeroForOne) {
                unspecifiedCurrency = key.currency1;
                unspecifiedDelta = delta.amount1();
            } else {
                unspecifiedCurrency = key.currency0;
                unspecifiedDelta = delta.amount0();
            }
        } else {
            if (params.zeroForOne) {
                unspecifiedCurrency = key.currency0;
                unspecifiedDelta = delta.amount0();
            } else {
                unspecifiedCurrency = key.currency1;
                unspecifiedDelta = delta.amount1();
            }
        }

        uint128 absUnspecified =
            unspecifiedDelta < 0 ? uint128(-unspecifiedDelta) : uint128(unspecifiedDelta);

        uint128 hookFee = uint128(uint256(absUnspecified) * HookConstants.HOOK_FEE_BPS / HookConstants.FEE_DENOMINATOR);

        if (hookFee > 0) {
            // Collect fee: pool manager transfers hookFee of unspecified currency to this hook.
            // Pattern from FeeTakingHook: take() first, then return positive hookDeltaUnspecified.
            POOL_MANAGER.take(unspecifiedCurrency, address(this), hookFee);

            if (unspecifiedCurrency == key.currency0) {
                protocolRevenue0[id] += hookFee;
            } else {
                protocolRevenue1[id] += hookFee;
            }
            emit PulseV4HookEvents.ProtocolFeeCollected(
                unspecifiedCurrency == key.currency0, hookFee
            );
        }

        // --- Volume Accounting ---
        uint128 volumeInBase = _computeVolumeInBase(delta);
        if (volumeInBase > 0) {
            super.updateVolume(key, volumeInBase);

            // Mark vault as stale if price moved out of active range
            (, int24 currentTick,,) = POOL_MANAGER.getSlot0(id);
            int24 usableTick = TickLib.toUsableTick(currentTick, key.tickSpacing);
            if (
                vaultActiveLiquidity[id] > 0 && !needsRebalance[id]
                    && usableTick != vaultTickLower[id]
            ) {
                needsRebalance[id] = true;
                emit PulseV4HookEvents.NeedsRebalanceSet(vaultTickLower[id], usableTick);
            }
        }

        // Return positive hookDeltaUnspecified: hook took 1bp from unspecified side
        return (IHooks.afterSwap.selector, hookFee > 0 ? int128(hookFee) : int128(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    // =========================================================================
    //                         IUnlockCallback
    // =========================================================================

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) {
            revert PulseV4HookErrors.NotPoolManager();
        }
        uint8 action = uint8(data[0]);
        bytes calldata payload = data[1:];

        if (action == ACTION_DEPOSIT) return _handleDeposit(payload);
        if (action == ACTION_WITHDRAW) return _handleWithdraw(payload);
        if (action == ACTION_REBALANCE) return _handleRebalance(payload);
        revert("PulseV4Hook: unknown action");
    }

    // =========================================================================
    //                         PUBLIC ENTRY POINTS
    // =========================================================================

    /// @notice Deposit into the 1-tick vault.
    ///         Caller must have approved this contract to spend amount0Max/amount1Max of each token.
    ///         Reverts if vault is stale and rebalance fails (strict deposit).
    /// @param amount0Max  Max token0 to contribute
    /// @param amount1Max  Max token1 to contribute
    /// @param key          Pool to deposit into
    /// @param amount0Max   Maximum amount of token0 to deposit
    /// @param amount1Max   Maximum amount of token1 to deposit
    /// @param recipient   Receives the vault receipt NFT
    /// @return tokenId    Minted receipt NFT ID
    function deposit(
        PoolKey calldata key,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient
    ) external whenNotPaused returns (uint256 tokenId) {
        PoolId id = key.toId();
        if (!initialized[id]) revert PulseV4HookErrors.NotInitialized();
        bytes memory result = POOL_MANAGER.unlock(
            abi.encodePacked(
                ACTION_DEPOSIT,
                abi.encode(id, key, msg.sender, amount0Max, amount1Max, recipient)
            )
        );
        return abi.decode(result, (uint256));
    }

    /// @notice Withdraw a vault position. Lenient: proceeds even if rebalance fails.
    /// @param key        Pool to withdraw from
    /// @param tokenId   Receipt NFT to burn (caller must own it)
    /// @param recipient Receives the withdrawn tokens
    function withdraw(PoolKey calldata key, uint256 tokenId, address recipient)
        external
        whenNotPaused
    {
        PoolId id = key.toId();
        if (!initialized[id]) revert PulseV4HookErrors.NotInitialized();
        if (RECEIPT_NFT.ownerOf(tokenId) != msg.sender) {
            revert PulseV4HookErrors.NotTokenOwner();
        }
        // Verify the token belongs to this pool
        if (PoolId.unwrap(depositPoolId[tokenId]) != PoolId.unwrap(id)) {
            revert PulseV4HookErrors.WrongPool();
        }
        POOL_MANAGER.unlock(
            abi.encodePacked(ACTION_WITHDRAW, abi.encode(id, key, tokenId, recipient))
        );
    }

    /// @notice Public rebalance entrypoint for keepers. Rewards caller on success.
    /// @param key Pool to rebalance
    function rebalance(PoolKey calldata key) external whenNotPaused {
        PoolId id = key.toId();
        if (!initialized[id]) revert PulseV4HookErrors.NotInitialized();
        if (!needsRebalance[id]) return;
        POOL_MANAGER.unlock(
            abi.encodePacked(ACTION_REBALANCE, abi.encode(id, key, msg.sender))
        );
    }

    /// @notice Keeper function: update volume for current tick ±7 range.
    ///         Any external party can call to update the volume state.
    /// @param key          Pool to update volume for
    /// @param volumeAmount Volume to add (in base token)
    function updateVolumeByKeeper(PoolKey calldata key, uint128 volumeAmount)
        external
        whenNotPaused
    {
        if (!initialized[key.toId()]) revert PulseV4HookErrors.NotInitialized();
        super.updateVolume(key, volumeAmount);
        _disperseKeeperReward(msg.sender);
        emit PulseV4HookEvents.VolumeUpdated(msg.sender, volumeAmount);
    }

    /// @notice Keeper function: refresh the cached dynamic fee. Rate-limited.
    /// @param key Pool to refresh fee for
    function pokeFee(PoolKey calldata key) external whenNotPaused {
        PoolId id = key.toId();
        if (!initialized[id]) revert PulseV4HookErrors.NotInitialized();
        if (uint48(block.timestamp) < lastFeeRefreshTime[id] + HookConstants.FEE_REFRESH_COOLDOWN) {
            revert PulseV4HookErrors.FeeRefreshTooSoon();
        }

        uint24 newFee = super.computeFee(key);
        cachedFee[id] = newFee;
        lastFeeRefreshTime[id] = uint48(block.timestamp);
        _disperseKeeperReward(msg.sender);
        emit PulseV4HookEvents.FeeRefreshed(msg.sender, newFee);
    }

    // =========================================================================
    //                               ADMIN
    // =========================================================================

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PulseV4HookEvents.Paused(_paused);
    }

    /// @notice Set the keeper reward token after deployment
    /// @param _rewardToken Address of the reward token contract
    function setKeeperRewardToken(address _rewardToken) external onlyOwner {
        if (_rewardToken == address(0)) revert("Invalid token");
        keeperRewardToken = IERC20Minimal(_rewardToken);
    }

    // =========================================================================
    //                           VIEW HELPERS
    // =========================================================================

    function getFeeInfo(PoolKey calldata key)
        external
        view
        returns (uint24 cached, uint24 computed)
    {
        computed = super.computeFee(key);
        return (cachedFee[key.toId()], computed);
    }

    function getVaultInfo(PoolKey calldata key)
        external
        view
        returns (
            int24 tickLower,
            uint128 activeLiquidity,
            bool rebalanceNeeded,
            uint256 totalShares_,
            uint256 idle0,
            uint256 idle1
        )
    {
        PoolId id = key.toId();
        return (
            vaultTickLower[id],
            vaultActiveLiquidity[id],
            needsRebalance[id],
            totalVaultShares[id],
            idleToken0[id],
            idleToken1[id]
        );
    }

    // =========================================================================
    //                      INTERNAL — UNLOCK HANDLERS
    // =========================================================================

    function _handleDeposit(bytes calldata payload) internal returns (bytes memory) {
        (
            PoolId id,
            PoolKey memory key,
            address depositor,
            uint256 amount0Max,
            uint256 amount1Max,
            address recipient
        ) = abi.decode(payload, (PoolId, PoolKey, address, uint256, uint256, address));

        // Strict: must rebalance before deposit
        if (needsRebalance[id]) {
            bool ok = _doRebalance(id, key, address(0));
            if (!ok) revert PulseV4HookErrors.RebalanceFailed();
        }

        // Current active range
        (, int24 currentTick,,) = POOL_MANAGER.getSlot0(id);
        int24 tickLower = TickLib.toUsableTick(currentTick, key.tickSpacing);
        int24 tickUpper = tickLower + key.tickSpacing;
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // Pull max amounts first (we need enough to cover any rounding differences)
        if (amount0Max > 0) _pullFrom(depositor, key.currency0, amount0Max);
        if (amount1Max > 0) _pullFrom(depositor, key.currency1, amount1Max);

        // Compute liquidity based on ACTUAL balances after pulling
        uint256 bal0 =
            IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 bal1 =
            IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));

        uint128 liquidity = LiquidityAmountsLib.getLiquidityForAmounts(
            sqrtPrice, sqrtPriceLower, sqrtPriceUpper, bal0, bal1
        );
        if (liquidity == 0) revert PulseV4HookErrors.ZeroShares();

        // Exact token amounts needed for this liquidity (should match what we have)
        (uint256 amount0, uint256 amount1) = LiquidityAmountsLib.getAmountsForLiquidity(
            sqrtPrice, sqrtPriceLower, sqrtPriceUpper, liquidity
        );

        // Add liquidity to vault range (uses hook data sentinel to suppress hook callbacks)
        bytes memory sentinel = abi.encode(HookConstants.INTERNAL_SWAP_SENTINEL);
        (BalanceDelta callerDelta,) = POOL_MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            sentinel
        );

        // Settle using callerDelta (not currencyDelta)
        _settleCallerDelta(key, callerDelta);

        // Update vault bookkeeping - add liquidity AFTER computing shares
        if (vaultActiveLiquidity[id] == 0) vaultTickLower[id] = tickLower;

        // Mint proportional shares (must use old vaultActiveLiquidity)
        uint256 sharesToMint = _computeNewShares(id, liquidity);
        totalVaultShares[id] += sharesToMint;
        vaultActiveLiquidity[id] += liquidity;

        uint256 tokenId = _nextTokenId++;
        depositPoolId[tokenId] = id;
        RECEIPT_NFT.mint(recipient, tokenId, sharesToMint);

        emit PulseV4HookEvents.VaultDeposit(
            depositor, tokenId, sharesToMint, amount0, amount1
        );
        return abi.encode(tokenId);
    }

    function _handleWithdraw(bytes calldata payload) internal returns (bytes memory) {
        (PoolId id, PoolKey memory key, uint256 tokenId, address recipient) =
            abi.decode(payload, (PoolId, PoolKey, uint256, address));

        uint256 userShares = RECEIPT_NFT.shares(tokenId);
        if (userShares == 0) revert PulseV4HookErrors.ZeroShares();
        uint256 totalShares_ = totalVaultShares[id];

        // Lenient rebalance attempt
        if (needsRebalance[id] && vaultActiveLiquidity[id] > 0) {
            _doRebalance(id, key, address(0)); // failure is acceptable for withdraw
        }

        // Proportional liquidity to remove
        uint128 liquidityToRemove =
            uint128(uint256(vaultActiveLiquidity[id]) * userShares / totalShares_);

        if (liquidityToRemove > 0) {
            bytes memory sentinel = abi.encode(HookConstants.INTERNAL_SWAP_SENTINEL);
            (BalanceDelta callerDelta,) = POOL_MANAGER.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: vaultTickLower[id],
                    tickUpper: vaultTickLower[id] + key.tickSpacing,
                    liquidityDelta: -int256(uint256(liquidityToRemove)),
                    salt: bytes32(0)
                }),
                sentinel
            );
            vaultActiveLiquidity[id] -= liquidityToRemove;

            // Take positive delta (fees earned) directly to recipient
            if (callerDelta.amount0() > 0) {
                POOL_MANAGER.take(
                    key.currency0, recipient, uint256(uint128(callerDelta.amount0()))
                );
            }
            if (callerDelta.amount1() > 0) {
                POOL_MANAGER.take(
                    key.currency1, recipient, uint256(uint128(callerDelta.amount1()))
                );
            }
        }

        // Proportional idle tokens (held as ERC20 in this contract)
        uint256 idleShare0 = idleToken0[id] * userShares / totalShares_;
        uint256 idleShare1 = idleToken1[id] * userShares / totalShares_;
        if (idleShare0 > 0) idleToken0[id] -= idleShare0;
        key.currency0.transfer(recipient, idleShare0);
        if (idleShare1 > 0) idleToken1[id] -= idleShare1;
        key.currency1.transfer(recipient, idleShare1);

        // Burn receipt
        // Note: callerDelta may be positive (fees) which were already taken to recipient above
        // idle tokens are transferred separately below
        totalVaultShares[id] -= userShares;
        RECEIPT_NFT.burn(tokenId);

        emit PulseV4HookEvents.VaultWithdraw(
            recipient, tokenId, userShares, idleShare0, idleShare1
        );
        return "";
    }

    function _handleRebalance(bytes calldata payload) internal returns (bytes memory) {
        (PoolId id, PoolKey memory key, address keeper) =
            abi.decode(payload, (PoolId, PoolKey, address));
        bool ok = _doRebalance(id, key, keeper);
        if (!ok) revert PulseV4HookErrors.RebalanceFailed();
        return "";
    }

    // =========================================================================
    //                        INTERNAL — REBALANCE
    // =========================================================================

    /// @dev Core rebalance logic. Called from within an active unlock callback.
    ///      1. Remove stale vault liquidity
    ///      2. Balance inventory for new tick range (internal swap if needed)
    ///      3. Add liquidity to new range
    ///      4. Settle net delta; excess becomes idle
    /// @return true on success
    function _doRebalance(PoolId id, PoolKey memory key, address keeper)
        internal
        returns (bool)
    {
        if (!needsRebalance[id]) return true;
        if (vaultActiveLiquidity[id] == 0) {
            needsRebalance[id] = false;
            return true;
        }

        (, int24 currentTick,,) = POOL_MANAGER.getSlot0(id);
        int24 newTickLower = TickLib.toUsableTick(currentTick, key.tickSpacing);
        int24 newTickUpper = newTickLower + key.tickSpacing;
        bytes memory sentinel = abi.encode(HookConstants.INTERNAL_SWAP_SENTINEL);

        // --- Step 1: Remove stale liquidity ---
        (BalanceDelta removeDelta,) = POOL_MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: vaultTickLower[id],
                tickUpper: vaultTickLower[id] + key.tickSpacing,
                liquidityDelta: -int256(uint256(vaultActiveLiquidity[id])),
                salt: bytes32(0)
            }),
            sentinel
        );

        // Current credits from pool manager (what pool owes us after removal + fees)
        // Positive callerDelta = pool owes us
        uint256 inv0 =
            removeDelta.amount0() > 0 ? uint256(uint128(removeDelta.amount0())) : 0;
        uint256 inv1 =
            removeDelta.amount1() > 0 ? uint256(uint128(removeDelta.amount1())) : 0;

        // Include any previously idle tokens
        inv0 += idleToken0[id];
        idleToken0[id] = 0;
        inv1 += idleToken1[id];
        idleToken1[id] = 0;

        // --- Step 2: Balance inventory for new range ---
        uint160 sqrtPrice = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(newTickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(newTickUpper);
        (inv0, inv1) =
            _balanceInventory(inv0, inv1, sqrtPrice, sqrtPriceLower, sqrtPriceUpper, key);

        // --- Step 3: Compute max liquidity and add ---
        uint128 newLiquidity = LiquidityAmountsLib.getLiquidityForAmounts(
            sqrtPrice, sqrtPriceLower, sqrtPriceUpper, inv0, inv1
        );

        if (newLiquidity == 0) {
            // Can't deploy: park everything as idle, take from pool
            _settleAllDeltas(id, key);
            // idleToken0[id] += inv0; // Not needed - _settleAllDeltas already handles it
            vaultActiveLiquidity[id] = 0;
            needsRebalance[id] = false;
            return true;
        }

        POOL_MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity)),
                salt: bytes32(0)
            }),
            sentinel
        );

        // --- Step 4: Settle net delta ---
        // After remove + swap + add, remaining positive delta = idle
        // Remaining negative delta = shouldn't happen (we reused exactly what we removed)
        (BalanceDelta addDelta,) = POOL_MANAGER.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: newTickLower,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(newLiquidity)),
                salt: bytes32(0)
            }),
            sentinel
        );

        // Positive delta = pool owes hook = idle
        if (addDelta.amount0() > 0) {
            idleToken0[id] = uint256(uint128(addDelta.amount0()));
            POOL_MANAGER.take(key.currency0, address(this), idleToken0[id]);
        } else if (addDelta.amount0() < 0) {
            revert PulseV4HookErrors.InsufficientInventory();
        }
        if (addDelta.amount1() > 0) {
            idleToken1[id] = uint256(uint128(addDelta.amount1()));
            POOL_MANAGER.take(key.currency1, address(this), idleToken1[id]);
        } else if (addDelta.amount1() < 0) {
            revert PulseV4HookErrors.InsufficientInventory();
        }

        // Update vault state
        vaultTickLower[id] = newTickLower;
        vaultActiveLiquidity[id] = newLiquidity;
        needsRebalance[id] = false;

        if (keeper != address(0)) _disperseKeeperReward(keeper);

        emit PulseV4HookEvents.VaultRebalanced(keeper, newTickLower, newLiquidity);
        return true;
    }

    /// @dev One-step inventory balancing: swap half the excess token to match new tick ratio.
    function _balanceInventory(
        uint256 inv0,
        uint256 inv1,
        uint160 sqrtPrice,
        uint160 sqrtPriceLower,
        uint160 sqrtPriceUpper,
        PoolKey memory key
    ) internal returns (uint256 new0, uint256 new1) {
        // Reference amounts for 1e12 units of liquidity to determine the required ratio
        (uint256 ref0, uint256 ref1) = LiquidityAmountsLib.getAmountsForLiquidity(
            sqrtPrice, sqrtPriceLower, sqrtPriceUpper, 1e12
        );

        if (ref0 == 0 && ref1 == 0) return (inv0, inv1);

        bool doSwap;
        bool zeroForOne;
        uint256 swapAmount;
        uint160 priceLimit;

        if (ref0 == 0) {
            // Entire range is token1 only — swap all inv0 to token1
            if (inv0 == 0) return (inv0, inv1);
            doSwap = true;
            zeroForOne = true;
            swapAmount = inv0;
            priceLimit = sqrtPriceLower + 1;
        } else if (ref1 == 0) {
            // Entire range is token0 only — swap all inv1 to token0
            if (inv1 == 0) return (inv0, inv1);
            doSwap = true;
            zeroForOne = false;
            swapAmount = inv1;
            priceLimit = sqrtPriceUpper - 1;
        } else {
            // Mixed: check which side has >5% excess
            uint256 liq0 = FullMath.mulDiv(inv0, 1e12, ref0);
            uint256 liq1 = FullMath.mulDiv(inv1, 1e12, ref1);
            if (liq0 > liq1 + liq1 / 20) {
                // Excess token0 — swap half excess
                uint256 excess0 = inv0 - FullMath.mulDiv(liq1, ref0, 1e12);
                swapAmount = excess0 / 2;
                if (swapAmount == 0) return (inv0, inv1);
                doSwap = true;
                zeroForOne = true;
                priceLimit = sqrtPriceLower + 1;
            } else if (liq1 > liq0 + liq0 / 20) {
                uint256 excess1 = inv1 - FullMath.mulDiv(liq0, ref1, 1e12);
                swapAmount = excess1 / 2;
                if (swapAmount == 0) return (inv0, inv1);
                doSwap = true;
                zeroForOne = false;
                priceLimit = sqrtPriceUpper - 1;
            }
        }

        if (!doSwap) return (inv0, inv1);

        // Internal swap (sentinel hookData: exempt from 1bp fee and volume tracking)
        BalanceDelta sd = POOL_MANAGER.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: priceLimit
            }),
            abi.encode(HookConstants.INTERNAL_SWAP_SENTINEL)
        );

        // sd is from pool's perspective (positive = pool received, negative = pool sent)
        // hook's credit change = -sd (hook paid what pool received, gained what pool sent)
        int256 s0 = int256(sd.amount0());
        int256 s1 = int256(sd.amount1());

        int256 new0Int = int256(inv0) - s0;
        int256 new1Int = int256(inv1) - s1;
        new0 = new0Int > 0 ? uint256(new0Int) : 0;
        new1 = new1Int > 0 ? uint256(new1Int) : 0;
    }

    // =========================================================================
    //                      INTERNAL — VOLUME / FEE
    // =========================================================================

    function _computeVolumeInBase(BalanceDelta delta) internal view returns (uint128) {
        int128 a = BASE_TOKEN_IS_TOKEN0 ? delta.amount0() : delta.amount1();
        return a < 0 ? uint128(-a) : uint128(a);
    }

    // INTERNAL — KEEPER REWARDS
    function _disperseKeeperReward(address keeper) internal {
        // Reward = 1 token per call, transferred from hook's balance
        keeperRewardToken.transfer(keeper, 1e18);
    }

    // INTERNAL — SETTLEMENT
    /// @dev Pull ERC20 tokens from `from` into this contract.
    function _pullFrom(address from, Currency currency, uint256 amount) internal {
        // Low-level transferFrom to avoid extra interface imports
        (bool ok, bytes memory ret) = Currency.unwrap(currency)
            .call(abi.encodeWithSelector(0x23b872dd, from, address(this), amount));
        require(
            ok && (ret.length == 0 || abi.decode(ret, (bool))),
            "PulseV4Hook: transferFrom failed"
        );
    }

    /// @dev Settle using callerDelta returned from modifyLiquidity (more reliable than currencyDelta)
    function _settleCallerDelta(PoolKey memory key, BalanceDelta callerDelta) internal {
        // Note: This function needs pool ID for idle token tracking, but currently
        // we don't track which pool idle tokens belong to when there's no active vault position
        // For now, we'll need a different approach - either pass poolId or handle differently
        // This is a limitation that needs addressing for proper multi-pool support
        int128 d0 = callerDelta.amount0();
        int128 d1 = callerDelta.amount1();

        if (d0 < 0) {
            uint256 amount = uint256(uint128(-d0));
            require(
                IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this))
                    >= amount,
                "Insufficient token0 balance for settle"
            );
            if (!key.currency0.isAddressZero()) {
                POOL_MANAGER.sync(key.currency0);
                key.currency0.transfer(address(POOL_MANAGER), amount);
            } else {
                POOL_MANAGER.settle{ value: amount }();
            }
            POOL_MANAGER.settle();
        }
        // Note: Positive deltas (fees earned) are not tracked per-pool in this function
        // This is acceptable because we're just settling the delta, not updating idle tracking

        if (d1 < 0) {
            uint256 amount = uint256(uint128(-d1));
            require(
                IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this))
                    >= amount,
                "Insufficient token1 balance for settle"
            );
            if (!key.currency1.isAddressZero()) {
                POOL_MANAGER.sync(key.currency1);
                key.currency1.transfer(address(POOL_MANAGER), amount);
            } else {
                POOL_MANAGER.settle{ value: amount }();
            }
            POOL_MANAGER.settle();
        }
    }

    /// @dev Legacy settlement using currencyDelta (kept for other uses)
    ///      Negative delta (we owe pool) → pay from hook's ERC20 balance.
    ///      v4 requires: sync() → transfer → settle()
    function _settleAllDeltas(PoolId id, PoolKey memory key) internal {
        int256 d0 = POOL_MANAGER.currencyDelta(address(this), key.currency0);
        int256 d1 = POOL_MANAGER.currencyDelta(address(this), key.currency1);

        if (d0 < 0) {
            // Hook owes pool: sync → transfer → settle
            uint256 amount0 = uint256(-d0);
            if (!key.currency0.isAddressZero()) {
                POOL_MANAGER.sync(key.currency0);
                key.currency0.transfer(address(POOL_MANAGER), amount0);
            } else {
                POOL_MANAGER.settle{ value: amount0 }();
            }
            POOL_MANAGER.settle();
        } else if (d0 > 0) {
            // Pool owes hook: take to self (e.g. feesAccrued on add)
            POOL_MANAGER.take(key.currency0, address(this), uint256(d0));
            idleToken0[id] += uint256(d0);
        }

        if (d1 < 0) {
            uint256 amount1 = uint256(-d1);
            if (!key.currency1.isAddressZero()) {
                POOL_MANAGER.sync(key.currency1);
                key.currency1.transfer(address(POOL_MANAGER), amount1);
            } else {
                POOL_MANAGER.settle{ value: amount1 }();
            }
            POOL_MANAGER.settle();
        } else if (d1 > 0) {
            POOL_MANAGER.take(key.currency1, address(this), uint256(d1));
            idleToken1[id] += uint256(d1);
        }
    }

    // INTERNAL — SHARE MATH
    function _computeNewShares(PoolId id, uint128 liquidity)
        internal
        view
        returns (uint256)
    {
        if (totalVaultShares[id] == 0 || vaultActiveLiquidity[id] == 0) {
            return uint256(liquidity); // first deposit: 1 share per unit liquidity
        }
        // Proportional: newShares = liquidity * totalShares / totalLiquidity
        return FullMath.mulDiv(
            uint256(liquidity), totalVaultShares[id], uint256(vaultActiveLiquidity[id])
        );
    }

    // INTERNAL — HELPERS
    function _isInternalSwap(bytes calldata hookData) internal pure returns (bool) {
        return
            hookData.length == 32
                && abi.decode(hookData, (bytes32)) == HookConstants.INTERNAL_SWAP_SENTINEL;
    }
}

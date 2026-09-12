# PulseV4Hook — Technical Specification

## 1. Hook Address Requirements

Required lower-14-bit flags (`address & 0x3FFF`):

| Flag | Bit | Value |
|------|-----|-------|
| AFTER_INITIALIZE | 12 | 0x1000 |
| BEFORE_SWAP | 7 | 0x0080 |
| AFTER_SWAP | 6 | 0x0040 |
| AFTER_SWAP_RETURNS_DELTA | 2 | 0x0004 |
| **Total** | | **0x10C4** |

Deploy with CREATE2 using `HookMiner.find()` to satisfy this constraint.

---

## 2. Storage Layout

### 2.1 Immutables (constructor)
| Variable | Type | Description |
|----------|------|-------------|
| `poolManager` | `IPoolManager` | Uniswap v4 pool manager |
| `receiptNFT` | `VaultReceiptNFT` | Deployed by constructor |
| `admin` | `address` | Can pause only |
| `baseTokenIsToken0` | `bool` | Volume measured in token0 or token1 |
| `minFee` | `uint24` | Floor LP fee (e.g. 500 = 0.05%) |
| `maxFee` | `uint24` | Ceiling LP fee (e.g. 10000 = 1%) |
| `feeConstantC` | `uint256` | Fee formula constant (e.g. 3000 = 0.3%) |

### 2.2 Pool state
| Variable | Type | Notes |
|----------|------|-------|
| `_poolKey` | `PoolKey` | Set in `afterInitialize`; single pool |
| `_poolId` | `PoolId` | Derived from poolKey |
| `_initialized` | `bool` | Guards double-init |

### 2.3 Fee state
| Variable | Type | Notes |
|----------|------|-------|
| `cachedFee` | `uint24` | Last computed fee; used in `beforeSwap` |
| `lastFeeRefreshTime` | `uint48` | Unix timestamp of last `pokeFee()` |

### 2.4 Volume state
| Variable | Type | Notes |
|----------|------|-------|
| `globalVolume` | `uint128` | L: global decayed volume |
| `globalVolumeTimestamp` | `uint48` | Last update time |
| `tickVolume[tick]` | `mapping(int24→uint128)` | L_tick per usable tick |
| `tickVolumeTimestamp[tick]` | `mapping(int24→uint48)` | Last update per tick |

### 2.5 Vault state
| Variable | Type | Notes |
|----------|------|-------|
| `vaultTickLower` | `int24` | Active vault position lower tick |
| `vaultActiveLiquidity` | `uint128` | Deployed liquidity |
| `needsRebalance` | `bool` | **Public** — keepers observe this |
| `totalVaultShares` | `uint256` | Total shares outstanding |
| `_nextTokenId` | `uint256` | Receipt NFT counter |
| `idleToken0/1` | `uint256` | ERC20 held in hook (dust/rebalance remainder) |

### 2.6 Protocol revenue
| Variable | Type | Notes |
|----------|------|-------|
| `protocolRevenue0/1` | `uint256` | 1bp fees accumulated (ERC20 in hook) |

---

## 3. Events

```solidity
VaultDeposit(address indexed depositor, uint256 indexed tokenId, uint256 shares, uint256 amount0, uint256 amount1)
VaultWithdraw(address indexed withdrawer, uint256 indexed tokenId, uint256 shares, uint256 amount0, uint256 amount1)
VaultRebalanced(address indexed keeper, int24 newTickLower, uint128 newLiquidity)
NeedsRebalanceSet(int24 oldTickLower, int24 newTickLower)
FeeRefreshed(address indexed keeper, uint24 newFee)
ProtocolFeeCollected(bool isToken0, uint128 amount)
Paused(bool state)
```

---

## 4. Errors

```solidity
NotAdmin()           NotPoolManager()      NotTokenOwner()
AlreadyInitialized() NotInitialized()      ContractPaused()
WrongPool()          RebalanceFailed()     ZeroShares()
FeeRefreshTooSoon()  InsufficientInventory()
```

---

## 5. Fee Formula

```
localSum = L_tick[t]*2 + L_tick[t-1] + L_tick[t+1] + L_tick[t-2] + L_tick[t+2]
rawFee   = L * C / localSum
fee      = clamp(minFee, maxFee, rawFee)
```

- **t** = `toUsableTick(currentTick, tickSpacing)`
- **L** = `globalVolume` after lazy decay
- **L_tick** = per-tick volume after lazy decay  
- **C** = `feeConstantC` (set at deployment, e.g. 3000)
- Decay: `0.8^n` where n = floor(elapsed_seconds / 3600)
- Volume units: absolute base-token amount of each external swap

---

## 6. Internal Swap Identification

Internal rebalance/deposit swaps pass a sentinel value in `hookData`:

```solidity
bytes32 constant INTERNAL_SWAP_SENTINEL =
    0x0101010101010101010101010101010101010101010101010101010101010101;

// Caller passes: abi.encode(INTERNAL_SWAP_SENTINEL)
// Hook checks:   hookData.length == 32 && abi.decode(hookData, bytes32) == INTERNAL_SWAP_SENTINEL
```

When detected, `beforeSwap` returns zero LP fee override and `afterSwap` skips all accounting.

---

## 7. Vault Rebalance Flow

Called from `rebalance()` (external keeper) or from deposit (strict).

1. `modifyLiquidity(key, {liquidityDelta: -vaultActiveLiquidity}, sentinel)` — remove stale position
2. Read `currencyDelta` → inventory = what pool owes us after removal
3. Call `_balanceInventory()` — single-step swap if >5% excess of one token
4. `modifyLiquidity(key, {liquidityDelta: +newLiquidity, newRange}, sentinel)` — add to current usable tick
5. Read final `currencyDelta`; positive remainder → `take()` to self as `idleToken`; negative → `revert InsufficientInventory`
6. `vaultTickLower = newTickLower`, `vaultActiveLiquidity = newLiquidity`, `needsRebalance = false`
7. Disperse 10% of `protocolRevenue` to keeper

---

## 8. Deposit / Withdraw Flow

### Deposit (strict)
1. `needsRebalance` → `_doRebalance(address(0))` must succeed
2. Compute `liquidity = getLiquidityForAmounts(sqrtP, lo, hi, amount0Max, amount1Max)`
3. `transferFrom(depositor, hook, exactAmount)` for each token
4. `modifyLiquidity(+liquidity)` → negative `currencyDelta`
5. `settleAllDeltas()` — pays pool from hook's ERC20, takes any feesAccrued as idle
6. Mint receipt NFT with `shares = liquidity * totalShares / totalLiquidity` (or `liquidity` if first)

### Withdraw (lenient)
1. Attempt `_doRebalance(address(0))` — failure OK
2. `modifyLiquidity(-proportionalLiquidity)` → positive `currencyDelta`
3. `take(currency, recipient, delta)` directly to recipient
4. `currency.transfer(recipient, idleShare)` from hook's ERC20
5. Burn receipt NFT, decrement `totalVaultShares`

---

## 9. Protocol Fee Collection

Charged via `afterSwap` `AFTER_SWAP_RETURNS_DELTA_FLAG`:

1. Compute `hookFee = |unspecifiedDelta| * 100 / 1_000_000` (1bp)
2. `poolManager.take(unspecifiedCurrency, address(this), hookFee)` — receive fee ERC20
3. Return `int128(hookFee)` from `afterSwap` — signals hook took 1bp from unspecified side
4. Accumulate to `protocolRevenue0` or `protocolRevenue1`

Keeper reward: 10% of protocolRevenue per `rebalance()` or `pokeFee()` call.

---

## 10. Trust Assumptions

- Pool manager is trusted; all callbacks validated via `msg.sender == address(poolManager)`
- Hook enforces single-pool use (`_initialized` flag + `_checkPool`)
- Admin powers limited to pause/unpause only
- All parameters immutable after deployment
- No oracle or external price feed dependency
- No ERC777 / callback tokens expected in vault (reentrancy guard not added; v4 lock protects)

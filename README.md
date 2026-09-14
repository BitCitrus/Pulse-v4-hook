# PulseFee Hook

**English** | [简体中文](README.zh-CN.md)

PulseFee is a **Uniswap v4 dynamic-fee hook**. It adjusts a pool's LP fee using the distribution of recent trading volume across price ticks. Volume concentrated near the current price generally produces a lower fee; volume concentrated elsewhere produces a higher fee.

The hook also collects a separate fee as project revenue. It supports ERC20/ERC20 and native-currency/ERC20 pools. LPs manage their positions through standard Uniswap v4 interfaces, while fee updates run automatically as part of swaps.

## Features

| Component | Behavior |
|---|---|
| Volume tracking | Each swap updates the pool's global volume and the usable tick bucket at the end of the swap, measured in the configured base token. |
| Dynamic LP fee | Uses five nearby tick buckets, with a weight of three for the center bucket. |
| Fee refresh | Starts at `MIN_FEE` on initialization, then recomputes on the first swap of each subsequent block. Later swaps in that block reuse the cached fee. |
| Revenue accounting | Accrues ERC-6909 claims inside PoolManager and records revenue separately for each pool and currency. |
| Revenue withdrawal | The owner redeems accrued claims; PoolManager transfers the underlying assets directly to the recipient. |
| Pause control | The owner can disable the additional hook fee while keeping LP fee calculation and swaps enabled. |

## Dynamic LP fee

Let `c` be the current usable tick, `s` the pool's `tickSpacing`, `V[t]` the decayed volume in tick bucket `t`, and `L` the decayed global volume:

```text
local = V[c-2s] + V[c-s] + 3*V[c] + V[c+s] + V[c+2s]

L == 0          -> MIN_FEE
L > 0, local=0  -> MAX_FEE
otherwise       -> clamp(floor(L * C / local), MIN_FEE, MAX_FEE)
```

Each swap contributes the absolute amount of the selected base token to two buckets: the global bucket and its final usable tick bucket. The usable tick is `floor(currentTick / tickSpacing) * tickSpacing`, including for negative ticks. A swap that crosses multiple ticks records its volume at the final bucket.

Volume halves at each elapsed UTC hour boundary. Updates and reads apply decay lazily; an elapsed interval of 90 hours or more explicitly returns zero. For example, volume recorded at 10:59 crosses its first decay boundary at 11:00. Stored volumes saturate at `uint128.max`.

The signal measures **relative concentration**. Scaling all volume equally leaves the ratio unchanged, apart from rounding, saturation and cutoff effects. When all recent volume is in the center bucket, the raw fee is `floor(C / 3)`.

### Example configuration

The defaults in [`.env.example`](.env.example) are:

| Parameter | Value | Meaning |
|---|---:|---|
| `MIN_FEE` | 100 pips | 1 bp / 0.01% LP fee floor |
| `MAX_FEE` | 3,000 pips | 30 bp / 0.30% LP fee ceiling |
| `FEE_CONSTANT_C` | 300 | Scales the dynamic fee formula |
| `TICK_SPACING` | 30 | Pool tick spacing, selected at pool creation |
| `BASE_TOKEN_IS_TOKEN0` | `true` | Measures volume in token0 after currencies are sorted by address |

One pip is one part per million; **100 pips = 1 bp = 0.01%**. With `C = 300`, volume entirely in the center bucket gives `300 / 3 = 100` pips. The fee bounds, `C` and base-token selection are immutable per hook deployment and shared by its pools.

## Additional hook fee

This charge is separate from both the LP fee and Uniswap core's own protocol fee. When collection is enabled and `block.basefee > 0`:

```text
hookFeePips = 100 + min(3000, floor(100 * tx.gasprice / block.basefee))
hookFee     = floor(abs(unspecifiedDelta) * hookFeePips / 1_000_000)
```

The fee applies to the output currency for exact-input swaps and to the input currency for exact-output swaps. At `tx.gasprice == block.basefee`, it is **2 bp**; the maximum is **31 bp / 0.31%**. Pausing collection or having `block.basefee == 0` makes this additional fee zero.

Quote simulation and transaction execution need to account for the gas price dependency, since different transaction environments can produce different additional fees.

## Revenue custody and permissions

During a swap, the hook calls `PoolManager.mint` to create ERC-6909 claims. The underlying assets remain inside PoolManager, and the hook's returned delta charges the swapper. For each currency, the hook's claim balance backs its combined revenue accounting across pools.

To withdraw revenue, the owner calls `withdrawProtocolRevenue`. The hook clears the pool's revenue accounting, opens a PoolManager unlock callback, burns the claims and transfers the underlying assets directly to the recipient. A failed withdrawal reverts the associated accounting and claim changes.

Fee collection therefore needs no token transfer to the hook during a swap. Normal swap settlement and revenue withdrawals still depend on token transfer behavior. [BlacklistingToken.t.sol](test/integration/BlacklistingToken.t.sol) covers a token that rejects transfers specifically to the hook while claim-based fee collection continues to work.

The owner can pause or resume the additional fee, withdraw accrued revenue, and transfer or renounce ownership. The hook has no upgrade mechanism, holds no LP positions and exposes no owner function to withdraw LP principal. Swap callbacks accept empty `hookData`.

## Build and test

Use **Foundry v1.5.1** and **Solidity 0.8.26**. The repository targets Cancun with via IR enabled, 200 optimizer runs and 1,000 runs per fuzz test.

From the repository root:

```sh
git submodule update --init --recursive
forge fmt --check src test script
forge build --skip test
forge build --sizes --skip test --skip script
forge test -vv
```

Current validation results: **76 tests passed**, with no failures or skips. The hook's deployed bytecode is **8,051 bytes**, below the 24,576-byte limit. Coverage includes native-currency settlement, ERC-6909 backing, withdrawal rollback, signed-amount boundaries, and 300 swaps across three pools sharing currencies followed by revenue withdrawals.

[GitHub Actions](.github/workflows/contracts.yml) runs formatting, builds, size checks and the test suite on pushes and pull requests. See the [testing notes](docs/testing.md) and [gas measurements](test/gas/README.md) for details.

## Deployment and integration

Start with [`.env.example`](.env.example) and the [deployment guide](docs/launch.md). Supply the target chain's PoolManager, administrator and token addresses, and review the initial price and fee parameters.

The deployment script mines the hook address with CREATE2 and initializes a pool. The address must have the required **`0x10C4` permission mask in its lowest 14 bits**, and the pool must use the dynamic-fee flag **`0x800000`**. Liquidity is added separately after initialization.

## Model scope

The fee is derived from volume distribution around the current price. It does not directly classify ordinary trading versus arbitrage, or establish that LP profitability exceeds that of a fixed-fee pool. Tick spacing, volume distribution and decay all affect the signal; the example parameters remain subject to market-data validation.

Local tests cover the behaviors listed above. Target-chain configuration, routing integration and nonstandard token behavior require their own validation. See the [specification](SPEC.md) and [remaining work](TODO.md) for the current scope.

## Further reading

The detailed documents below are currently in Chinese.

| Document | Contents |
|---|---|
| [Specification](SPEC.md) | Units, fee formulas, permissions and behavioral boundaries |
| [Architecture](docs/refactor.md) | Modules, call boundaries and design decisions |
| [Deployment and integration](docs/launch.md) | Configuration, deployment, frontend and indexer integration |
| [Testing and verification](docs/testing.md) | Commands, coverage and results |
| [Gas measurements](test/gas/README.md) | Benchmark methodology and results |
| [Remaining work](TODO.md) | Outstanding implementation and validation work |

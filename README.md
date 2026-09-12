# Pulse-v4-hook

Pulse-v4-hook is a Uniswap v4 hook project that combines two core ideas in a single pool strategy:

1. **Dynamic LP fee driven by recent local trading activity**
2. **A hook-managed shared 1-tick liquidity vault**

The goal is to make LP capital highly concentrated around the current usable tick while dynamically lowering fees when recent nearby trading activity is strong, and raising fees when activity becomes sparse.

---

## 1. Project overview

This project is a Uniswap v4 hook for a dynamic-fee pool.

It supports two liquidity paths in the same pool:

- **Normal Uniswap liquidity**: users can still add liquidity in the standard Uniswap way.
- **1-tick vault liquidity**: users can deposit into a hook-managed shared vault that only makes markets in the current usable tick space.

The hook manages a shared vault that always attempts to place liquidity only in the current usable range:

- active range = `[tickLower, tickLower + tickSpacing]`
- `tickLower = floor(currentTick / tickSpacing) * tickSpacing`

When price moves out of the current active range, the vault becomes stale and marks itself as needing rebalance.
A separate rebalance flow then:

- removes stale liquidity
- swaps inventory internally if needed
- rebuilds liquidity in the final current tick space

---

## 2. Naming and design intention

**Pulse-v4-hook** reflects two pillars:

- **PulseFee**: fee is based on recent local trading volume pulses
- **NTick**: the vault only provides liquidity in one usable tick space at a time

This is not a generic passive LP vault. It is an actively managed hook-native liquidity system.

---

## 3. Dynamic fee model

### 3.1 Volume state

The hook maintains:

- `L`: exponentially decayed total recent volume, measured in a deployment-specified **base token**
- `L_tick`: exponentially decayed recent volume for each **usable tick**

Important rules:

- All volume accounting is measured in a single base token chosen at deployment.
- Ticks are always **usable ticks**, not raw ticks.
- Internal rebalance swaps performed by the hook **do not count** toward `L` or `L_tick`.

### 3.2 Decay rule

Decay is hourly and exponential:

- every 1 hour, volume is multiplied by `0.8`

This applies to both:

- global `L`
- per-tick `L_tick`

Decay should be implemented lazily, not by updating storage every block.
The intended behavior is:

- compute elapsed full hours since last update
- apply multiplier `0.8 ^ n`
- then apply new observed volume

### 3.3 Fee formula

The dynamic fee is based on local trading activity around the current usable tick.

Let the center usable tick be `t`.
Then the local weighted volume denominator is:

`sum = (L_tick[t] * 2) + L_tick[t-2] + L_tick[t-1] + L_tick[t+1] + L_tick[t+2]`
(i.e., center tick has double weight, sum over ±2 usable tick range)

The intended raw fee expression is:

`rawFee = L * C / sum`

Then clamp it:

`fee = clamp(minFee, maxFee, rawFee)`

Interpretation:

- if recent volume is concentrated near current price, `sum` is large, so fee goes **down**
- if recent volume is sparse around current price, `sum` is small, so fee goes **up**

### 3.4 Keeper volume update

Keepers can periodically update the volume state via `updateVolume()`.
Volume is tracked over a **wider ±7 tick range** to capture more trading activity.
This wider range helps maintain volume data even when price moves around.

### 3.5 Fee refresh model

Dynamic fee is **pool-wide** and applies to the whole pool.
It is not specific to vault LP only.

Fee refresh should support keeper participation.
The preferred architecture is:

- store `cachedFee`
- allow a public keeper function to refresh the cached fee
- the hook uses `cachedFee` in swap flow

A hybrid design is acceptable if later needed, but current preference is to make fee refreshing part of keeper incentives.

### 3.5 Internal swap fee exemption

When the hook performs an internal swap for vault rebalance:

- it should **not** be charged the extra `1bp` hook fee
- it should **not** contribute to volume accounting
- it should ideally use **zero dynamic LP fee override** for that internal rebalance swap path

This requires the hook / manager flow to distinguish internal rebalance swaps from user swaps.

---

## 4. 1-tick vault model

### 4.1 Shared vault

The 1-tick liquidity system is a **shared vault**, not separate per-user isolated positions.

Properties:

- all users in the vault share one hook-managed liquidity position
- the hook manages the active position
- the hook rebalances the vault into the latest current usable tick space

### 4.2 Position style

Vault liquidity only makes market in the **current usable tick space**.

That means there is only one active range at a time:

- `[tickLower, tickLower + tickSpacing]`

### 4.3 User receipt model

The project wants a user experience similar to LP position NFTs.
However, economically this vault behaves like a **shared share-based vault**.

Recommended interpretation:

- user receives an NFT-like position receipt
- the receipt represents vault shares, not a unique isolated liquidity range

In implementation, the exact token standard can still be finalized later, but the economic meaning is:

- **shared vault shares with NFT-style receipt UX**

### 4.4 Deposit behavior

Users may still use normal Uniswap liquidity flows outside the vault.
Separately, they may deposit into the 1-tick vault.

For vault deposits:

- hook should internally convert deposited assets toward the best ratio for the current active range
- before deposit, vault must rebalance first if stale
- deposit is **strict**: if rebalance fails, deposit reverts

### 4.5 Withdraw behavior

For vault withdrawals:

- the system should attempt rebalance first
- withdrawal is **lenient**: if rebalance fails, user can still withdraw based on current vault state

This means:

- deposit strict
- withdraw lenient

### 4.6 Capital usage objective

Vault capital should be used as fully as reasonably possible in the active 1-tick range.
The design target is to use almost all deployable capital, while tolerating small unavoidable dust.

---

## 5. Rebalance model

### 5.1 Public rebalance state

The vault exposes a public state flag:

- `needsRebalance`

This is intentionally public so external keepers can observe it and participate.

### 5.2 Rebalance trigger

If swap ends in a different usable tick space than the vault’s active range, the hook marks vault state as stale.

Preferred behavior:

- swap path marks vault as needing rebalance
- actual rebalance is done through a separate explicit rebalance entrypoint

### 5.3 Rebalance action

A rebalance should:

1. remove stale liquidity
2. inspect current vault inventory
3. perform internal inventory-balancing swap if needed
4. rebuild liquidity in the final current usable tick space

### 5.4 Keeper incentives

Rebalance is keeper-friendly.
The protocol explicitly wants to incentivize external callers to trigger maintenance.

Keeper reward source:

- rewards are funded from protocol revenue collected through the extra `1bp` hook fee

### 5.5 Rebalance fee treatment

For internal rebalance swaps:

- no extra `1bp` hook fee
- no contribution to volume tracking
- intended zero dynamic LP fee override for internal flow

---

## 6. Fee and revenue model

The protocol charges an extra **1bp hook fee** on normal user swaps.

This revenue is used for protocol-side functions such as:

- keeper incentives
- maintenance incentives

The 1-tick vault’s trading PnL, fee earnings, and rebalance costs belong economically to vault participants.

Specifically:

- vault trading fees belong to vault users
- rebalance slippage and costs are borne by vault users
- keeper incentives come from protocol 1bp revenue, not directly from vault assets

---

## 7. Administrative powers

The project only wants minimal admin control.

Admin powers:

- pause contract / pause critical flows

Deployment-time constants should be fixed on-chain, rather than later tuned by admin, including for example:

- `minFee`
- `maxFee`
- `C`
- base token choice
- decay parameters

---

## 8. Manipulation stance

The current design intentionally does **not** try to heavily suppress fee-shaping manipulation.

Reasoning:

- if someone pays real fees to increase recent local volume and thereby lower the local fee, that effect is public and benefits all subsequent flow in that region

Therefore, the current design preference is:

- no aggressive anti-manipulation clipping for now
- no per-trade truncation just to suppress this behavior

This can be revisited later if tests show pathological behavior.

---

## 9. Main components to build

Likely components include:

- `Hook` contract implementing Uniswap v4 hook interfaces
- `Vault` accounting logic for shared 1-tick LP
- `RebalanceManager` or equivalent internal manager/router for privileged internal flows
- `Keeper incentive` accounting module
- NFT-style receipt contract for vault shares
- libraries for decayed volume math and usable tick accounting

---

## 10. Current agreed decisions summary

The following have already been decided:

- project name: `Pulse-v4-hook`
- dynamic fee based on decayed `L` and decayed usable-tick `L_tick`
- hourly decay factor = `0.8`
- center usable tick has double weight
- fee formula is inverse local-activity style: `L * C / localSum`, then clamp
- volume measured in a deployment-specified base token
- internal rebalance swaps do not count toward `L` / `L_tick`
- internal rebalance swaps do not pay the extra `1bp` hook fee
- pool-wide dynamic fee applies to the whole pool
- normal Uniswap liquidity and vault liquidity both coexist
- shared vault only provides liquidity in current usable tick space
- `needsRebalance` is public
- keeper rewards come from the extra `1bp` hook fee revenue
- deposits are strict and must rebalance first
- withdrawals are lenient if rebalance fails
- admin can pause, but key parameters should be fixed at deployment

---

## 11. What this README is for

This README is meant to give Claude Code or any other coding agent enough context to understand:

- what the protocol is
- which decisions are already finalized
- what architectural constraints matter
- what must be preserved while implementing

This file is a product/design handoff, not a finished technical spec.

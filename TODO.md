# TODO - Pulse-v4-hook

This file lists the implementation status.

---

## Completed

- [x] Initialize project structure for a Uniswap v4 hook repository
- [x] Decide and set toolchain: Foundry
- [x] v4-core dependency
- [x] Create base folders: src/, test/, script/
- [x] Write SPEC.md
- [x] Define hook responsibilities
- [x] Define vault responsibilities (1-tick vault)
- [x] Define keeper responsibilities
- [x] Define protocol fee accounting responsibilities
- [x] Define all storage variables before implementation
- [x] Define event list
- [x] Define custom errors
- [x] Explicitly describe internal rebalance swap flow
- [x] Explicitly describe how internal swaps are identified so fee exemption is possible
- [x] Finalize contract split (monolithic hook)
- [x] NFT-style receipt with share accounting
- [x] Protocol fee treasury internal to hook
- [x] Keeper rewards via ERC20 token transfer
- [x] Implement storage for fee state (cachedFee, lastFeeRefreshTime, minFee, maxFee, C)
- [x] Implement fee refresh function (pokeFee)
- [x] Implement storage for global decayed volume L
- [x] Implement storage for per-usable-tick decayed volume L_tick
- [x] Store timestamps needed for lazy hourly decay
- [x] Implement lazy decay math for elapsed whole hours
- [x] Handle very old stale states safely
- [x] Implement usable tick normalization helpers (TickLib.toUsableTick)
- [x] Implement local sum calculation (±7 tick range)
- [x] Implement dynamic LP fee override path (beforeSwap)
- [x] Charge extra 1bp hook fee for external user swaps
- [x] Exempt internal rebalance swaps from extra 1bp
- [x] Exempt internal rebalance swaps from dynamic LP fee (use MIN_FEE)
- [x] Update volume accounting in afterSwap
- [x] Determine final usable tick space after swap
- [x] If vault active range is stale, set needsRebalance = true
- [x] Implement shared-vault share accounting
- [x] Track idle assets and active position assets
- [x] Implement deposit entrypoint (strict)
- [x] Implement withdraw entrypoint (lenient)
- [x] Implement public rebalance() entrypoint
- [x] Implement protocol revenue tracking
- [x] Implement keeper reward distribution
- [x] Implement pause functionality
- [x] Add full test suite
- [x] Multi-pool support (mapping by PoolId)

---

## NOT APPLICABLE

- This hook does NOT support standard Uniswap liquidity (only vault LP)
- This hook does NOT use a separate RebalanceManager module

---

## Future improvements

- [ ] Gas optimization (if bytecode exceeds 24KB)
- [ ] Fuzz tests
- [ ] Economic simulation tests
- [ ] Security audit
- [ ] Deploy to mainnet
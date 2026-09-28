# Pricer: model, parameters, provenance

Covers `contracts/src/Pricer.sol` and its Stylus twin `pricer/src/lib.rs` /
`pricer/core/src/lib.rs`. Both implement `IPricer.quote()` and share one feed-independent
core function (`priceCore` in Solidity, `price_core` in Rust) so the pricing math itself,
not just the ABI, is provably identical across toolchains (see Parity below).

## Model

Excess-of-loss layer over a portfolio's weekend gap risk. For each of 504 historical
weekend scenarios `s`, per market `i` in the caller's `exposure`/`feeds` arrays:

```
scaledGap[i][s]   = table[i][s] * volScalePpm[i] / 1_000_000
loss[s]           = sum_i(exposure[i] * scaledGap[i][s] / 10_000)      // BPS gap -> loss
payout[s]         = min(limit, max(0, loss[s] - retention))
el                = mean(payout[s])                        over all 504 scenarios
tvar95            = mean(payout[s])                         over the worst 25 (5%) scenarios
premium           = el + RISK_LOAD_PPM * (tvar95 - el) / 1_000_000
                       + CAPITAL_CHARGE_ANNUAL_PPM * limit * LOCK_DAYS / (DAYS_PER_YEAR * 1_000_000)
```

Two terms, replacing the earlier single cost-of-capital load
(docs/security/capacity-review.md "Re-review (2026-09-28)", "Pricing (item 2)"):

- **Risk load**: a flat 3% of `(tvar95 - el)`, the tail mass above the expected loss. Not
  prorated by time: a weekend gap prices as a discrete per-bind event (one Friday-close to
  Monday-open crossing), not a continuous-time process, so there is no duration to prorate
  it against.
- **Capital charge**: the risk-free rate (4% annualised) on the fully collateralised
  `limit`, charged for the real capital-lock duration `LOCK_DAYS / DAYS_PER_YEAR` (7 days
  of 365). This replaces the old `WEEKEND_HOURS = 66` proration, which undercounted the
  real bind-to-settlement window (Treaty locks capital from bind, as early as Monday
  00:00 UTC, until settlement, up to about 7.5 days later; the EST weeks run 67h, not 66).

The 50 bps rate-on-line floor (`MIN_RATE_ON_LINE_BPS` in `Treaty.sol`) and the volatility
scale floor (`MIN_SCALE_PPM = 1_000_000`, 1.0x, see "On-chain volatility scale" below) are
both unchanged in kind, carried over from the pre-rewrite pricer.

## Parameters

| Name | Value | Meaning |
|---|---|---|
| `SCENARIOS` | 504 | historical weekends per market table |
| `TAIL` | 25 | worst 5% of `SCENARIOS`, used for `tvar95` |
| `RISK_LOAD_PPM` | 30,000 (3.00%) | flat per-weekend load on `(tvar95 - el)`, not prorated |
| `CAPITAL_CHARGE_ANNUAL_PPM` | 40,000 (4.00%) | risk-free annualised rate on `limit` for the real capital lock |
| `LOCK_DAYS` | 7 | capital-lock duration the capital charge prorates against |
| `DAYS_PER_YEAR` | 365 | proration denominator |
| `VOL_ROUNDS` | 8 | prior Chainlink rounds read per feed for the volatility scale |
| `NORMAL_ROUND_MOVE_BPS` | 50 | live-measured Chainlink deviation threshold; volatility scale is relative to this |
| `MIN_SCALE_PPM` / `MAX_SCALE_PPM` | 1,000,000 / 3,000,000 | volatility scale clamp, 1.0x-3.0x (floored at neutral, docs/security/capacity-review.md P4) |

## Economics sourcing

The risk load and capital charge rates above, and the acceptance numbers in "Before /
after" below, are the reviewer's estimates from docs/security/capacity-review.md
"Re-review (2026-09-28)", section "Pricing (item 2)" (derivation script:
`/tmp/heracles-rr/econ.py` against `evidence/gap-tables/*.json`). **These premium
benchmarks are the reviewer's estimates and are not externally verified** against a
priced reinsurance or DeFi-cover benchmark; treat them as an internally-consistent risk/
capital model, not a market-calibrated rate. The prior cost-of-capital sourcing (Solvency
II 6% risk-margin rate) is superseded by this two-term model and no longer applies.

## Data provenance (weekend-gap tables)

Source: `api.nasdaq.com` historical daily-bar API (no key required), same endpoint the
pre-rewrite single-table version already used. Method: for every Friday close, find the
next trading day's open (Monday, or later on a holiday Monday) and compute
`gap_bps = round((next_open - friday_close) / friday_close * 10000)`.

- Script: `scripts/generate_gap_tables.py` (re-runnable; `python3 scripts/generate_gap_tables.py`
  regenerates all four tickers over the default 10-year window; `--tickers`/`--fromdate`/`--todate`
  override).
- Raw output: `evidence/gap-tables/{NVDA,AAPL,SPY,TSLA}.json` (full detail, per-Friday dates
  and computed bps, plus the exact source URL and fetch date used) and
  `evidence/gap-tables/{NVDA,AAPL,SPY,TSLA}.gaps.txt` (bare bps lists, pasted verbatim into
  `Pricer.sol`'s `gaps{NVDA,AAPL,SPY,TSLA}` arrays and `pricer/core/src/lib.rs`'s
  `{NVDA,AAPL,SPY,TSLA}_GAPS` consts).
- 504 scenarios per market (10 years of Fridays), matching `SCENARIOS`.

`_tableFor`/`table_for` selects by an explicit per-market table id (`marketTableIds` in
Solidity, `table_ids` in Rust), a constructor-supplied array, not by exposure array
position (docs/security/capacity-review.md "Re-review (2026-09-28)" P2: the testnet
deploy has a single SPY feed at index 0, and position-based selection priced it on the
NVDA table). Table id 0 = NVDA, 1 = AAPL, 2 = SPY, 3 = TSLA.

**Fail closed, no fallback (P2 re-review, docs/security/capacity-review.md "Re-review
(2026-09-28)").** The positional fallback (`_defaultTableId`/`default_table_id`) and the
id-value fallback to NVDA for any id > 3 have both been deleted; there is no longer any
path that silently reprices an unmapped or misconfigured market. In both languages:

- Constructor/`price_core` reverts (`BadTableId` in Solidity, an `Err` in Rust) if
  `tableIds`/`table_ids` is empty or any entry is not 0-3.
- `tableIdAt`/`table_id_at` reverts (`MissingTable`) if `i` is past the configured
  array, instead of returning `_defaultTableId(i)`. `_tableFor`/`priceCore`/`quote` in
  Solidity route through this same getter, so a quote spanning more markets than the
  deploy configured reverts at the same single guard rather than needing a duplicate
  length check.
- `price_core` (Rust) additionally checks `table_ids.len() >= exposure.len()` directly
  (it has no constructor to gate at deploy time, since it is a pure function called
  directly by the Stylus wrapper and by `pricer_cli`/tests), returning `MissingTable`
  on the same condition.

A deployment must now pass an explicit, correctly-sized table id array; there is no
"leave it empty and get the old default" option left.

## On-chain volatility scale

Each market's scenario table is scaled by that market's own realised volatility before
pricing, read live from its Chainlink feed:

1. Read `latestRoundData()`. **Fails closed in both implementations**
   (docs/security/capacity-review.md P1): Solidity has no `try/catch` around this outer
   call, so a reverting/unset feed reverts the whole `quote()`; Rust's outer call is now
   `.map_err(|_| b"FeedReadFailed".to_vec())?`, propagating the same revert instead of the
   pre-fix silent fallback to neutral (which contradicted this doc and Solidity's
   behaviour). Chainlink's real `roundId` is `phaseId << 64 | aggregatorRoundId`, a
   `uint80` that does not fit in a `u64` once a proxy has gone through more than one
   phase; the fix does all round-id arithmetic in `U80` (never truncates to `u64`) so a
   live round id like `18446744073709553978` (phase 1, round 2362, the real Arbitrum
   Sepolia SPY/USD id read 2026-09-28) does not panic.
2. Walk backwards `VOL_ROUNDS` (8) rounds via `getRoundData()`. Unlike step 1, a missing
   or unreadable round *here* still degrades gracefully to neutral in both languages
   (Solidity's inner `try/catch`, Rust's `let Ok(...) = ... else { break }`), since this
   is a best-effort sample, not the primary feed-liveness check.
3. Compute the mean absolute round-over-round move in bps.
4. Scale relative to `NORMAL_ROUND_MOVE_BPS` (50), clamp to `[MIN_SCALE_PPM, MAX_SCALE_PPM]`
   (1.0x-3.0x; floored at neutral, docs/security/capacity-review.md P4, so the scale can
   only raise a quote above the static historical table, never cut it below).
5. Default to 1_000_000 (neutral, 1.0x) only for the step-2/3/4 sampling loop (too little
   round history, or every walk-back round unreadable); a step-1 failure reverts instead,
   per the fail-closed rule above.

Implemented identically in both `Pricer._volScalePpm` (Solidity) and
`Pricer::vol_scale_ppm` (Rust), not "Stylus-only for gas reasons": the added cost is
dominated by the `CALL` opcode to each feed, which costs the same regardless of caller
language, so skipping it in one implementation would buy no real gas advantage, only a
silent behaviour mismatch between the two `IPricer` implementations.

`priceCore`/`price_core` itself takes `volScalePpm` as a plain input array and is feed-independent
(no live reads), which is what makes it fuzzable and parity-testable (below); `quote()` is
the thin per-toolchain wrapper that computes `volScalePpm` from live feeds and calls the core.

## Parity (Solidity vs Stylus)

Both `priceCore` (Solidity) and `price_core` (Rust, in the standalone `pricer-core` crate
pulled in by both `pricer/src/lib.rs`, the Stylus contract, and `pricer/pricer_cli`, the
native parity-test CLI) implement the formula above over the same literal tables, using
checked arithmetic throughout.

`contracts/test/PricerParity.t.sol` proves bit-for-bit equality in-process via Foundry's
`vm.ffi`: it shells out to `pricer/pricer_cli` (a native CLI wrapping `price_core`) and
`abi.decode`s its output, then asserts exact equality against `pricer.priceCore()` for the
same inputs: five fixed cases plus a bounded fuzz run (`testFuzz_priceCoreMatchesRustExactly`,
exposure up to $5M, `volScalePpm` across the full clamp range, retention/limit up to
$1M). Requires `ffi = true` in `contracts/foundry.toml` (already set); reproduce with:

```
cd contracts && forge test --match-contract PricerParityTest -vv
```

## Reproducibility

```
python3 scripts/generate_gap_tables.py            # regenerate evidence/gap-tables/*
cd pricer/core && cargo test                      # pure pricing math, 10 tests
cd pricer && cargo test --lib                      # Stylus wrapper, 6 tests (TestVM)
cd pricer && cargo stylus check --endpoint https://sepolia-rollup.arbitrum.io/rpc
cd contracts && forge test --match-path 'test/Pricer*.sol'
```

## Before / after (README's example: long $2,000,000, retention $20,000, limit $60,000,
neutral 1.0x vol scale)

`exposure=[2_000_000_000_000]`, `retention=20_000_000_000`, `limit=60_000_000_000`, all
6dp USDG units:

| Table | premium | el | tvar95 | rate on line (premium/limit) | multiple of EL |
|---|---|---|---|---|---|
| Before (single cost-of-capital load, NVDA table) | 5,062,541,027 | 5,040,079,365 | 54,728,000,000 | 8.44% | 1.0045x |
| After (risk load + capital charge, NVDA table) | 6,576,744,381 | 5,040,079,365 | 54,728,000,000 | 10.96% | 1.305x |
| After (risk load + capital charge, SPY table) | 1,676,722,158 | 1,051,190,476 | 20,368,000,000 | 2.79% | 1.60x |

`el` and `tvar95` are unchanged from the "before" row for the NVDA case (same table, same
inputs); only the load changed. The pre-rewrite cost-of-capital-only load priced the
writer's expected excess return at 0.037% of locked capital per weekend (1.95% a year on
a one-week lock, below the USDG risk-free rate, Sharpe ratio about 0.01). The risk-load +
capital-charge model prices the NVDA case at 129% a year on the limit against a 159%
annual payout standard deviation (Sharpe about 0.8) and the SPY case at Sharpe about 0.7;
both sit above the bootstrap p90 of EL (1.15x for NVDA, 1.34x for SPY), covering the
estimation error the 504-scenario sample carries (standard error of EL is about 11.7% of
EL for NVDA, 25% for SPY). On the buyer side, the net cost of cover beyond expected
recoveries is about 4.0%/year of notional for the NVDA case and 1.6%/year for SPY.

These are the reviewer's rounded figures (each of the three summed components
independently rounded to cents before summing: 5,040.08 + 1,490.64 + 46.03 = 6,576.75 for
NVDA, 1,051.19 + 579.50 + 46.03 = 1,676.72 for SPY). This implementation's exact integer
premium is 6,576.744381 for NVDA (a $0.01 difference from the reviewer's 6,576.75, a
rounding-accumulation artifact of summing three independently-cent-rounded components
rather than computing on raw integers) and 1,676.722158 for SPY (matches the reviewer's
1,676.72 exactly, cross-validating the formula and constants). **These premium
benchmarks are the reviewer's estimates and are not externally verified.**

Reproduce the NVDA "after" row:
`cd pricer/pricer_cli && cargo build --release && ./target/release/pricer-cli
20000000000 60000000000 2000000000000 1000000 ""`, then `abi.decode` the printed 96-byte
hex as `(uint256,uint256,uint256)`, or equivalently call
`pricer.priceCore([2_000_000_000_000], [1_000_000], 20_000_000_000, 60_000_000_000)` on a
`Pricer` constructed with `[0]` (NVDA at index 0; P2 re-review, empty arrays now revert
the constructor) in Solidity. For the SPY row, pass `"2"` as the CLI's table-ids arg, or
construct `Pricer` with `[2]`.
`contracts/test/PricerParity.t.sol`'s `test_acceptanceNumbersMatchRustExactly` asserts
both rows bit-for-bit against Solidity and Rust together.

## Gas (Stylus vs Solidity)

`cargo stylus check` (non-deploying, run against `sepolia-rollup.arbitrum.io`) confirms
the current wasm binary: **26.6 KB (26,553 bytes, 2 fragments)**, wasm data fee 0.000125
ETH; `cargo stylus check` passes (exit 0). This grew from the pre-P1/P2/P4-fix 21.3 KB
(21,309 bytes, 1 fragment) figure because of the `StorageBytes table_ids` field, the new
`#[constructor]`, the U80 (not u64) round-id arithmetic, and the fail-closed `Result`
propagation on the outer feed read (docs/security/capacity-review.md P1/P2/P4); the P2
re-review's `BadTableId`/`MissingTable` fail-closed constructor and `tableIdAt` guard
(replacing the positional/id-value fallback) added another 308 bytes on top of that,
26,245 to 26,553. `cargo stylus check` itself is the authoritative pass/fail gate for the
wasm size limit, and it still passes with 2 fragments, but the binary no longer fits in
the single 24 KiB (24,576 byte) fragment the pre-fix build did.

The previously-published **4.06x** Stylus-vs-Solidity call-gas ratio
(`spikes/stylus-pricer/FINDINGS.md`) predates this rewrite (single table, no
cost-of-capital load, no volatility scale, no checked-arithmetic overhead) and is **not
valid for the current contract**. Re-measuring it honestly requires a live call-gas
comparison (e.g. a local Stylus devnode or a Sepolia deployment calling both `quote()`
implementations with mocked/live feeds), which this task's scope explicitly excludes
("Do NOT deploy"). No new Stylus call-gas ratio is claimed here; only the wasm
size/activation-fee numbers above, which do not require a call, are reported. Treat the
4.06x figure as retracted until it is re-measured against this contract.

## Limitations

- **Volatility basis mismatch.** The volatility scale is computed from round-to-round
  Chainlink price moves (a proxy for realised intraday/inter-update volatility), while the
  scenario tables are Friday-close-to-Monday-open weekend gaps (a different, lower-frequency
  statistic). Scaling a weekend-gap table by an intraday-volatility ratio is a reasonable,
  documented approximation, not a rigorous volatility-of-volatility model; the clamp
  ([0.5x, 3.0x]) bounds how far a noisy or manipulated recent-round read can move the price.
- **`phaseId` not tracked.** `_volScalePpm`/`vol_scale_ppm` walks the raw Chainlink round id
  backwards by 1 per step and does not track `phaseId`. A phase change inside the last
  `VOL_ROUNDS` rounds truncates the sample early via the failed-`getRoundData`-call branch
  (falls back toward neutral) rather than crossing into the wrong phase's round ids; it does
  not silently read wrong data, but it can under-sample right after a phase change.
  Mirrored identically in both implementations.
- **Only 4 sourced tables.** `_tableFor`/`table_for` only has real, independently sourced
  tables for ids 0-3 (NVDA/AAPL/SPY/TSLA). This used to silently fall back to NVDA for any
  other id or any market position past the configured array; P2 re-review
  (docs/security/capacity-review.md "Re-review (2026-09-28)") closed that: the constructor
  now reverts `BadTableId()` on any id > 3, and `tableIdAt`/`table_id_at` reverts
  `MissingTable()` for any market position not covered by the deploy's table id array. A
  fifth market still needs a real sourced table added before it can be priced at all; it
  can no longer be priced silently on NVDA's data instead.
- **Gas ratio unmeasured post-rewrite.** See "Gas" above: the 4.06x figure is retracted,
  not replaced, pending a permitted deployment/devnode run.

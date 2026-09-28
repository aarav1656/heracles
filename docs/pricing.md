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
premium           = el + c * (tvar95 - el)
```

`c` is an annualised cost-of-capital rate prorated to one weekend's capital lock:

```
c = COST_OF_CAPITAL_ANNUAL_PPM * WEEKEND_HOURS / (HOURS_PER_YEAR * 1_000_000)
  = 60_000 * 66 / (8_760 * 1_000_000)
  ≈ 0.0004521  (0.04521%, i.e. a 6% annual rate charged for 66 hours out of 8,760)
```

This replaces the pre-rewrite `0.5 * TVaR95` risk load (a flat 50% loading on the whole
tail mean, with no relationship to how long the underwriter's capital is actually locked)
with a load sized to the actual 66-hour Friday-19:30-UTC to Monday-13:30-UTC capital lock
Treaty enforces, at a rate benchmarked against real capital markets (below).

## Parameters

| Name | Value | Meaning |
|---|---|---|
| `SCENARIOS` | 504 | historical weekends per market table |
| `TAIL` | 25 | worst 5% of `SCENARIOS`, used for `tvar95` |
| `COST_OF_CAPITAL_ANNUAL_PPM` | 60,000 (6.00%) | annualised cost-of-capital rate `c` is derived from |
| `WEEKEND_HOURS` | 66 | Treaty's actual bind-lock-to-settle window (Fri 19:30 UTC to Mon 13:30 UTC) |
| `HOURS_PER_YEAR` | 8,760 | proration denominator |
| `VOL_ROUNDS` | 8 | prior Chainlink rounds read per feed for the volatility scale |
| `NORMAL_ROUND_MOVE_BPS` | 50 | live-measured Chainlink deviation threshold; volatility scale is relative to this |
| `MIN_SCALE_PPM` / `MAX_SCALE_PPM` | 500,000 / 3,000,000 | volatility scale clamp, 0.5x-3.0x |

## Cost-of-capital sourcing (`c`)

- Solvency II's standard-formula risk-margin cost-of-capital rate is 6% per annum:
  https://www.eiopa.europa.eu/rulebook/solvency-ii-single-rulebook/article-2160_en and
  https://www.skadden.com/insights/publications/2024/05/the-standard-formula-a-guide-to-solvency-ii-chapter-7
- The 2025 Solvency II review lowers it to 4.75%:
  https://www.deloitte.com/lu/en/our-thinking/future-of-advice/solvency-ii-review-2025.html
  The UK already runs 4%. 6% is the higher, still-in-force EU rate, chosen as the
  conservative (buyer-friendly, i.e. cheaper-for-the-buyer) end.
- It sits well below realised DeFi cover capital yields: Sherlock stakers launched at 10%
  USDC + 5% SHER APY
  (https://www.coindesk.com/business/2022/09/14/crypto-auditing-platform-sherlock-raises-4m-in-funding)
  and were reported above 14% APY on USDC alone by 2023
  (https://medium.com/@jamesowen.dev/sherlock-the-protocol-revolutionizing-web3-audits-and-smart-contract-coverage-8b1aae43c5e4).

6% is therefore cheap relative to what DeFi cover capital actually charges today, and is
the traditional-reinsurance benchmark rate rather than a number picked to make the quote
look good.

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

`_tableFor`/`table_for` selects by exposure index: 0 = NVDA (also the fallback for any
index >= 4, so a caller passing more than 4 markets doesn't revert, just re-uses NVDA's
table for the extra legs), 1 = AAPL, 2 = SPY, 3 = TSLA.

## On-chain volatility scale

Each market's scenario table is scaled by that market's own realised volatility before
pricing, read live from its Chainlink feed:

1. Read `latestRoundData()`.
2. Walk backwards `VOL_ROUNDS` (8) rounds via `getRoundData()`.
3. Compute the mean absolute round-over-round move in bps.
4. Scale relative to `NORMAL_ROUND_MOVE_BPS` (50), clamp to `[MIN_SCALE_PPM, MAX_SCALE_PPM]`
   (0.5x-3.0x).
5. Default to 1_000_000 (neutral, 1.0x) on any read failure, non-positive answer, or
   insufficient round history (matches Solidity's `try/catch` fallback and Rust's `Result`
   fallback exactly).

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
same inputs — five fixed cases plus a bounded fuzz run (`testFuzz_priceCoreMatchesRustExactly`,
exposure up to $5M, `volScalePpm` across the full clamp range, retention/limit up to
$1M). Requires `ffi = true` in `contracts/foundry.toml` (already set); reproduce with:

```
cd contracts && forge test --match-contract PricerParityTest -vv
```

## Reproducibility

```
python3 scripts/generate_gap_tables.py            # regenerate evidence/gap-tables/*
cd pricer/core && cargo test                      # pure pricing math, 7 tests
cd pricer && cargo test --lib                      # Stylus wrapper, 3 tests (TestVM)
cd pricer && cargo stylus check --endpoint https://sepolia-rollup.arbitrum.io/rpc
cd contracts && forge test --match-path 'test/Pricer*.sol'
```

## Before / after (README's example, single-market NVDA table, neutral 1.0x vol scale)

`exposure=[2_000_000_000_000]` (long $2,000,000, 6dp), `retention=20_000_000_000`
($20,000), `limit=60_000_000_000` ($60,000):

| | premium | el | tvar95 | rate on line (premium/limit) | multiple of EL |
|---|---|---|---|---|---|
| Before (`0.5 * tvar95` load) | 33,664,099,206 | 5,040,079,365 | 54,728,000,000 | 56.11% | 6.68x |
| After (cost-of-capital load) | 5,062,541,027 | 5,040,079,365 | 54,728,000,000 | 8.44% | 1.0045x |

`el` and `tvar95` are unchanged (same table, same inputs); only the load changed. The old
flat `0.5x` tail-mean load priced the layer at 6.68x its own expected loss regardless of
how long the capital was locked; the new load prices it at ~1.0045x EL, i.e. it charges
almost exactly EL plus a 66-hour rental on the tail capital at 6%/year, which is the
buyable, capital-market-benchmarked number the item-2 gate calls for. Reproduce the
"after" row: `cd pricer/pricer_cli && cargo build --release && ./target/release/pricer-cli
20000000000 60000000000 2000000000000 1000000`, then `abi.decode` the printed 96-byte hex
as `(uint256,uint256,uint256)`, or equivalently call
`pricer.priceCore([2_000_000_000_000], [1_000_000], 20_000_000_000, 60_000_000_000)` in
Solidity.

## Gas (Stylus vs Solidity)

`cargo stylus check` (non-deploying, run against `sepolia-rollup.arbitrum.io`) confirms
the current wasm binary: **21.3 KB (21,309 bytes)**, under the 24 KiB (24,576 byte)
target, wasm activation data fee 0.000104 ETH. This is a real, freshly-measured number for
the rewritten contract (four tables plus the volatility-scale logic, not the old
single-table version).

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
- **NVDA-fallback beyond 4 markets.** `_tableFor`/`table_for` only has real, independently
  sourced tables for indices 0-3 (NVDA/AAPL/SPY/TSLA); any exposure index >= 4 re-uses the
  NVDA table rather than reverting. A caller pricing a 5th+ market gets NVDA's historical
  gap distribution applied to that market's exposure, not that market's own data, until a
  real table is sourced and added.
- **Gas ratio unmeasured post-rewrite.** See "Gas" above: the 4.06x figure is retracted,
  not replaced, pending a permitted deployment/devnode run.

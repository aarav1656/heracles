# Heracles: weekend move data and the reference/fixing rule

Written 2026-09-26, annotated 2026-09-28. This file started as a wider research pass
(an auction-format comparison, an options-strike/Black-Scholes reference price, and a
physical stock-token settlement path for a Robinhood Chain product) that is **not**
what Heracles ships. Heracles has no auction: `Treaty.bind` quotes a fixed
EL-plus-TVaR premium from `Pricer.quote()` in the same transaction, there is no strike
or take-side bidding, settlement is cash-only in USDG, and the deploy target is
Arbitrum (One/Sepolia), not Robinhood Chain. The auction-design, Black-Scholes-strike
and physical-delivery sections that used to be here have been removed; they described
a different product's spec, not this repo's code. What remains below is the two pieces
of this research that Heracles' code and docs actually use.

## 1. Weekend move statistics (source for the per-market scenario tables)

Friday close to next open, 504 weekends per ticker, 2016-09-26 to 2026-09-26, from
`https://api.nasdaq.com/api/quote/<T>/historical?assetclass=stocks&fromdate=2016-09-26&todate=2026-09-26&limit=9999`
(SPY: `assetclass=etf`); no split residue (no gap over 40%):

| Ticker | mean abs | median | p90 | >3% | >5% | open < 97% | std | worst |
|---|---|---|---|---|---|---|---|---|
| NVDA | 1.33% | 0.93% | 2.64% | 7.1% | 2.6% | 4.4% | 2.12% | -14.7% |
| AAPL | 0.84% | 0.50% | 1.82% | 3.0% | 1.6% | 1.8% | 1.44% | -13.0% |
| SPY | 0.52% | 0.32% | 1.12% | 1.6% | 0.4% | 1.0% | 0.93% | -10.4% |
| TSLA | 1.73% | 1.26% | 3.74% | 14.3% | 4.8% | 6.5% | 2.60% | -14.9% |

`contracts/src/Pricer.sol` and `pricer/src/lib.rs` currently apply only the NVDA
504-scenario series (in basis points) as a shared weekend shock to every bound market;
this is a disclosed simplification (README "What we cut"), not fabricated data. The
AAPL/SPY/TSLA rows above are the sourced-but-not-yet-wired per-market tables the
Roadmap references.

## 2. The reference rule

Adverse-selection research on 21 tokenized-equity/RWA instruments found weekend price
predictability strong enough to matter for a Friday-priced, Monday-settled instrument
(Dombrowski and Arshadi, Sept 2023 to April 2026: weekday beta 0.022 (t 1.22),
"weekend predictability is stronger, with nine of 21 tokens reaching 5% significance
and R2 up to 0.35", https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6999355). The
practical implication for Heracles: a "Friday reference" that can already be read by a
buyer at bind time hands them a free option (bind after the reference has printed,
before the weekend risk starts). The rule that avoids this is: **the reference is the
first Chainlink round with `updatedAt >= Friday's official close (20:00 UTC EDT /
21:00 UTC EST)`**, not the last round printed before that time. `Treaty.setReference`
now implements exactly this rule (`contracts/src/Treaty.sol`, DST-aware via
`_isUsDst`); see `contracts/test/ReferenceRule.t.sol` for the round-selection and
bind-cutoff tests, and `docs/security/capacity-review.md` for the
live-feed evidence that motivated the fix.

Blind spot: the gap table above is one feed (Nasdaq daily bars) and Friday-close
gaps only; it has not been cross-checked against Chainlink's own equity-feed update
cadence for false precision.

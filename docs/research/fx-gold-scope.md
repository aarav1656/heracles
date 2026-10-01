# FX and gold scope for Heracles

Data and evidence only. No contract, pricer, forge or deploy changes, nothing committed. Every number below carries the block or fetch time it came from.

## 1. Ostium's live exposure by asset class

Read `getPairOpeningInterestInfo` on TradingStorage `0xcCd5891083A8acD2074690F65d3024E7D13d66E7` for all 83 pairs at Arbitrum One block 510265853, then priced each leg (units are 1e18 fixed point, not USD) with Ostium's own subgraph `lastTradePrice` (api.subgraph.ormilabs.com, fetched the same session). Grouped into five buckets: equities (stocks, indices, etf), fx (forex), gold_metals (XAU, XAG, XPT, XPD), commodities (everything else in Ostium's commodities group), crypto.

| Group | Long USD | Short USD | Net USD | Pairs |
|---|---|---|---|---|
| fx | 3,052,586.42 | 944,610.41 | 2,107,976.02 | 9 |
| gold_metals | 1,891,694.35 | 2,948.80 | 1,888,745.54 | 4 |
| commodities | 1,075,366.71 | 4,326.87 | 1,071,039.84 | 3 |
| equities | 1,883,348.43 | 1,015,491.65 | 867,856.78 | 58 |
| crypto | 234,695.64 | 134,108.52 | 100,587.12 | 9 |

FX and gold together are 3.6x the equity net exposure this book carries into the weekend. Within fx, EUR/USD alone is net long $2,483,099.80 (long $2,519,940.51, short $36,840.70), next largest is GBP/USD at $511,347.84, so EUR/USD is the pair step 3 builds a table for. Within gold_metals, XAU/USD is net long $1,610,525.06 (long $1,613,179.20, short $2,654.14).

The vault `0x20D419a8e12C45f88fDA7c5760bb6923Cee27F98` reads `totalAssets()` = $6,484,600.57 and `getBufferSize()` = $154.73 at block 510273005 (2026-09-30T06:58:51Z), a fresher read than the OI block above since the public RPC had already pruned block 510265853's state by the time I went back for the vault numbers. The coordinator's own independent read, roughly 5,300 blocks later at block 510,278,303, has `totalAssets()` = $6,484,739.24 and `getBufferSize()` = $289.98. The buffer was $13,954.75 as of the prior research pass (2026-09-29), $154.73 a day later at block 510273005, then $289.98 at block 510,278,303: it is moving but stays two to three orders of magnitude below the fx/gold exposures below, essentially a rounding error against either instrument's net OI. All three reads are `arb1.arbitrum.io/rpc`, no archive node needed since they were live at read time. The "Ostium sizing" section (5) below uses the coordinator's $289.98 at block 510,278,303 as the live buffer, being the freshest of the three.

Full pair-by-pair breakdown: `evidence/gap-tables/ostium-oi-by-group.json`.

## 2. Chainlink feeds

EUR/USD `0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84` and XAU/USD `0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c` on Arbitrum One, addresses from Chainlink's `reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json` catalog, both verified live at block 510265853: `decimals()` = 8 for both, `description()` = "EUR / USD" and "XAU / USD", `latestRoundData()` answers $1.13471 (updatedAt 2026-09-30T06:02:38Z) and $4,169.475 (updatedAt 2026-09-29T18:16:29Z).

**Arbitrum Sepolia has no standard AggregatorV3 feed for either pair.** I checked `feeds-ethereum-testnet-sepolia-arbitrum-1.json` (2,239 feeds) and found only Data Streams/Datalink test variants with no callable proxy address for XAU/USD or EUR/USD. Only SPY/USD (Heracles' existing Sepolia deployment) and crypto pairs have real proxies there. This is a hard gap: a Sepolia FX or gold demo needs either a mock feed or a different testnet.

I walked each feed's round history (`getRoundData`, binary search over the phase-2 round range) for the two most recent weekends to see how the round in effect at Friday 16:00 ET and Monday 9:30 ET actually behaves:

- **EUR/USD updates roughly hourly through both boundaries.** For 2026-09-25/28: last round before Friday close was 38 minutes earlier (answer $1.139885), first round after Monday reopen was 31 minutes later ($1.13633). For 2026-09-18/21: 36 minutes before, 34 minutes after. No stale gap around either instant.
- **XAU/USD updates on a sparser, deviation-triggered cadence.** For 2026-09-25/28: the round in effect at Friday close was already 5 hours old (set 10:56 ET, next update not until the next afternoon), and the round crossing Monday reopen landed 70 minutes late. For 2026-09-18/21: the Friday reference round was 3 hours old and the next update didn't land until 21 hours later (Saturday). This means Treaty's actual on-chain fix for XAU/USD can sit tens of minutes to hours away from the "exact instant" price the gap table below uses. It is a real settlement-basis risk specific to gold, not present in EUR/USD.

Round data: `evidence/gap-tables/chainlink-weekend-rounds.json`.

## 3. Weekend scenario tables

Source: Dukascopy's live-chart JSON feed (`freeserv.dukascopy.com/2.0/index.php?path=chart/json3`, reached through the `dukascopy-python` package), 1-minute BID candles, free, no auth. This is the same Dukascopy tick archive that standalone `.bi5` downloaders use, already decoded. For each weekend I took the open of the 1-minute bar starting exactly at Friday 16:00 ET and at Monday 9:30 ET, with DST resolved through IANA `America/New_York` (each instant's own calendar date decides DST, matching `Treaty._isUsDst`/`fridayCloseOf`/`weekWindow`, which use the identical 2nd-Sunday-March/1st-Sunday-November rule). `gap_bps = round((monday_price - friday_price) / friday_price * 10000, 2)`.

**Both tables now hold exactly 504 real weekends, per the coordinator's requirement that the pricer needs exactly 504 scenarios and holidays must not be backfilled.** The generator (`scripts/generate_fx_gold_gap_tables.py`) was rewritten to walk backward one weekend at a time from 2026-09-25, skipping (logging, never interpolating) any weekend with no Dukascopy tick within 180 minutes of either target instant, and continuing further back in time until 504 real weekends were collected. This pushed each table's start date earlier than a naive 504-consecutive-calendar-weekend span, by exactly as many weekends as were skipped.

EUR/USD: 504 of 504 real weekends, spanning **2016-12-23 to 2026-09-25** (start weekend 2016-12-23/2016-12-26). 6 weekends skipped along the way, all Christmas/New Year weeks: 2017-12-22, 2017-12-29, 2020-12-25, 2021-01-01, 2023-12-22, 2023-12-29. Worst weekend: 2025-05-09 to 2025-05-12, -118.24 bps. 8 weekends past 1%, 0 past 4%.

XAU/USD: 504 of 504 real weekends, spanning **2016-06-03 to 2026-09-25** (start weekend 2016-06-03/2016-06-06), pushed back roughly 6.5 months further than EUR/USD's start because gold has far more holiday-thin weekends. 35 weekends skipped, all US holiday weekends (Good Friday, Thanksgiving, Christmas/New Year, Juneteenth, July 4th) across 2016 through 2026: 2016-11-25, 2016-12-23, 2016-12-30, 2017-04-14, 2017-11-24, 2017-12-22, 2017-12-29, 2018-03-30, 2018-11-23, 2019-04-19, 2019-11-29, 2020-04-10, 2020-07-03, 2020-11-27, 2020-12-25, 2021-01-01, 2021-04-02, 2021-11-26, 2021-12-24, 2022-04-15, 2022-11-25, 2022-12-23, 2022-12-30, 2023-04-07, 2023-11-24, 2023-12-22, 2023-12-29, 2024-03-29, 2024-11-29, 2025-04-18, 2025-07-04, 2025-11-28, 2026-04-03, 2026-06-19, 2026-07-03. Worst weekend: 2020-03-13 to 2020-03-16, -404.88 bps (the COVID crash weekend). 82 weekends (16.3%) past 1%, 1 (0.2%) past 4%.

int16 safety (money-path requirement, checked with an `assert` in `build_table()` before either file is written, and confirmed by reading the regenerated `.gaps.txt` files back): EUR/USD's 504 `gap_bps` values range **-118.24 to 155.38**; XAU/USD's range **-404.88 to 339.11**. Both comfortably inside `int16`'s `-32768..32767`.

Cross-check, 20 random weekends each (same seed, re-run on the extended 504-row tables; the sampled weekends are unchanged from the first pass because the candidate pool is filtered to `friday >= 2023-12-15`, which the backward extension never touches, only the older history before it does), against Yahoo Finance 60-minute bars (linearly interpolated to the exact target instant, since Yahoo has no multi-year 1-minute history): EUR/USD vs `EURUSD=X`, max absolute difference 11.3 bps. XAU/USD vs `GC=F` (COMEX gold futures, the closest Yahoo has to spot gold), max absolute difference 29.29 bps, larger because futures carry their own spot basis and a different daily maintenance-break trading calendar than the true 24/5 spot market, not because the two sources disagree on spot price.

Files: `evidence/gap-tables/EUR.json`, `evidence/gap-tables/XAU.json` (504 rows each), `.gaps.txt` (504 bps values each), `.crosscheck.json` per pair. Generator: `scripts/generate_fx_gold_gap_tables.py`. I did not extend `scripts/generate_gap_tables.py` (the equities generator): it pulls daily bars from api.nasdaq.com, which has no notion of a Friday-4pm/Monday-9:30 intraday instant, so reusing it would have meant faking the exact timestamps it can't provide.

## 4. What a layer would have paid

`loss_usd = exposure_usd * max(0, -gap_bps) / 10000` (both instruments are net long on Ostium's book, so only a down gap is a loss), `payout = min(limit, max(0, loss_usd - retention))`. Exposure is each instrument's own net OI from step 1 (EUR/USD $2,483,099.80, XAU/USD $1,610,525.06), not the blended fx/gold_metals group totals, since the gap table only prices that one instrument's move. Recomputed against the new 504-real-weekend tables (`scripts/summarize_gap_tables.py`).

EUR/USD, 504 weekends:
| Retention | Limit | Total paid | Weekends paying | Worst single payout |
|---|---|---|---|---|
| $0 | $124,155 | $1,550,690.86 | 236 | $29,360.17 |
| $24,831 | $248,310 | $9,872.80 | 3 | $4,529.17 |
| $49,662 | $496,620 | $0.00 | 0 | $0.00 |

XAU/USD, 504 weekends:
| Retention | Limit | Total paid | Weekends paying | Worst single payout |
|---|---|---|---|---|
| $0 | $80,526 | $2,194,420.92 | 232 | $65,206.94 |
| $16,105 | $161,053 | $488,638.13 | 41 | $49,101.69 |
| $32,211 | $322,105 | $132,765.24 | 11 | $32,996.44 |

Gold's tail is fatter and more frequent than EUR/USD's at every attachment point, matching its 16.3% past-1% weekend rate against EUR/USD's 1.6%. Extending the history by 6 (EUR) and 35 (XAU) real weekends moved the totals by little (EUR total paid $1,517,010.09 to $1,550,690.86; XAU $2,076,544.98 to $2,194,420.92): the added weekends are ordinary ones, and both instruments' worst weekend was already inside the shorter window.

## 5. Ostium sizing

One retention/limit layer proposed per market, sized against the coordinator's live reads: buffer $289.98 at block 510,278,303, net exposure EUR/USD $2,483,099.80, XAU/USD $1,610,525.06.

**Retention = $289.98 for both markets.** This attaches the layer exactly where Ostium's own buffer runs out today, the same "retention tracks the live buffer" logic already established for Heracles' equity layers: the buffer is the vault's own first-loss capital, and a retention set below it would mean Heracles pays for a loss Ostium's buffer would otherwise absorb, while a retention set meaningfully above it leaves the buffer's thinness (two to three orders of magnitude under either exposure, see section 1) uncovered. At $289.98 this is close to zero relative to either exposure, so in practice the layer pays on almost any down-gap weekend; that is a direct, honest consequence of how thin the live buffer is right now, not a modeling artifact, and it is the main reason this sizing should be revisited if the buffer materially rebuilds.

**Limit sized to the worst historical loss in the 504-weekend sample**, so the layer would have covered every one of the last 504 real weekends in full, not just a percentile:
- EUR/USD: worst-weekend loss $29,360.17 (2025-05-09, -118.24 bps on $2,483,099.80) minus $289.98 retention = limit **$29,100**.
- XAU/USD: worst-weekend loss $65,206.94 (2020-03-13, -404.88 bps on $1,610,525.06) minus $289.98 retention = limit **$65,000**.

What each layer would have paid across the 504 weekends (`retention=$289.98`, computed directly from the regenerated tables):

| Market | Limit | Paying weekends | Mean payout (over paying weekends) | Mean payout (over all 504 weekends) | Max payout |
|---|---|---|---|---|---|
| EUR/USD | $29,100 | 230 / 504 (45.6%) | $6,448.00 | $2,942.54 | $29,070.19 |
| XAU/USD | $65,000 | 228 / 504 (45.2%) | $9,331.70 | $4,221.48 | $64,916.96 |

Both layers pay on close to half of all weekends at this retention, which is the direct cost of anchoring retention to a near-zero live buffer rather than to a materially larger one: a buffer of, say, $25,000 to $30,000 (roughly where the $24,831/$16,105 retention rows in section 4 sit) would drop the paying-weekend count to single digits for EUR/USD and the low tens for XAU/USD, at a fraction of the max payout risk. That tradeoff, not the mechanics above, is the actual decision for Ostium: today's ~$290 buffer makes any layer priced to protect it pay often; a materially rebuilt buffer would make the same layer pay rarely.

## Source coverage

EUR.json and XAU.json each hold exactly 504 real weekends with no backfilled or interpolated rows; EUR/USD's window reaches back to 2016-12-23 and XAU/USD's to 2016-06-03 to absorb 6 and 35 skipped holiday weekends, both lists in full in section 3. The XAU/USD cross-check source is GC=F futures, a different instrument from spot XAU/USD, so its 29.29 bps max difference bounds the data-source gap from above.

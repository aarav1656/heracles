# Auction, pricing, adverse selection, settlement

Written 2026-09-26. Live reads: CBOE delayed quotes (2026-09-26 06:01:02 UTC), api.nasdaq.com daily bars.

## 1. Auction design

Setting: 1 to 3 bidders (evidence/critic-judge.md). Robinhood Chain is first-come-first-served by sequencer arrival, no priority gas auction (https://docs.robinhood.com/chain/differences-from-ethereum/).

| Format | Contract | No-show | Sniping | FCFS front-run |
|---|---|---|---|---|
| (a) Sealed commit-reveal, first price | 2 phases, 2 tx per bidder, deposit >= bid, forfeit on no-reveal | Deposit covers it; a silent bidder still delays clearing | None | None |
| (b) Open ascending, 10-min extension | bid() escrows, refunds prior top | Escrow | Extension | Latency race, neutralised by extension; bids leak the book to hedgers |
| (c) Dutch descending ask | price(t) + take(qty); smallest | None, premium paid in take tx | N/A | Latency race only when two takers share a value |
| (d) Batch uniform price (EasyAuction) | ~600 lines, ordered bid list, multi-tx clearing, cancellation cutoff, G0 audit (https://github.com/Gnosis-Auction/auction-contracts/blob/main/README.md) | Escrow at order | Cancellation window | None; clears at the lowest accepted bid, with 2 bidders that is the reserve |

Ribbon left Gnosis because it "clears at the lowest possible price where demand meets supply" for Paradigm blind all-or-nothing auctions at 4 bps (https://docs.ribbon.finance/theta-vault/theta-vault/auctions). Market makers "sell the relevant options on exchanges ahead of the auction"; ETH puts cleared 1.72 to 2.82 vols, calls 1.83 to 2.64 vols under Deribit's 24h VWAP; fix: several blind, full-size, fixed-time auctions over 24h (https://www.research.ribbon.finance/blog/ribbon-auction-performance-analysis). Paradigm/OrBit: 1-week ETH ATM IV around Friday auctions averages 4 vols below the prior 24h, 0.10% premium per week, 5.35% APY (https://www.paradigm.co/blog/paradigm-defi-options-vaults). Ribbon V3 spread flow over 10 random-time auctions Friday to Sunday (https://ribbonfinance.medium.com/ribbon-v3-8a3cd8757ecc). TEE sealed bids (https://arxiv.org/abs/2510.19491) and leaderless auctions (https://www.paradigm.xyz/writing/leaderless-auctions) are out of scope in 8 days.

Recommendation: (c). Ask starts at 2x reference, decays linearly to the reserve (1.25x) at the Friday 19:30 UTC cutoff; take(qty) pays premium and locks cover in one transaction; unsold cover returns to the writer. With 1 to 3 bidders every format clears near the reserve, so reserve quality (section 2) beats format; Dutch needs no escrow bookkeeping or reveal phase, and the disclosed reference price is the curve itself. The 4-vol front-run needs predictable size a desk can pre-hedge; our takers are inventory hedgers and series are capped. Move to (a) past 3 takers.

## 2. Reference pricing

IV source: `https://cdn.cboe.com/api/global/delayed_quotes/options/NVDA.json` (free, 15-min delayed, browser User-Agent required). Read today: NVDA 224.9975, 3,940 contracts with `iv`, `delta`, `bid`, `ask`; 2026-09-28 expiry 217.5 put (96.7% of spot) iv 0.2534, bid 0.14, ask 0.16; ATM iv 0.2041. Yahoo chart endpoints (yfinance backend) returned 429 today, so yfinance is fallback only.

Weekend variance: calendar-day models (365) decay 7 days over 5 sessions, business-day models (251) drop weekends; options decay less than calendar theta over a weekend, seen as Monday IV rising (https://moontowermeta.com/weekend-theta/, https://www.optionseducation.org/advancedconcepts/theta). AfterHours: `sigma_eff^2 T = sigma^2 (T_open + m^2 T_closed)`, `closedVolMult = 1.5e18` in contracts/script/Deploy.s.sol (https://github.com/bchuazw/afterhours).

Friday close to next open, 504 weekends per ticker, 2016-09-26 to 2026-09-26, from `https://api.nasdaq.com/api/quote/<T>/historical?assetclass=stocks&fromdate=2016-09-26&todate=2026-09-26&limit=9999` (SPY: assetclass=etf); no split residue (no gap over 40%):

| Ticker | mean abs | median | p90 | >3% | >5% | open < 97% | std | mean 97% put payoff | worst |
|---|---|---|---|---|---|---|---|---|---|
| NVDA | 1.33% | 0.93% | 2.64% | 7.1% | 2.6% | 4.4% | 2.12% | 0.161% (0.181% last 2y) | -14.7% |
| AAPL | 0.84% | 0.50% | 1.82% | 3.0% | 1.6% | 1.8% | 1.44% | 0.064% | -13.0% |
| SPY | 0.52% | 0.32% | 1.12% | 1.6% | 0.4% | 1.0% | 0.93% | 0.026% | -10.4% |
| TSLA | 1.73% | 1.26% | 3.74% | 14.3% | 4.8% | 6.5% | 2.60% | 0.150% | -14.9% |

Cross-check: NVDA median overnight gap is 32.9% of a day's range, 46.4% of weekend gaps fill within 24h (https://fxbacktest.app/research/weekend-gap-statistics/). Implied m for NVDA: 0.57 at IV 45%, 1.01 at the listed 25.3%. A normal gap underprices the tail (2.6% of NVDA weekends exceed 5%), so floor on the empirical payoff.

```
T       = m^2 * closedSeconds(cutoff, fixing) / 31_536_000     # m = 1, T_open = 0 after cutoff
sig     = CBOE iv of the put nearest 97% strike, nearest expiry >= Monday
d1      = (ln(S/K) + sig^2 T/2) / (sig sqrt T);  d2 = d1 - sig sqrt T
bs      = K N(-d2) - S N(-d1)                                   # r = 0 over 60h
ref     = max(bs, S * meanPayoff97_2y[ticker])
reserve = 1.25 ref;  start = 2 ref
```

Worked NVDA, K = 97%, IV 45%, 60h, m = 1: sig sqrt T = 3.72%; d1 = (0.03046 + 0.00069)/0.0372 = 0.837; d2 = 0.800; N(-d2) = 0.2119; N(-d1) = 0.2013; bs = 0.97 x 0.2119 - 0.2013 = 0.42% of spot = $0.96 per token at $225; empirical floor $0.41; reserve $1.20, start $1.92. At today's 25.3% IV the formula gives 0.07%, matching the listed Monday-expiry ask 0.16/225 = 0.071% (which covers Monday's session too), so the empirical floor binds: reserve $0.51.

## 3. Adverse selection

Dombrowski and Arshadi, 21 Backed tokens, Sept 2023 to April 2026: weekday beta 0.022 (t 1.22), "weekend predictability is stronger, with nine of 21 tokens reaching 5% significance and R2 up to 0.35" (https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6999355, abstract via https://timdombrowski.com/research.html). The signal exists only during the weekend, so:

1. Takes close Friday 19:30 UTC, before any weekend on-chain premium prints; Chainlink 24/5 feeds have no off-hours heartbeat (https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood).
2. Strike = 97% of the first Chainlink round with updatedAt >= Friday 20:00 UTC, computed in-contract, no parameter.
3. Reserve from section 2; nothing clears below model plus empirical.
4. Caps: series notional <= writer escrow; per taker <= 25% of the series.
5. Cash settlement from escrowed USDG. Delivering at K equals K minus S in cash, so physical removes selection only if tokens are escrowed at take, which forces pool operators to pull the weekend inventory they are hedging.

## 4. Settlement

Cash in USDG, pull-based: fix() stores `owed = max(K - fix, 0) * qty`, each side calls claim(). One token, one transfer, judges read "pays the gap". Physical adds a second approval and a stock-token transfer the issuer registry can block per address (`blockAccounts/isBlocked`, pausable, `adminBurn`; evidence/lane-official.md 1.5). Pull claims keep one blocked claimant from jamming the series. Physical is a v2 opt-in with tokens escrowed at take.

Blind spots: Paradigm's 4 vols is ETH 2021-22; gap table is one feed, Friday-only weekends; CBOE read pre-market.

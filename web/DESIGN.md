# Heracles web: the vault page, on paper

Direction picked by the user on 2026-09-29: mockup C (`mockups/v3-c.html`), modelled on
Morpho's vault page (app.morpho.org/ethereum/vault/0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB/steakhouse-usdc).
The page adds three things to C: A's declared-position input and cover-band slider inside the
buy panel, A's parametric note under Buy cover, and B's compare-markets strip as the chart's
market switcher.

## First screen (`/`)

Reading order, left column then panel:
1. `SPY weekend cover` at 64px, the last word muted (Morpho's "Steakhouse USDC"), a
   "Parametric" badge, then the meta row: pricer address, Arbitrum Sepolia, Stylus pricer, USDG.
2. One description: who it is for (the LP vaults of stock perp exchanges) and the trigger and
   payout rule, which follows the band: "more than 1% below Friday's close".
3. Three figures, each with its source under it:
   - **Premium**: `quote` on the deployed Stylus pricer, read at a named block, raised to the
     Treaty floor (`minRateOnLineBps` of the limit) exactly as `Treaty.bind` charges it.
   - **Cover pays up to**: the limit derived from the declared position and the band.
   - **Weekends it would have paid**: `backtest()` over `src/data/gap-tables/SPY.json`, plus
     how many hit the cap.
4. Tabs, all real: Weekends (the chart), This week (`WeekStrip` and the SPY feed), Pricer (EL,
   TVaR95 from the same quote, the browser rerun, the source file), Book (pool and layers with
   settle and claim).
5. Chart card: `GapChart` in compact mode. The market switcher is the compare strip: each
   ticker carries the weekends the same cover would have paid out of 504, computed from each
   gap table with the panel's current terms (SPY 36, TSLA 122, NVDA 110, AAPL 70 on the
   reference terms; guarded by `src/lib/gaps.test.ts`).
6. Panel: the vault's declared position (typed) with Long/Short, the cover band (two native
   range inputs on one track, 0.25% to 12% in 0.25% steps), rows for what the vault keeps,
   the cover period from `weekWindow`/`fridayCloseOf`, and the premium; then `BuyCover`;
   then the parametric note.

## Live re-quote

`useLiveQuote(terms)` waits 350 ms after the last keystroke or drag, reads the block number,
then calls `quote` at that block, so the block printed is the one the price came from. A newer
input cancels an older one in flight. While a new quote is pending the old figure dims to 45%
and its caption reads "re-quoting"; an invalid position clears the figures and prints the
reason. `/bind` uses the same hook.

## One bind path

`components/BuyCover.tsx` holds approve and `Treaty.bind` for both `/` and `/bind`, the
closed-window state, and the writer-backing shortfall (button reads "Buy cover, waiting for
writer backing", the note names the free USDG and the block). The v3 book (USDG or USDC) and
tranche choice become props here and on the Write ticket when the new ABI lands; nothing
about them is shown until then.

## Tokens (from the Morpho capture, `refshot.py ... 1440 1000 --full`, set on paper)

| Token | Value | Morpho source |
|---|---|---|
| ground | `#ECE8DF` | page behind the rounded sheet |
| sheet | `#FBFAF6`, 1px `#E2DDD1`, radius 16px, inset 10px | content surface |
| card | `#F3F0E8`, radius 14 to 16px | ticket boxes, chart card |
| ink / ink-2 / ink-3 | `#1C1A16` / `#3A362F` / `#6F6A5F` (5.2:1 on sheet) | text |
| mute | `#8C8679` (3.5:1, display sizes only) | the muted word in titles and units |
| teal | `#0B6B6B`, the only accent | CTA, band, paid slices, active tab |
| type | Geist Variable (Morpho's FK Grotesk is not free) | |
| nav pills | 13px, padding 12px 16px, radius 8px, active `rgba(28,26,22,.07)` | `a` token: 13px, radius 8px, padding 0 16px |
| display | 64px / 1, weight 400, -0.025em | |
| figures | 40px / 1, -0.03em, unit muted | "$66.23M" |
| body small | 14px / 21px; rows 12px | desc 13px / 20.8px |
| CTA | 48px tall, radius 8px, full panel width | "Connect" |

## Rules

- Parametric copy only: the payout is set by the price feed and the declared position, never by
  the vault's books. No indemnity words, no loss adjusting.
- Every on-chain figure carries its block; every historical figure is computed from the gap
  tables in the browser.
- No horizontal scroll from 320 to 1920 px (checked on `/`, `/bind`, `/write` at 12 widths).
- Under 640px the route pills fold into a menu by the logo, the badge hides, and a fixed bar
  carries the premium and the buy action (disabled with the reason when no backing exists).

## Gate record

Cold reader, fresh context, shown only `book-1440.png` and `book-390.png`, verbatim (one dash set as a comma):

> 1. Sells parametric weekend-gap insurance for SPY (and other tickers) to LP vaults on stock perp exchanges, paying out based on a price feed and a self-declared position if Monday's open falls too far below Friday's close.
>
> 2. Crypto-native perp exchange operators / vault managers hedging weekend gap risk, plus writers who back the coverage for premium.
>
> 3. "Connect" (top right), since nothing else is actionable until a wallet is linked.
>
> Confusing: the "Buy cover" button is disabled ("waiting for writer backing", 0 of 60,000 USDG funded), the whole flow is a promise of a live product with no capital actually behind it yet.

Read: correct on what, who and the first click. The disabled buy is the true testnet state
(the pool held 0 USDG at the capture block); "and other tickers" comes from the compare strip,
which the chart labels as the same cover drawn over other markets.

Slop check and side by side with `c-1440.png`: PASS on both after two rounds (removed the
tinted callout, the chart key and source inside the card, the enabled mobile buy with no
backing; C's four ticks; mobile nav folded). The first screen's chart card closes at y 955
against C's 920; the panel is taller than C's by the band slider and the parametric note,
both part of the brief.

# Heracles web: a trade desk for the weekend gap

The skin is GMX's (sidebar, navy surface, 4px instrument buttons, a numerals face split
from the UI face; tokens below). The product UX is GMX Trade's reading order applied to a
different market: the market is the weekend gap, the chart is every recorded weekend, the
order ticket prices a layer across that chart, and the book of positions sits underneath.
The reader is a vault risk lead, a multisig signer, or a USDG writer. Every figure on
screen is a live contract read at a stamped block or a row of a committed repo file named
next to it.

## First screen contract

**The sentence a judge must get in 5 seconds.** "Weekend-gap cover for perp LP vaults":
when a stock reopens on Monday away from Friday's close, the vault keeps the first loss
and a Heracles layer pays the next slice, priced on chain from 504 recorded weekends.
This is the page's `<h1>` plus one sentence, the only prose above the fold.

**What the first screen shows, in reading order (1440x900, verified by screenshot):**

1. `<h1>` and the one-sentence lede.
2. Market bar (GMX Trade's stat header): tabs SPY (marked live), NVDA, AAPL, TSLA, one per
   pricing table, then that table's worst weekend, biggest up gap, count of gaps past 1%,
   and the SPY/USD feed price.
3. The noun: every weekend of the selected table as one bar (Friday close to next open, in
   percent), the reference layer as a band across them from its attach gap to its
   exhaust gap. Bars that reach into the band are the weekends it would have paid (blue),
   bars through it used the full limit (red). The readout above the plot names the
   weekend under the pointer or keyboard cursor, defaulting to the worst on record.
4. The ticket rail: the live Stylus premium on the reference layer, its rate on line,
   EL, TVaR95, how many of 504 weekends it pays and exhausts, the block it was quoted at,
   then the two actions.

**Hero figures and their sources:**

| Figure | Value at build time | Source |
|---|---|---|
| Premium on the reference layer | 1,676.72 USDG | live `Pricer.quote([2,000,000e6], [SPY feed], 20,000e6, 60,000e6)` at the latest block, block number printed beside it (`hooks/useReferenceQuote.ts`); on failure the page says so and shows the README's recorded quote at block 313,690,038 |
| EL / TVaR95 | 1,051.19 / 20,368.00 | same live call |
| Weekends it pays / full limit | 36 / 2 of 504 | `evidence/gap-tables/SPY.json`, `Pricer.priceCore`'s payout rule at 1.0x volatility (`lib/gaps-core.ts`); the page states when the browser's EL matches the live pricer's |
| Worst SPY weekend | −10.45%, 13 Mar 2020 | `evidence/gap-tables/SPY.json` (source api.nasdaq.com, fetched 2026-09-28) |
| Gaps past 1% | 64 of 504 (SPY) | same file |
| SPY/USD price | e.g. 767.38 | `latestRoundData()` on the Sepolia SPY feed, inside the pinned book read |
| Stylus gas | 8.01x less L2 execution gas | `docs/pricing.md` "Gas", block 313,704,736; fine print, not a hero |

The reference layer is the README's own example (long 2,000,000 USDG SPY, retention
20,000, limit 60,000): the first number a visitor sees is a real, non-zero price for real
cover, not a balance.

**Page openings differ by job:** `/` stacks the `<h1>` over a two-line lede (the one
page that must explain the product); `/bind` and `/write` set the `<h1>` and a one-line
job statement on a single baseline.

**Primary action:** "Price your own layer" (to `/bind`, prefilled with the reference
layer). Secondary: "Write capacity".

**Honest state, lower down:** "This cover week" (the treaty's own `weekWindow` and
`fridayCloseOf`) and "The book" (layers bound, writer capacity, free to bind, all from
the pinned book read) sit below the fold. On this deploy both read zero, and the page says
so in one plain sentence with a link to become the first writer. An empty pool is never a
headline.

**Not on the first screen, on purpose:** the pool balance, contract addresses (one line at
the foot), the tower drawing (kept for a bound layer's details row).

## Flows

- **`/` Weekend gaps.** Job: prove the product exists and what it costs. Read the gap
  history, switch tables to see NVDA/AAPL/TSLA price the same layer very differently
  (TSLA pays on 122 of 504 weekends against SPY's 36), then leave through the ticket. For
  the three non-SPY tables the rail says plainly that the Sepolia pricer holds SPY only
  (`tableIdAt(1)` reverts `MissingTable`) and shows the table's EL/TVaR95 instead of a
  premium. A bound layer, when one exists, appears as a positions table with its settle
  and claim actions (`SettleItem`, `ClaimRow`, unchanged).
- **`/bind` Price a layer.** Job: the order ticket. Left column: the same chart drawing
  the buyer's own band, redrawn on every keystroke (sign flips move it to the up-gap
  side), then the cover week. Right rail: exposure, retention, limit (prefilled with the
  reference layer), the live premium with EL, TVaR95, attach gap and weekends paid, the
  rate-on-line floor note, then approve (only once a wallet is connected) and bind; when
  the limit exceeds free capacity the bind button says so and the line above it states
  both figures at the read block (`useTx`, contract calls unchanged). Mobile order: chart,
  ticket, week.
- **`/write` Write capacity.** Job: tell a writer what they are paid and what they can
  lose before asking for USDG. The panel is titled "In-sample backtest, not a forecast"
  and draws a writer's running result over the 504 SPY weekends at today's live premium
  on the reference layer, with y and year axes, red dots on the two full-limit weekends
  (−58,323 USDG each, 6 and 13 Mar 2020) and the deepest drawdown shaded and keyed below.
  Rail: deposit with permit (`useDepositWithPermit`, amount starts empty) and withdraw
  (`Capacity.withdraw`), quick-fill chips on real balances. Below: the pool, one plain
  sentence while it is empty, the free/locked/owed strip once it is not.

## Product study (GMX as a product, not a skin)

Read live in the `deepsurge` profile on 2026-09-29 (`app.gmx.io/trade`) and from
`docs/design-refs/gmx-{trade,pools}/study.md`:

- Reading order on Trade: market selector and live price, a stat header of market-wide
  numbers, the chart, then your own positions, with the order ticket in a right rail
  (direction, amounts, quick percentages, one CTA, then a consequence summary:
  liquidation price, fees).
- Density: 11px uppercase captions over 13-15px figures, 8/4/12px spacing leaders.
- Empty states: "No open positions" as plain text inside the positions table, never a
  headline. The first screen leads with the market's numbers, which are never empty.
- Pools leads with a market-wide figure (TVL), then rows.

Heracles maps each piece: the market is the weekend gap, the stat header is the table's
extremes, the chart is 504 weekends, the ticket's consequence summary is EL, TVaR95 and
weekends paid, and the positions table is the book.

Primary reference: the GMX Pools route at `app.gmx.io/#/pools`, captured as
reference screenshots and design tokens (desktop, mobile).
Secondary reference: the GMX Trade route (the trade route's right-rail order
form) and Ostium (a perp terminal in the same family, used only for the
quick-fill chip idea, never for its IBM Plex type or orange accent).

## Font substitution

GMX ships two proprietary faces: `TTHoves` for UI text and
`Relative`/`RelativeNumber` as a dedicated numerals face
("Type pairing" in the reference study; both are licensed and
are not copied). This project already carries three open faces
(`package.json`), so the substitution needed no new install:

- UI face: **Albert Sans Variable** (`@fontsource-variable/albert-sans`,
  already a dependency) stands in for TTHoves. Same role: nav, labels, body
  copy, buttons.
- Numerals face: **Archivo Variable** (`@fontsource-variable/archivo`,
  already a dependency), imported at its `wght.css` weight axis instead of
  the old `wdth.css` width axis, stands in for RelativeNumber. Same role:
  every figure, every table number, every big stat. GMX's own signature move
  ("Type pairing", point 3) is a UI face split from a numerals face; keeping
  that split with our own two families reproduces the move without touching
  the licensed fonts.
- Mono face: **DM Mono** (`@fontsource/dm-mono`, already a dependency),
  unchanged in role: addresses, tx hashes, round ids only, the trading-desk
  convention this project already used.

## Tokens

```css
--bg:          #090A14;  /* gmx-pools tokens.json body.background, rgb(9,10,20) */
--bg-1:        #121421;  /* tokens.json rootCustomProperties --color-slate-900, row/panel surface */
--bg-2:        #1E2033;  /* --color-slate-800, input fill / hover surface */
--bg-3:        #22243A;  /* --color-slate-700, secondary hover / active row */
--wash:        rgba(180,187,255,0.10); /* tokens.json colorHistogram.background top entry (32 occurrences): translucent lavender row tint over navy, not a hairline */
--border:      #363A59;  /* --color-stroke-primary */
--border-soft: #22243A;  /* --color-slate-700 used as a dim hairline */
--text:        #FFFFFF;  /* --color-typography-primary */
--text-2:      #A0A3C4;  /* --color-typography-secondary / --color-slate-100 */
--text-3:      #646A8F;  /* --color-slate-500, captions and dim labels */
--text-4:      #3E4361;  /* --color-typography-inactive, disabled text */
--primary:     #2D42FC;  /* --color-blue-400, elements.button.backgroundColor */
--primary-h:   #2A3DE5;  /* --color-button-primaryHover */
--primary-a:   #2536CD;  /* --color-button-primaryActive */
--positive:    #0FDE8D;  /* --color-green-500, colorHistogram.text positive figures */
--negative:    #FF506A;  /* --color-red-500, colorHistogram.text negative figures */
--focus:       #7885FF;  /* --color-blue-300; motion/focus states are not observable in a static
                             capture, so this ring is our own choice, picked for AA contrast on --bg */
```

Radius: `--radius-btn: 4px` (gmx-pools design tokens `elements.button.borderRadius`,
"the sharpest corner language of all nine references studied", reference study
signature move 4). `--radius-input: 8px` (design tokens `elements.input.borderRadius`).
`--radius-card: 12px` is a visual estimate from the rounded row corners in
`desktop.png`; tokens.json has no generic-`div` radius sample to cite, so this
one is read off the screenshot rather than the JSON.

Spacing: a 4px grid, weighted to 8/4/12px, the three leading values in both
references' spacing histograms (gmx-pools: 8px×263, 4px×218, 12px×200;
gmx-trade: 8px×117, 12px×103, 4px×53). This is tighter than the old design's
scale, matching "a data-dense trading dashboard" (reference study, "Density and
rhythm").

Type: `th` 11px/500/0.88px tracking, color `--text-2` (design tokens
`elements.th`, exact). `td` 13px/400 (`elements.td`, exact). Body copy 14px
(design tokens `elements.table`/`elements.input` fontSize; the 10px sampled on
`body.p` is a CSS-reset artifact from an unstyled text node, not a rendered
size, so it is not used). Nav links 14px (`elements.a`). Buttons 14px/600,
padding matching `elements.button.padding` (12px 24px) at the card scale, 8-10px
at compact scale. The headline figure is 34px/700, the middle of the reference
study's "visually ~32-36px bold" read of GMX's TVL numeral.

## Macrostructure

Fixed left sidebar (brand, three section links, the contract link, the
network name) plus a scrollable content column, replacing the ruled slip
header. This is GMX's "canonical DeFi-dashboard archetype" (reference study,
Macrostructure): sidebar for section switching, everything else is a panel.
On narrow viewports the sidebar becomes one top bar (brand, nav, wallet) that
wraps instead of scrolling, so nothing pans horizontally at 375px; GMX's own
mobile pattern is a slide-out drawer, which this project does not build since
there is no secondary content to hide behind one (three links fit a wrapped
bar without needing an off-canvas menu).

**Weekend gaps** (`Overview.tsx`) maps to the Trade route, not Pools: market bar, gap
chart, ticket rail, then the week and the book below. See "First screen contract".

**Price a layer** (`Bind.tsx`) maps to the Trade route: the gap chart with the buyer's
band sits where the price chart sits; the terms, live premium and bind action sit in the
right rail, mirroring the order form's inputs/CTA/consequence-summary stack. Contract
calls, exposure parsing and the quote pipeline are untouched.

**Write** (`Write.tsx`) is the pool deposit panel: deposit and withdraw stay
a left-column form, the pool's capacity strip stays a right-rail card. Both
amount fields gained quick-fill chips (25/50/75/Max of the caller's own
wallet balance for deposit, Free/Max redeemable for withdraw), the one
addition to this page beyond re-skinning; it is Ostium's and GMX's shared
"quick fill sits directly under the amount field" move (both studies list
it), wired to real balances already read by `useBook`, not new numbers.

## Signature moves applied

1. Superseded: the first screen no longer leads with the pool balance. It leads with a
   real `<h1>`, then the gap chart and the live premium (see "First screen contract").
2. Every row (layer rows, contract rows, table rows) is separated by
   `--wash` over the navy base, never by a hairline (move 2).
3. Numerals split from UI text into their own face, Archivo Variable
   standing in for RelativeNumber (move 3).
4. Buttons sit at the 4px "instrument" radius (move 4).
5. Trade-route shape: tower where the chart goes, order-ticket rail beside
   it (gmx-trade study, Macrostructure and Component archetypes).
6. Trade-route CTA language: rounded-rectangle primary buttons, not pills
   (gmx-trade study, move 4), reused as the one `.btn` class across the app.
7. Quick-fill chips under an amount input (gmx-trade move 3, Ostium move 2),
   applied to Write's deposit and withdraw fields against real balances.

## What stayed

Every contract call, every handler, every loading/empty/error branch, and every figure
the chain reports are unchanged. Additions: `lib/gaps.ts` (imports the committed gap
tables), `lib/gaps-core.ts` (the pricer's payout rule, tested against the pricer's
recorded outputs in `lib/gaps.test.ts`), `hooks/useReferenceQuote.ts`, and
`hooks/useWeekWindow.ts` (moved out of Bind). `quoteLive` gained an optional block number. The
tower's geometry (`tower-geometry.ts`) and its test are unchanged; only the
CSS painting its existing classnames moved from the cold-paper palette to
the tokens above. Copy was rewritten for the new layout (panel titles,
button labels) but no contract name or measured figure was invented; the gas
figure is the current 8.01x from `docs/pricing.md` (the older 4.06x was measured on a
superseded pricer).

## Chart tokens

`--pay: #8C97FF` (paid weekends, the brand-mark lavender already in the stylesheet),
`--band: rgba(120,133,255,0.09)` with a dashed `--band-edge` line at attach and exhaust,
`--negative` for weekends that used the full limit, `--text-3` for losses the vault keeps,
`--text-4` for gains on the covered side.

## States, focus, and motion

Unchanged in substance: every on-chain read still shows loading, empty, and
error with the decoded revert name; a missing value is still a dash with a
reason, never a zero. Focus is a 3px `--focus` ring at 2px offset on every
control (`:focus-visible`), visible against `--bg` and `--bg-2` alike. Motion
stays two primitives, a 120ms colour/opacity transition and a 1px press, both
inside `prefers-reduced-motion: reduce`. The gap chart is keyboard-operable (a slider:
arrows step a weekend, PageUp/PageDown a year, Home/End the ends) with the readout in an
`aria-live` line. No italic headings, no emoji icons,
no em dashes.

## Gate record (2026-09-29)

- `uicraft read` lock written before any TSX/CSS edit (`web/.uicraft-read.json`, git-ignored).
- `uicraft gate --cwd web/src`: 0 high findings; the same gate exits 1 on a slop fixture
  (7 high: transition-all, text-8xl, rainbow gradient, filler verbs).
- Hallmark slop test, gates checked on the rendered pages: no Inter/Roboto display face,
  no gradient text, no three-card grid, no nested cards, no transition-all, reduced-motion
  covers every transition, no horizontal scroll at 320/375/1920 on any route (measured
  `scrollWidth === innerWidth` over CDP), no two-line button labels, three font families,
  every chart figure has an accessible name, no invented metric (every figure is a chain
  read or a named repo file).
- `lib/gaps.test.ts`: 3 pass; flipping the loss sign in `gaps-core.ts` turns 2 red.
- Console: zero app errors on `/`, `/bind`, `/write`; the only exception seen is a browser
  wallet extension's `evmAsk.js` redefining `window.ethereum`.

**demo-judge verdict, round 3 (final):** "VERDICT: PASS. Nothing on these six screens
reads as templated or AI-generated. The GMX-style sidebar and market bar read as a
deliberate family resemblance, not a stock layout. Every figure on screen carries a
block number or a source file, and the empty pool is shown honestly without being the
hero." Per route: Weekend gaps PASS, Price a layer PASS, Write capacity PASS, Mobile 390
PASS. Round 1 was "PASS" with named templated tells (identical page openings, uppercase
stat-tile rows, five zero tiles, invisible paid bars, an unlabelled in-sample curve) and
round 2 "PASS" with one leftover label; each was fixed before the next round. The judge's
remaining highest-leverage item is product, not design: deposit and bind once on
Sepolia so the book shows a real layer.

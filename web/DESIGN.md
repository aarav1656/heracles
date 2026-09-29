# Heracles web: the underwriter's exhibit

Locked 2026-09-29 for branch `ui-v2`, after the mockup round. Research behind every choice:
`design-research/REFS.md` (10 references, screenshots in `design-research/refs/`),
extracted systems in `design-research/tokens-mercury*.json`, `tokens-morpho.json`,
`tokens-owid.json`, the replaced UI and its tells in `design-research/negative/`, the three
directions and the judge's pick in `design-research/mockups/PICK.md`. Identity claimed in
`.progress/ui-v2-registry.md` (row "Heracles"), distinct from Payday and Janus.

## Art direction

Heracles reads like an underwriter's exhibit on warm paper: a serif states the argument,
ink draws ten years of weekend gaps, and one deep teal marks the layer and nothing else.
The chart is the page and the ticket sits beside it; every figure carries the block or the
file it came from, in the quiet voice of a reinsurer, not the glow of a trading terminal.

North star: **Mercury's in-app screens** (two weights, three inks, one accent on one job,
flat ledger rows, cents set small). Secondaries: **Morpho's vault page** (a ticket beside a
pool's history and its risk text) and **Our World in Data's grapher** (serif title, caveat
as subtitle, source and note under the plot).

## Reader and first screen

The reader is a risk lead at a stock-perp exchange's LP vault, a multisig signer, or a USDG
writer. In five seconds they must get: *if a stock opens Monday far from Friday's close,
Heracles pays the vault a set amount worked out from the price feed and the position it
declared, and here is what that cover costs today.* Heracles is parametric: it never sees
the vault's books.

The first screen (1440x900) shows, in reading order:
1. the argument: serif `<h1>` "Cover for the weekend gap" and a one-sentence lede;
2. the noun: every SPY weekend since 2016 as one bar, the example cover drawn across the
   bars as a teal band, the part of each weekend inside the band filled solid teal, and one
   note in clear space: "Heracles pays when the Monday gap reaches this band";
3. the action: a flat ruled ticket beside the chart with one sentence carrying the live
   Stylus price, a plain line on how the payout is worked out, the history behind a
   disclosure, then "Price cover for your vault".

It is not the big-metric template: the premium is a figure in a sentence, set at the
sentence's size, and no stat tiles exist anywhere.

## Typefaces (two, both OFL)

- **Newsreader** (Production Type, variable weight and optical size,
  `@fontsource-variable/newsreader`). Display, titles, section titles, the ticket's terms
  sentence, and every figure. Why: a text face drawn for reading news on screens; the first
  screen is an editorial claim with a source line (the OWID title move), and a serif is the
  reinsurance register (Lloyd's slips, Re's Cormorant, Carta's SangBleu) without copying any
  of them. `font-optical-sizing: auto`.
- **Atkinson Hyperlegible Next** (Braille Institute, variable 200 to 800,
  `@fontsource-variable/atkinson-hyperlegible-next`). Words: UI text, labels, inputs,
  buttons, prose. Why: drawn so look-alike letters never collapse, for a reader who must
  not misread a term. Used light (360 to 420), the way Mercury runs Arcadia at 360/380.

Figures: Atkinson's zero is slashed and the face has no plain zero; beside Newsreader's
plain zero it read as a terminal (judge, `mockups/PICK.md`). So a `@font-face` named
`Heracles Figures` maps Newsreader's file to digits and figure punctuation only
(`unicode-range: U+0030-0039, U+002C, U+002E, U+0025, U+002B, U+2212`), and the sans stack
starts with it: every digit on the page is Newsreader.

No monospace face. Addresses and file names are set in the UI face as quiet links.

## Type scale

Tracking tightens with size (Carta measured -0.03em at 72px; Heracles uses -0.022em at
display). Tabular figures only in rows of figures (`.rows`, tables); proportional figures
in prose.

| Token | Face | Size / leading | Weight | Tracking | Use |
|---|---|---|---|---|---|
| `display` | Newsreader | 56 / 60 (mobile 38 / 42) | 380 | -1.23px | `<h1>` on `/` |
| `title` | Newsreader | 40 / 46 (mobile 30 / 36) | 400 | -0.8px | `<h1>` on `/bind`, `/write` |
| `section` | Newsreader | 24 / 30 | 420 | -0.3px | section `<h2>` |
| `chart` | Newsreader | 20 / 26 | 420 | -0.2px | chart titles |
| `terms` | Newsreader | 21 / 30 | 400 | -0.1px | the ticket's terms sentence |
| `lede` | Atkinson | 18 / 28 | 360 | 0 | under an `<h1>` |
| `body` | Atkinson | 15 / 24 | 380 | 0 | prose, rows |
| `small` | Atkinson | 13 / 20 | 400 | +0.1px | sources, notes, block stamps |
| `label` | Atkinson | 11.5 / 16 | 600 | +0.9px, uppercase | the only uppercase: field and row labels |

Money figures set their decimals small: 0.62em on a raised baseline (Mercury's
"$5,144,707.08"), via the `Money` component.

## Colour, 70 / 20 / 10

| Role | Token | Value | Job |
|---|---|---|---|
| 70 dominant | `--paper` | `#F3F0E8` | the page, warm, a treaty slip rather than a screen |
| | `--paper-2` | `#E9E5D9` | input fill |
| 20 support | `--ink` | `#1C1A16` | text, primary buttons, bars through the band |
| | `--ink-2` | `#57534A` | secondary text |
| | `--ink-3` | `#7F7A6E` | captions, losses the vault keeps |
| | `--ink-4` | `#B9B3A5` | gains on the covered side, disabled |
| | `--rule` | `rgba(28,26,22,0.14)` | hairlines, 1px |
| 10 accent | `--layer` | `#0B6B6B` | **the layer, only the layer**: band edges, paid slices, the note naming it, the swatch beside its terms. Deep reinsurance teal (Swiss Re's own is `rgb(0,110,115)`); vermilion belongs to Payday and amber to Janus in the registry |
| | `--layer-wash` | `rgba(11,107,107,0.09)` | the band's fill |

Primary buttons are ink: the accent never means "click". Errors are ink with a 2px ink rule
on the left and a bold lead word, never a second colour. Gains and losses are not coloured
green and red; the sign is printed and position says the side.

## Space, radius, elevation

8px scale: 4, 8, 12, 16, 24, 32, 48, 64, 96. Content max width 1240px, 32px gutters (20px
under 720px). Grid: main column 1fr, ticket 320px, gap 48px.

Radius 8px on controls and buttons (Mercury, 28 uses); nothing else is rounded. No panels:
sections are separated by space and one hairline. The ticket is flat: a 2px ink rule on
top, hairline rows (Mercury's ledger), no fill, no shadow. Elevation: none.

## Atmosphere

Paper, not a flat fill: a fractal-noise grain (inline SVG `feTurbulence`, 3.5% opacity,
multiply) over a warm vertical gradient (`#F6F3EC` to `#EFEBE1`). The chart field alone
carries rules: hairline gridlines every 2.5% of gap and a faint rule at each new year, an
exhibit on ruled paper. No glow, no blur, no gradient text, no hatching, no dotted grids.

## Motion

One orchestrated load, "the layer is set" (claimed in the registry):
1. 0 to 420ms: `<h1>` and lede rise 10px and fade in, `cubic-bezier(.2,.7,.2,1)`.
2. 120 to 420ms: all 504 weekends appear at once: the history is simply there.
3. 460 to 1060ms: the teal band opens downward from the retention line to the exhaust
   line, and each paid slice appears as the band's edge passes its depth, shallowest gap
   first, deepest last.
4. 1080 to 1300ms: the band's note (and on `/bind` the edge notes and the worst-weekend pin) fade in.
5. 280 to 640ms: the ticket fades in with final figures.

After that, state transitions only: changed terms on `/bind` move the band's edges over
240ms and cross-fade the figures over 120ms. No hover lifts, no scattered micro-animation.
`prefers-reduced-motion: reduce` removes every animation and transition.

## Structure, taken from real screens

- **Top bar** from Mercury's in-app header (`refs/mercury-accounts-1440.png`): wordmark
  left, three route names as plain words (active in `--ink` with a 2px ink underline, as
  Mercury's active tab carries a 2px inset rule; others `--ink-3`; no pills, no icons), the
  wallet button right. Replaces the GMX sidebar.
- **`/`** from OWID's grapher (`refs/owid-chart-1440.png`) plus Morpho's vault ticket
  (`refs/morpho-vault-1440.png`): argument, then the chart with its title, caveat and a
  source line directly under the plot; the ticket in the right column. Below the fold, a
  document in Morpho's order: the cover week and the book as Mercury's flat ledger rows
  (`refs/mercury-accounts-1440.png`), then how the quote is priced and the contracts.
- **`/bind`** from Morpho's vault page: the ticket on the right holds the inputs and the
  consequence rows; the chart on the left redraws the buyer's band on every keystroke.
- **`/write`** from Morpho's vault page: the writer's payout path (OWID's caveat as its
  subtitle, "In-sample backtest, not a forecast") beside the deposit ticket; the pool below
  as flat rows. The empty pool is one plain sentence, never a headline.
- **Mobile** from Morpho's key-value rows (`refs/morpho-earn-390.png`): the chart first,
  full width, then the ticket, then the document; nothing scrolls sideways.

## Components (one set, every route)

`Top`, `GapChart` (the noun, band, paid slices, pinned notes, keyboard readout), `Ticket`
(`.ticket`: terms sentence, `.rows`, actions), `Rows` (flat ledger rows: cover week, book,
pool, figures), `Field`, `.btn` (ink solid) and `.btn.line` (ink outline), `.src` (source
line), `Money` (figure with small decimals), `Stamp` (block link).

## Refusal list

- No cards, no panels, no card inside a card, no drop shadows.
- No stat tiles, no metric strip, no big figure over a small label.
- No pills or chips except the input quick-fills, which are text buttons.
- No monospace. No uppercase except `label`.
- No dark theme, no navy, no lavender, no glow, no glass, no gradient text.
- No second accent. Teal is the layer; it is never a button, a link or an error.
- No green and red gain and loss colouring.
- No icons in navigation, no icon above a heading, no sidebar.
- No invented number: every figure is a chain read at a printed block or a row of a named
  repo file. The empty pool is stated once, plainly, below the fold.
- No em dashes.

## Figures and their sources

| Figure | Source |
|---|---|
| Premium, EL, TVaR95 on the reference layer | live `Pricer.quote([2,000,000e6], [SPY feed], 20,000e6, 60,000e6)` at the latest block (`hooks/useReferenceQuote.ts`), block printed; on failure the README's recorded quote at block 313,690,038 is shown and labelled |
| Weekends paid / full limit | `data/gap-tables/SPY.json` (copy of `evidence/gap-tables`, source api.nasdaq.com, fetched 2026-09-28), `Pricer.priceCore` payout rule at 1.0x (`lib/gaps-core.ts`) |
| Stylus gas, 8.01x less L2 execution gas than the Solidity twin | `docs/pricing.md` "Gas", block 313,704,736 |
| SPY/USD price, book, capacity, allowance | `useBook` pinned read, block printed |

## Simplicity and plain words (user rules, 2026-09-29)

First screen of `/`: one sentence (the lede), one visual (the SPY chart with one note,
"Heracles pays when the Monday gap reaches this band"), one primary action ("Price cover
for your vault"). Three figures: 2,000,000, 1,676.72, 1%. The tail figures, the payout
schedule and the block live behind "What it would have paid since 2016" and in the small
source line. Terms are glossed where they appear: "Vault keeps first" (retention),
"Heracles pays up to" (limit, the cap), "Average payout a weekend" (expected loss),
"Average in the worst 5% of weekends" (TVaR95). Nav: Weekend gaps, Price cover, Earn
premium. Heracles is parametric, so every payout line says it is worked out from the price
feed and the declared position, never "pays the vault's loss".

## Gate record

- Critic, round 2 (final): "VERDICT: PASS. All eight fixes are in the new screenshots. The
  new first-screen rule holds on `/`, and I found no line that says Heracles pays the
  vault's actual losses." Full record: `design-research/VERDICT.md`.
- Cold reader, shown only the two first-screen screenshots: "It lets a perp exchange's
  liquidity vault get paid out when a stock's price gaps over the weekend, based on a price
  feed and the vault's declared position, and lets others earn premium by backing that
  cover." Who: "People running or backing a perp-exchange LP vault holding stock exposure
  ... plus USDG holders willing to underwrite that risk for yield." First click: "Price
  cover for your vault". PASS, not stronger than the contract.
- `npm run build` passes; `npm test` 3 pass (flipping the loss sign in `gaps-core.ts` turns
  2 red); `uicraft gate --cwd src` 0 high findings (4 high on a slop fixture); no
  horizontal scroll at 320, 390, 1440, 1920 on any route; zero app console errors on every
  route at 1440 and 390 (the one exception per page is a wallet extension's `evmAsk.js`).

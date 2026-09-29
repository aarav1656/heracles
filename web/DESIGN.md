# Heracles web: the underwriter's exhibit

Locked 2026-09-29 for branch `ui-v2`. Research behind every choice:
`design-research/REFS.md` (10 references, screenshots in `design-research/refs/`),
extracted systems in `design-research/tokens-mercury*.json`, `tokens-morpho.json`,
`tokens-owid.json`, the replaced UI and its tells in `design-research/negative/`.

## Art direction

Heracles reads like an underwriter's exhibit on warm paper: a serif states the argument,
ink draws ten years of weekend gaps, and one vermilion marks the layer and nothing else.
The chart is the page and the ticket sits beside it; every figure carries the block or the
file it came from, in the quiet voice of a reinsurer, not the glow of a trading terminal.

North star: **Mercury's in-app screens** (two weights, three inks, one accent on one job,
flat ledger rows, cents set small). Secondaries: **Morpho's vault page** (a ticket beside a
pool's history and its risk text) and **Our World in Data's grapher** (serif title, caveat
as subtitle, source and note under the plot). Visually distinct from the three sibling
products, which are all dark.

## Reader and first screen

The reader is a risk lead at a stock-perp exchange's LP vault, a multisig signer, or a USDG
writer. In five seconds they must get: *the vault keeps the first slice of a Monday gap
loss, a Heracles layer pays the next slice, and here is what that layer costs today.*

The first screen (1440x900) shows, in reading order:
1. the argument: serif `<h1>` and a two-line lede;
2. the noun: every SPY weekend since 2016 as one bar, the reference layer drawn across the
   bars as a vermilion band, the slice of each weekend's loss the layer pays hatched inside
   the band (Stripe Capital's hatched repayment slice), with tags pinned onto the drawing
   ("vault keeps", "layer pays", the worst weekend) the way Carta pins labels on its globe;
3. the action: a ticket beside the chart stating the reference layer in one sentence, its
   live Stylus premium inside that sentence, the consequence lines (expected loss, TVaR95,
   weekends paid, the block it was quoted at), then "Price your own layer".

It is not the big-metric template: the premium is a figure in a sentence, set at the
sentence's size in the serif, and no stat tiles exist anywhere.

## Typefaces (two, both OFL)

- **Newsreader** (Production Type, variable weight and optical size,
  `@fontsource-variable/newsreader`). Display, page titles, section titles, and the
  ticket's terms sentence. Why: a text face drawn for reading news on screens; Heracles's
  first screen is an editorial claim with a source line, the OWID title move, and a serif
  is the reinsurance register (Lloyd's slips, Re's Cormorant, Carta's SangBleu) without
  copying any of them. Optical size follows the size (`font-optical-sizing: auto`).
- **Atkinson Hyperlegible Next** (Braille Institute, variable 200 to 800,
  `@fontsource-variable/atkinson-hyperlegible-next`). All UI text, labels, every figure,
  inputs, buttons. Why: drawn so that look-alike glyphs (1 l I, 0 O, 5 S, 8 B) never
  collapse; a risk lead typing 2,000,000 against 20,000 must not misread a digit. Used at
  light weights (360 to 420) the way Mercury runs Arcadia at 360/380.

No monospace face. Addresses and file names are set in the UI face; a file name is
written as a quiet link, not as code.

## Type scale

Tracking tightens with size at Linear's measured ratio (-0.022em at display).
Tabular figures only inside tables (`font-variant-numeric: tabular-nums` on `table` and
the ticket's figure list); proportional lining figures everywhere else.

| Token | Face | Size / leading | Weight | Tracking | Use |
|---|---|---|---|---|---|
| `display` | Newsreader | 56 / 60 (mobile 38 / 42) | 380 | -1.23px (-0.022em) | `<h1>` on `/` |
| `title` | Newsreader | 40 / 46 (mobile 30 / 36) | 400 | -0.8px (-0.02em) | `<h1>` on `/bind`, `/write` |
| `section` | Newsreader | 24 / 30 | 420 | -0.3px | section `<h2>`, chart titles |
| `terms` | Newsreader | 21 / 30 | 400 | -0.1px | the ticket's terms sentence, with the premium in it |
| `lede` | Atkinson | 18 / 28 | 360 | 0 | one or two sentences under an `<h1>` |
| `body` | Atkinson | 15 / 24 | 380 | 0 | prose, table cells |
| `small` | Atkinson | 13 / 20 | 400 | +0.1px | source lines, notes, block stamps |
| `label` | Atkinson | 11.5 / 16 | 600 | +0.9px, uppercase | the only uppercase: field and column labels (OWID's 12px/900/1.2px, lighter) |

Cents are set small: in a money figure, the decimal part is 0.62em on a raised baseline
(Mercury's "$5,144,707.08").

## Colour, 70 / 20 / 10

| Role | Token | Value | Job |
|---|---|---|---|
| 70 dominant | `--paper` | `#F3F0E8` | the page, warm, a treaty slip rather than a screen |
| | `--paper-2` | `#EBE7DC` | the ticket, the one filled surface (Morpho's move) |
| | `--paper-3` | `#E2DDD0` | input fill, pressed rows |
| 20 support | `--ink` | `#1C1A16` | text, primary buttons, bars |
| | `--ink-2` | `#57534A` | secondary text |
| | `--ink-3` | `#8A8578` | captions, a loss the vault keeps |
| | `--ink-4` | `#B9B3A5` | gains on the covered side, disabled text |
| | `--rule` | `rgba(28,26,22,0.13)` | hairlines, 1px |
| 10 accent | `--layer` | `#D2431C` | **the layer, and only the layer**: the band, its edge lines, the hatched paid slices, the tags that name it, the swatch beside its terms |
| | `--layer-wash` | `rgba(210,67,28,0.08)` | the band's fill |

Primary buttons are ink, not accent (Carta's black "Request a demo"): the accent never
means "click". Errors are ink with a 2px ink rule on the left and a bold lead word; they
are never a second red. Gains and losses are not coloured green and red: the chart says
which side is which by position, and the sign is always printed.

## Space, radius, elevation

8px scale: 4, 8, 12, 16, 24, 32, 48, 64, 96. Content max width 1240px, 32px gutters
(20px under 720px). Grid on `/`: chart column 1fr, ticket 360px, gap 48px.

Radius: controls and buttons 8px (Mercury, 28 uses); the ticket 12px; nothing else is
rounded. No panels: sections are separated by space and one hairline, never by a box.

Elevation: one, on the ticket only: `0 1px 0 rgba(28,26,22,0.05), 0 18px 40px -24px
rgba(28,26,22,0.28)`.

## Atmosphere

Paper, not a flat fill: a fractal-noise grain (inline SVG `feTurbulence`, 3.5% opacity,
multiplied) over a two-stop warm gradient (`#F6F3EC` at the top to `#EFEBE1` at the foot).
The chart field alone carries drafting rules: hairline gridlines at every 2.5% gap and a
faint rule at each year, like an exhibit on graph paper. No glow, no blur, no gradient on
text.

## Motion

One orchestrated load on `/` (and the same chart entrance on `/bind`):
1. 0 to 420ms: `<h1>` and lede rise 10px and fade in, `cubic-bezier(.2,.7,.2,1)`.
2. 160 to 900ms: the weekends draw left to right, each bar growing out of the zero line,
   delay = its index / 504 x 560ms, 240ms each: ten years of history written in.
3. 900 to 1240ms: the layer band wipes in from the left (clip-path), then its hatched
   slices and tags fade in.
4. 280 to 640ms: the ticket fades in; its figures are already final.

State transitions only after that: when terms change on `/bind`, the band's edges move
over 240ms and the figures cross-fade over 120ms; hover on the chart moves the readout
cursor without animation. No scattered micro-animations, no hover lifts.
`prefers-reduced-motion: reduce` removes every animation and transition.

## Structure, stolen from real screens

- **Top bar** from Mercury's in-app header and Linear's filter tabs
  (`refs/mercury-accounts-1440.png`, `refs/linear-top-1440.png`): wordmark left, three
  route names as plain words (active in `--ink`, others `--ink-3`, no pills, no icons), the
  wallet button right. Replaces the GMX sidebar.
- **`/`** from OWID's grapher (`refs/owid-chart-1440.png`) plus Morpho's vault ticket
  (`refs/morpho-vault-1440.png`): title and caveat, then the chart with the source line
  directly under the plot, the ticket pinned to the right column. Below the fold, a
  document in Morpho's order: the cover week (on Linear's date rail), the book (Mercury's
  flat ledger rows, `refs/mercury-accounts-1440.png`), then the contracts line.
- **`/bind`** from Stripe Capital's offer-and-chart pairing
  (`refs/stripe-capital-1440.png`): terms on the right redraw the chart on the left.
- **`/write`** from Morpho's vault page: the writer's payout path (OWID caveat as its
  subtitle: "In-sample backtest, not a forecast") beside the deposit ticket; the pool below
  as flat rows. The empty pool is one plain sentence, never a headline.
- **Mobile** from Morpho's key-value rows (`refs/morpho-earn-390.png`): the chart first,
  full width, then the ticket, then the document; no table scrolls sideways.

## Components (one set, every route)

`Top` (bar), `Argument` (h1 plus lede), `GapChart` (the noun, with `layer` and `tags`),
`Ticket` (terms sentence, figure list, actions), `Rail` (the cover week), `Ledger` (flat
rows: the book, the pool), `Field` (label, input, hint), `Button` (ink solid, ink outline),
`Source` (small line: what, where from, at which block), `Money` (figure with small cents).

## Refusal list

- No cards, no panels, no card inside a card. One filled surface per screen: the ticket.
- No stat tiles, no metric strip, no big figure over a small label.
- No pills or chips except the input quick-fills, which are text buttons.
- No monospace. No uppercase except `label`.
- No dark theme, no navy, no lavender, no glow, no glass, no gradient text.
- No second accent. Vermilion is the layer; it is never a button, a link or an error.
- No green and red gain and loss colouring.
- No icons in navigation, no icon above a heading.
- No sidebar.
- No invented number: every figure is a chain read at a printed block or a row of a named
  repo file. The empty pool is stated once, plainly, below the fold.
- No em dashes.

## Figures and their sources (unchanged from the previous build)

| Figure | Source |
|---|---|
| Premium, EL, TVaR95 on the reference layer | live `Pricer.quote([2,000,000e6], [SPY feed], 20,000e6, 60,000e6)` at the latest block (`hooks/useReferenceQuote.ts`), block printed; on failure the README's recorded quote at block 313,690,038 is shown and labelled |
| Weekends paid / full limit | `data/gap-tables/SPY.json` (copy of `evidence/gap-tables`, source api.nasdaq.com, fetched 2026-09-28), `Pricer.priceCore` payout rule at 1.0x (`lib/gaps-core.ts`) |
| Stylus gas, 8.01x less L2 execution gas than the Solidity twin | `docs/pricing.md` "Gas", block 313,704,736 |
| SPY/USD price, book, capacity, allowance | `useBook` pinned read, block printed |

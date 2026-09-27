# Heracles web: rebuilt on GMX's Pools and Trade design

Replaces the cold-paper placing slip. This reads as a dashboard inside the GMX
family: a fixed left sidebar, a dark navy surface, rounded card rows instead
of ruled lines, a blue primary action, and a big on-chain figure leading the
page instead of a headline. The reader is still a vault risk lead, a multisig
signer, or a USDG writer, and every number on the page is still a direct
contract read at a stamped block. Only the visual language changes.

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

**Book** (`Overview.tsx`) maps to the Pools route: a headline figure (the
pool's USDG balance, a direct `Capacity.balanceOf`-chain read, already in
`useBook`) leads the page with free/locked/owed as its sub-stats and a thin
proportion bar underneath, in place of GMX's period-tab row. The period tabs
(Last 30d/90d/180d/Total) switch a time series this contract does not expose;
inventing tab behaviour with no data behind it would be exactly the fake
metric the brief forbids, so the tabs are dropped and the sub-stats plus the
strip carry their job instead. "Layers on the book" and "Writer capacity"
render as the two GMX-style panels, each a rounded card, each row inside them
a translucent-wash card rather than a ruled line (signature move 2).

**Bind** (`Bind.tsx`) maps to the Trade route: the layer tower sits where the
chart sits, full width in the main column, in the reference's colour
language. The exposure/retention/limit form, the live premium quote, the
week clock, and the bind action move into a fixed-width right rail, mirroring
the order form's margin/size/leverage/CTA/liquidation-summary stack
(reference study, gmx-trade "Component archetypes"). `LayerTower.tsx`'s markup and
`tower-geometry.ts` are unchanged; only the CSS the classnames resolve to
changes; contract calls, exposure math, and the quote pipeline are untouched.

**Write** (`Write.tsx`) is the pool deposit panel: deposit and withdraw stay
a left-column form, the pool's capacity strip stays a right-rail card. Both
amount fields gained quick-fill chips (25/50/75/Max of the caller's own
wallet balance for deposit, Free/Max redeemable for withdraw), the one
addition to this page beyond re-skinning; it is Ostium's and GMX's shared
"quick fill sits directly under the amount field" move (both studies list
it), wired to real balances already read by `useBook`, not new numbers.

## Signature moves applied

1. The Book page leads with a raw numeral, no semantic h1 wrapping it; the
   number is the headline the way GMX's TVL is (reference study move 1). A real
   `<h1>` still exists for the page's own accessible name, styled as a small
   eyebrow label, so markup and visual hierarchy diverge on purpose the same
   way GMX's does.
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

Every hook, every contract call, every handler, every loading/empty/error
branch, and every figure the chain reports are unchanged; `src/hooks`,
`src/lib`, `src/abi`, `src/chain.ts`, and `scripts/` were not touched. The
tower's geometry (`tower-geometry.ts`) and its test are unchanged; only the
CSS painting its existing classnames moved from the cold-paper palette to
the tokens above. Copy was rewritten for the new layout (panel titles,
button labels) but no fact, no contract name, and no measured figure (the
4.06x Stylus gas figure, the 0.5% rate-on-line floor, the Sherlock cover-cost
range) was changed or dropped.

## States, focus, and motion

Unchanged in substance: every on-chain read still shows loading, empty, and
error with the decoded revert name; a missing value is still a dash with a
reason, never a zero. Focus is a 3px `--focus` ring at 2px offset on every
control (`:focus-visible`), visible against `--bg` and `--bg-2` alike. Motion
stays two primitives, a 120ms colour/opacity transition and a 1px press, both
inside `prefers-reduced-motion: reduce`. No italic headings, no emoji icons,
no em dashes.

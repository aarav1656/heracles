# Heracles design references (2026-09-29)

Captured in the `deepsurge` profile with `scripts/refshot.py` (waits for load, fonts and
network quiet; refuses error, challenge and blank pages). Desktop is 1440 wide with
`--full`, mobile is 390x844. Every PNG named here was opened and viewed before its entry
was written. Token values come from the `*.tokens.json` written beside each PNG and, for the
north star and the two secondaries, from a fuller computed-style pass over CDP saved as
`../tokens-<site>.json` (type-scale, colour, radius, border and shadow histograms).

The first capture pass (a script that shot before render) was deleted in full and redone
with refshot; nothing below comes from it.

Heracles's problem shape: a risk lead at a perp exchange's LP vault reads a history (504
weekend gaps), sees a layer drawn across it, and prices or binds that layer. A writer
reads the same history as a payout path and deposits. So the references are money
products that put a history and an action on one screen, and domain products that sell
cover or allocate risk capital.

---

## 1. Mercury, in-app demo (north star)

Screens: `refs/mercury-dashboard-1440.png` / `-390.png`, `refs/mercury-transactions-1440.png` /
`-390.png`, `refs/mercury-accounts-1440.png` / `-390.png` (demo.mercury.com, the product,
not the marketing page). The deepsurge profile prefers dark, so the PNGs are Mercury's dark
theme; the light theme's values were read with `prefers-color-scheme: light` emulated
(`../tokens-mercury-light.json`).

What the screen is: a business bank. Home is a balance with a 30-day line, then accounts;
Transactions is a filterable ledger; Accounts is a balance over a flat table of accounts.

Moves worth stealing:
- Light-weight display type for a money product: h1 "Accounts" Arcadia Display 28px,
  weight 380, leading 36px; body Arcadia Text 16px weight 360. Nothing is bold; hierarchy
  comes from size and ink tone, three inks only (light theme `rgb(30,30,42)`,
  `rgb(83,84,97)`, `rgb(112,112,125)`).
- Cents set small and raised: "$5,144,707.08" with ".08" at roughly 60% size on a raised
  baseline, repeated in every table cell ("$12,505.87"). Figures read as money, not as code.
- Flat ledger rows, no cards: Accounts is a table of rows 66px tall split by one hairline
  `1px solid rgba(112,115,147,0.1)` (light), right-aligned amounts, a two-line name cell
  (name, then "Checking ••1038" in the tertiary ink).
- One accent, one job: `rgb(82,102,235)` fills the single primary action ("Open account",
  "Send") and the active tab's `0 -2px 0 0 inset` underline. Everything else is ink.
- Radius discipline: 8px (28 uses) on controls, 4px (21) on small chips, 9999px only for
  the action row pills.
- Action row directly under the page title (Send, Transfer, Deposit, Request): the verbs
  sit above the data, not in a card footer.

Numbers, empty states, primary action: numbers are right-aligned with superscript cents;
money in is the accent green only in the ledger. "AR $0.00" is shown as a normal row,
never a headline or an apology. Primary action is the one filled pill.

Do NOT take: the side-stat strip next to "Available" (big figure plus two small stats is
the template this rebuild must avoid); the promo drawer ("Try out Mercury for yourself");
the dark theme (all three sibling products are dark); tables that clip sideways at 390
(`mercury-accounts-390.png` cuts the balance column).

## 2. Morpho app (secondary: how a risk product shows capacity and a deposit ticket)

Screens: `refs/morpho-earn-1440.png` / `-390.png` (vault list), `refs/morpho-vault-1440.png` /
`-390.png` (Steakhouse USDC vault detail, full page), `refs/morpho-borrow-1440.png` / `-390.png`
(market list). Tokens: `refs/morpho-*.tokens.json`, `../tokens-morpho.json`.

What the screen is: the vault page is the closest shape to Heracles's `/write`: a pool of
capital, what it is exposed to, its history, its risk, and a deposit ticket.

Moves worth stealing:
- One weight for everything: FK Grotesk at weight 400 across the whole page (432 nodes at
  16px/400, 304 at 12px/400, figures at 38px/400). Hierarchy is size plus ink opacity only:
  `rgba(255,255,255,0.95)`, `0.698`, `0.5`.
- Two-tone titles and units: "Steakhouse" in full ink, "USDC" in the second ink; "$66.23" in
  full ink with the "M" in the second ink. The unit is present but quiet.
- Deposit ticket pinned top right of the vault page, above the fold, with the consequence
  lines under the amount (APY, projected monthly and yearly earnings) before the one
  button. The ticket is the only filled surface; the rest of the page is bare.
- Hairlines at half a pixel: `0.5px solid rgba(255,255,255,0.07)`; control radius 8px,
  panel radius 20px, accent `rgb(41,115,255)` only on Connect and the active tab.
- Page order below the fold is a document, not a dashboard: Overview, Allocation,
  Performance, Risk (plain-text risk disclosure paragraph), Activity.
- Mobile turns table rows into key-value blocks (`morpho-earn-390.png`): label left, value
  right, one per line, instead of a sideways-scrolling table.

Numbers, empty states, primary action: every token amount carries its USD twin in a small
grey chip; percentages are plain. Primary action is the blue Connect in the ticket.

Do NOT take: the dark theme; the stacked logo "exposure" icon clusters (Heracles has one
market live, not a basket); the three-figure stat row at the top of the vault page (Total
Deposits, Liquidity, Exposure, Net APY is the metric-strip template); the chat bubble.

## 3. Our World in Data grapher (secondary: a history chart that carries its source)

Screens: `refs/owid-chart-1440.png` / `-390.png` (column chart view),
`refs/owid-table-1440.png` / `-390.png` (table view, full page including the
"What you should know", "Sources and processing" and "Reuse this work" sections),
`refs/owid-sources-1440.png` / `-390.png` (a second grapher, economic damage by disaster
type). Tokens: `refs/owid-*.tokens.json`, `../tokens-owid.json`.

Replaced: Nexus Mutual's app was the first pick for this slot, but `/staking` and the quote
route return "page not found" to refshot and the mobile capture was a cookie wall, so it was
deleted. OWID fits the shape better anyway: Heracles's argument is a 10-year history of
losses with a source line under every figure, and OWID is the reference product for that.

What the screen is: one chart per page, a title that says what is drawn, a one-sentence
caveat, the chart, then data source, note and licence directly under the plot, then a
long-form document explaining the indicator.

Moves worth stealing:
- Serif title over a sans chart: h1 Playfair Display 25px weight 600, leading 30px, ink
  `rgb(45,46,45)`, with the date range "1970 to 2025" inline after the title in a lighter
  grey. Body and chart labels Lato 16px/400, leading 25.6px, ink `rgb(91,91,91)`.
- The caveat is the subtitle: "Note that this largely reflects increases in data reporting,
  and should not be used to assess the total number of events." Heracles's writer path
  needs exactly this ("in-sample backtest, not a forecast") in the same place.
- Source block under the plot at 13px: "Data source: EM-DAT, CRED / UCLouvain (2026)",
  then "Note:", then the licence. No source floats in a tooltip.
- Small caps section labels at 12px, weight 900, tracking 1.2px (`ADD/REMOVE DISASTER TYPES`)
  in `rgb(118,118,118)`: the only uppercase on the page.
- Chart / Table toggle on one chart. The table view shows each series with first value,
  last value, a sparkline and absolute and relative change.
- Timeline scrubber under the plot (1970 to 2025 handles), keyboard operable.
- Radii 2px (21 uses) and 4px (14): corners are barely there; borders `1px solid
  rgb(242,242,242)`.

Numbers, empty states, primary action: axis values are plain ("$400 billion"), series totals
are right-aligned in the side list ("Extreme weather $63B"); a zero is written "$0", not
hidden. There is no primary action: the page is the product.

Do NOT take: the navy header bar and red rule (institutional branding); Playfair Display
(the most over-used free display serif); the multi-hue categorical palette (Heracles has
one series and one layer); the donate strip.

## 4. Carta (marketing page; the one move is the annotated drawing)

Screens: `refs/carta-1440.png` (full page), `refs/carta-390.png`. Tokens:
`refs/carta-1440.tokens.json` plus a histogram pass over CDP (IBM Plex Mono labels, coral
fills, border colours).

What the screen is: the equity and fund-admin company's homepage. The product itself is
behind a login, so this is not a secondary; it is here for one move.

Move worth stealing: the hero draws the noun as a line drawing (a globe of dashed and solid
orange strokes) with labelled tags pinned to it ("CAP TABLE", "FUND", "LIMITED PARTNER"),
each tag a small filled label on the stroke it names. Heracles can pin its tags the same
way: "vault keeps", "layer pays", "13 Mar 2020" pinned onto the gap chart. Type: h1
sangBleuVersailles 72px weight 400, tracking -2.16px (-0.03em), leading 86.4px (1.2), ink
`rgb(26,26,26)`; h2 22px, tracking -0.66px. Body Plus Jakarta Sans 16px/400, leading 24px;
secondary ink `rgb(101,107,107)`. One accent, coral `rgb(255,125,85)`, only on the drawing
and its tags. Buttons: filled ink and outlined ink, both 8px radius, stacked full-width on
mobile (`carta-390.png`). Hairlines `1px solid rgb(222,223,223)`.

Numbers, empty states, primary action: "Trusted by 50,000 companies" is set in the serif at
22px as a sentence, not a stat tile; the one large figure ("1.7M+") sits far down the page.
Primary action is the black "Request a demo".

Do NOT take: IBM Plex Mono tags (monospace labels are on the refusal list); the dark "C
onnect" grid section; the three-up feature cards; the logo wall.

## 5. Swiss Re Institute, sigma research (the reinsurer's own voice)

Screens: `refs/swissre-1440.png` (full page), `refs/swissre-390.png`. Tokens:
`refs/swissre-1440.tokens.json`, plus a histogram pass over CDP.

What the screen is: the research index of the world's second-largest reinsurer: sigma
reports, short insights, one featured article on excess and surplus lines.

Move worth stealing: reinsurance speaks quietly. Swiss Re Sans at weight 200 for display and
body (22px, leading 33px; 234 nodes at 22px/200), ink `rgb(60,65,80)`, never black. The one
accent is a deep teal `rgb(0,110,115)` used only on the filled buttons ("Read more",
"Find all sigma data"). The feature block (`SIGMA INSIGHTS 02/2026` over "A new phase for
the US surplus lines insurance market") sets a small tracked label, a light 30px headline and
a four-line paragraph, then one button: argument first, action last. Radii 4px.

Numbers, empty states, primary action: the only figure on the page is the share price in the
footer ("CHF 142.90", "+0.88%" in a small green chip, "28 Sep 2026, 17:30 CEST"): every figure
is dated. Primary action is the one teal button per block.

Do NOT take: stock photography heroes (the eye, the server hall); floating white cards with
`0 10px 60px rgba(0,0,0,0.2)` shadows; the carousel; weight 200 at body size on screens
(thin strokes blur on a non-retina panel, use it for display only).

## 6. Ethena transparency dashboard (domain; mostly a negative lesson)

Screens: `refs/ethena-1440.png` (viewport; the `--full` pass caught the four chart panels
before their data loaded, so it was recaptured at viewport height where the charts render),
`refs/ethena-390.png`. Tokens: `refs/ethena-1440.tokens.json`.

What the screen is: USDe's proof-of-reserves page: backing ratio, backing and supply
figures, backing and price history charts, custodian attestations, auditor checks.

Move worth stealing: proof as a dated table. "Proof of Reserves, Last Updated: 25 Sep 26
05:29", then a four-row table (Auditor x Overcollateralized x Delta-Neutral, each "Yes"),
and a pager to the previous date. Heracles's equivalent is its block stamp: every chain read
carries the block it was read at and links to it. Type: SuisseIntl, h2 24px/500 leading
32px, h3 18px/500 leading 28px, body 16px/400 on `rgb(5,5,5)` with ink `rgb(229,231,235)`.

Numbers, empty states, primary action: numbers in four equal stat tiles ("101.35%", "$4.97B",
"4.91B", "$0.9997"); the charts carry `$`/`%` and range toggles. Primary action (Connect
Wallet) is a dark outlined pill.

Do NOT take (this is the list of tells in one screen): four stat tiles inside a bordered
card (cards in cards and the big-metric row); glow gradient on the Proof of Reserves banner;
a logo row as proof; every panel the same rounded dark box; nine-hue categorical chart
legends; Inter as the fallback face.

## 7. Linear changelog (type discipline and a date rail)

Screens: `refs/linear-top-1440.png` (viewport), `refs/linear-1440.png` (full page, 25,898px
tall, used only to confirm the rail repeats down the page), `refs/linear-390.png`. Tokens:
`refs/linear-top-1440.tokens.json`.

What the screen is: Linear's "Now" page, the changelog: a date in a left rail, the entry in a
reading column to its right, one diagram per entry.

Moves worth stealing:
- Tracking that tightens as size grows, measured: h1 48px/510 at -1.056px (-0.022em), h2
  32px/590 at -0.704px (-0.022em), h3 24px/590 at -0.288px (-0.012em), body 17px/400 at
  normal tracking with 27.2px leading (1.6). Heracles's display sizes take the same ratios.
- The date rail: "September 24, 2026" at 15px beside a 1px vertical rule and a small accent
  dot, content column starting at x=408. Heracles's cover week (bind by, Friday reference,
  Monday settlement) is a dated sequence and reads better on a rail than in three tiles.
- The entry diagram: small labelled boxes joined by thin curved connectors, drawn in the
  page's own greys. Diagrams are drawings, not screenshots.
- Filter tabs as plain words ("All", "Changelog", "Product launches") with the active one in
  full ink and the rest at `rgb(138,143,152)`; no pill, no underline.

Numbers, empty states, primary action: few numbers; dates are written out in full. The
primary action ("Sign up") is the only filled pill on the page.

Do NOT take: Inter Variable (on the refusal list) and Berkeley Mono labels in the diagrams;
the near-black `rgb(8,9,10)` page (the siblings are dark).

## 8. Stripe Capital (an offer drawn against the history it is repaid from)

Screens: `refs/stripe-capital-1440.png` (the page restored its scroll to "How it works",
which is the section worth studying), `refs/stripe-capital-390.png` (hero and the product
mock). Tokens: `refs/stripe-capital-1440.tokens.json`.

What the screen is: Stripe's merchant financing page. The "How it works" block shows three
offers on the left (loan, fee, share of sales) and on the right a bar chart of daily sales
where the part withheld for repayment is hatched on top of each bar.

Moves worth stealing:
- The hatched slice. Each bar is a day of sales; the repaid share is the same bar's top,
  drawn in diagonal hatching of the same green, with the amount above it ("₹156"). The
  day with no sales is labelled "No payment" at the baseline instead of drawing nothing.
  This is Heracles's chart exactly: each bar a weekend's gap, the part the layer pays
  hatched inside the band, and "layer pays nothing" written where it pays nothing.
- Selecting an offer redraws the chart (9%, 12%, 15% of sales). Heracles's `/bind` ticket
  redraws the band on every keystroke; the same cause-and-effect pairing.
- Offers as plain rows of three lines ("₹20,000 loan", "₹2,000 loan fee", "12% of sales
  toward repayment"), the selected one outlined in the accent at 2px, radius about 6px.
- Page `rgb(246,249,252)`, ink navy `rgb(10,37,64)`, body `rgb(66,84,102)` at sohne-var
  weight 300, 16px. Section label "How it works" 18px/500 tracking +0.2px in the accent
  green `rgb(21,190,83)`. Dotted-grid background only inside the demo frame, dashed
  column guides behind the steps.

Numbers, empty states, primary action: amounts carry their currency sign and sit above the
bar they describe; the zero day is named, not blank. Primary action: "Contact sales"
filled green pill, "Explore the docs" as a text link beside it.

Do NOT take: step numbers in tinted circles over three or four equal columns (the
feature-grid template); the floating product-mock collage on mobile; the green (Payday owns
fee-income green).

## 9. Teenage Engineering, OP-1 product page (one accent, one job)

Screens: `refs/te-1440.png`, `refs/te-390.png` (product page for the OP-1 field). Tokens:
`refs/te-1440.tokens.json`.

What the screen is: a product page for an instrument; the page is the instrument, photographed
top-down, under one sentence.

Moves worth stealing:
- The 70/20/10 lesson in hardware: a warm grey body (page `rgb(240,240,239)`), ink keys
  and legends `rgb(15,14,18)`, and a single red dot on the one key that records. Red means
  "this is the take" and nothing else on the device is red. Heracles's accent gets the same
  single job: it marks the layer (the band, and the slice of each weekend it pays).
- Ultralight nav with line-drawn glyphs: "products", "store", "latest", "finder" at te-20
  weight 100, 16-19px, in `rgb(119,119,123)`, each over three lowercase sub-links.
- A single lowercase sentence as the page title ("the beauty of evolution."), about 56px,
  dark ink, centred over the object: the sentence introduces the thing, the thing is the
  hero.

Numbers, empty states, primary action: no numbers above the fold; the cart counter ("0",
mobile) is a plain digit in a small grey key. Primary action is buried in the nav (store),
which is right for a brand page and wrong for Heracles.

Do NOT take: the proprietary te-20/te-40 faces; weight 100 for anything a risk lead must
read; centred everything; product photography (Heracles has no object to photograph; its
object is the chart).

## 10. Gauntlet vaults app (domain: a risk manager's own product)

Screens: `refs/gauntlet-1440.png`, `refs/gauntlet-390.png` (app.gauntlet.xyz/vaults).
Tokens: `refs/gauntlet-1440.tokens.json`. Replaces Chaos Labs, whose risk portal
(`community.chaoslabs.xyz`) returned "can't be reached" to refshot on this network.

What the screen is: the list of vaults Gauntlet curates, filterable by asset class, chain,
token and strategy, each row ending in a View button.

Moves worth stealing:
- Amounts as two lines, right-aligned: "$415M" over "415M USDC" in the secondary ink. The
  USD figure leads; the native unit confirms it. Heracles's USDG figures need no twin, but
  premium over "2.79% of the limit" is the same two-line pairing.
- The page title carries its own explanation on the next line ("Vaults curated by
  Gauntlet's experienced risk management team across DeFi"), 20px, secondary ink.
- Nav in PP Telegraf 16px/500 with +2% tracking, active item in the accent
  `rgb(141,153,247)`, radius 4px.

Numbers, empty states, primary action: numbers are plain, APY in green; there is no empty
state on this screen. Each row's action is an outlined "View" button.

Do NOT take: Sohne Mono column headers (monospace labels); the TVL plus "APY Up To" stat
pair top right (the big-metric corner); four font families on one page (PP Telegraf,
Sohne, Sohne Mono, Inter); tinted strategy chips on every row (pills everywhere); the
lavender-on-violet dark palette.

---

## Chosen

- **North star: Mercury (in-app).** A money product for an operator that is calm because
  it removes things: two weights, three inks, one accent on one action, flat ledger rows,
  cents set small. Heracles's reader (a vault risk lead or a signer) has the same job:
  read a figure, trust it, act once.
- **Secondary: Morpho vault page.** The deposit ticket beside a pool's history and risk
  text, with the consequence lines under the amount; mobile rows as key-value blocks.
- **Secondary: Our World in Data grapher.** A history chart whose title says what is
  drawn, whose subtitle is the caveat, and whose source, note and date sit under the plot.

Minor citations only (principles, never the source of Heracles's type, palette, skeleton or
motion, per the coordinator's registry notes): Teenage Engineering's one accent with one job;
Carta's tags pinned onto the drawing and its measured display tracking (-0.03em); Swiss
Re's quiet voice and dated figures. Stripe (claimed by Payday) and Linear were studied and
are not used. Ethena and Gauntlet are kept as a list of what not to do.

# Phase 4 gate record (2026-09-29, branch ui-v2)

## Critic (fresh `demo-judge`, never saw the build)

Given the after screenshots of `/`, `/bind`, `/write` at 1440 (first screen and full page)
and 390 (full page and first screen), the north star and secondaries side by side
(`refs/mercury-accounts-1440.png`, `refs/morpho-vault-1440.png`, `refs/owid-chart-1440.png`),
the negative list, the rejected UI, and the sibling products' mockups and registry rows.

**Round 1: "VERDICT: FAIL".** Desktop passed on all three routes; phone failed. Defects:
phone header touching the screen edges; the chart not saying who pays past the cap;
colliding year labels on the phone `/write` chart; the phone `/bind` putting the cover week
above the terms; repeated facts (worst weekend twice, the cover week on two routes);
`/write` using a rounded premium; a wallet menu left open by another browser session and
"Injected" as a label; the bind button below the fold at 1440x900. All fixed.

Between rounds the user's simplicity and "plain words must stay true" rules landed: the
first screen was cut to one sentence, one chart, one action and three figures, and every
line about the payout now says it is worked out from the price feed and the declared
position, not from the vault's books.

**Round 2 (final), verbatim opening:** "VERDICT: PASS. All eight fixes are in the new
screenshots. The new first-screen rule holds on `/`, and I found no line that says Heracles
pays the vault's actual losses. Three small defects are left (1 to 3 below). None of them
is structural, so I'd put my name on it."

Per route: `/` PASS, `/bind` PASS, `/write` PASS, phone at 390 PASS. Sibling check: PASS
("Janus is a dark stage with a condensed grotesque and amber. Chiron is a line drawing with
numbered callouts. Payday's current build is a dark green ground with a full-width hatched
chart."). Generic execution: "No. The 504 bars, the teal band set at exactly -1% and -4%,
and the slices filled only where a weekend reached the band all come from the product."
Every tell on the negative list: absent. Its seven leftover nits (the `/` premium's block
number, phone `/write` gaps, "limit" vs "cap", the end label, the hint's weight, the
59,800 weekend looking capped, a disabled primary button when no wallet is connected) were
fixed after the verdict.

## Cold reader (fresh agent, shown only `after/after-book-1440.png` and `after/after-book-390-first.png`)

Verbatim:

> (a) It lets a perp exchange's liquidity vault get paid out when a stock's price gaps over
> the weekend, based on a price feed and the vault's declared position, and lets others
> earn premium by backing that cover.
>
> (b) People running or backing a perp-exchange LP vault holding stock exposure (SPY, NVDA,
> AAPL, TSLA) who want weekend gap protection, plus USDG holders willing to underwrite that
> risk for yield.
>
> (c) I'd click "Price cover for your vault" (also "Connect wallet" is plausible first),
> expecting it opens a flow to quote/configure cover for my own vault's position size and
> asset.
>
> (d) Unclear how "Connect wallet" relates to the "Weekend gaps / Price cover / Earn
> premium" tabs, i.e. whether connecting is required before pricing cover or only for the
> "Earn premium" side.

Checked against the truth: correct, and not stronger than the contract (it says the payout
is based on the price feed and the declared position, not on the vault's losses). Point (d)
was answered on the page: "No wallet needed to see a price; connect one to buy."
**Cold-reader test: PASS.**

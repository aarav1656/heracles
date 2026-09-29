# Three directions for the first screen, and the pick

Mockups (static HTML served by the app's Vite server, real SPY table, last live quote):
`a-exhibit.html` / `a-exhibit-1440.png`, `b-slip.html` / `b-slip-1440.png`,
`c-tape.html` / `c-tape-1440.png`.

- **A, the exhibit.** Warm paper, Newsreader argument, the SPY chart with a vermilion band
  and hatched paid slices, a ticket on the right.
- **B, the slip.** A Lloyd's-style placing slip: ruled fields (type, interest, retention,
  limit, premium, rated by, history) beside the argument, the chart below as "Exhibit A",
  ink-blue accent.
- **C, the tape.** Dark green-black, the 504 weekends as a full-bleed seismograph trace with
  an amber band, a light serif headline under it.

Judged by a fresh `demo-judge` agent against REFS.md and the negative list.

**Pick: A.** The judge's reasons, condensed:
1. Only A makes the argument on the chart itself: the band is labelled with its money, the
   paid slices are hatched (Stripe Capital), and the worst weekend carries a pinned note
   (Carta). B's band is never named and has no axis; C labels it once, in a collision.
2. A follows the north star: premium with raised cents inside a sentence (Mercury), the
   ticket beside the history with consequence rows before the button (Morpho), title,
   subtitle and source under the plot (OWID), one accent that only marks the layer
   (Teenage Engineering).
3. A is distinct from the three dark sibling products; C fails that outright, and B's navy
   accent echoes the rejected blue-on-navy UI.

C was also scored "generic execution: yes" (dark hero, full-bleed chart, serif headline).

**What the build had to fix in A (from the same verdict):**
- label collisions on the chart: move the band labels into clear space with a paper
  knockout, sentence case, at least 12px; axis and year labels at least 12px;
- the chart was about 770x260 with dead space under it: make it 360px or taller;
- the ticket's fill and drop shadow are Swiss Re's "do not take": make it flat, a ledger;
- five stat rows is the metric template again: three rows, the tail figures behind a
  disclosure, the gas footnote moved off the ticket;
- Atkinson's slashed zero next to Newsreader's plain zero reads mildly terminal: set every
  figure in Newsreader.

## After the pick: registry changes (2026-09-29, 03:53Z)

The identity registry (`.progress/ui-v2-registry.md`) gave Payday vermilion and Stripe, and
the coordinator ruled that Linear, Teenage Engineering and Stripe may not drive a second
product's look. So the build changed three things from mockup A: the layer's accent is deep
teal `#0B6B6B` instead of vermilion; paid slices are solid instead of Stripe-style hatched;
the cover week is a set of ledger rows instead of a Linear date rail. The signature motion
was rewritten so it does not echo Payday's oldest-first rise: the band opens downward and
catches the weekends it pays, shallowest gap first.

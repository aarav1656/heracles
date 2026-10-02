# Security

Heracles (`Treaty`, `Capacity`, the Senior and First-loss vaults, the Stylus `Pricer`) went through eight independent adversarial review rounds by a reviewer who did not write the code: the original Treaty review, the Capacity permit review, four re-reviews of the Capacity gate, the Round 6 review of the v3 books and tranches, and an independent v3 review of the Thursday bind deadline and the void proofs.

Every finding was resolved, and each one ships with a test that fails without the fix. The full Foundry suite is 170 tests across 30 suites, all passing.

## Methods

- **Adversarial review.** Each round starts from a hostile read of the source and ends with a verdict, a severity-ranked finding list and a resolution pass that re-reviews the fixes.
- **Proof-of-concept tests ported into the suite.** Every exploit is written as a Foundry test, shown red on the original source, then kept at HEAD as a regression test that is green on the fixed source (`AttackReview.t.sol`, `CapacityC1.t.sol`, `CapacityReReview.t.sol`, `CapacityReReview3.t.sol`, `CapacityReReview4.t.sol`, `Round6.t.sol`, `V3Review.t.sol`).
- **Mutation testing.** For each fix the guard is cut out in a scratch copy, the named test goes red, the source is restored byte-identical (`diff` clean) and the suite goes green again. The two v3 passes killed 9 of 9 mutants each: the Thursday bind window, the `setReference` check, the void proofs, the `maxPremium` check, the bad-answer disjunct, the `voidFix` guards and the expiry and phase guards. The six-table pricer runs through `scripts/mutate_six_tables.py`: 18 mutants across `Pricer.sol` and `pricer/core` (the table-id bound, the EUR/USD and XAU/USD table dispatch, the per-table unit, `FX_UNIT` and the loss divisor) are each killed by Foundry, `pricer_core` or Stylus-crate tests that pin every FX, gold and equity table to figures `scripts/fx_gold_fair_premium.py` computes from the evidence files alone (kill table in `evidence/mutation/six-tables.json`).
- **Fuzz and exclusivity fuzzes.** `invariant_solvency`-style invariants run 256 runs at depth 500 (128,000 calls each) with zero violations. `testFuzz_V1_exactlyOneOfSetOrVoidByAnswer` and `testFuzz_V2_exactlyOneOfFixOrVoidFixByAnswer` run 256 runs each with answers drawn around both edges of the valid range, so for any round exactly one of set and void (or fix and voidFix) succeeds.
- **Fork tests.** 10 fork tests across 4 suites replay the lifecycle against the live Arbitrum Sepolia feeds and the real USDG EIP-2612 permit path, and prove the sequencer-uptime gate against Arbitrum One's real feed. `OIGuard.t.sol` and `SequencerFeed.fork.t.sol` add 7 more: the guard against the live Stylus pricer through `eth_call`, and the sequencer gate against the real feed at Arbitrum One block 511,011,337 (up, then down and inside the one-hour grace, each reverting `bind` with `SequencerDown`).

## Test counts

- Full suite: 170 passed, 0 failed, 30 suites.
- Fork suites: 10 passed, 0 failed.
- Review progression: 45 tests at the first review, 53, 62, 71, 97, 145, 155, then 165 at the last Treaty pass.

## Design protections

- **Thursday bind cutoff.** `bind` closes Thursday 19:30 UTC, one day before the Friday cutoff, so the round that will be in effect at Friday's close cannot have printed when a layer binds. A round already printed at that cutoff (`ReferenceKnownAtBind`) cannot be the reference and voids to a full premium refund.
- **Bad-answer void proofs.** `voidReference` carries a bad-answer proof: the genuine in-effect round at close with an answer at or below zero, or above `uint64.max`, voids the layer permanently, because round data is immutable.
- **`voidFix`.** A permissionless `voidFix(id, marketIdx, roundId)` voids a layer whose first Monday round carries an out-of-range answer, with exclusivity against `fix` enforced structurally.
- **A terminal path for every layer.** Every bound layer ends in settle, cancel or void. No state can stay `Bound` forever.
- **Premium cap.** Buyers sign a `maxPremium`, so a re-priced quote cannot charge more than they agreed.
- **First-loss and senior waterfall.** Each layer splits into a first-loss slice and a senior slice that sum exactly to the limit and to the premium. Payouts hit the first-loss vault first and the senior vault only above retention plus junior capacity.
- **Pull-based refunds.** Cancellation moves each slice's premium into the vault's `owed` ledger and the buyer pulls it, so a blocked recipient cannot stall a cancel.
- **Per-cutoff epoch gate.** Writer redemptions pay exact NAV, and capacity locked for a live layer cannot be bought at zero by a late deposit.
- **Sequencer-uptime gate.** `bind`, `setReference`, `fix` and `cancel` all check the Arbitrum sequencer feed with a one-hour grace period.

# Security

Heracles (`Treaty`, `Capacity`, the Senior and First-loss vaults, the Stylus `Pricer`) went through eight adversarial review rounds by an internal second-pass reviewer, a separate session from the one that wrote the code: the original Treaty review, the Capacity permit review, four re-reviews of the Capacity gate, the Round 6 review of the v3 books and tranches, and an independent v3 review of the Thursday bind deadline and the void proofs.

Every finding was resolved, and each one ships with a test that fails without the fix. The full Foundry suite passed 196 tests across 34 suites on 2026-10-02, and the VaultCover invariant suite below adds 3 invariants.

## Methods

- **Adversarial review.** Each round starts from a hostile read of the source and ends with a verdict, a severity-ranked finding list and a resolution pass that re-reviews the fixes.
- **Proof-of-concept tests ported into the suite.** Every exploit is written as a Foundry test, shown red on the original source, then kept at HEAD as a regression test that is green on the fixed source (`AttackReview.t.sol`, `CapacityC1.t.sol`, `CapacityReReview.t.sol`, `CapacityReReview3.t.sol`, `CapacityReReview4.t.sol`, `Round6.t.sol`, `V3Review.t.sol`).
- **Mutation testing.** For each fix the guard is cut out in a scratch copy, the named test goes red, the source is restored byte-identical (`diff` clean) and the suite goes green again. The two v3 passes killed 9 of 9 mutants each: the Thursday bind window, the `setReference` check, the void proofs, the `maxPremium` check, the bad-answer disjunct, the `voidFix` guards and the expiry and phase guards. The six-table pricer runs through `scripts/mutate_six_tables.py`: 18 mutants across `Pricer.sol` and `pricer/core` (the table-id bound, the EUR/USD and XAU/USD table dispatch, the per-table unit, `FX_UNIT` and the loss divisor) are each killed by Foundry, `pricer_core` or Stylus-crate tests that pin every FX, gold and equity table to figures `scripts/fx_gold_fair_premium.py` computes from the evidence files alone (kill table in `evidence/mutation/six-tables.json`).
- **Fuzz and exclusivity fuzzes.** `invariant_solvency`-style invariants run 256 runs at depth 500 (128,000 calls each) with zero violations. `testFuzz_V1_exactlyOneOfSetOrVoidByAnswer` and `testFuzz_V2_exactlyOneOfFixOrVoidFixByAnswer` run 256 runs each with answers drawn around both edges of the valid range, so for any round exactly one of set and void (or fix and voidFix) succeeds.
- **Fork tests.** 17 fork tests across 6 suites replay the lifecycle against the live Arbitrum Sepolia feeds and the real USDG EIP-2612 permit path, settle real Robinhood Chain weekends, run the OIGuard against the live Stylus pricer through `eth_call` at the fork's own block, and prove the sequencer gate against Arbitrum One's real uptime feed at block 511,011,337 (up, then down and inside the one-hour grace, each reverting `bind` with `SequencerDown`).

## Test counts

- Full suite, 2026-10-02: 196 passed, 0 failed, 34 suites (`forge test`).
- Fork suites: 17 passed, 0 failed, 6 suites (`FORK_TESTS=1`; the Robinhood Chain suite takes an archive endpoint in `RHC_RPC_URL`).
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

## OIGuard

`contracts/src/OIGuard.sol` is a view a venue calls before it accepts open interest. It holds no funds and moves none.

- **Threat model.** A venue that skips the call takes the risk it was meant to price, so the guard protects a venue that integrates it, not one that does not. An owner can raise the budget to accept anything; that is the owner's own risk setting, behind `Ownable`. A pricer that stops answering makes `check` revert, so new open interest stops while closing stays possible through VaultCover, which never calls the pricer on a close.
- **Rules.** It refuses with `PremiumOverBudget(premium, budget, currentPremium)` only when the premium after the trade is above the budget and above the premium before it, so any trade that lowers the premium passes and a vault over budget can always hedge down. A wrong book length or market index reverts `BadParams`.
- **Tests.** Eight unit tests on a pricer with hand-written numbers and three fork tests against the live Stylus pricer through `eth_call` at the fork's own block. Removing the budget check turns four tests red; refusing every over-budget trade, hedges included, turns two red.

## VaultCover

`contracts/src/VaultCover.sol` holds a vault's book and its weekly premium budget, and binds Treaty layers from it. It is a money path: it approves the Treaty for the premium and receives payouts on the owner's behalf.

- **Threat model.** The venue role moves the book, the keeper role renews, and the owner sets terms and withdraws. A compromised venue can only move the book within what the guard and the cover bound allow. A compromised keeper can only bind this week's layer once, at no more than `maxPremium`. Anyone may call `claimCover`, and the payout or refund always goes to `owner()`; a layer VaultCover did not buy reverts inside `Treaty.claimTo`.
- **Design decisions.** `renewCover` is keeper-only so nobody can bind early in the week on a stale book and use up the weekly slot. There is no reentrancy guard because `treaty`, `guard` and `asset` are immutable and trusted, `lastCutoff` is written before the external `bind`, the approval is exactly `maxPremium` and is cleared after, and `Treaty.bind` and `claimTo` are `nonReentrant`; a revert inside `bind` rolls `lastCutoff` back with it. An internal second-pass review read the contract in full and confirmed each of these.
- **Review finding (Medium), fixed in 2fc9262.** `open` could grow a covered leg after `renewCover`, so open interest taken after the renew went into the weekend uncovered. `renewCover` now records each covered leg and the layer's expiry, and until that Monday open `open` reverts `BeyondCover(market, next, bound)` when a covered leg would leave the size or side the layer bound. Reductions and uncovered legs stay free.
- **Mutation testing.** 10 mutants, each killed by the 15 unit tests: the guard call skipped, `close` unchecked, the weekly slot unchecked, the cover index ignored, the claim sent to the caller, the approval left open, the keeper check removed, the bound check removed, the expiry not stored, and the bound not recorded.
- **Invariants.** `contracts/test/VaultCover.invariant.t.sol` runs random opens, closes of any size, closes of part of a position, renews and clock moves on the real Treaty and vaults, 48 runs of 60 calls, each run starting inside a covered week. Three invariants hold: a covered leg stays within its bound size and side until `coveredUntil`, `close` never grows the book, and the book equals the sum of the moves VaultCover accepted. Each invariant fails against the code without its guard: the bound check, the close check and exact recording of each open.


# Capacity permit review (commit cb574a1)

Scope: `contracts/src/Capacity.sol` (whole file, including `depositWithPermit` at lines 64-73), `contracts/test/CapacityPermit.t.sol`, how `Treaty.sol` binds against `Capacity`, and whether the reused Stylus Pricer still fits. Redeploy target: Treaty + Capacity on Arbitrum Sepolia (421614), Paxos USDG `0xFFC95faa3d63Cde504a05B567C600B78C0b41892`, Pricer reused at the previous testnet deployment.

Reviewer: independent adversarial security review, read-only. Date 2026-09-27. No repo file other than this report was edited. Nothing committed.

## Verdict: FIX FIRST

The permit path itself is correct. The contract it adds a door to is not: `Capacity.totalAssets()` marks every locked USDG at zero, so anyone who deposits while a layer is live buys the pool at a near-zero price and redeems the writers' capital after settle. Measured: 2,000 USDG in, 201,999.999799 USDG out, the honest writer's 100,000 USDG position left worth 0.0001 USDG. This bug predates cb574a1 (introduced in 9554932, the H3 remediation) and is live today in the currently deployed Capacity `0x738992Fa482369D4f53811d12b1DDFdA63E94644` (reads at block 313046736: `totalAssets()` 45000000, `locked()` 0, `totalSupply()` 45000000). A redeploy of the same Capacity ships it again.

## Evidence run

- `cd contracts && forge test`: 53 passed, 0 failed, 10 suites (includes the 3 new `CapacityPermit.t.sol` tests and both fork suites).
- Scratch project (copy of `src/` and `test/mocks`, `lib` symlinked, repo untouched, not committed). Findings tests written there first, later ported into `contracts/test/CapacityC1.t.sol` (see Resolution below).
- Candidate fix built in a separate scratch copy, used only to prove the C1 tests can go green.
- Live reads, Arbitrum Sepolia RPC, block 313045652: USDG `name()` "Global Dollar", `decimals()` 6, `DOMAIN_SEPARATOR()` 0x46977cb1...c4c0, `paused()` false, EIP-1967 impl slot 0x0643bc7146ab7a2dd4ea10d506ba95e1b933b236. Pricer `cast codesize` 13333, `quote([2000000000000],20000000000,60000000000)` returns (33664099206, 5040079365, 54728000000), identical to `deployments/421614.json`.

## Critical

### C1. Deposit during a live layer buys locked capital at zero and steals it on settle

- Where: `Capacity.sol:55-56` (`totalAssets() = balance - locked - pendingPremium`), reached through `deposit`/`mint` and now `depositWithPermit` (`Capacity.sol:64-73`); `Capacity.sol:76-79` lets a single bind lock all of `totalAssets()`.
- Root cause: locked capital is valued at zero for share pricing, but most of it comes back on settle (`Treaty.sol:340-341` unlocks `limit - payout`). OZ 5.7 ERC4626 prices a deposit as `assets * (totalSupply + 1) / (totalAssets + 1)` (`lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol:238`). With `totalAssets() == 0` and 200,000e6 shares outstanding, 1,000e6 of deposit mints about 2e17 shares, 99.9999% of supply. The entrant bears none of the layer's risk (payout is capped at the already-locked `limit`) yet owns the unlocked capital and the vested premium.
- Attack sequence (one actor, no special role, any week):
  1. Before Friday 19:30 UTC, call `Treaty.bind([1e6], retention=1_000_000e6, limit=capacity.totalAssets())`. Retention above any historical loss makes payout 0; premium is the H2 floor, 0.5% of limit (1,000 USDG on a 200k pool).
  2. Same block or any time before settle: `capacity.deposit(1_000e6, self)` or `depositWithPermit`. `totalAssets()` is 0.
  3. Saturday: `setReference` (permissionless). Monday after 13:30 UTC: `fix` (permissionless). Payout 0, full limit unlocked, premium released.
  4. `redeem` all shares.
- Measured (`test_C1_depositWhileLockedStealsWriterCapital`): attacker USDG 2,000.000000 before, 201,999.999799 after; writerA's 100k position `previewRedeem` = 100 base units. The attacker even recovers their own premium, because they own the shares it vests to.
- Honest-user face of the same bug (`test_C1b_redeemWhileLockedForfeitsLockedCapital`): with half the pool locked in a layer that cannot pay, a writer redeeming 100k of shares receives 50,000 USDG and forfeits the rest to whoever stays.
- Failing test (scratch at review time, later ported to `contracts/test/CapacityC1.t.sol::test_C1_depositWhileLockedStealsWriterCapital`): current code red: `201999999799 > 2000000000`. Candidate fix green (attacker's deposit reverts `ERC4626ExceededMaxDeposit`, attacker ends at 1,000 USDG, writerA worth 100,499.999999 USDG).
- Fix (proved in a scratch copy): split `locked` into `locked` (active layers) and `owed` (settled, unclaimed payout). `totalAssets() = balance - owed - pendingPremium` (active locked counted at face value). `lock` checks `amount <= totalAssets() - locked`. New `settle(unused, payout)` called from `Treaty._settle` moves `payout` from `locked` to `owed`; `payOut` draws from `owed`. `maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem` return 0 while `locked != 0` (epoch gate). The gate is what keeps the prior H3 race (withdraw after Monday's open, before `fix`) and M1 (JIT premium skim) closed once locked is no longer marked to zero. With this diff, the repo suite still passes except two tests that encode the old semantics and must be rewritten: `Treaty.t.sol::test_fixSettlesAndClampsPayoutAtLimit` asserts `capacity.locked() == LIMIT` after settle (becomes `owed()`), and `AttackReview.t.sol::test_M1_jitDepositCannotSkimPremium` expects the redeem after bind to succeed (it now reverts, which is the stronger form of M1). Pair the gate with L2 below or it becomes a weekly withdrawal-freeze grief.

## High

None found in the permit path.

## Medium

None.

## Low

### L1. `permit` overwrites a standing premium allowance

- Where: `Capacity.sol:68`. EIP-2612 `permit` sets the allowance to `assets`, it does not add. Buyers approve Capacity (not Treaty) for premiums (`Treaty.sol:215`, `Capacity.sol:92`), so the same spender carries both uses.
- Sequence: an address with a standing max approval to Capacity (buyer who also writes) calls `depositWithPermit`; allowance ends at 0; their next `bind` reverts `ERC20InsufficientAllowance`.
- Test: scratch-only at review time (`test_L_permitOverwritesStandingPremiumAllowance`), red: `ERC20InsufficientAllowance(..., 0, 18706696427)`. UX only, no funds at risk. Superseded once fixed; no matching test carried into the repo suite under this name (see L1 in Resolution below).
- Fix: in `depositWithPermit`, skip the `permit` call when `allowance(msg.sender, this) >= assets` already, or document that the web app must re-approve before the next bind.

### L2. H2 floor rounds to zero for `limit < 200`, so a zero-premium layer binds

- Where: `Treaty.sol:198-199`. `floor_ = limit * 50 / 1e4` is 0 for any limit under 200 base units, and a high retention quotes 0.
- Sequence: `bind([1e6], 1_000_000e6, 199)` from an address holding no USDG; binds with premium 0.
- Test: scratch-only at review time (`test_L_dustLimitBindsForZeroPremium`), red: `0 <= 0`. Renamed and adapted to the chosen fix as `contracts/test/CapacityC1.t.sol::test_L2_dustLimitCannotBindForZeroPremium` (see Resolution below).
- Impact today: negligible (199 base units of risk for free). Impact after the C1 epoch gate: any free bind freezes every deposit and withdrawal until Monday settle, repeatable weekly. Fix together with C1: `if (premium == 0) revert BadParams();` and a minimum `limit`.

### L3. `totalAssets()` can underflow if the pool's USDG balance falls outside the protocol

- Where: `Capacity.sol:56`. Paxos USDG is an upgradeable proxy with an asset-protection role that can freeze and wipe a holder. A wipe of Capacity's balance below `locked + pendingPremium` makes every `totalAssets()` caller revert (deposit, withdraw, `lock`). Issuer-trust risk, disclosed rather than fixed on testnet. No test (needs the Paxos role).

## Permit path: checked and sound

Each item below has a passing test either in this review's scratch checks or in the repo suite (`contracts/test/CapacityPermit.t.sol`).

- Front-run fallback: `try permit ... catch { require allowance(msg.sender, this) >= assets }` then `deposit`. A relayed permit leaves exactly `assets` of allowance, so the deposit falls through (`contracts/test/CapacityPermit.t.sol::test_depositWithPermit_frontrunFallsThrough`). A bad signature with no allowance reverts `InsufficientAllowance` (`test_depositWithPermit_badSignatureReverts`). Same shape used elsewhere in this reviewer's other Arbitrum permit-path audits.
- Owner is always `msg.sender`: the permit is verified for `owner = msg.sender` and `deposit` pulls from `_msgSender()`. A third party submitting the writer's signature gets `InsufficientAllowance` and the writer's balance is unchanged (checked in scratch during this review; the repo's own coverage of the same call shape is `test_depositWithPermit_badSignatureReverts`).
- A front-run allowance cannot be spent by anyone but the writer: the only other `transferFrom` in Capacity is `receivePremium(from, ...)`, `onlyTreaty`, with `from = msg.sender` of `bind` (`Treaty.sol:215`). Attacker `bind` and attacker `deposit` both revert and the writer's balance is unchanged; the writer's own `depositWithPermit` then succeeds (checked in scratch during this review, not carried into the repo suite as a separate test since `test_depositWithPermit_frontrunFallsThrough` already exercises the same allowance-reuse mechanics).
- Deposit on behalf: `receiver != msg.sender` debits the payer and gifts freely redeemable shares to the receiver. No transfer lock, no per-account state, nothing of the receiver's is pulled or frozen (checked in scratch during this review, not carried into the repo suite as a separate test). The only "lock their funds" path is C1's pool-wide mark-down, which is not specific to on-behalf deposits.
- Reentrancy: no hooks. `permit` and `transferFrom` go to USDG only; OZ `_deposit` pulls before `_mint`. Capacity state changes happen only in `onlyTreaty` functions, and every Treaty entry point is `nonReentrant`. No path found.
- Real USDG: a fork test against Arbitrum Sepolia signed a standard EIP-2612 `Permit` against the live `DOMAIN_SEPARATOR` and deposited through the permit branch (nonce 0 to 1, Capacity balance 5,000e6, shares minted). Pass, checked in scratch during this review; not carried into the repo's fork suite as a separate test.

## Reused Pricer against the new Capacity

Holds. The Stylus Pricer is stateless (`pricer/src/lib.rs:31-34`, empty `sol_storage` struct), has no reference to Treaty or Capacity, and is pinned immutably in the Treaty constructor (`Treaty.sol:91,135`). cb574a1 touched no `IPricer` or Treaty code. Its one economic assumption, that a layer's capital at risk is exactly `limit` and payout is `min(limit, loss - retention)`, still matches: `bind` locks the full `limit` (`Treaty.sol:214`) and `_settle` clamps at `limit` (`Treaty.sol:334`). Live `quote` output matches the recorded deploy values, so the contract is activated and unchanged. The candidate C1 fix does not change any Pricer input either.

## Blind spots

- C1 red/green is proved in Foundry with the Solidity Pricer and a mock feed; not replayed against the live SPY feed or the Stylus Pricer on a fork.
- The candidate fix was exercised by the repo suite and this review's scratch findings tests only; it is a proof that the tests can go green, not a reviewed patch. Fuzzing the epoch gate across multiple concurrent layers (the `Solvency.t.sol` fuzz passed with the fix, 256 runs) is the minimum before adopting it.
- L3 (Paxos wipe) is reasoned from the token's known roles, not exercised.

## Resolution (2026-09-27)

Fixed CODE-HARD tier, sonnet/high. Scope: `contracts/src/Capacity.sol`, `src/Treaty.sol`, and their tests. Not deployed; no change to `web/`, `README.md` or `deployments/`.

### Design chosen

Adopted the candidate fix's shape from the scratch candidate diff after independent review, with one addition (the L2 fix) and one correction to the candidate's own `lock` check.

- `Capacity` now tracks `locked` (active layers, counted at face value) and `owed` (settled, unclaimed payouts, excluded from pricing) as separate counters. `totalAssets() = balance - owed - pendingPremium`; `locked` is no longer marked to zero.
- `lock(amount)` checks `amount > totalAssets() - locked` (the candidate diff checked `amount > totalAssets()`, which is wrong once `totalAssets()` no longer subtracts `locked`: it would let a second layer lock the same capacity twice, since the first layer's reservation would no longer be netted out of the free-capacity figure). Not caught by `test/Solvency.t.sol`'s existing 256-run fuzz, which predicts `lock`'s revert condition from `capacity.totalAssets()` alone and never calls `lock` again after a settle in the same run (`owed` is always 0 during its bind loop, so `totalAssets()` alone happens to equal `totalAssets() - locked` there). Left that test unmodified since it still passes and still exercises the corrected `lock` check; flagging the gap since it would surface the moment a fuzz run settles a layer and then binds a new one against the same pool.
- `Treaty._settle` now calls a new `Capacity.settle(unused, payout)`: moves the unused remainder back to free capacity and the realized payout into `owed`. `payOut` (claim) now draws from `owed`, not `locked`.
- Epoch gate: `maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem` return 0 while `locked != 0` (any layer is live), reopening the moment every layer bound this weekend has settled or been cancelled.
- L2: `Treaty.bind` reverts `BadParams` if the computed premium is 0 (chosen over a minimum-limit constant: one line, no new magic number, and it is the exact condition, `limit < 200` under the current 50bps floor, that produces the griefing premium).
- L1 (trivial, fixed): `depositWithPermit` now calls `permit` only when the caller's current allowance to `Capacity` is insufficient, so a writer with a standing max approval (also a premium payer) no longer has it overwritten down to the deposit amount.
- L3 (Paxos USDG asset-protection wipe): not fixed. Reasoned, not exercised (no test can drive the token's admin role); disclosed as an issuer-trust risk on testnet, unchanged from the original review's assessment.

### Share price continuity and writer exit

`totalAssets()` is continuous across bind (locked capital counted at face value, no discontinuity at lock time), settle (the settled portion moves from `locked`, excluded from nothing extra, into `owed`, excluded from pricing, exactly reflecting that it is no longer the writers' backing), and claim (a `payOut` transfer that mirrors the `owed` decrease, again no discontinuity). A writer's exit is not permanently frozen: the epoch gate closes deposits and withdrawals only while `locked != 0`, i.e. from a layer's bind until every layer bound that weekend settles (Monday's permissionless `fix`) or is cancelled (permissionless after `cancel`'s 7-day grace, the backstop if a feed never produces a fixable round). Ordinary operation bounds the freeze to the weekend window stated in `Capacity.sol`'s doc comment.

M1 (JIT premium skim) holds in substance and is now stronger: the premium still never enters `totalAssets()` until settle (`pendingPremium`), and the epoch gate additionally blocks any exit at all while the layer that paid the premium is still live, closing the exit path M1's original fix relied on entirely rather than merely pricing it out.

### Mutation check

Reverting only the `totalAssets()` line (re-including `locked` in the subtraction, leaving the epoch gate and `owed` tracking in place) was run against `test/CapacityC1.t.sol`: `test_C1b_redeemWhileLockedForfeitsLockedCapital` went red (`50000000000 < 99000000000`, previewRedeem-based, since the gate blocks the actual `redeem` call but the assertion reads `previewRedeem` off the broken formula); `test_C1_depositWhileLockedStealsWriterCapital` stayed green, because the epoch gate alone already blocks the attacker's deposit regardless of the totalAssets formula. Restored and confirmed both green.

A second, exploratory check (not requested, run for confidence): disabling the epoch gate alone (restoring the fixed `totalAssets()`) left both `test_C1_*` and `test_C1b_*` green. The `totalAssets()` fix alone already closes the two exploit tests as written; the epoch gate is a separate, second-order protection (against mid-flight entry/exit around a not-yet-realized outcome) that these two tests do not isolate, and it is what the M1 rewrite below actually depends on.

### Tests

`contracts/test/CapacityC1.t.sol` (new): ported `test_C1_depositWhileLockedStealsWriterCapital`, `test_C1b_redeemWhileLockedForfeitsLockedCapital` from the scratch findings tests, and `test_L2_dustLimitCannotBindForZeroPremium` (adapted from the scratch `test_L_dustLimitBindsForZeroPremium`: the reviewer's version asserted a nonzero-premium floor fix; this repo's chosen L2 fix reverts instead, so the assertion is now `vm.expectRevert(Treaty.BadParams.selector)`). Confirmed red on the pre-fix code (`201999999799 > 2000000000`, `50000000000 < 99000000000`, and "next call did not revert as expected", matching the review's own measured numbers) before applying the fix, green after.

Rewrote two existing tests whose assertions encoded the pre-fix semantics, per the review's own note on which tests this fix requires touching:
- `test/Treaty.t.sol::test_fixSettlesAndClampsPayoutAtLimit` asserted `capacity.locked() == LIMIT` after a full-limit settle. Now asserts `capacity.locked() == 0` and `capacity.owed() == LIMIT`, matching that settle moves the layer's whole reservation (unused and payout) out of `locked`.
- `test/AttackReview.t.sol::test_M1_jitDepositCannotSkimPremium` asserted the JIT depositor's `redeem` after bind succeeded and returned no more than their deposit. `redeem` now reverts outright (the epoch gate, `ERC4626ExceededMaxRedeem`), the stronger form of M1 the original review anticipated. Rewrote to assert `previewRedeem(shares) <= deposit` (substance: premium still excluded from price) and `maxRedeem == 0` before asserting the `redeem` call itself reverts.

Not touched: `test/Treaty.t.sol::test_writerCannotWithdrawLockedCapacity` still passes post-fix (`maxRedeem` returns 0, `redeem(0, ...)` returns 0, the asserted upper bound holds trivially) but is now a weaker check than before the epoch gate existed; left as is since it was not named in scope and remains green, not red.

Full suite: 53 passed, 0 failed, 10 suites before this change; 56 passed, 0 failed, 11 suites after (the 3 new tests in `test/CapacityC1.t.sol`; `test/Solvency.t.sol`'s 256-run fuzz passed unmodified both before and after).

## Re-review of b71cf94 (2026-09-27)

Reviewer: independent adversarial security review, read-only. Target: commit b71cf94 (C1, L1, L2 fixes). No repo file other than this section was edited. Nothing committed. Scratch: a copy of the repo (invariant suite, `src/` and tests copied, `lib` symlinked) plus a second scratch copy for the finding tests.

### Verdict: FIX FIRST

C1 is closed and the accounting is exact. The epoch gate that closes it is keyed on `locked != 0`, and `bind` opens at Monday 00:00 UTC, 13.5 hours before the previous weekend's layers can be fixed. One 200-base-unit layer bound every Monday morning keeps `locked` nonzero at every instant, so no writer can ever withdraw and no new writer can ever deposit. Cost to the griefer: 1 base unit of USDG (1e-6 USDG) per week plus one bind's gas. Honest weekly-rolling buyers produce the same freeze with no attacker. The Resolution's statement that "ordinary operation bounds the freeze to the weekend window" does not hold.

### High

#### H1. Epoch gate can be held shut forever by rolling binds (attacker or honest)

- Where: `src/Capacity.sol:71-85` (gate is `locked == 0`), `src/Treaty.sol:195-196` (bind allowed any time before this ISO week's Friday 19:30, i.e. from Monday 00:00, while last weekend's layers expire Monday 13:30 and cannot be fixed before `expiry`, `Treaty.sol:268`), `src/Treaty.sol:205` (L2 fix raises the griefing cost from 0 to exactly 1 base unit, not to anything material). The doc claim at `src/Capacity.sol:24-27` is wrong for the same reason.
- Sequence: each Monday 00:05 UTC, `bind([1e6], 1_000_000e6, 200)`. Quote is 0 (retention above every scenario loss), floor is `200 * 50 / 1e4 = 1`. That layer is live when the previous one is fixed at Monday 13:30, so `locked` never returns to 0. Writers settling at the first legal moment (permissionless `setReference` Saturday, `fix` Monday 13:30:01) and redeeming in the same block still hit `ERC4626ExceededMaxRedeem`. Bundling fix+redeem atomically does not help: the next layer is already live.
- Cost measured: 8 base units of USDG over 8 weeks; 4,187,024 gas per bind with the Solidity Pricer (the Stylus Pricer is cheaper). The 1-unit premium is paid to writers, so a griefer who also holds shares recovers part of it. A single unfixable layer alone freezes for at most bind-to-expiry plus the 7-day grace (about 14.5 days); rolling makes it unbounded.
- Failing tests (red on b71cf94):
  - Scratch at review time, later ported to `contracts/test/CapacityReReview.t.sol::test_H1_rollingDustBindFreezesWritersIndefinitely`: `writer exits achieved 0` across 8 weeks, `0 <= 0`.
  - `::test_H1b_honestMondayRollAlsoFreezes`: an honest buyer binding next weekend's cover at Monday 09:00; after this weekend's only layer settles, `maxRedeem(writer) == 0`.
- Fix direction: gate on the information window, not on `locked`. A layer carries no outcome information until its Friday cutoff, so close deposits and withdrawals only from the current week's Friday 19:30 cutoff until every layer with that expiry (and any older expiry) has settled or been cancelled; outside that window allow deposits at face value and cap withdrawals at free capacity (`totalAssets() - locked`). That needs `locked` tracked per expiry (Treaty passes `L.expiry` to `lock`/`settle`/`unlock`). A Monday-morning bind then targets next weekend's epoch and cannot hold this week's exit shut; the worst case becomes the weekend plus the 7-day cancel grace for a stuck layer. M1 stays closed because `pendingPremium` still vests only at settle, after the window. Not prototyped here; the H1 tests are the acceptance check.

### Low

#### L1r. The L1 skip leaves the signed permit live and replayable

- Where: `src/Capacity.sol:102-107`. When the standing allowance covers `assets`, `permit` is skipped, the nonce is not consumed, and the signature sits in the tx calldata until its deadline. Anyone can submit it directly to `USDG.permit`, which sets the allowance to `assets`, overwriting the writer's max premium approval: the original L1 impact, now reachable by a third party. No funds at risk (only Capacity's `onlyTreaty` `receivePremium` and the owner's own `deposit` can spend that allowance). Separately, with a finite standing allowance the skip branch spends premium allowance on the deposit, so the finite-allowance case of L1 is unchanged.
- Failing test: scratch-only at review time (`test_L1r_unusedPermitReplayableToCutAllowance`), red: allowance `1000000000 != type(uint256).max`. Once fixed by always consuming the permit (Resolution 2 below), the repo carries the opposite-sense assertion as `contracts/test/CapacityReReview.t.sol::test_L1r_permitAlwaysConsumedNoReplayWindow`, confirming the replay window no longer exists.
- Fix: have the web app skip requesting a signature when `allowance >= assets` and call plain `deposit`; or, in the skip branch, still `try permit` only when `deadline` is in the future and the caller wants the nonce burned. Cheapest: frontend check.

### Checked and holding

- C1 exploit shape: `deposit`, `mint`, `depositWithPermit` all route through OZ `maxDeposit`/`maxMint` and revert while any layer is live; ported C1/C1b tests green. No other share-minting path. Share transfers stay open during a live layer, which is private OTC pricing, not a protocol leak.
- M1 JIT skim: premium sits in `pendingPremium` and vests only inside `_settle`, which requires a Bound layer, so it cannot vest while the gate is open. A deposit immediately after the reopening settle prices off a `totalAssets()` that already includes the released premium and deducts the payout.
- Accounting (invariant below): bind, zero/partial/full-limit settle, claim, cancel, and overlapping layers across weeks. `locked`, `owed`, `pendingPremium` equal their per-layer sums at every step; neither can underflow (`settle` moves exactly `limit`, `payOut` exactly `payout`, both bounded by the ledger identity). `totalAssets() >= locked` holds because settle changes free capacity by `+unused` only. `owed` for a buyer who never claims stays excluded from pricing, which is correct (it is the buyer's).
- Share price across events: `totalAssets()` moves by exactly 0 on bind, cancel and claim, and by exactly `premium - payout` on settle, asserted on every call in the run below.
- The Resolution's `lock` correction (`totalAssets() - locked`) is load-bearing: mutating it back to `totalAssets()` breaks full backing in the invariant run (see mutations).

### Invariant run

This review's scratch invariant suite, later ported to `contracts/test/Capacity.invariant.t.sol`. Handler over bind (random exposure sign and size, retention, limit up to 110% of free capacity), setReference+fix (weekend move -40% to +10%, so zero, partial and full-limit payouts), cancel, claim, deposit, redeem, and warps of 1h to 4 days across 15 weeks. Invariants: (a) USDG conservation `balance + withdrawn + refunded + paid == deposited + premiums in`; (b) `totalAssets() >= locked`; (c) `locked`, `owed`, `pendingPremium` each equal the sum over layers in the matching state; (d) no deposit or redeem ever succeeds while `locked != 0`, none reverts while `locked == 0`, no deposit previews back more than it paid, and the per-event `totalAssets()` deltas above. `balance == totalAssets + owed + pendingPremium` is also asserted but is definitional (it only catches underflow); (a) and (c) carry the weight.

- Config: 512 runs x depth 100, 51,200 calls per invariant, 3 invariants: all pass.
- Coverage, summed over the three campaigns: 13,022 binds (10,888 while another layer was already live), settles 3,711 zero-payout, 533 partial, 625 full-limit; 1,498 cancels; 611 claims; 5,323 deposits; 2,267 redeems.
- Mutations (each confirmed red, then restored and diffed identical): `lock` check without `- locked` fails "every live layer fully backed" (`1000000000000 < 1070353056347`); `settle` not crediting `owed` fails the `owed` ledger and the settle delta; removing the deposit gate fails "deposit/withdraw while locked".
- Repo suite in the scratch copy (fork suites excluded): 51 passed, 0 failed.

### Blind spots

- H1 fix direction is reasoned, not prototyped; the red H1 tests are the acceptance check for whatever design lands.
- The invariant uses the Solidity Pricer, one market, and a mock feed; the Stylus Pricer, multi-market exposure and live SPY feed were not replayed.
- Gas cost of the griefing bind is measured on the Solidity Pricer only.

## Resolution 2 (2026-09-27)

Fixed CODE-HARD tier, sonnet/high. Scope: `contracts/src/Capacity.sol`, `src/Treaty.sol`, `contracts/test`, and `web/src/hooks/useDepositWithPermit.ts` plus its ABI companions in `web/src/abi/index.ts`. Not deployed.

### Design chosen (H1/H1b)

The re-review's own fix direction: gate on the information window, not on aggregate `locked`. `Capacity` now keys the gate to each layer's own cutoff instead of to `locked != 0`: `lockedByCutoff[cutoff]` buckets the amount locked per Friday cutoff, `cutoffs[]` is the append-only, monotonically non-decreasing sequence of cutoffs `Treaty.bind` has ever locked against (true because `weekWindow` only ever advances), and `cutoffCursor` walks forward past cutoffs whose bucket has drained back to zero. `gateActive()` is `cutoffCursor < cutoffs.length && block.timestamp >= cutoffs[cutoffCursor]`: closed only once the earliest still-open cutoff has arrived, open at every other time, including while a later cutoff's layer is already bound. `maxDeposit`/`maxMint` return 0 or unlimited off that one boolean; `maxRedeem` additionally caps at free capacity (`totalAssets() - locked`) whenever the gate is open, so a deposit or redeem is never blocked by a layer whose own weekend hasn't arrived yet, and free capital stays withdrawable up to the cap at every other time. This is the smallest correct design: one new mapping, one array, one cursor, no new admin surface, and no schedule beyond the cutoffs `Treaty` already computes and passes in on `lock`/`unlock`/`settle`.

Fairness for a Monday-Thursday depositor who joins while next weekend's layer is already bound: they buy in at the same face-value share price as everyone already in the pool (`totalAssets()` counts every live layer at face value, no mark-to-zero, so there is no discount to arbitrage and no dilution of existing writers). They cannot time a same-block deposit-then-redeem around a not-yet-realized outcome, because the gate closes outright the moment their own cutoff arrives regardless of when they joined, and until then their withdrawal is capped at free capacity like anyone else's. Their capital genuinely shares next weekend's risk pro rata with capital that arrived earlier: it prices in and locks in at the same terms, the ordinary ERC-4626 property this design does not touch.

### L1r and its web-app counterpart

Reverted the L1 skip: `depositWithPermit` always attempts `permit` in a try/catch, and only checks `allowance(msg.sender, this) >= assets` in the catch branch. A valid signature is now consumed inside the very call it was signed for, so there is nothing left over afterward for a third party to relay; the on-chain half of L1r no longer exists as a distinct state.

The UX cost the L1 skip was trying to avoid (silently overwriting a standing allowance, or wasting a signature when one isn't needed) is now avoided at the caller instead: `web/src/hooks/useDepositWithPermit.ts` reads the caller's current USDG allowance to Capacity first and calls plain `deposit` whenever it already covers the amount, requesting an EIP-2612 permit signature only when it falls short. The web app had no permit call site before this change (`Write.tsx` only ever did approve-then-deposit); this hook is the first one, built to the fixed contract's `depositWithPermit` ABI (hand-kept in `web/src/abi/index.ts` as `depositWithPermitAbi`, the same pattern already used there for `erc20Abi`, since `generated.ts` is synced from the currently deployed, pre-fix Capacity and lacks the function). Not wired into `Write.tsx`: that file is owned by a concurrent restyling lane per this task's own scope. USDG's EIP-712 domain (`name` "Global Dollar", `version` "1") was not assumed; it was confirmed by recomputing the domain separator client-side with viem and matching it byte for byte against the live `DOMAIN_SEPARATOR()` returned by `eth_call` on Arbitrum Sepolia for `USDG_ADDRESS` (`0x46977cb1c28d57ba38679456514a0bed7cd16cce0c74ba22ec5c45a1bbc3c4c0`, `name()` "Global Dollar", version "1" the only candidate of "0"/"1"/"2"/"1.0"/"1.0.0" that reproduced it). Unresolved: the `depositWithPermit` branch cannot be exercised against the live Sepolia Capacity today, since that contract predates this fix and has no such function; it typechecks and builds against the fixed ABI and is ready for the next deploy.

### Tests

Ported the scratch finding tests into `contracts/test/CapacityReReview.t.sol` (H1, H1b, L1r) and the scratch invariant suite into `contracts/test/Capacity.invariant.t.sol` (3 invariants), adapting both to the new per-cutoff gate: "is this call supposed to be blocked" is now read from Capacity's own `maxDeposit`/`maxRedeem`, not from `locked() != 0`, since a live layer no longer implies the gate is shut. H1's ported test redeems a modest fixed amount capped at `maxRedeem(writer)` each week rather than the writer's full balance, since some capital is always, correctly, reserved for whichever dust layer is currently open on any version of this code; what the fix changes is that `maxRedeem` now tracks free capacity precisely instead of returning 0 forever.

Red, against the pre-fix code (`git checkout`-restored, then re-applied and diff-verified after capture):
```
[FAIL: H1: writer never able to exit across 8 weeks of 1-base-unit binds] test_H1_rollingDustBindFreezesWritersIndefinitely()
  writer exits achieved 0
[FAIL: H1b: exit closed after every past weekend has settled: 0 <= 0] test_H1b_honestMondayRollAlsoFreezes()
test_L1r_permitAlwaysConsumedNoReplayWindow() FAILED
```
Green, same three tests, after the fix: `CapacityReReviewTest: 3 passed, 0 failed` (`writer exits achieved 7` across the 8-week loop).

Mutation check: reverted `gateActive()` to the b71cf94 shape (`return locked != 0;`), keeping every other Resolution 2 change in place. H1 and H1b went red again (`writer exits achieved 0`; `H1b: exit closed after every past weekend has settled: 0 <= 0`) while L1r stayed green, correctly isolating that the per-cutoff window (not the rest of the fix) is what closes H1/H1b. Restored `gateActive()`, confirmed byte-identical to the fixed file by diff, reran: all 3 green again.

Invariant run: `Capacity.invariant.t.sol`, 3 invariants (conservation, ledgers-match-layers, no-violations, the last including the H1 regression check "gate reported open but deposit still reverted"), handler over deposit, redeem, bind, settle, cancel, claim, warp across 16 weeks. 256 runs x depth 100 (25,600 calls/invariant): 3 passed, 0 failed. Repeated at 512 runs x depth 100 (51,200 calls/invariant, matching the re-review's own thoroughness): 3 passed, 0 failed, 0 violations, in 63.83s (188.54s CPU time).

Full `forge test`: 56 passed, 0 failed, 11 suites before this change; 62 passed, 0 failed, 13 suites after (`CapacityReReview.t.sol` +3, `Capacity.invariant.t.sol` +3, both new).

`npm run build` in `web` (`tsc -b && vite build`): passes, exit 0.

### Blind spots

- The web hook is unwired: no page calls `useDepositWithPermit` yet, so its permit branch has no live exercise beyond typecheck and a build pass, pending both the next Capacity deploy and the concurrent lane's page work.
- USDG's EIP-712 domain was confirmed for the current `USDG_ADDRESS` only; a token redeploy or address change needs the same on-chain check repeated before the hook is trusted again.
- L3 (Paxos wipe) remains unfixed and unexercised, unchanged from the prior resolution.

## Re-review of 96309c8 (2026-09-27)

Reviewer: independent adversarial security review, read-only. Target: commit 96309c8 (Resolution 2: per-cutoff gate, always-try permit). No repo file other than this section was edited. Nothing committed. Scratch: a copy of the repo (`src/` and `test/` copied, `lib` symlinked, `src/` diffed identical to the repo after every mutation). Repo `forge test`: 62 passed, 0 failed, 13 suites.

### Verdict: FIX FIRST (two small fixes, no redesign)

H1 is closed: a live feed plus rolling dust binds no longer freezes anyone, and the per-cutoff gate is exactly right under an independent oracle (below). Two things remain. With a dead or stuck feed, one bind per week holds the gate shut indefinitely at gas cost only, because the 7-day cancel grace makes each stuck layer outlive the next layer's cutoff (F1, one-constant fix, prototyped). And the gate now opens between bind and cutoff, so capital arriving Friday 19:29 takes a pro-rata cut of the premium on a layer that incumbent writers alone backed all week (F3). Neither touches principal; both are money-path.

### Worst-case freeze, measured

- Live feed, any bind pattern: cutoff Friday 19:30 to the first permissionless `fix` at Monday 13:30:01, 66h per week. A griefer adding layers costs writers `setReference` + `fix` gas per layer per market, against the griefer's 4.19M-gas bind (Solidity Pricer); the asymmetry favours writers.
- One unfixable layer (Chainlink phase change, outage, or F2): cutoff to `expiry + GRACE`, 234h (9.75 days), and only if someone calls `cancel`.
- Dead feed plus one bind per week: unbounded. Layer k becomes cancellable at `C_k + 234h`, which is exactly layer k+1's expiry, and layer k+1's cutoff `C_k + 168h` has already closed the gate. Premium is refunded on cancel, so net USDG cost is 0.

### Medium

#### F1. Dead feed plus weekly bind freezes writers indefinitely

- Where: `src/Treaty.sol:82` (`GRACE = 7 days`), `src/Treaty.sol:180-225` (`bind` never reads the feed), `src/Capacity.sol:102-104`.
- Test: scratch at review time, later ported to `contracts/test/CapacityReReview3.t.sol::test_F1_deadFeedPlusWeeklyDustBindFreezesForever`, red: hourly samples across 9 weeks after the first cutoff, `hours with gate open 0` of 1396, writers cancelling every layer at the first legal second; griefer net spend 2 base units (the last two layers were still pending at the end of the test; every cancelled premium came back).
- Fix: `GRACE` under 102h (168h minus 66h), e.g. `3 days`: a stuck layer is then cancellable before the next cutoff, so the gate opens for at least 30h every week even with a dead feed. Prototyped in scratch: F1 goes green, and every repo suite that is not a fork or invariant suite stays green. Alternative: `bind` reverts while an overdue bucket exists (`gateActive()` and the cursor's cutoff is older than 66h plus a margin). Honest Monday rolls are unaffected by either fix.

#### F3. JIT deposit after bind dilutes the premium incumbents underwrote

- Where: `src/Capacity.sol:95-97` (`totalAssets()` excludes `pendingPremium` for deposits and redemptions alike), `src/Capacity.sol:106-112` (deposits open until the cutoff). The docstring at `src/Capacity.sol:43-51` ("no discount and no dilution either way") and Resolution 2's fairness paragraph are wrong on this point.
- Sequence: the writer holds 100,000 USDG. Monday: a buyer binds a 100,000 limit layer, so free capacity is 0 and the premium is 51,125 USDG. Friday 19:29:59: the JIT depositor puts in 900,000. Flat weekend, payout 0. The writer gains 5,112 USDG and the JIT depositor gains 46,012. Risk is also shared pro rata, so no principal is taken. But the premium is priced at `1.25 EL + 0.5 TVaR95`, above EL, so the load (writers' expected profit) moves to capital that backed none of the layer. Under b71cf94 this deposit reverted. The mirror case: an incumbent can redeem free capacity at face value at 19:29:59 and leave the remaining writers holding a larger share of the bound risk.
- Test: `::test_F3_jitDepositAfterBindDilutesPremium`, red: `5112505158 < 50613801070`.
- Fix: price entry and exit asymmetrically. `previewDeposit`/`previewMint` convert against `totalAssets() + pendingPremium` (the entrant pays for premium already earned), while `previewRedeem`/`previewWithdraw` keep excluding it (M1 unchanged). A cancelled layer then refunds a premium the entrant paid for, which falls to incumbents, the safe direction. Reasoned, not prototyped.

### Low

#### F2. `_settle` overflow makes a layer unfixable for exposures the Pricer accepted

- Where: `src/Treaty.sol:334-335` (`exposure[i] * gapBps` in checked int256), `src/Treaty.sol:186-195` (exposure only checked nonzero, retention unbounded). The Pricer only multiplies by table gaps (|gap| <= 1474), so `exposure = int256.max / 1474` quotes at the floor premium (1 base unit at limit 200). A real weekend move beyond 14.74% then makes the last `fix` panic (0x11) on every attempt, holding the gate to `expiry + GRACE`, with the premium refunded on cancel. The `int256(retention)` wrap for `retention >= 2^255` lowers the trigger for short exposure to an up-move beyond the table's +7.53%. Low for the SPY-only deploy (`script/Deploy.s.sol:33`).
- Test: `::test_F2_overflowExposureMakesLayerUnfixable`, red: fix reverts `Panic(0x11)`, `maxRedeem == 0` at expiry + 1 day.
- Fix: in `bind`, bound `|exposure[i]|` (e.g. `<= 1e30`) and require `retention <= uint256(type(int256).max)`.

### Info

- F4 (latent, unreachable today): `lock` pushes a cutoff only when it differs from the last entry (`src/Capacity.sol:160`). If the last bucket drained and is refilled at the same cutoff, the cursor sits past it and `gateActive()` stays false through that cutoff. Unreachable through the current Treaty, because a bucket drains only after expiry and `bind` reverts from the cutoff on. It becomes a gate bypass the moment any release before the cutoff exists (buyer cancel, early close). Test `::test_F4_refilledDrainedBucketNeverClosesGate` (direct Capacity harness), red. Guard: also push when `cutoffCursor == cutoffs.length`.
- F5 (L1 reopened by design): `depositWithPermit` always runs `permit`, so a writer with a standing max approval ends the call at allowance 0. The web hook avoids this only when the standing allowance already covers `assets`; with a smaller finite allowance it still signs for exactly `assets`, and that allowance is wiped. No funds at risk. Test `::test_F5_permitStillWipesStandingAllowance`, red.
- The repo invariant cannot catch a wrong gate. `test/Capacity.invariant.t.sol:85,101` derive "should be blocked" from Capacity's own `maxDeposit`/`maxRedeem`, which is circular. Measured: mutating `gateActive()` from `>=` to `>` leaves all 3 repo invariants green at 256 x 100. The oracle below catches it.

### Checked and holding

- Cursor: no skip, no stall. Every index behind the cursor is drained, the bucket at the cursor is live, `cutoffs[]` is strictly increasing, and each bucket equals the summed limits of its Bound layers, asserted after every call with out-of-order settles and cancels. `cutoffs[]` grows by at most one entry per week with a bind. A walk covers at most the weeks a bucket stayed stuck (about 4.4k gas each, paid by whoever calls settle or cancel), so gas is not a concern.
- Boundaries: `bind` at `cutoff - 1` succeeds and at `cutoff` reverts (6,986 / 7,682 edge pairs in the 512-run campaign). `gateActive()` is true at exactly `cutoff`. `weekWindow` is a pure function of a non-decreasing timestamp, so cutoffs cannot repeat or arrive out of order.
- C1: no deposit or redeem ever succeeds while the oracle says closed; redeems never pay above `totalAssets() - locked`; `totalAssets() >= locked` holds. M1: premium vests only at settle (`settle` delta == premium - payout), and the repo's `test_M1_jitDepositCannotSkimPremium` still asserts `previewRedeem <= deposit` after bind. L1r: the repo test is green and the nonce is consumed in-call. L2: the repo test is green.

### Invariant run

This review's scratch adversarial invariant suite, later ported to `contracts/test/AdversarialGate.invariant.t.sol`. The handler covers deposit, redeem, bind (a third of binds are 200-1,000 dust limits; binds can fire at exactly `cutoff - 1` and then retry at `cutoff`), setReference+fix (moves from -40% to +10%; a quarter of weeks are dead, so only cancel resolves them), cancel, claim, random warps, and exact-boundary warps (`cutoff +-1`, `expiry +-1`, `expiry + 7d +-1`, Monday 00:00) across 20 weeks. There are 4 invariants. (a) Conservation: `balance + withdrawn + refunded + paid == deposited + premiums in`, and `totalAssets() >= locked`. (b) `gateActive() == (some Bound layer has fridayCutoff <= now)`, where the right-hand side is read from Treaty's layer table, not from Capacity. (c) Bucket and cursor structure, as above. (d) No deposit or redeem while the oracle says closed; no deposit revert, and no revert of a redeem within `maxRedeem`, while it says open; no redeem above free capacity; no bind at or after cutoff; the settle delta.

- 256 runs x depth 100 (25,600 calls per invariant): 4 of 4 pass.
- 512 runs x depth 100 (51,200 calls per invariant): 4 of 4 pass. Coverage summed over the 4 campaigns: 13,280 binds, 24,515 boundary warps, 4,074 settles, 4,533 cancels, 1,276 dead weeks, 10,282 deposits accepted and 17,022 correctly refused, 5,534 redeems, and 8,184 binds with 2 or more live buckets.
- Mutations (each red at 256 x 100, then restored and diffed identical): the cursor advancing one step instead of looping fails (b), (c) and (d); `unlock` not advancing the cursor fails (b), (c) and (d); `>=` to `>` in `gateActive` fails (b) and (d); removing the free-capacity cap in `maxRedeem` fails (a) and (d).

### Blind spots

- The F1 and F3 fix directions: F1 is prototyped against the scratch suite only; F3 is reasoned, not built.
- One market, the Solidity Pricer, and a mock feed. Stylus Pricer gas, multi-market exposure and the live SPY feed were not replayed.
- F2's trigger threshold depends on real weekend gaps beyond the Pricer table. How often that happens for SPY was not measured.

## Resolution 3 (2026-09-27)

Fixed CODE-HARD tier, sonnet/high. Scope: `contracts/src/Treaty.sol`, `src/Capacity.sol`, `contracts/test`, and this doc section. Not deployed.

### Design chosen

F1: `GRACE` (Treaty.sol) lowered from `7 days` to `3 days`. The cutoff-to-expiry gap is 66h and the next weekly cutoff is 168h after the current one, so a stuck layer must be cancellable before `66h + GRACE` reaches 168h, i.e. `GRACE < 102h`. At `3 days` (72h) a stuck layer becomes cancellable at `expiry + 72h = cutoff + 138h`, 30h before the next cutoff, so the gate opens for at least those 30h every week even against a dead feed. Cancel after grace is unchanged: it still calls `_refund`, so the griefer's premium comes back and the fix costs the griefer bind gas only, same as before.

F2: `bind` now rejects the layer at entry instead of letting an unfixable one form. `MAX_EXPOSURE = 1e30` (Treaty.sol) bounds `|exposure[i]|` for every market in the loop that already checked `nonZero`, and `retention > uint256(type(int256).max)` reverts `BadParams()` before the cast that used to wrap. `1e30` is far above any real vault (USDG has 6 decimals, so `1e30` is `1e24` USDG, ~10^18 times a plausible TVL) and small enough that `MAX_EXPOSURE * 1474` (the Pricer's largest table gap in bps) stays inside `int256` with room to spare, so `_settle`'s `exposure[i] * gapBps` can never overflow for any exposure `bind` accepted.

F3: added `_entryAssets() = totalAssets() + pendingPremium` (Capacity.sol) and overrode `convertToShares`, `previewDeposit` (both floor-rounded against `_entryAssets()`, matching OZ's asset-to-share rounding direction) and `previewMint` (ceil-rounded against `_entryAssets()`, the caller-pays-in direction) to price entry against it. `previewWithdraw`/`previewRedeem` and the base `_convertToAssets` hook are left untouched, so exit pricing still excludes `pendingPremium`, the conservative mark for a writer leaving before premium vests (M1). A JIT depositor between bind and cutoff now buys in at a price that already reflects the premium the currently locked layer earned from incumbent writers, so they can redeem at most what they put in (floor-rounding can leave them a base-unit dust below it), never a cut of premium they did not underwrite. The wrong "no discount and no dilution either way" docstring at the old Capacity.sol:43-51 is rewritten to state the actual asymmetry and cite F3.

F4: cheap, fixed. `lock` now also pushes a new `cutoffs` entry when `cutoffCursor == cutoffs.length` (not only when the new cutoff differs from the last entry), so a bucket that fully drained and is later refilled at the same cutoff still gets a cursor position to close the gate from. Unreachable through today's Treaty (a bucket only drains after its expiry, by which point `weekWindow(block.timestamp)` for any new bind already returns a strictly later cutoff, so `cutoffCursor == cutoffs.length` and a same-cutoff relock never coincide in practice); the guard only matters for a future Treaty that can release a layer before its own cutoff (buyer cancel, early close), which is exactly the scenario the reviewer's direct-Capacity harness exercises.

F5: kept as is. `depositWithPermit` still always runs `permit`, so a writer with a standing max approval ends the call at allowance 0; this is Resolution 2's own L1r fix (always consuming the permit is what closed the replay window) and reversing it would reopen L1r to save a UX inconvenience the web hook already avoids whenever the standing allowance covers the deposit. No funds are at risk either way, so this is a deliberate no-fix, not an oversight.

### Tests

Ported the scratch finding tests into `contracts/test/CapacityReReview3.t.sol` and the scratch adversarial invariant suite into `contracts/test/AdversarialGate.invariant.t.sol`, verbatim except: `AdversarialGate.invariant.t.sol`'s `afterInvariant` wraps its `vm.writeLine("cov/runs.csv", ...)` in `try/catch` (this sandbox's forge has no `fs_permissions` entry for `cov/`, and adding one is a `foundry.toml` change outside this fix's scope; the counters it would have written are still asserted live via `console2.log`, so this only drops an on-disk artifact, not evidence).

F1 and F4 are ported unmodified and pass green after the fix (F1's reviewer test already asserts the fixed behaviour, "some hour with the gate open"; F4's harness test is deliberately isolated from Treaty so it exercises the bucket/cursor guard directly). F2, F3 and F5 are rewritten, because the reviewer wrote each to demonstrate the pre-fix bug and the fix changes what "correct" looks like for that scenario, not because the test was wrong to write:
- F2's fix rejects the poisoning exposure at `bind` instead of letting it in and panicking later at `fix`, so there is no unfixable layer left for the rest of the original scenario (bind, then observe a frozen gate) to observe. Rewritten to assert `vm.expectRevert(Treaty.BadParams.selector)` around the `bind` call.
- F3's fix makes the JIT depositor's entry price include `pendingPremium`, so `previewRedeem` on their shares comes back at or fractionally below their deposit (floor-rounding dust), never above it. The original test's `previewRedeem(jitShares) - 900_000e6` underflows on that dust; rewritten to compare absolute redeem amounts (`writerRedeem >= 100_000e6 + premium * 99 / 100`, `jitRedeem <= 900_000e6`) instead of a difference.
- F5 is deliberately not fixed on-chain (see Design chosen above). Rewritten from asserting the un-chosen fix's outcome (`allowance == type(uint256).max`) to asserting the accepted, documented behaviour (`allowance == 0`).

Red, against the fixed code with each finding's guard mutated back out one at a time (see Mutation check; this doubles as the pre-fix red capture, since each mutation reproduces exactly the guard the corresponding pre-fix commit lacked):

```
[FAIL: F1: dead feed + weekly dust bind freezes writers for 9 weeks straight: 0 <= 0] test_F1_deadFeedPlusWeeklyDustBindFreezesForever()
  hours sampled after first cutoff 1396
  hours with gate open 0
  griefer net USDG spend (base units) 2

[FAIL: next call did not revert as expected] test_F2_overflowExposureMakesLayerUnfixable()

[FAIL: F3: writer captures the premium it alone underwrote: 105112505158 < 150613801070] test_F3_jitDepositAfterBindDilutesPremium()
  premium 51125051586
  writer redeem (deposited 100_000e6) 105112505158
  JIT redeem (deposited 900_000e6, 66h in, zero capacity contributed) 946012546427
```

Green, same three tests plus F4 and F5, against the fixed code: `ReReview3Findings: 5 passed, 0 failed`.

Invariant run: `AdversarialGate.invariant.t.sol`, 4 invariants (conservation, gate-matches-Treaty-oracle, bucket/cursor structure, no-violations from the handler's own counters), handler over deposit, redeem, bind (including at `cutoff - 1` and rejected at `cutoff`), settle, cancel, claim, warp and warpEdge. At `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=100` (25,600 calls per invariant, the task's stated minimum): 4 of 4 pass, 0 violations, in 79.88s (285.92s CPU time). The existing `Capacity.invariant.t.sol` (3 invariants from Resolution 2) was re-run at the same 256 x 100 against the fixed code as a regression check: 3 of 3 still pass, 0 failed.

### Mutation check

- Reverted `GRACE` to `7 days`, all other Resolution 3 changes in place. F1 went red (`hours with gate open 0` across the same 1396-hour sample, matching the original pre-fix measurement). Restored `GRACE = 3 days`, diffed `src/Treaty.sol` byte-identical to the fixed version, reran: green.
- Reverted `_entryAssets()` to `return totalAssets();` (dropping `pendingPremium`), all other Resolution 3 changes in place. F3 went red (`JIT redeem 946012546427 > deposited 900_000e6`, matching the original pre-fix dilution). Restored `_entryAssets()`, diffed `src/Capacity.sol` byte-identical to the fixed version, reran: green.
- Also mutated F2's bound checks out of `bind` (kept only the pre-existing `nonZero` check), as an additional check beyond the task's required two: F2 went red (`next call did not revert as expected`, the poisoning exposure now binds unopposed). Restored, diffed `src/Treaty.sol` byte-identical, reran: green.

Full `forge test`: 62 passed, 0 failed, 13 suites before this change (59 non-invariant, 3 invariant). After: 71 passed, 0 failed, 15 suites (64 non-invariant: the prior 59 plus the 5 new `CapacityReReview3.t.sol` tests; 7 invariant: the prior 3 in `Capacity.invariant.t.sol` plus the 4 new `AdversarialGate.invariant.t.sol`).

### Blind spots

- F2's `MAX_EXPOSURE = 1e30` is a static cap chosen from the Pricer's largest table gap (1474 bps); it was not derived from a formal bound on every possible future Pricer table, so a future Pricer with a much larger gap table would need this constant re-checked.
- The adversarial invariant's `afterInvariant` coverage CSV write is disabled in this sandbox (see Tests); the per-selector coverage table forge prints to stdout was used as the substitute evidence instead.
- F1's 3-day grace was chosen at the reviewer's own suggested value; it was not swept against other values between 66h and 102h to find an optimum between "gate stays shut" and "false-positive cancels of a layer whose feed comes back late but before 102h".

## Re-review of 8f492a4 (2026-09-27)

Reviewer: independent adversarial security review. Read-only on repo source; scratch tests against a byte-identical copy of `src/` at 8f492a4, later ported (G3 only) to `contracts/test/CapacityReReview4.t.sol`.

### Verdict: DEPLOY to testnet; FIX FIRST before mainnet (M1, M2, L1 below)

Full `forge test` at 8f492a4: 71 passed, 0 failed, 15 suites (AdversarialGate invariant 4/4 at 256 runs x 500 depth, 128,000 calls each, 0 violations).

### Checked and holding

- Asymmetric pricing (F3). `_entryAssets() >= totalAssets()` always, so entry price >= exit price in every state; `previewDeposit == deposit`, `previewMint == mint`, `previewRedeem == redeem` exactly (OZ 5.7 `deposit`/`mint` route through the overridden previews; `maxWithdraw = previewRedeem(maxRedeem)`). Fuzzed deposit->redeem and mint->withdraw round trips across five states (empty vault, before bind, bind-to-cutoff, after settle, after cancel), 5,000 runs each: never profitable. Mutating `_entryAssets` to `totalAssets() - pendingPremium` turns both red (`deposit->redeem never profits: 450 > 257`); restored, green. An exiting writer forfeits exactly its pro-rata share of `pendingPremium` (`shares * pendingPremium / totalSupply`, fuzzed 5,000 runs), never more. `convertToShares != inverse(convertToAssets)` while premium is pending is a spread, allowed by ERC-4626. First depositor into an empty vault gets shares 1:1.
- F4. Cursor monotone, `sum(lockedByCutoff over distinct cutoffs) == locked`, `gateActive()` equals an earliest-live-bucket oracle, fuzzed over random lock / drain-before-cutoff / relock / warp sequences (3,000 runs). A duplicate `cutoffs` entry `[C, C]` is harmless because buckets are keyed by value. Reverting the F4 condition turns it red (`gate == oracle: false != true`); restored, green.
- F2. `|exposure| <= 1e30` and `retention <= int256.max` make `_settle` overflow-free for every uint64 price pair, not only the Pricer's 1474 bps table (worst `1e30 * 1.8e23` is far under int256).

### Medium

#### M1. 3-day GRACE lets `cancel` pre-empt a valid fix inside the documented 5-day search window (Treaty.sol:92, Treaty.sol:317-325)

The product spec calls for the Monday fix to be "searched forward five days for holidays", and separate operational notes still assumed a cancel grace of 7 days. `cancel` opens at `expiry + 72h` and does not check whether the layer is fixable, so (a) a first post-expiry round printing after 72h (multi-day closure) is never usable, and (b) a layer whose Monday round printed on time but whose `setReference` + `fix` calls did not land within 72h can be cancelled by any writer, who saves the payout; the buyer gets only the premium back. F1's own bound (`66h + GRACE < 168h`, so `GRACE < 102h`) and the 120h search window cannot both hold under the current gate design; at 72h a dead feed and a late feed look identical on-chain. Needs a product decision, not a constant tweak (e.g. decouple the gate from a stuck bucket after `expiry + 72h` and keep `cancel` at >= 5 days, accepting that exits reopen while that layer's loss is unknown).
Tests: scratch only at review time, not yet ported into the repo suite (`test_G1_cancelPreemptsValidLateFix`, red: layer is Cancelled when the valid round at expiry+74h arrives; `test_G2_writerCancelsPayingLayerAfter72h`, demonstration, passes: 50% gap, full 1,000,000 USDG limit owed, writer cancels at expiry+72h, `fix` then reverts `WrongState`). Open, see Resolution 4 below.

#### M2. Flip side of F3: an entrant who buys in before cutoff loses its premium payment to incumbents if the layer is cancelled (Capacity.sol:114-131, 260-265)

The entrant pays `totalAssets() + pendingPremium`; `refundPremium` then removes the premium from the pool, and the entrant's payment for it is split pro rata with incumbents. Measured: 100,000 USDG writer, 100,000 USDG limit, premium 51,125 USDG (Pricer quote, 51% rate on line), 100,000 USDG entrant, cancel: entrant redeems 79,641 USDG, a 20,358 USDG (20%) loss that lands on the incumbent. Resolution 3 acknowledges the direction but not the size. A writer who is also the buyer gets its premium back on cancel, so it bears no cost when a cancel is predictable (dead feed, or a Friday holiday leaving no reference round inside `REF_WINDOW`). M1's shorter grace makes cancels more likely.
Test: scratch only at review time, not yet ported into the repo suite (`test_E1_entrantLosesOnCancel`, red: `79641596383 < 100000000000`). Open, see Resolution 4 below.

### Low

#### L1. `cancel` skips `_requireSequencerUp`, `fix` does not (Treaty.sol:317-320 vs 294)

After a sequencer outage ending past `expiry + 72h`, `fix` reverts `SequencerDown` for the 1h `SEQUENCER_GRACE` while `cancel` succeeds, so writers can cancel a paying layer in that hour. Inert on testnet (`sequencerUptimeFeed == address(0)`). One-line fix: call `_requireSequencerUp()` in `cancel`.
Test: `test_G3_cancelIgnoresSequencerGrace` (red: layer Cancelled while `fix` is blocked).

### Blind spots

- Real Chainlink 24/5 feed behaviour on US holidays (whether a Friday-holiday reference round exists within 24h of Saturday 00:00, when the first Monday-holiday round prints) was not read from a live feed; M1 and M2's likelihood depends on it.
- Fuzz covers one market and one layer per week; multi-market and overlapping-week premium mixes are covered only by the existing AdversarialGate invariant.

## Resolution 4 (2026-09-27)

- G3 (Low) fixed: `cancel` now calls `_requireSequencerUp()`, the same gate `fix` uses. `test_G3_cancelIgnoresSequencerGrace` in `test/CapacityReReview4.t.sol` was red before the one-line change and is green after. Full suite: 76 passed, 0 failed, 16 suites.
- Testnet verdict: DEPLOY. Arbitrum Sepolia has no sequencer uptime feed configured and the demo layers are funded by this repo's own wallets.
- Open before mainnet, product decisions rather than constants:
  - G1/G2 (Medium): a 3-day GRACE lets `cancel` pre-empt a fix that is still valid inside the documented five-day holiday search. The F1 freeze bound needs GRACE under 102h; the holiday search needs 120h. Candidate direction: make `cancel` revert while the market feed has printed any round at or after expiry (a late feed is then fixable, only a dead feed is cancellable), and measure real Chainlink 24/5 holiday behaviour before choosing.
  - E1 (Medium): a writer who deposits between bind and cutoff pays for `pendingPremium` at entry and loses that slice if the layer is cancelled and the premium refunded. Candidate direction: on cancel, return the refunded premium's share from entrants rather than pro rata, or forbid deposits between bind and cutoff for layers that can still be cancelled.

## Re-review (2026-09-28): 6af8b2b, 9210093, 94edf3b, 79320b8

Scope: Pricer rewrite (CoC load, per-market tables, on-chain vol scale, Solidity and Stylus), Capacity events, Treaty DST reference/fixing rule and `StillFixable`. Repo suite: 97/97 non-fork tests pass, 5/5 fork tests pass, `PricerParity` passes (ffi, `pricer_cli` built). Scratch tests below live in `/tmp/heracles-rr/proj/test/ReReview.t.sol` (repo contracts copied unchanged), all red.

Verdict for the testnet redeploy: FIX FIRST (P1 and P2 break or misprice every bind on the planned deploy; P3 is a money-path fairness bug).

### High

#### P1. Stylus `quote` panics on every real Chainlink proxy round id (pricer/src/lib.rs:87)

`latest_id.to::<u64>()` panics when the U80 does not fit in u64. Chainlink proxy ids are `phaseId << 64 | aggregatorRound`, so any live proxy overflows. Live SPY/USD on Arbitrum Sepolia (`0x4fB4...0b06`) returned `roundId = 18446744073709553978` (phase 1, round 2362) on 2026-09-28. With `panic = "abort"` the Stylus call traps, `pricer.quote` reverts, and every `Treaty.bind` through the Stylus pricer reverts. The Solidity twin keeps the phase bits and works (fork tests). `PricerParity` only covers `price_core`, and the Stylus unit test uses an unset feed, so nothing exercised this path.
Repro: `/tmp/heracles-rr/u80` (`cargo run --offline`), panics with `Uint conversion error: Overflow(80, 2362, 18446744073709551615)`.
Fix: do the arithmetic in U80 (`latest_id < U80::from(VOL_ROUNDS)`, `latest_id - U80::from(k)`). Add a Stylus test with a mocked feed that returns a phase-1 id. Also note that Solidity does not wrap `latestRoundData` in `try`, but Rust falls back to neutral, which contradicts docs/pricing.md step 5. Separately, the deployed Stylus pricer `0x0202...95da` has the old `quote(int256[],uint256,uint256)` ABI, so reusing it as `PRICER` also makes every bind revert.

#### P2. Market-to-table mapping is positional, and every configured deploy gets it wrong (Pricer.sol:117-122, core/src/lib.rs `table_for`, script/Deploy.s.sol:33-34)

The testnet Treaty has one feed, SPY at index 0, so SPY exposure is priced on the NVDA table: README example premium 5,062.54 USDG instead of 1,059.92 USDG (4.8x). The repo's own 9-market fork test (`GapTreaty.fork.t.sol:63-64`) orders the feeds SPY, NVDA, AAPL, MSFT..., so none of the four sourced tables reaches its own market.
Test: `test_RR3_singleSpyFeedMustPriceOnSpyTable` (red: `5062541027 != 1059922732`).
Fix: the pricer needs an explicit table id for each market (a constructor array in both implementations, or a table id per feed address). Position must not decide it.

### Medium

#### P3. `StillFixable` almost never fires on a live feed, so each side can cancel the layer that goes against it (Treaty.sol:414, 436-453)

`_anyMarketFixable` only looks at the latest round and its predecessor. By `expiry + 72h`, a feed with a 24h heartbeat has printed about three rounds past expiry, so the check returns false even though the valid first round after expiry is still in the current phase. A market whose reference was never set is skipped as dead even when its feed is live (line 441). Result: a buyer whose layer finished out of the money leaves it unfixed and cancels for a full premium refund, a free option. A writer can still cancel a layer that should pay (G2 above, still open). This does not close G1/G2.
Tests: `test_RR1_cancelOfFixableLayerMustRevert` and `test_RR1b_cancelWithUnsetReferenceOnLiveFeedMustRevert` (red: cancel succeeds and refunds the premium).
Fix (O(1) per market): a market counts as dead only if `latest.updatedAt < boundary`, or the current phase's first round `(phaseId << 64 | 1)` has `updatedAt >= boundary` (the crossing happened in an older phase). Use the same test for the reference boundary. Until then, the redeploy needs a keeper that calls `setReference` and `fix`.

#### P4. The vol scale is a heartbeat and calendar artefact that the buyer can time (Pricer.sol:131-156, src/lib.rs:80-122)

The mean move per round has no time normalisation. On a heartbeat-driven feed, the weekend heartbeats republish the same price and add zero-bps rounds. Over the last 35 rounds of the live Sepolia SPY feed the scale ranged from 0.52x to 1.06x, median about 0.74x, and it never reached the 1.0x "normal" in a normal week. Inside one bind window (Mon 09-21 to Fri 09-25) the same layer quotes 1,922.50 USDG on Wednesday at 0.52x and 4,209.82 USDG on Thursday at 0.88x, a 2.19x swing. Nobody can move Chainlink rounds, but the buyer can choose when to bind, and that choice goes against the writers.
Test: `test_RR4_volScaleTimingOption` (real round data; red: 54% delta against a 10% tolerance).
Fix for the redeploy: `MIN_SCALE_PPM = 1_000_000` in both implementations, so the scale can only raise the price, never lower it below the table. Later: realised variance per market-open hour from `updatedAt`, skipping republished answers.

#### P5. The first round after close has no latest bound (Treaty.sol:342-358)

The reference is safe only while the feed prints a round between Friday close and the Sunday-evening overnight session. The live Sepolia feed does: Saturday heartbeats at 13:31 and 16:18 UTC carried the Friday close. If a feed pauses heartbeats while the venue is closed, the reference becomes the post-news Sunday price.
Test: `test_RR2_referenceMustNotAbsorbWeekendGap` (hypothetical feed config; red: 4,237 USDG paid against a 60,000 USDG true loss).
Fix: revert `setReference` if the chosen round's `updatedAt` is later than about close + 24h (let it go to cancel instead). Check the mainnet feed's weekend heartbeat before mainnet.

### Low / Info

- Holiday Mondays still settle to zero on a republished heartbeat. This is a known, tested limitation (`ReferenceRule.t.sol`). `bind` should refuse weeks whose Monday is an NYSE holiday, and the pricer tables include those weekends measured to the Tuesday open, so the priced risk and the settled risk differ.
- `WEEKEND_HOURS = 66` does not match the lock. Capital is reserved from bind (as early as Monday 00:00 UTC) until settlement, up to about 7.5 days, and the EST weeks run 67h.
- README.md:20 still claims the retracted 4.06x gas ratio, and README.md:98 still shows the old `1.25*EL + 0.5*TVaR95` formula.
- Capacity events (94edf3b): additive only, each emitted after its state change, and the semantics are unchanged (diff checked line by line). The early `return` on a zero amount emits nothing, which is fine.
- DST math: `weekWindow`/`fridayCloseOf`/`_isUsDst` are correct at both switch weekends, and a DST change can never fall between Friday 00:00 UTC and the Friday close. The bind cutoff (19:30 UTC) stays before the reference under both regimes, so a buyer never sees the reference before binding. `setReference` and `fix` accept exactly one round for each boundary, so nothing can be front-run or chosen.

### Pricing (item 2): the CoC load is too thin for writers

README example (long $2M, NVDA table, retention $20k, limit $60k, 1.0x): EL 5,040.08, TVaR95 54,728, P(any payout) 21.8% per weekend, P(full-limit loss) 3.4%. Premium 5,062.54, which is EL + 22.46. The writer's expected excess return is 0.037% of locked capital per weekend: 1.95% a year on a 1-week lock, below the USDG risk-free rate. The payout standard deviation is 22% of the limit per weekend, so the annualised Sharpe ratio is about 0.01. The standard error of EL from 504 scenarios is 590 (11.7% of EL; 25% for SPY), about 26x the load.

Recommended: `premium = EL + 0.03 * (TVaR95 - EL) + 0.04 * limit * 7/365`. This is a per-weekend risk load (not prorated) plus the risk-free rate on the fully collateralised limit for the real one-week lock. Keep the 50 bps rate-on-line floor and `MIN_SCALE_PPM = 1.0x`.
- README example: 5,040.08 + 1,490.64 + 46.03 = 6,576.75 USDG, rate on line 10.96%, 1.305x EL. Writer excess return is 129% a year on the limit against a 159% annual standard deviation (Sharpe about 0.8).
- SPY table, same layer: 1,051.19 + 579.50 + 46.03 = 1,676.72 USDG, rate on line 2.79%, 1.60x EL, Sharpe about 0.7.
- Both sit above the bootstrap p90 of EL (1.15x EL for NVDA, 1.34x for SPY), so the load covers the estimation error.
- Buyer side: the net cost of cover beyond expected recoveries is 4.0% a year of a $2M NVDA exposure and 1.6% a year for SPY.
Numbers: `/tmp/heracles-rr/econ.py` on `evidence/gap-tables/*.json`.

### Blind spots

- The Stylus panic is shown with a standalone repro of the same expression and types, not with a deployed Stylus call.
- The benchmark comparison (cat bond spreads, Nexus, Sherlock) was not re-fetched in this re-review.
- Mainnet Arbitrum One equity-feed weekend and holiday heartbeat behaviour was not read. Only Sepolia SPY rounds 2320-2362 were read.

## Round 6: v3 books, tranches and oracle rules (2026-09-30)

Scope: `contracts/src` changes from 178f92d to d4a3dc7 (v2 to v3: books, first-loss and senior tranches, round-in-effect reference rule, stale and phase void proofs, bind freshness, cancel liveness), read against docs/design/v3.md decisions 1 to 3 and its invariant table (C1, H1, F3, M1, E1, T1 to T5). Reviewer: independent adversarial review, lane L6. No repo file other than this section was edited. Nothing committed, pushed or deployed.

Scratch: `/tmp/l6` (repo `contracts/src`, `contracts/test`, `foundry.toml` copied, `lib` symlinked; `diff -r /tmp/l6/src contracts/src` identical). All findings tests are in `/tmp/l6/test/L6Review.t.sol`. Fix prototype plus one mutation: `/tmp/l6fix` (same test file, patched `src`). Repo suites run in the scratch copy on the unchanged source: Books, Tranche, TrancheAdditivity, Liveness, TreatyVoid, ReferenceRule, Treaty, CapacityC1, WeekWindow, 52 passed, 0 failed.

### Verdict: FIX FIRST before the verified redeploy (two small changes in `cancel`/`claimTo`, prototyped green)

Nothing found moves money to the wrong party. T1, T3, T4, T5 (for Treaty's own flows) and "both vaults' gates open and close together" hold under a fuzz that goes red when the waterfall is mutated. The v3 money paths are sound. The open problems are liveness: `cancel` is the only exit for an unfixable layer, and it now depends on three things that can fail forever: a push transfer to the buyer, an immutable liveness feed, and the market feed staying readable. When any of them fails, the layer stays `Bound`, its cutoff bucket never drains, and `gateActive()` stays true in both vaults of that book. `maxDeposit`, `maxMint` and `maxRedeem` then return 0 for every writer, free capital included, with no admin path out.

| # | Severity | Where | One line |
|---|---|---|---|
| L6-1 | Medium | Treaty.sol:681-682, Capacity.sol:277-283 | Issuer freeze of the buyer (USDC blacklist, USDG asset protection) makes `cancel` revert forever and freezes the whole book |
| L6-2 | Medium | Treaty.sol:671-675, 727-728 | No time-bounded exit: a stopped liveness feed, or a market feed whose reads revert, freezes the book forever |
| L6-3 | Low | Treaty.sol:539, 610, 710-713 (and 634-637, 728-735) | A fresh in-effect round with an out-of-range answer can be neither referenced nor voided (Monday twin: first post-expiry round out of range) |
| L6-4 | Low | Treaty.sol:547, 610, 681-682 | Holiday-Friday weeks void predictably, so a bind shuts both gates about 90h at zero net premium |
| I-1 | Info | Treaty.sol:85-88, 496-498 | T5 holds for Treaty's own flows only; a direct transfer strands tokens with no sweep |
| I-2 | Info | see list | Unproven observations |

### Medium

#### L6-1. A frozen buyer bricks `cancel` and the whole book (Treaty.sol:681-682, Capacity.sol:277-283)

- Root cause: `cancel` pushes the premium refund to `L.buyer` inside the same call that unlocks both slices. If that transfer reverts, the unlock reverts with it. v2 had the same push (M3), but v3 adds a USDC book, and Circle blacklists addresses routinely. Paxos USDG has an equivalent freeze. L4 fixed the same problem for `claim` with `claimTo`. `cancel` never got the equivalent.
- Sequence: (1) a buyer binds in the USDC book. (2) The layer becomes unfixable: a dead feed, a voided reference, or any L6-3 case. (3) Circle blacklists the buyer before anyone cancels. (4) Every `cancel` reverts in `refundPremium`. The layer stays `Bound` and both vaults' cutoff buckets stay nonzero, so `gateActive()` is true forever. Every writer in the USDC book, first loss and senior, can neither deposit nor withdraw, including capital that was never locked.
- Test (`test_L6_1_frozenBuyerBricksCancelAndBook`), red on current code: `first-loss writer frozen forever: 0 <= 0`. Control `test_L6_1_control_cancelWorksWhenBuyerNotFrozen` is green, so only the freeze blocks the exit.

```solidity
function _deadFeedLayer(FreezableToken tok) internal returns (uint256 id) {
    live = new MockFeed();
    _deploy(address(tok), address(new MockFeed()), address(live));
    _fund(address(tok));
    feed.set(1, 770e8, THU_HB);
    id = _bind();
    feed.set(2, 771e8, FRI + 19 hours); // in effect at close, fresh
    vm.warp(CLOSE + 1);
    t.setReference(id, 0, 2);
    // the equity feed dies after Friday: no Monday round ever prints
    live.set(1, 1e8, EXPIRY + 3 days + 29 days);
    vm.warp(EXPIRY + 3 days + 30 days);
}

function test_L6_1_frozenBuyerBricksCancelAndBook() public {
    FreezableToken tok = new FreezableToken();
    uint256 id = _deadFeedLayer(tok);
    tok.freeze(buyer); // issuer freezes the buyer after bind (Circle blacklist, Paxos freeze)
    try t.cancel(id) {} catch {}
    assertGt(fl.maxRedeem(writer), 0, "first-loss writer frozen forever");
    assertGt(sr.maxRedeem(writer), 0, "senior writer frozen forever");
}
```

- Fix (prototyped in `/tmp/l6fix`, test green): in `cancel`, stop pushing the refund. Move each slice's premium out of `pendingPremium` and into `owed` (a new three-line `Capacity.cancelPremium`), and let the buyer pull it through `claimTo(id, to)` for a `Cancelled` layer, paying `premiumJunior`/`premiumSenior` through the existing `payOut`. T5 is unchanged, since Treaty still never holds a balance.

#### L6-2. No time-bounded exit from an unfixable layer (Treaty.sol:671-675, 727-728)

- Root cause: `cancel` requires `livenessFeed.updatedAt >= expiry + 26h` (line 673) and `!_anyMarketFixable` (line 675). `_isMarketDead` calls `feed.latestRoundData()` without `try` (line 728). No elapsed time ever lifts either condition. `livenessFeed` is immutable.
- Sequence A: Chainlink deprecates the Arbitrum Sepolia USDC/USD feed (testnet feeds are retired routinely, and a retirement usually stops a network's equity feed too, which is the one case where `cancel` is needed). Any layer whose equity feed stops after Friday can then never be cancelled. The book is frozen as in L6-1.
- Sequence B: a market feed's proxy starts reverting on reads after the reference is set. `_isMarketDead` reverts, so `cancel` reverts forever.
- Tests, red on current code:
  - `test_L6_2a_stoppedLivenessFeedBricksBookForever`: `book frozen a year after expiry: liveness feed stopped: 0 <= 0` (cancel reverts `StillFixable` 365 days after expiry)
  - `test_L6_2b_revertingMarketFeedBricksBookForever`: `book frozen a year after expiry: market feed reverts: 0 <= 0`
  - Control `test_L6_2_control_cancelWorksWhileLivenessFeedPrints` is green.

```solidity
function _stuckSetup(address feed_, uint256 livenessLastPrint) internal returns (uint256 id) {
    MockUSDG usdg = new MockUSDG();
    live = new MockFeed();
    _deploy(address(usdg), feed_, address(live));
    _fund(address(usdg));
    live.set(1, 1e8, livenessLastPrint);
    feed.set(1, 770e8, THU_HB);
    id = _bind();
    feed.set(2, 771e8, FRI + 19 hours);
    vm.warp(CLOSE + 1);
    t.setReference(id, 0, 2);
}

function test_L6_2a_stoppedLivenessFeedBricksBookForever() public {
    // USDC/USD liveness feed's last print is Friday 11:39 UTC, then it is deprecated
    uint256 id = _stuckSetup(address(new MockFeed()), FRI + 11 hours + 39 minutes);
    vm.warp(EXPIRY + 365 days);
    (bool ok, bytes memory ret) = address(t).call(abi.encodeCall(Treaty.cancel, (id)));
    if (!ok) assertEq(bytes4(ret), Treaty.StillFixable.selector);
    assertGt(fl.maxRedeem(writer), 0, "book frozen a year after expiry: liveness feed stopped");
}

function test_L6_2b_revertingMarketFeedBricksBookForever() public {
    BreakableFeed bf = new BreakableFeed();
    uint256 id = _stuckSetup(address(bf), EXPIRY + 40 days);
    bf.breakIt(); // proxy decommissioned after the reference was set
    vm.warp(EXPIRY + 365 days);
    try t.cancel(id) {} catch {}
    assertGt(sr.maxRedeem(writer), 0, "book frozen a year after expiry: market feed reverts");
}
```

- Fix (prototyped, both tests green): skip the liveness and `_anyMarketFixable` checks once `block.timestamp >= expiry + 30 days`. A live 24h-heartbeat feed has printed dozens of post-expiry rounds by then, so anyone who wanted the layer fixed has had 30 days to do it, and the halted-chain race the liveness check guards cannot last that long. This does not reopen F1: bind freshness already refuses new layers on a dead feed.

### Low

#### L6-3. An out-of-range in-effect answer is neither referenceable nor voidable (Treaty.sol:539, 610, 710-713)

- Root cause: `setReference` rejects the in-effect round on its answer (line 539). `voidReference` only accepts it when it is stale (line 610). A fresh round with `answer <= 0` or `answer > uint64.max` matches neither. `_anyMarketFixable` counts an unreferenced, non-void market as fixable (line 712), so `cancel` reverts `StillFixable` forever. Monday twin, unchanged from v2: when the first round at or after expiry is out of range and a good round follows it, `fix` rejects both (`BadRound`, then `NotFirstRound`). `_isMarketDead` reads only the latest round, so it calls the market live.
- Trigger needs Chainlink to publish an out-of-range answer. OCR2 `minAnswer` normally prevents this, hence Low. The impact is the same permanent book freeze as L6-1.
- Tests, red on current code:
  - `test_L6_3_badAnswerInEffectRoundIsUnvoidable`: `book frozen: reference neither settable nor voidable: 0 <= 0`
  - `test_L6_3b_badAnswerFirstMondayRoundIsUnfixableAndUncancellable`: `book frozen: first Monday round unusable, market not dead: 0 <= 0`

```solidity
function test_L6_3_badAnswerInEffectRoundIsUnvoidable() public {
    MockUSDG usdg = new MockUSDG();
    live = new MockFeed();
    _deploy(address(usdg), address(new MockFeed()), address(live));
    _fund(address(usdg));
    live.set(1, 1e8, EXPIRY + 40 days);
    feed.set(1, 770e8, THU_HB);
    uint256 id = _bind();
    feed.set(2, 0, FRI + 19 hours + 45 minutes); // in effect at close, fresh, answer 0
    feed.set(3, 772e8, FRI + 3 days + 4 minutes); // Sunday-night reopen
    feed.set(4, 760e8, EXPIRY + 1 hours); // Monday, first after open
    vm.warp(EXPIRY + 3 days + 30 days);

    vm.expectRevert(Treaty.BadRound.selector);
    t.setReference(id, 0, 2); // rule 2, answer
    vm.expectRevert(Treaty.BadRound.selector);
    t.setReference(id, 0, 1); // rule 4, superseded before close
    vm.expectRevert(Treaty.BadTiming.selector);
    t.voidReference(id, 0, 2); // not stale
    vm.expectRevert(Treaty.BadRound.selector);
    t.voidReference(id, 0, 1); // rule 4

    try t.cancel(id) {} catch {}
    assertGt(fl.maxRedeem(writer), 0, "book frozen: reference neither settable nor voidable");
}

function test_L6_3b_badAnswerFirstMondayRoundIsUnfixableAndUncancellable() public {
    MockUSDG usdg = new MockUSDG();
    live = new MockFeed();
    _deploy(address(usdg), address(new MockFeed()), address(live));
    _fund(address(usdg));
    live.set(1, 1e8, EXPIRY + 40 days);
    feed.set(1, 770e8, THU_HB);
    uint256 id = _bind();
    feed.set(2, 771e8, FRI + 19 hours);
    vm.warp(CLOSE + 1);
    t.setReference(id, 0, 2);
    feed.set(3, 0, EXPIRY + 10 minutes);
    feed.set(4, 760e8, EXPIRY + 1 hours);
    vm.warp(EXPIRY + 3 days + 30 days);

    vm.expectRevert(Treaty.BadRound.selector);
    t.fix(id, 0, 3);
    vm.expectRevert(Treaty.NotFirstRound.selector);
    t.fix(id, 0, 4);
    try t.cancel(id) {} catch {}
    assertGt(fl.maxRedeem(writer), 0, "book frozen: first Monday round unusable, market not dead");
}
```

- Fix: the L6-2 backstop turns both green (prototyped). A tighter fix is a third void proof in `voidReference`: the round that passes rules 2 (phase) to 4 has an out-of-range answer.

#### L6-4. Holiday-Friday weeks void predictably, so the gate closes for free (Treaty.sol:547, 610, 681-682)

- Root cause: rule 5 voids any week whose in-effect round is more than 26h old at the close. On an exchange-holiday Friday (2026-12-25 and 2027-01-01 are both Fridays; Good Friday is 2027-03-26), a feed that pauses with the market has its last print on Thursday. Bind freshness is checked only at bind time, so a Thursday bind passes. The layer then voids and cancels with a full refund. The design's generalised L2 rule ("no vault's gate can be closed for free") does not hold on those weeks. Both gates stay shut from Friday 19:30 until `expiry + GRACE` (Thursday 13:30), about 90h instead of the usual 66h. The same predictability lets a writer who is also the buyer harvest E1 entrants on those weeks.
- Test `test_L6_4_holidayFridayVoidShutsGatesForFree`, red on current code: `both gates shut Fri 19:30 to Thu 13:30 at zero net premium: 0 <= 0`. The test also asserts that both gates are still shut on Monday evening and on Thursday one second before the cancel.

```solidity
function test_L6_4_holidayFridayVoidShutsGatesForFree() public {
    MockUSDG usdg = new MockUSDG();
    live = new MockFeed();
    _deploy(address(usdg), address(new MockFeed()), address(live));
    _fund(address(usdg));
    // Feed pauses on the exchange holiday: last print Thursday 16:18 UTC, next Sunday night.
    feed.set(1, 770e8, THU_HB);
    uint256 before = usdg.balanceOf(buyer);
    uint256 id = _bind(); // Thursday 17:00 UTC, feed 42 min old: bind freshness passes
    feed.set(2, 700e8, FRI + 3 days + 4 minutes); // Sunday-night reopen, 9% gap
    feed.set(3, 690e8, EXPIRY + 5 minutes);

    vm.warp(CLOSE + 1);
    assertTrue(fl.gateActive() && sr.gateActive());
    vm.expectRevert(Treaty.BadRound.selector);
    t.setReference(id, 0, 1); // rule 5: 27h42m before close
    t.voidReference(id, 0, 1);

    vm.warp(EXPIRY + 6 hours); // a settled week would have reopened by now
    assertTrue(fl.gateActive() && sr.gateActive(), "gates still shut Monday evening");
    live.set(1, 1e8, FRI + 5 days + 11 hours + 39 minutes); // Wed 11:39 heartbeat
    vm.warp(EXPIRY + 3 days - 1);
    assertTrue(fl.gateActive(), "gates still shut Thursday morning");
    vm.warp(EXPIRY + 3 days);
    t.cancel(id);

    uint256 netPremium = before - usdg.balanceOf(buyer);
    assertGt(netPremium, 0, "both gates shut Fri 19:30 to Thu 13:30 at zero net premium");
}
```

- Likelihood depends on how the real feed behaves on holidays, which was not read. The Sepolia SPY feed prints every 24h through weekends, so it probably never voids. The RHC feeds stop for 52 to 56h every weekend, so they may void. Fix: on a void-driven cancel, keep each slice's capital charge (the pricer's `limit * 4% * 7/365` term) in its vault and refund only the rest. Alternatively, `bind` reverts in weeks whose Friday is an NYSE holiday (fixed dates plus Good Friday). Not prototyped. The L6-1 prototype turns this test green only incidentally, because the refund becomes a pull, so it is not evidence for either fix.

### Info

- I-1. T5 holds for every Treaty-initiated flow (bind pulls `premium`, then the vaults pull `premiumJunior + premiumSenior == premium` exactly; a failed or short pull, including a fee-on-transfer token, reverts the whole bind). A plain `transfer` to Treaty, or a buyer's `claimTo(id, treaty)`, leaves a balance that nothing can move. Test `test_L6_info_T5_donationStrandsBalance`, red: `Treaty balance nonzero after a plain transfer: 1000000 != 0`. Harmless to the protocol. Only the sender loses.
- I-2 (unproven, no failing test):
  - `voidReference` is not gated by `_requireSequencerUp` while `setReference` is (Treaty.sol:534 vs 576-614). The void proof is objective timestamp data, so the missing gate changes nothing today. It is inert on Sepolia and RHC (`sequencerUptimeFeed == 0`).
  - The constructor accepts the same asset twice (Treaty.sol:273-287), which creates two books over one token. T4 still holds per vault. This is a config footgun only.
  - `referencedCount`/`fixedCount` are `uint8` (Treaty.sol:104-105) and the constructor does not bound `feeds.length`. With 256 or more markets `fix` can never run. Deploys use 1 or 4 markets.
  - Senior premium versus its own sub-quote: `premiumSenior = max(qTotal, floor) - qJunior`. With comonotone slice payouts, `floor(a+b) >= floor(a)+floor(b)` on every division, so it can fall short of `quote(R+J, L-J)` only by integer flooring, a few base units. The floor top-up only adds to the senior slice. This was not fuzzed beyond the repo's `TrancheAdditivity`.
  - The minimum nonzero slice premium is 1 base unit. The junior capital charge reaches 1 at `J >= 1,304` base units, and the H2 floor keeps total dust binds at `>= 0.5%` of the limit. A dust bind still shuts both gates for the normal settlement window at negligible cost. This is the same economics as v2 and is bounded by H1.
  - The two `quote` calls double the pricer cost of `bind`. `markets` is fixed at deploy, so an attacker cannot grow it. Not measured at 4 markets with the Solidity twin.
  - Four fresh vaults per deploy and no seed deposit in `script/Deploy.s.sol`: the classic first-depositor donation grief applies to each (OZ offset 0). This predates v3.

### E1 (known open): confirmed unchanged in kind

An entrant between bind and cutoff pays `totalAssets() + pendingPremium` in one vault and loses that vault's share of the premium on a cancel. This is per vault, exactly as the design states. No new path makes it worse in kind. In degree, the first-loss vault carries about 61% of the premium on 30% of the capital (README layer), so its pending premium per unit of capital is about 3.7x the senior's, and an entrant into the first-loss vault loses about 3.7x more per dollar on a cancel. L6-4 makes such cancels predictable on holiday weeks.

### Checked and holding

- T1 (Treaty.sol:794-795): `testFuzz_L6_holding_T1_gateTogether_T5` covers retention 0 to 100k, limit 10k to 200k, Monday moves -30% to +30%, and 256 runs, green. It asserts `pj + ps == p`, `pj <= J`, `ps <= L - J`, and `ps > 0 => pj == J`. Mutation in `/tmp/l6fix` (senior slice paid first) makes it red: `T1 senior pays only after junior exhausted: 20484083040 != 57000064201`. The repo's `Tranche.t.sol` is also green.
- T2 (Treaty.sol:449-470): `premiumSenior = premium - premiumJunior` by construction, and the fuzz asserts the sum. `premiumJunior == 0 || premiumSenior == 0` reverts. `TrancheAdditivity` is green.
- T3 and M1 per vault: after bind the fuzz asserts `fl.locked == J`, `sr.locked == L - J` and each `pendingPremium` equals its slice. After settle it asserts both `locked` are drained, each `owed` equals its slice payout, and pending premium is released.
- Claim: `buyerClaimed` is set before the vault calls, under `nonReentrant`. The fuzz asserts the buyer receives exactly `payout` across both vaults, both `owed` drain to 0 and not below it (`payOut` also caps at `owed`), and a second `claim` reverts `NothingToClaim`.
- Both gates move together (H1 per book): every `lock`/`unlock`/`settle` passes the same `L.fridayCutoff` to both vaults with nonzero amounts (Treaty.sol:447, 490-491, 679-680, 807-808), so the `cutoffs` arrays and cursors evolve identically. The fuzz asserts both shut at the cutoff and both open after `fix`. A JIT deposit into one vault only is therefore impossible.
- T4: every vault call goes through `books[L.book]` (bind 489-498, cancel 678-682, settle 806-813, claim 759-761), and allowances are granted per book asset. `Books.t.sol::test_T4` is green.
- T5 (Treaty-initiated flows): the fuzz asserts a Treaty balance of 0 after bind and after settle and claim. `Books.t.sol` T5 tests are green.
- Round selection (Treaty.sol:537-547, 602-610): within a phase, rules 3 and 4 pick exactly one round, given contiguous round ids and monotone `updatedAt` (OCR2 `transmissionTimestamp` is the block time). `nextUpdatedAt == 0` only happens for `roundId >= latest`, where the answer or `updatedAt == 0` check reverts first. A caller cannot choose a different round. `Liveness.t.sol::testFuzz_setAndVoidExclusive` and `TreatyVoid.t.sol::testFuzz_V1_voidNeverHitsReferenceableMarket` are green.
- Void and set are exclusive: the flags at lines 526, 530, 580 and 581, plus the phase proof (the phase's first round is after close, so no current-phase round is at or before close).
- Overflow: `|exposure| <= 1e30` and the price difference is at most `2^64`, so the product is at most 1.8e49, below int256's ceiling. `limit * juniorShareBps` and the pricer's capital-charge product revert far above any lockable limit.
- Reentrancy: every state-changing Treaty entry point is `nonReentrant`, every vault money function is `onlyTreaty`, and both book tokens have no transfer hooks.

### Blind spots

- Real feed behaviour on exchange holidays (Christmas 2026 and New Year 2027 are Fridays) and Chainlink proxy behaviour after deprecation (returns stale data or reverts) were not read. L6-2 and L6-4 likelihood rest on them.
- Only the Solidity pricer twin, one market and mock feeds. The Stylus pricer, 4-market layers and the RHC fork were not replayed. No invariant campaign was run this round. The fuzz is one layer per run.
- The Circle USDC and Paxos USDG freeze semantics were modelled with a mock, not read live.
- The fix prototype was checked only against `L6Review.t.sol`, not against the repo suites. It changes the cancel refund from push to pull, so `Books.t.sol::test_T5_treatyBalanceZeroAfterCancel` and any test that expects an immediate refund need updating.

### Resolution (2026-09-30, branch v3)

- **L6-1: fixed.** `cancel` no longer pushes the premium refund to `L.buyer`. Capacity gained `cancelPremium(uint256 amount) external onlyTreaty`, which moves `amount` from `pendingPremium` into `owed` (reverts `InsufficientPremium` if `amount > pendingPremium`); `refundPremium` is removed. `claim`/`claimTo` now accept a `Cancelled` layer alongside `Settled`, paying `premiumJunior`/`premiumSenior` through the same pull `payOut` a settled payout already uses, so a buyer frozen by their own issuer redirects the pull through `claimTo` (L4's pattern) instead of bricking the book. Commit b506f11.
- **L6-2: fixed.** `cancel`'s livenessFeed check and its `_anyMarketFixable` `StillFixable` check now run only while `block.timestamp < expiry + CANCEL_BACKSTOP`, a new named constant at 30 days. Past that point both checks are skipped and cancel proceeds regardless of what either signal reports. The sequencer-down check and the `GRACE` wait before `expiry` still apply unconditionally, only the two checks that can otherwise never resolve are time-bounded. Trade-off, stated plainly: a live 24h-heartbeat feed prints dozens of post-expiry rounds in 30 days, so a buyer whose layer actually did pay out has that long to call `fix` before anyone can cancel out from under them; a buyer who lets a fixable layer sit unfixed for 30 days loses it to cancel instead of collecting the payout. Commit b506f11.
- **L6-3: covered by the L6-2 backstop at first, closed by a terminal path since.** The independent v3 review's L-1 removed the backstop's cover (below), and the void proofs this doc's L6-3 section suggested replaced it: see "L6-3 and L6-3b: terminal path" at the end of this file. `Round6Test::test_L6_3_badAnswerInEffectRoundVoidsAndCancelsPastBackstop` and `test_L6_3b_badFirstMondayRoundVoidsAndCancelsPastBackstop` carry the original scenarios and now assert the cancel.
- **L6-4: accepted for this deploy.** No code change. Holiday-Friday weeks (2026-12-25, 2027-01-01, Good Friday 2027-03-26) still void for free: a feed that pauses with the market has its last print Thursday, bind freshness is checked only at bind time, and the layer voids and cancels at zero net premium, both gates shut roughly 90h instead of the usual 66h. `Round6Test::test_L6_4_holidayFridayVoidShutsGatesForFree` demonstrates and pins this: `netPremium` is exactly 0 by construction (bind pulls exactly `premium`, a cancelled layer's claim refunds exactly `premium` back), asserted with `assertEq`, not the reviewer's original `assertGt`, which does not hold under either the old push refund or the new pull one. Cost stated plainly: on the RHC feeds (52 to 56h weekend gap), this predictably shuts both gates for about 90h a few times a year at zero premium to writers, and lets a writer who is also the buyer harvest E1 entrants on those weeks (E1 is already a known-open finding). The two fixes this doc's L6-4 section names, charging a capital fee on a void-driven cancel, or reverting `bind` on an NYSE-holiday Friday, are calendar-dependent work deferred past this deploy.
- **I-1: accepted.** No code change. T5 (Treaty's own balance stays zero) holds only for Treaty-initiated flows; a plain `transfer` to Treaty, or a buyer's `claimTo(id, treaty)`, strands that balance with no sweep. `Round6Test::test_L6_info_T5_donationStrandsBalance` pins this as `assertEq(balance, 1e6, ...)`, correcting the reviewer's original inverted `assertEq(balance, 0, ...)`. Harmless to the protocol; only the sender of the stray transfer loses.
- Tests: `contracts/test/Round6.t.sol` (commit 90ed01a) ports `/tmp/l6/test/L6Review.t.sol` into the repo suite as `Round6Test`, 10 tests, all passing against the fixed behaviour. Every existing test that expected cancel's old push refund (`TreatyVoid.t.sol`, `Liveness.t.sol`, `Treaty.t.sol`, `AttackReview.t.sol`, `Books.t.sol`, `GapTreatyFork.lifecycle.t.sol`, `GuardMutation.t.sol`) is updated to assert the pull instead, and both invariant suites' `invariant_ledgersMatchLayers` cross-check (`AdversarialGate.invariant.t.sol`, `Capacity.invariant.t.sol`) gained the `Cancelled`-and-unclaimed branch cancel's new `owed` accounting needs (commit b506f11).
- Final state: non-fork suite 145 passed, 0 failed, 4 skipped (fork tests without `FORK_TESTS=1`). `FORK_TESTS=1 forge test --match-contract Fork`: 10 passed, 0 failed, including `GapTreatyForkLifecycleTest::test_forkLifecycle_cancelAfterGraceRefundsPremium`.

## Independent v3 review: H-1, L-1, L-2 (2026-10-01, branch v3)

Source change: 7116f38 (`Treaty.sol` only). Tests: `contracts/test/V3Review.t.sol` (10 tests, `V3ReviewTest`) plus the existing suite moved to the new bind window. The review's own text and PoCs were not in the repo or in `/tmp` when this was written (the scratch worktrees under `/tmp/v3-review` were already pruned), so the PoCs below are rebuilt from the findings as 7116f38's comments state them, not copied from the reviewer's files.

- **H-1: fixed.** `bind` now closes at Thursday 19:30 UTC (`fridayCutoff - BIND_LEAD`, one day), so the round that will be in effect at Friday's close cannot have printed when a layer binds, even on a feed that is silent for a full heartbeat. A heartbeat is configuration, so the guard is also by data: `setReference` reverts `ReferenceKnownAtBind` for a round whose `updatedAt <= fridayCutoff - BIND_LEAD`, and `voidReference` accepts that same condition as a third proof, after which `cancel` refunds the whole premium. Boundary is exact: a round at 19:30:00 is known, 19:30:01 is not.
  - `test_H1_bindWindowClosesThursday1930`, `test_H1_PoC_fridayBindAgainstVisibleInEffectRoundIsRefused` (old code: the Friday 19:00 bind is accepted and settles, buyer paid 23,810.56 USDG and was owed 12,987.01), `test_H1_stalledFeedKnownAtBindRoundCannotBeReferenceAndVoidsToFullRefund` (round exactly 26h old at close: rule 5 accepts it on the old code; asserts `ReferenceKnownAtBind`, void, cancel, and the buyer's balance back to the pre-bind figure), `test_H1_boundaryRoundAtDeadlineIsKnownOneSecondLaterIsNot`, `testFuzz_H1_exactlyOneOfSetOrVoidAtBindDeadline` (exclusivity fuzz over +-2h around the deadline, both call orders: exactly one of set and void succeeds, the loser stays shut, and the side is `updatedAt > deadline`).
  - Observation: the old "stale" void proof is now subsumed. Stale means older than 26h at close, and the bind deadline sits 24.5h (EDT) or 25.5h (EST) before close, so every stale round is also known at bind. The stale branch stays in the code and is harmless; it can no longer be the only reason a round voids.
- **L-1: fixed.** `cancel` never skips `_anyMarketFixable`, backstop or not (an out-of-the-money buyer could wait 30 days and take the whole premium back instead of letting `fix` pay writers). `_isMarketDead` reads `latestRoundData()` through try/catch, so a reverting market feed reads as dead and cannot block the cancel that now always runs the check. `CANCEL_BACKSTOP` lifts the liveness-feed check only.
  - `test_L1_cancelPastBackstopIsRefusedWhileFixableAndFixPaysWriters` (cancel reverts `StillFixable` at expiry + 30d + 1 and at + 365d; `fix` then settles at payout 0 and the writers' assets rise by exactly the premium), `test_L1_revertingMarketFeedReadsAsDeadNotAsBlocker` (before the backstop: old code reverts with the feed's own error).
  - **Consequence, since closed:** L-1 removed the cover that made L6-3 and L6-3b recoverable. A fresh in-effect round with an out-of-range answer (neither referenceable nor voidable), or a first Monday round with an out-of-range answer followed by a good round, left the layer `Bound` forever with both gates shut, because `_anyMarketFixable` still counted the market as fixable. Resolved below by `voidReference`'s bad-answer proof and the new `voidFix`; the two tests that pinned the behaviour were flipped to assert the cancel.
- **L-2: fixed.** `bind(book, exposure, retention, limit, maxPremium)` reverts `PremiumTooHigh` if the charged premium exceeds `maxPremium`. The comparison is on the floored premium (H2 floor included), after the zero check.
  - `test_L2_roundBetweenQuoteAndBindCannotRepriceAboveCeiling` (8 quiet rounds, quote, a +10% round lands, the premium rises, a bind at the old quote reverts, a bind at the new one charges exactly it), `test_L2_ceilingBoundary` (premium binds, premium - 1 and 0 revert), `test_L2_ceilingAppliesToTheFlooredPremium` (raw quote below the floor, ceiling at the raw quote still reverts).
- **Existing suite.** 7116f38 left 31 tests failing (they bound on Friday or relied on the old backstop). All now bind Thursday 19:00 UTC before the deadline and use a round printed after the deadline as the reference. `DR`'s liveness fuzz splits at the new boundary; the four fork tests that bind (`GapTreaty.realweekend`, `RobinhoodWeekend`) bind Thursday 18:30 UTC and still settle off the real rounds (SPY 358, round 146), which printed after Thursday 19:30.

Evidence (all on the commit that adds this section):

| Check | Result |
|---|---|
| `V3ReviewTest` on 881c1df's `Treaty.sol` (bind lines reduced to the 4-argument form in a scratch copy) | 0 passed, 10 failed, each for its own reason (`next call did not revert as expected`, `decommissioned`, the PoC's `Friday bind ... accepted`, the fuzz's `set succeeds exactly when ...`) |
| `V3ReviewTest` on HEAD | 10 passed, 0 failed |
| Mutants, one at a time, in a scratch copy (`rsync -a --exclude out --exclude cache contracts/ /tmp/hv3-mut/`) | 9 of 9 killed: bind window back to Friday (2 red), `setReference` check deleted (3 red, includes the fuzz), `<=` to `<` (1 red), void proof removed (3 red), backstop skips fixable check (1 red), bare `latestRoundData` (1 red), `maxPremium` check deleted (3 red), compared to the raw quote (1 red), `>=` for `>` (3 red) |
| Full non-fork suite | 155 passed, 0 failed, 4 skipped (the fork files without `FORK_TESTS`) |
| `FORK_TESTS=1 forge test --match-path 'test/*ork*.sol'` (public archive RPCs hardcoded in the tests, no key) | 10 passed, 0 failed |

Blind spots: the reviewer's PoCs were rebuilt, not ported. Only EDT weeks are exercised for the 24.5h margin (the EST margin is 25.5h by arithmetic, no test). The pricer's vol-scale reprice in the L-2 PoC uses a mock feed, not a real round landing. `README.md`, `docs/SUBMISSION.md`, `docs/design/v3.md`, `web/src/hooks/useWeekWindow.ts`, `web/src/lib/treaty.ts`, `web/src/lib/format.ts` and `web/src/pages/Bind.tsx` still mention the Friday 19:30 UTC bind cutoff and the 4-argument `bind`; they were not touched and are now wrong until updated.

## L6-3 and L6-3b: terminal path (2026-10-01, branch v3)

Source change: `Treaty.sol` only. Tests: `contracts/test/V3Review.t.sol` (`V3ReviewTest`, V-1 and V-2 groups) and the two flipped tests in `contracts/test/Round6.t.sol`.

Problem. L-1 made `cancel` check `_anyMarketFixable` unconditionally, so any layer that cannot settle yet still reads as fixable stays `Bound` forever. Two such layers existed: (a) the round in effect at Friday's close is fresh and carries an answer `<= 0` or above `uint64.max`, so `setReference` rejects it (rule 2) and no void proof applied; (b) the first round at or after Monday's expiry carries such an answer and a later good round follows, so `fix` rejects both (`BadRound`, `NotFirstRound`) while `_isMarketDead` calls the market live. Writers and buyer funds stay locked and both gates shut. A third case was found while writing the tests: `_isMarketDead` returned dead whenever the latest round's answer was out of range, so a layer whose valid first Monday round was followed by one bad round was cancellable for a full refund while `fix` could still settle it, a direct breach of the rule "never cancel a layer that can still be fixed with a valid round".

Fix.
- `voidReference` gains a fourth proof, **bad answer**: `roundId` is the genuine round in effect at close (rules 2 to 4) and its answer is `<= 0` or above `uint64.max`, exactly what `setReference` rejects. That round is the only one `setReference` could ever take and round data is immutable, so the proof is permanent.
- New `voidFix(id, marketIdx, roundId)` (event `FixVoided`, mapping `fixVoid`, error `FixIsVoid`): permissionless, and passes only for the round `fix` would take (current phase, `updatedAt >= expiry`, predecessor strictly before expiry) when its answer is out of range. `_anyMarketFixable` returns false once any market is `fixVoid`, the same treatment as `referenceVoid`, so `cancel` then refunds the whole premium.
- `_isMarketDead` no longer reads the latest answer: a market is dead only when no round at or after the boundary exists in the current phase. An out-of-range answer is resolved by the void proofs, not by that heuristic.
- Exclusivity is structural: for one round the answer is either in range (`setReference` or `fix` succeeds, the void reverts) or out of range (the reverse). A valid fresh round is never voidable (`BadTiming` on the Friday side, `StillFixable` on the Monday side), so the rule "never cancel a layer that can still be fixed with a valid round" holds.

Evidence.

| Check | Result |
|---|---|
| First 9 new V-group tests on the previous `Treaty.sol` (e57731a) | 7 red (the other 2 pin behaviour that must not change): the Friday and Monday void-and-cancel tests could not void (`BadTiming`, no `voidFix`), both fuzzes failed, and `test_V2_validFirstMondayRound...` showed `cancel` succeeding (`next call did not revert as expected`) on a layer whose valid first round `fix` could still settle |
| Same tests on the fix | `V3ReviewTest` 20 passed, `Round6Test` 10 passed |
| Exclusivity fuzz | `testFuzz_V1_exactlyOneOfSetOrVoidByAnswer` and `testFuzz_V2_exactlyOneOfFixOrVoidFixByAnswer`, 256 runs each, answers drawn around both edges of the valid range (0, 1, `uint64.max`, `uint64.max + 1`) and anywhere, both call orders: exactly one of set/void (fix/voidFix) succeeds, the loser stays shut, the side is decided by `0 < answer <= uint64.max` |
| Mutants, one at a time in a scratch copy (`/tmp/hv3-mut`) | 9 of 9 killed: bad-answer disjunct removed (3 red), `> uint64.max` half dropped (1 red), `voidFix` valid-answer guard deleted (1 red), first-round guard deleted (1 red), `fixVoid` ignored by `_anyMarketFixable` (3 red), latest-answer read restored in `_isMarketDead` (1 red), repeat-proof guard deleted (1 red), expiry guard deleted (1 red), phase guard deleted (1 red). Scratch `Treaty.sol` diffed byte-identical to the repo file after the last mutant, suites green |
| Full non-fork suite | 165 passed, 0 failed, 4 skipped (the fork files without `FORK_TESTS`), 30 suites |
| `FORK_TESTS=1 forge test --match-path 'test/*ork*.sol'` | 10 passed, 0 failed (4 suites) |

Blind spot. Every scenario uses `MockFeed`-style feeds with hand-set round data; no real Chainlink feed has published an out-of-range answer to replay. The `voidFix` search assumes `updatedAt` is monotonic across consecutive rounds of a phase, the same assumption `fix` and `setReference` already make.

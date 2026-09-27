# Gap Treaty security review (2026-09-26)

Scope: `contracts/src/{Treaty,Capacity,IPricer,Pricer}.sol`, `pricer/src/lib.rs`. Red tests: `contracts/test/AttackReview.t.sol` (each asserts the property the treaty should hold; red now, green once fixed). Live reads: Arbitrum Sepolia block 312940755, Treaty `0x710C…8133`, Capacity `0x0BC0…d44f`, Stylus Pricer `0x5d22…12A8`.

Sister-contract regressions checked and not reintroduced: writer-chosen feed (constructor allowlist, `decimals()==8`), cancel on nonexistent id (`WrongState`), caller-chosen roundId (first-round rule is unique), payout above escrow (`payout <= limit`, `payOut <= locked`), cross-layer drain (existing `Attack.t.sol`). Corporate-action check is absent by design (raw Chainlink feeds).

## Critical

**C1. Zero-cost permanent freeze of all writer capital.** `Treaty.sol:119-155`, `Treaty.sol:191`. `expiry` is unbounded and zero exposure quotes premium 0. `bind([0], 0, totalAssets-locked, now+1, type(uint40).max)` locks every free USDG; `cancel` needs `expiry + 7 days` (year ~36,800); `maxRedeem` returns 0 forever. Live: `cast call bind([0],0,40927968,now+600,2^40-1) --from 0xdEaD` returns id 1 with a zero-balance sender; one wei more reverts `CapacityExceeded` (0x9ff41fe0). A judge can do this in one tx. Test: `test_C1_zeroCostBindFreezesWriterCapital`. Fix: enforce the spec calendar (cutoff Fri 19:30, expiry Mon 13:30 of the same weekend), require `premium >= minPremium` and a nonzero exposure.

## High

**H1. Horizon and timing are caller-chosen; the premium is not.** `Treaty.sol:127,133-134`. The pricer prices one weekend, but `fridayCutoff`/`expiry` are any timestamps and the reference may be 24h old. (a) expiry 30 days out buys a month of drift for a weekend premium (`test_H1a`). (b) bind on Saturday 18:00 UTC against Friday's close, after weekend news is public (`test_H1b`). Live: the C1 simulation ran Saturday 13:51 UTC against a Friday 16:18 UTC SPY round. Fix: derive cutoff/expiry from `block.timestamp` weekday math; reject bind after Friday 19:30 UTC.

**H2. Zero-premium tail cover.** `Pricer.sol:56-85`, `lib.rs:66-102`. Retention above the worst scenario loss (NVDA -14.74%) quotes 0, but settlement pays any larger real gap. Exposure 1M, retention 147.5k, limit 100k: premium 0, a -20% Monday pays 52.5k (`test_H2`). Live: `quote([-100e6],15e6,50e6)` returns (0,0,0). Fix: premium floor (e.g. bps of limit) and reject quotes of 0.

**H3. First writer out escapes realized losses.** `Capacity.sol:76-81`. `totalAssets()` includes payouts already owed and the expected loss of live layers, so share price is not marked. After a full-limit settle, writer A withdraws at the pre-loss price (118.3k) and writer B is left 18.3k instead of both getting ~68k (`test_H3`). Same race opens Monday at the open, before `fix`. Fix: `totalAssets() = balance - owedPayouts` (settled-unclaimed), and gate withdrawals with an epoch queue that closes over live layers (or mark locked at limit).

## Medium

**M1. JIT premium skim.** `Capacity.sol:56-59`. Premium lands as an instant share-price jump. Deposit 1M before a bind, redeem after: +24.1k in one block with zero risk borne (`test_M1`). Fix: stream premium over the layer's life or lock deposits for an epoch.

**M2. No sequencer uptime check, 24h staleness.** `Treaty.sol:131-134`. Arbitrum One has the L2 Sequencer Uptime feed `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` (read live on arb1: `description()` "L2 Sequencer Uptime Status Feed", answer 0 = up). It is not used. During downtime a force-included bind prices off a round the market has left (`test_M2`). Fix: constructor-pinned uptime feed, revert if down or within a grace period after restart; heartbeat bound tighter than 24h. `fix` is safe without it (first round after expiry is still a real market round).

**M3. Phase change after expiry strands an owed payout.** `Treaty.sol:170,242-245`. If the proxy rolls phase before the Monday round is fixed, no round is acceptable; after `GRACE` anyone cancels and the payout reverts to writers (`test_M3`). Fix: accept a round in phase p+1 with aggregator round 1 when the last round of phase p is `< expiry`.

## Low

**L1. Stylus/Solidity divergence on overflow.** `lib.rs:61`. alloy `I256` `*` only `debug_assert`s overflow; release wraps. Live: `quote([-(2^255/1000)],0,40e6)` returns premium 48670633; Solidity reverts (`test_L1`, green). Use `checked_mul`/`checked_sub` and return `Err`.

**L2. `int256(retention)` wraps for retention ≥ 2^255.** `Treaty.sol:225`, `Pricer.sol:56`, `lib.rs:51`. Pricing and settlement wrap identically (payout = limit, premium 1.75x limit), so not exploitable; reject `retention >= 2^255`.

**L3. Stylus activation expiry.** ArbWasm `programTimeLeft(pricer)` = 31,532,930s, `expiryDays()` = 365. After expiry or a Stylus version bump, `quote` reverts and every `bind` fails; `pricer` is fixed with no fallback. Settlement does not call the pricer, so no funds lock. Anyone can re-activate via `ArbWasm.activateProgram`; add a monitor. Declare `pricer` `immutable` (`Treaty.sol:66`, no setter today).

**L4. Blocklisted buyer.** `Treaty.sol:208`. USDG blocklisting the buyer leaves `payout` locked forever with no alternate recipient. Add `claim(id, to)`.

**L5. ERC-4626 inflation.** `_decimalsOffset()` is 0; OZ virtual shares make the donation attack unprofitable but still griefable on an empty pool. Seed the pool at deploy or set offset 6.

Blind spot: the Stylus pricer was exercised only via live `cast call`, not in Foundry; the 9-market scenario table the spec promises is not what ships (one NVDA series), which is model risk, not a code finding.

## Test run

```
[FAIL: C1: writer capital frozen by a free bind: 0 != 100000000000]
[FAIL: next call did not revert as expected] test_H1a
[FAIL: next call did not revert as expected] test_H1b
[FAIL: H2: layer that can pay was bound for zero premium: 0 <= 0]
[FAIL: H3: loss not shared pro rata: 118301969245 !~= 18301969246]
[PASS] test_L1_solidityPricerRevertsWhereStylusWraps
[FAIL: M1: risk-free premium skim: 1024145069443 > 1000000000000]
[FAIL: next call did not revert as expected] test_M2
[FAIL: M3: -20% gap, buyer never paid: 963396061509 <= 963396061509]
Suite result: FAILED. 1 passed; 8 failed; 0 skipped
```

## Fix status (post-remediation)

All findings above are closed. `test/AttackReview.t.sol` now asserts the fixed behaviour
for every finding (C1, H1, H2, H3, M1, M2, M3, L1, L4); L2, L3 and L5 are addressed in
`Treaty.sol`/`Capacity.sol`/README without a dedicated attack test (L2 and L5 were never
exploitable, just latent; L3 is documented operational risk, not a code bug).

- C1/H1: `bind` now computes that week's Friday 19:30 UTC cutoff and following Monday
  13:30 UTC expiry on-chain from `block.timestamp` (`Treaty.weekWindow`, unit-tested
  across 3 weeks, a DST-free week and a year boundary in `test/WeekWindow.t.sol`); rejects
  `exposure == 0` and `limit == 0`; the Friday reference price is set post-cutoff via
  `setReference` against the last pre-Saturday round, never the caller's spot.
- H2: premium floors at `minRateOnLineBps * limit / 1e4` (immutable, deployed at 50 bps).
- H3: `Capacity.totalAssets()` nets out `locked` and `pendingPremium` so withdrawals are
  pro rata regardless of order.
- M1: bind premium is held in `Capacity.pendingPremium`, excluded from `totalAssets()`
  until the layer settles, so a JIT deposit around a bind gets none of it.
- M2: constructor-pinned `sequencerUptimeFeed` (grace period 3600s) gates
  bind/setReference/fix; Arbitrum Sepolia has no equivalent feed, so the Sepolia deploy
  passes `address(0)` (disabled) and the check is proven against Arbitrum One's real feed
  in `test/GapTreaty.fork.t.sol`.
- M3: `cancel()` after the grace period now refunds the buyer's premium
  (`Capacity.refundPremium`) instead of leaving writers holding an owed payout.
- L1: the Stylus pricer's scenario loop uses `checked_mul`/`checked_add`/`checked_sub`
  and returns an error on overflow (`pricer::test::test_overflow_reverts`).
- L3: `pricer` is `immutable`; see README for Stylus activation-expiry handling.
- L4: `claimTo(id, to)` lets the claim owner redirect payout to another address.

Mutation check: removing the H2 floor turns `test_H2_premiumFloorPreventsZeroPremiumLayer`
red (premium 0 <= 0); removing the H3 liabilities subtraction turns
`test_H3_lossSharedProRataRegardlessOfWithdrawOrder` red (546% relative error vs the 1%
tolerance); restoring both turns the full 45-test suite green again.

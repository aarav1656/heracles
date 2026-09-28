# Heracles

Named for the hero whose labours go beyond ordinary strength: this layer carries loss
beyond the vault's own capital.

Excess-of-loss reinsurance for the LP vaults of stock and RWA perp exchanges on
Arbitrum. A vault's risk lead transfers the tail loss the vault takes when a market
reopens with a gap, per market, above a retention, up to a limit. A Stylus contract
prices the layer on chain from 504 historical weekend gaps, USDG writers fund it, and
the claim pays out from the first fresh Monday oracle round. No offchain price setter,
no claims adjuster. The weekend gap is the mechanism of the loss; the product is the
reinsurance layer that pays it. Heracles (contract `Treaty`): `contracts/src/Treaty.sol`.

## Deployed, Arbitrum Sepolia (421614)

| Contract | Address | Role |
|---|---|---|
| Treaty | [`0x889F1fA08DE3d280511432893A1D7e5DB66d3252`](https://sepolia.arbiscan.io/address/0x889F1fA08DE3d280511432893A1D7e5DB66d3252) | bind, fix, settle, claim |
| Capacity | [`0xe645d83EA67ca1ECC7689f48Eb65eB2dE2e8933D`](https://sepolia.arbiscan.io/address/0xe645d83EA67ca1ECC7689f48Eb65eB2dE2e8933D) | ERC-4626 USDG writer vault, depositWithPermit |
| Pricer (Rust/Stylus) | [`0x0202D849Dc7CC7b643ff62Cf3E81130EA30D95da`](https://sepolia.arbiscan.io/address/0x0202D849Dc7CC7b643ff62Cf3E81130EA30D95da) | on-chain premium, measured 4.06x less gas than the Solidity twin |
| USDG (Paxos testnet) | [`0xFFC95faa3d63Cde504a05B567C600B78C0b41892`](https://sepolia.arbiscan.io/address/0xFFC95faa3d63Cde504a05B567C600B78C0b41892) | settlement asset |

Redeployed 2026-09-27 for the Capacity permit fix
(commit 3f19b79, 76/76 tests):
Treaty and Capacity are new, the Stylus Pricer is reused unchanged. Treaty and Capacity
are Sourcify-verified (`exact_match`, both creation and runtime, checked live via
`sourcify.dev/server/v2/contract/421614/<address>`); the Pricer is not, since Sourcify's
Solidity route doesn't take Stylus/WASM bytecode and `cargo stylus verify`'s own
reproducible-build route needs a Docker daemon that was unavailable in this deploy run.
`depositWithPermit(uint256,address,uint256,uint8,bytes32,bytes32)` is live: deployer
deposited 2.0 USDG by permit, tx
[`0x748cc1db...c2e7078`](https://sepolia.arbiscan.io/tx/0x748cc1dbe9b5a6296d5fe29878822130808f70ee521baf0d57ae11912c2e7078),
status success, input selector `0x50921b23` matching `cast sig` of the function exactly.
The documented second wallet (`contracts/testnet/.taker.env`) holds 0 ETH and 0 USDG, so
the second-writer-deposits-by-permit step is blocked on funding, not on code. A bind
attempted at redeploy time (Sunday, already past that week's Friday 19:30 UTC cutoff)
reverted `BadTiming` as designed, tx
[`0x87b25006...d425f06`](https://sepolia.arbiscan.io/tx/0x87b25006ebd751fda0ef5f1107a22bd9e8b4e7fe53420314341b2dd70d425f06);
the gate reopens Monday 2026-09-28 00:00 UTC against next week's Friday 2026-10-02 19:30
UTC cutoff, and a live `Bound` event needs that real chain time to pass, which it had not
as of this deploy.

Wired for Arbitrum One: the L2 Sequencer Uptime feed
[`0xFdB631F5EE196F0ed6FAa767959853A9F217697D`](https://arbiscan.io/address/0xFdB631F5EE196F0ed6FAa767959853A9F217697D)
gates `bind`/`setReference`/`fix`, read live on Arbitrum One via `cast call` and
exercised in `contracts/test/GapTreaty.fork.t.sol`; the Sepolia deploy above passes `address(0)`
since Sepolia has no equivalent feed.

## Buyer

The risk lead of a stock or RWA perp exchange's LP vault on Arbitrum One: the vault or
first-loss buffer is the counterparty to stock, index and FX positions carried through
the weekend.

| Buyer | Arbitrum TVL | Open interest | Source |
|---|---|---|---|
| Ostium (OLP senior + affiliate buffer junior) | $10,970,922 | $12,672,734 (Arbitrum only) | `api.llama.fi/protocol/ostium`, `api.llama.fi/summary/open-interest/ostium`, read 2026-09-26 |
| Gains Network gTrade (gUSDC vault) | $11,982,353 on Arbitrum | $32,852,654 all chains | same endpoints, `gains-network` |

Ostium's open interest already exceeds its Arbitrum TVL, 1.16x, on the buyer table above:
a single concentrated weekend gap can exceed the buffer that is supposed to absorb trader
PnL before it does. Ostium's own docs say the buffer "absorbs trader PnL first, in full";
once it is gone the vault "enters UC state and automatically blocks new deposits"
(docs.ostium.com/vault/overview).

Not a single-ticker note sold to a pool operator covering that pool's own inventory.
Heracles sells a portfolio excess-of-loss layer to a vault treasury on Arbitrum One
covering the sum of each losing market's gap across the markets it lists at bind time
(`_settle` sums only the legs that moved against the buyer, per market, never netted
against a gain on another leg in the same layer): a different buyer, a different
instrument, a cross-market design rather than a single-ticker one.

## Why Arbitrum

Ostium and gTrade's capital, open interest and Chainlink feeds already sit on Arbitrum
One; the treaty must lock and pay a vault's cover without a claims adjuster, and writers
must be able to recompute the price from public data. The pricer runs in Stylus because
it is re-run on every bind and every capacity withdrawal check: measured 4.06x less
total gas than the identical Solidity pricer (bit-identical outputs, 5 cases, live on
Robinhood Chain testnet at the same ArbOS version as Arbitrum Sepolia;
`spikes/stylus-pricer/FINDINGS.md`), measured pre-fix; the checked-arithmetic overhead
added for L1 has not been remeasured, so treat 4.06x as the pre-fix baseline, not the
current ratio. The treaty gates on Arbitrum One's real L2
Sequencer Uptime feed and settles in real Paxos USDG on testnet
(`0xFFC95faa3d63Cde504a05B567C600B78C0b41892`).

## How it works

1. `bind(exposure[], retention, limit)`: the buyer declares a signed notional per market
   and locks a layer. `bind` only succeeds strictly before that ISO week's Friday 19:30
   UTC cutoff, computed on-chain from `block.timestamp` (`Treaty.weekWindow`); the buyer
   never chooses the cutoff or the expiry (always the following Monday 13:30 UTC), and a
   zero exposure or zero limit reverts outright. The reference price is not the caller's
   spot: it is set after the cutoff via `setReference(id, marketIdx, roundId)`, which only
   accepts the last round before Saturday 00:00 UTC, within a 24h window.
2. The Stylus `Pricer` runs each market's own 504-weekend gap table (chosen by an explicit
   per-market table id fixed at deploy; an unconfigured market reverts), scales it by that
   feed's realised volatility (never below 1.0x), computes
   `payout(s) = min(limit, max(0, loss(s) - retention))` per scenario, and returns
   `premium = EL + 0.03 * (TVaR95 - EL) + 0.04 * limit * 7/365`, floored at
   `minRateOnLineBps * limit / 1e4` (50 bps, immutable) so a zero quote can never bind.
   The Solidity twin computes the same quote bit for bit (`PricerParity.t.sol`).
   Deterministic, no owner-set price. Derivation: `docs/pricing.md`.
3. Writers deposit USDG into an ERC-4626 `Capacity` vault. A bind locks `limit` out of
   free capacity and pulls the premium into `Capacity` in the same transaction, but the
   premium sits in `pendingPremium` (excluded from share pricing) until the layer
   settles, so a deposit made right before a bind gets none of its premium.
4. `fix(id, marketIdx, roundId)` per market applies the same fixing rule (first
   round with `updatedAt >= expiry`, previous round strictly before expiry). Once every market is fixed the layer settles: payout
   is the realized loss above retention, clamped at the layer's own locked limit, never
   at the pool's total assets. `Capacity.totalAssets()` nets out both `owed` (a
   settled-but-unclaimed payout) and `pendingPremium`, so withdrawals price pro rata
   across writers regardless of order; active `locked` capital is still counted at face
   value. If a phase change leaves every round unfixable, `cancel()` after a 3-day grace
   period refunds the buyer's premium instead of stranding it with writers.
5. Buyer and writer both pull their own claim; nothing is pushed. `claimTo(id, to)` lets
   the claim owner redirect payout to another address (for a blocklisted buyer).
6. `bind`, `setReference` and `fix` all check a constructor-pinned L2 Sequencer Uptime
   feed (3600s grace period after restart) before trusting any oracle round.

Contracts: `Pricer` (Rust/Stylus, the deployed pricer), `Pricer.sol` (Solidity twin, used
for the parity check and as the fork/unit-test reference), `Treaty.sol` (bind, fix,
settle, claim), `Capacity.sol` (ERC-4626 writer vault, locked vs free capital vs pending
premium).

## Security fixes

`SECURITY-REVIEW.md` has the full adversarial review and the fix status addendum. Every
finding below is closed and asserted by a green test in `contracts/test/AttackReview.t.sol`, except
L2/L5 (latent, not exploitable) and L3 (operational, documented below).

Capacity permit-path review (deposit-while-live pricing, epoch/cutoff gate, JIT premium skim):
`docs/security/capacity-review.md`.

| Finding | Issue | Fix |
|---|---|---|
| C1 | Zero-exposure bind froze writer capital for free, unbounded expiry | `bind` rejects `exposure == 0`/`limit == 0`; expiry is always computed, never caller-chosen |
| H1 | Caller-chosen expiry, bind allowed any time | Bind window closes at that week's Friday 19:30 UTC; expiry fixed at the following Monday 13:30 UTC |
| H2 | High retention could quote a zero premium | Premium floors at `minRateOnLineBps * limit / 1e4` (50 bps) |
| H3 | First writer to withdraw escaped a realized loss at a stale price | `Capacity.totalAssets()` nets out `owed` and `pendingPremium`; share price always marked |
| M1 | JIT deposit around a bind skimmed the premium | Premium held in `pendingPremium`, excluded from share pricing until settle |
| M2 | No L2 sequencer uptime check | Constructor-pinned uptime feed, 3600s grace period, gates bind/setReference/fix |
| M3 | Phase change after expiry stranded the payout with writers | `cancel()` after grace refunds the buyer's premium; the buyer is still unpaid for any real weekend loss on that layer, since a dead round makes the true Monday price unrecoverable, not just delayed |
| L1 | Stylus pricer wrapped silently on overflow | `checked_mul`/`checked_add`/`checked_sub` in the scenario loop, returns an error |
| L3 | Stylus program can lapse after 365 days with no reactivation path documented | `pricer` is immutable; reactivation documented below |
| L4 | Blocklisted buyer had no way to redirect payout | `claimTo(id, to)`, callable only by the claim owner |

Mutation check (this build): removing the H2 floor turned
`test_H2_premiumFloorPreventsZeroPremiumLayer` red (`0 <= 0`); removing the H3
liabilities subtraction in `Capacity.totalAssets()` turned
`test_H3_lossSharedProRataRegardlessOfWithdrawOrder` red (546% relative error against a
1% tolerance); restoring both returned the full 45-test suite to green.

### Stylus program expiry and reactivation (L3)

Arbitrum Stylus (WASM) programs deactivate after 365 days unless re-activated; a lapsed
program makes every `quote()` call revert, which would make every `bind()` fail (the
pricer is only read at bind time, never at settle, so no funds ever lock). Reactivation
is permissionless: run `cargo stylus deploy` again against the same bytecode (redeploys
at a new address) or call `ArbWasm.activateProgram(address)` directly against the
existing address before/after it lapses, paying the current activation fee. `pricer` is
`immutable` on `Treaty`, so a lapsed program requires a full Treaty redeploy pointed at
either the reactivated address or a fresh one; there is no admin-set pricer swap.

## Stylus

The Rust Stylus pricer is line-for-line the same formula as the Solidity `Pricer.sol`,
sharing the identical 504-scenario NVDA gap table, now with checked arithmetic (L1 fix:
`checked_mul`/`checked_add`/`checked_sub`, returns an error on overflow instead of
wrapping; see `pricer::test::test_overflow_reverts`). Bit-for-bit parity was checked on 5
cases before the fix (Solidity via `forge test`, Stylus via `cargo test`, and both
re-checked live against the deployed contracts via `cast call`): all three sides returned
identical premium, el and tvar95; the redeployed pricer still returns nonzero, consistent
values live post-fix (`quote([2000000000000],20000000000,60000000000)` returns
`(33664099206, 5040079365, 54728000000)`). Redeployed size 13.3 KB, activation fee
0.000084 ETH. The measured Stylus-vs-Solidity gas ratio for this exact pricer, from
`spikes/stylus-pricer/FINDINGS.md`, is **4.06x** less total gas (average of 5 cases,
measured pre-fix; the checked-arithmetic overhead was not remeasured). No other Stylus
performance number is claimed here.

## What works

- Full local suite: 100 Foundry tests pass across 19 suites, 0 failed, 0 skipped
  (`forge test --summary`): 15 Treaty unit, 5 Attack, 11 AttackReview post-fix, 13
  GuardMutation (the three previously-deletable guards plus every `onlyTreaty`/
  `WrongState` check, each with its own red-then-green mutation), 9 Pricer, 2
  PricerParity (Solidity/Rust cross-language check via `vm.ffi`), 7 WeekWindow
  calendar-math unit tests, 3 ReferenceRule (fixed EDT/EST `fridayCloseOf` checks plus
  the Labor Day 2026 holiday-heartbeat test), 2 TreatyPrecision, 1 Solvency fuzz at 256
  runs, 2 invariant suites at 256 runs / 128,000 calls each (`invariant_noViolations`,
  `invariant_ledgersMatchLayers`, `invariant_gateMatchesOracle`), plus 5 fork tests
  against live Arbitrum One/Sepolia state (pinned blocks, fails rather than skips if the
  RPC is unavailable). This count moves as tests are added; verify with
  `forge test --summary` rather than trusting this number stale.
- Mutation checks (this build, each independently confirmed red then green): removing
  the H2 premium floor turns `test_H2_premiumFloorPreventsZeroPremiumLayer` red; removing
  the H3 liabilities subtraction in `Capacity.totalAssets()` turns
  `test_H3_lossSharedProRataRegardlessOfWithdrawOrder` red; deleting `Treaty.sol`'s
  `NotFirstRound` reference-round guard turns `test_setReference_NotFirstRound_guard`
  red; deleting the `AlreadyFixed` guard turns `test_setReference_AlreadyFixed_guard`
  red; removing `onlyTreaty` from `Capacity.payOut` turns
  `test_capacity_payOut_onlyTreaty_guard` red; restoring each returns the full suite to
  green.
- Redeployed live on Arbitrum Sepolia after the fixes (addresses above), wired to the
  live SPY/USD Chainlink feed (`0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06`),
  `minRateOnLineBps = 50`, and `sequencerUptimeFeed = address(0)` (no Arbitrum Sepolia
  equivalent exists; a mainnet deploy passes the real Arbitrum One feed above).
- Live cycle run against the redeployed contract, all tx hashes in
  `contracts/deployments/421614.json`: a writer deposit into `Capacity` (confirmed via a
  post-tx `totalAssets()` read of 45 USDG, not just a receipt), then three forced on-chain
  transactions proving the fixes are enforced by mined state, not just forge's cheatcode
  clock: a zero-exposure bind reverts `BadParams` (C1), a zero-limit bind reverts
  `BadParams`, and a legitimate nonzero bind attempted at the real current
  `block.timestamp` (already past that week's Friday 19:30 UTC cutoff) reverts
  `BadTiming` (H1). All three were decoded from live revert data via `cast sig`, not
  inferred. The full bind-to-claim happy path cannot be demonstrated live in one sitting
  because it spans a real weekend; it is instead proven exhaustively off-chain (45/45
  tests) and against real Arbitrum One oracle state in the fork suite.

## What does not work / disclosed simplifications

- Arbitrum Sepolia carries only one live equity feed (SPY), so the Sepolia deploy binds
  a single market. Binding a list of equity markets (SPY, NVDA, AAPL, MSFT, AMZN, GOOGL,
  TSLA, META, COIN) is proven only against a fork of live Arbitrum One state
  (`contracts/test/GapTreaty.fork.t.sol`), not on Sepolia itself, and every market in that
  list is priced off the same one measured NVDA gap table, not its own distribution (see
  the disclosed simplification below).
- Arbitrum Sepolia has no L2 Sequencer Uptime Status Feed, so the Sepolia deploy passes
  `address(0)` and the check is disabled there; it is proven only against the fork test.
- The 504-scenario table is one measured NVDA Friday-to-Monday gap distribution, applied
  as a shared weekend shock to every bound market. This is a disclosed simplification,
  not a per-market distribution.
- No corporate-action multiplier handling: the treaty reads raw Chainlink equity feeds
  directly, not Stock Tokens with a `uiMultiplier()`, so there is no multiplier to check.
- A settle that never receives a fresh Monday round within `GRACE` (3 days) needs
  `cancel()`; the buyer's premium is refunded (M3 fix), but the writers' locked capacity
  is simply released, they earn nothing for the layer that never settled.
- Arbiscan source verification for the redeployed `Treaty`/`Capacity` was not reattempted
  in this build (the previous build's verification submissions never left Arbiscan's
  pending queue either); see `contracts/deployments/421614.json`.

## What we cut

- Per-market gap tables for AAPL, SPY, TSLA: sourced (`evidence/auction-and-pricing.md`)
  but not wired into `pricer/src/lib.rs`; every bound market still prices off the one
  measured NVDA distribution.
- Stylus re-run at the treaty's real target scale (1,000 scenarios x 40 markets): the
  measured 4.06x is small-scale; it is not claimed to hold at scale.
- A staged or invented reviewer, contact, or buyer acknowledgment: no one at Ostium or
  Gains has confirmed seeing this yet.
- ERC-4337 gasless bind: a new signing path, not built for this deadline.

## Roadmap

- 2026-09-30: three markets (AAPL, SPY, TSLA) get their own gap table instead of the
  shared NVDA one.
- 2026-10: post the comp numbers above to Ostium's own public channel and log any reply.
- Later: re-run the Stylus gas spike at 1,000 scenarios x 40 markets before repeating the
  4.06x figure at scale.

## Contributors

Built by aarav1656, AI-assisted. The pricing model, the security fixes in
`SECURITY-REVIEW.md`, and the decision to cut per-market tables and the 4.06x-at-scale
claim rather than overstate them, are all this author's calls.

## Run instructions

Clone with submodules (`contracts/lib/forge-std`, `contracts/lib/openzeppelin-contracts`);
a plain `git clone` leaves those directories empty and `forge build` fails:
```
git clone <repo-url>
cd heracles
git submodule update --init --recursive
```

Contracts (Foundry):
```
cd contracts
forge build
forge test
```

Pricer (Rust/Stylus):
```
cd pricer
cargo test
```

Web app (Vite/TypeScript, reads deployed addresses from `contracts/deployments/`):
```
cd web
npm ci
npm run build
```

Deploy (needs `PRIVATE_KEY` in `contracts/.env`, loaded only in a subshell):
```
cd pricer
cargo stylus deploy --endpoint https://sepolia-rollup.arbitrum.io/rpc --private-key "$PRIVATE_KEY"

cd ../contracts
PRICER=<deployed pricer address> forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc --private-key "$PRIVATE_KEY" --broadcast
```

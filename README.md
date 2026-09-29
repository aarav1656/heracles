# Heracles

Named for the hero whose labours go beyond ordinary strength: this layer carries loss
beyond the vault's own capital.

Parametric excess-of-loss cover for the LP vaults of stock and RWA perp exchanges on
Arbitrum. A vault declares its position size per market; if a market opens Monday far
from Friday's close, Heracles works out the loss those positions would take from the
price feed and pays the slice of it above a retention, up to a limit. The payout comes
from the feed, not from the vault's own books. A Stylus contract prices the layer on
chain from 504 historical weekend gaps, USDG writers fund it, and settlement uses the
first fresh Monday oracle round. No offchain price setter, no claims adjuster. Heracles (contract `Treaty`): `contracts/src/Treaty.sol`.

Live app: https://heracles-virid-seven.vercel.app (reads the book below from the chain; screenshots of all three routes at 1440 and 390 px in `evidence/web-{book,bind,write}-{1440,390}.png`).

## Deployed, Arbitrum Sepolia (421614)

| Contract | Address | Role |
|---|---|---|
| Treaty | [`0xA5F3832DBa96e3f13a5B7a4C6179f2451681Ac27`](https://sepolia.arbiscan.io/address/0xA5F3832DBa96e3f13a5B7a4C6179f2451681Ac27) | bind, fix, settle, claim |
| Capacity | [`0x9f4dA127f5CA9Ad4b7F4e55BFF0909745DCF6159`](https://sepolia.arbiscan.io/address/0x9f4dA127f5CA9Ad4b7F4e55BFF0909745DCF6159) | ERC-4626 USDG writer vault, depositWithPermit, created by the Treaty constructor |
| Pricer (Rust/Stylus) | [`0xbe99217180a5fcb83372375b0928c971dfa71f88`](https://sepolia.arbiscan.io/address/0xbe99217180a5fcb83372375b0928c971dfa71f88) | on-chain premium, measured 8.01x less L2 execution gas than the Solidity twin |
| USDG (Paxos testnet) | [`0xFFC95faa3d63Cde504a05B567C600B78C0b41892`](https://sepolia.arbiscan.io/address/0xFFC95faa3d63Cde504a05B567C600B78C0b41892) | settlement asset |

Redeployed 2026-09-28: Treaty and Capacity share one deploy tx
([`0x7eb7e54a...9369d46d61`](https://sepolia.arbiscan.io/tx/0x7eb7e54ab75b662a0025074f637dad40125960a1bca4abf0bcc0259369d46d61),
block 313,869,456, status success), and the Stylus Pricer above is a fresh deploy too, tx
[`0x01a37192...b4ee945e7d`](https://sepolia.arbiscan.io/tx/0x01a37192c882dc7f856baf81bbee70679267b983723ca20e7b9460b4ee945e7d),
block 313,689,917: 25,765 bytes compressed, deployed as two fragments behind a 48-byte
root contract, constructed with table id `[2]` (SPY). Treaty and Capacity are
Sourcify-verified (`exact_match`, both creation and runtime, matchId 53809711 and
53809724, checked live via `sourcify.dev/server/v2/contract/421614/<address>`) and
Blockscout-verified (`is_verified: true`, checked live via
`arbitrum-sepolia.blockscout.com/api/v2/smart-contracts/<address>`):
[Treaty on Blockscout](https://arbitrum-sepolia.blockscout.com/address/0xA5F3832DBa96e3f13a5B7a4C6179f2451681Ac27?tab=contract),
[Capacity on Blockscout](https://arbitrum-sepolia.blockscout.com/address/0x9f4dA127f5CA9Ad4b7F4e55BFF0909745DCF6159?tab=contract).
The Pricer is verified on neither, since Sourcify's Solidity route and Blockscout's
verifier both take EVM bytecode, not Stylus/WASM, and `cargo stylus verify`'s own
reproducible-build route needs a Docker daemon that was unavailable in this deploy run.

Every wiring read on the new Treaty checks out live: `pricer()` and `capacity()` point at
the two addresses above, `usdg()` points at the Paxos USDG address, and
`minRateOnLineBps()` reads 50. The Pricer itself reads back its one configured market:
`tableIdAt(0)` returns `2` (SPY), `tableIdAt(1)` reverts `MissingTable`. A live quote at
block 313,690,038, long 2,000,000 USDG of SPY with a 20,000 USDG retention and a 60,000
USDG limit, against the live SPY/USD feed
[`0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06`](https://sepolia.arbiscan.io/address/0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06)
at round id `18446744073709553978` (the Chainlink phase id sits in the upper bits of that
round, the same input shape that used to panic the earlier pricer): premium 1,676.722158
USDG, EL 1,051.190476 USDG, TVaR95 20,368 USDG.

Deposit and bind are still pending on this deployment: the owner wallet holds 0 USDG,
since the Paxos testnet faucet has not delivered to it yet.

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

## Why would a vault buy this

Ostium and Gains Network gTrade are named above as prospects on the strength of their
public TVL/OI numbers, not as users: neither has signed, deposited, or otherwise
confirmed intent to buy this cover, and that gap is tracked as an open risk, not implied
away.

**What they use today, and why it does not close the gap:**

- **Ostium's own affiliate buffer capital** absorbs trader PnL first, but it is sized off
  the pool's own capital, not off a weekend-gap distribution; once the buffer is spent the
  vault "enters UC state and automatically blocks new deposits"
  (docs.ostium.com/vault/overview). It is the same capital taking every other risk the
  pool already carries, not capital set aside specifically for the Friday-to-Monday gap.
- **An offchain hedge reconciled against a broker** (the pattern Ostium already runs with
  Jump Trading, docs.ostium.com) needs a signed counterparty, a settlement process outside
  the chain, and trust that the reconciliation actually happens; nothing about it is
  verifiable from on-chain state the way a Chainlink round id and a `Settled` event are.
- **Reopening the position in CME equity-index futures (ES/NQ) Sunday evening** only
  exists for broad indices, trades on a different clock (CME's own Sunday 6pm ET open, not
  the underlying stock's Monday 9:30am ET open), and does not exist at all for a
  single-name gap (NVDA, AAPL, TSLA): an index future cannot hedge one ticker's
  idiosyncratic weekend move.
- **Listed single-stock options** close at Friday's regular session close along with the
  underlying, so they cannot be bought or sold to cover a gap that has not happened yet
  without already being held going into the weekend, and CBOE has no standing
  Saturday/Sunday session to trade them in.

None of these four is a defined-risk, on-chain, permissionlessly-priced weekend put; all
of them either need a standing relationship, cover only part of the exposure, or use
capital that is also on the hook for every other risk the pool runs. That is the gap
Heracles is a candidate for filling, contingent on Ostium or Gains actually wanting to buy
it (unconfirmed, tracked as this submission's kill shot).

**Honest cost, recomputed from this repo's own data, not restated from memory:**

```
$ python3 -c "
gaps = [int(x) for x in open('evidence/gap-tables/SPY.gaps.txt').read().strip().split(',')]
exposure, retention, limit = 2_000_000_000_000, 20_000_000_000, 60_000_000_000
payouts = [min(limit, max(0, max(0, exposure*(-b)//10000) - retention)) for b in gaps]
print(sum(1 for p in payouts if p > 0), '/', len(gaps), 'weekends pay')
el = sum(payouts)/len(payouts)
tvar95 = sum(sorted(payouts, reverse=True)[:25])/25
premium = el + 30_000*(tvar95-el)/1e6 + 40_000*limit*7/(365*1e6)
print('premium', premium/1e6, 'USDG =', premium/limit*100, '% of limit')
"
36 / 504 weekends pay
premium 1676.7221591650357 USDG = 2.794536931941726 % of limit
```

For a long 2,000,000 USDG SPY position with a 20,000 USDG retention and a 60,000 USDG
limit (the same parameters as the live quote above), the headline layer pays out on 36 of
the 504 ten-year historical Friday-to-Monday weekends in the SPY table (7.1% of
weekends), and its risk-neutral-plus-load premium is 2.79% of the limit per weekend
bound, matching the live on-chain quote (1,676.722158 USDG) to the last cent. This is not
a small number restated as a rounding error: a vault buying this cover every week for a
year pays roughly 145% of the limit in premium (52 x 2.79%) against a 7.1% chance of
collecting per week, which only makes sense priced against the tail it is not willing to
carry itself, not as a routine weekly expense.

**Who is already eating this gap today, unhedged:**

- **Aave started lending USDC against seven tokenized stocks (NVDA and AMZN among them)
  on 2026-09-25, capped at $21M. The price feeds hold Friday's close until 8pm Sunday ET
  while loans keep running, so the tokens trade all weekend on a frozen price and USDC
  lenders eat the Monday gap.**
  (@MoneyNomads1, 2026-09-28, https://x.com/MoneyNomads1/status/2104630009302290492) This
  is a major lending protocol now structurally exposed to exactly the gap this treaty
  prices, with a real cap already hit, not a hypothetical.
- **"Billion-dollar-plus days in Stock Token volume, 72% of it on weekends."** (Johann
  Kerbrat, SVP & GM Crypto and International, Robinhood, 2026-09-26,
  https://x.com/JohannKerbrat/status/2103874953053622694) The weekend is not the tail case
  for this asset class, it is the majority of flow.

## Why Arbitrum

Ostium and gTrade's capital, open interest and Chainlink feeds already sit on Arbitrum
One; the treaty must lock and pay a vault's cover without a claims adjuster, and writers
must be able to recompute the price from public data. The pricer runs in Stylus because
it is re-run on every bind and every capacity withdrawal check: measured 8.01x less L2
execution gas than the Solidity twin (7.93x less total gas), read live at block
313,704,736 via NodeInterface's `gasEstimateComponents` against a Solidity twin deployed
at [`0x6aAf1b58939d55d1142a34aE02903bB788E9e771`](https://sepolia.arbiscan.io/address/0x6aAf1b58939d55d1142a34aE02903bB788E9e771)
for this comparison only (`script/DeployPricerTwin.s.sol`): Stylus 584,865 total gas /
578,444 L2 execution gas, Solidity 4,639,494 total / 4,632,865 L2 execution, identical
outputs. That figure covers a single-market call; a multi-market call is not measured.
Full numbers in `docs/pricing.md` under "Gas". The treaty gates on Arbitrum One's real L2
Sequencer Uptime feed and settles in real Paxos USDG on testnet
(`0xFFC95faa3d63Cde504a05B567C600B78C0b41892`).

## How it works

1. `bind(exposure[], retention, limit)`: the buyer declares a signed notional per market
   and locks a layer. `bind` only succeeds strictly before that ISO week's Friday 19:30
   UTC cutoff, computed on-chain from `block.timestamp` (`Treaty.weekWindow`); the buyer
   never chooses the cutoff or the expiry (always the following Monday 13:30 UTC), and a
   zero exposure or zero limit reverts outright. The reference price is not the caller's
   spot: it is set via `setReference(id, marketIdx, roundId)`, which only accepts the first
   round at or after the Friday 4:00pm New York close, in the feed's current phase, landing
   within 36h of that close. If that first round is later, anyone can call `voidReference`
   with it as proof, and the layer can then only be cancelled, with the premium refunded.
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
   is the loss computed from the declared exposure and the feed's gap, above retention,
   clamped at the layer's own locked limit, never
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
1% tolerance); restoring both returned the full suite to green (`forge test --summary`:
122 tests, 23 suites, 0 failed, re-run 2026-09-29).

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
sharing the identical 504-scenario per-market gap tables, with checked arithmetic (L1 fix:
`checked_mul`/`checked_add`/`checked_sub`, returns an error on overflow instead of
wrapping; see `pricer::test::test_overflow_reverts`). The deployed pricer takes the
4-arg `quote(int256[],address[],uint256,uint256)` shape (the old 3-arg signature from an
earlier build now reverts on this deployment). Live call, block 313,858,503:

```
cast call 0xbe99217180a5fcb83372375b0928c971dfa71f88 \
  "quote(int256[],address[],uint256,uint256)(uint256,uint256,uint256)" \
  "[2000000000000]" "[0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06]" 20000000000 60000000000 \
  --rpc-url https://sepolia-rollup.arbitrum.io/rpc
-> premium 1,676.722158 USDG, EL 1,051.190476 USDG, TVaR95 20,368.000000 USDG
```

The Solidity twin at `0x6aAf1b58939d55d1142a34aE02903bB788E9e771` returns the identical
triple for the same call. The 2026-09-28 redeploy compresses to 25,765 bytes, split
across two fragments behind a 48-byte root contract, activation fee 0.000084 ETH. The
measured Stylus-vs-Solidity gas ratio for that deploy, read live via NodeInterface's
`gasEstimateComponents` at block 313,704,736, is **8.01x** less L2 execution gas (7.93x
less total gas, single-market call; see `docs/pricing.md` under "Gas"). No other Stylus
performance number is claimed here.

## What works

- Full local suite, 2026-09-29: 122 Foundry tests pass across 23 suites, 0 failed, 0
  skipped (includes `GapTreatyRealWeekendForkTest`, a full bind-reference-fix-claim
  lifecycle replayed against real Chainlink round data). This count moves as tests are
  added; verify with `forge test --summary` rather than trusting this number stale.
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
- No live cycle has run on this redeployment: `cast call Capacity totalAssets()` and
  `totalSupply()` both read 0 at block 313,858,431. The deployer wallet holds 0.044 ETH
  and 0 USDG (`cast balance` / `cast call USDG balanceOf`, same block); the Paxos testnet
  faucet has not delivered USDG to it. `contracts/deployments/421614.json` lists only the
  three deploy transactions, no deposit, bind, settle or claim hashes. See "Live testnet
  state" below for what blocks a deposit. The full bind -> setReference -> fix -> claim
  lifecycle is instead proven end to end on a pinned Arbitrum One fork against the real
  SPY/USD feed's actual recorded rounds for the real 2026-09-25/28 weekend, not a
  MockFeed: `contracts/test/GapTreaty.realweekend.fork.t.sol`, a real 0.50% Monday-below-
  Friday gap, 2,000,000 USDG exposure, 5,000 USDG retention, settles a 5,015.006303 USDG
  payout and `claim()` moves exactly that much of the real forked USDG token to the buyer.
  Mutation-checked (deleting `_settle`'s retention subtraction moves the asserted payout
  from 5,015.006303 to a wrong 10,015.006303 and the test goes red; restoring returns it
  to green); see `docs/e2e/heracles.md` for the full round-selection derivation and
  command output.

## Scope of this deployment

- The Sepolia deploy binds SPY, the one live equity feed Arbitrum Sepolia carries. NVDA,
  AAPL, SPY and TSLA each price on their own 504-weekend gap table, and a four-market layer
  is exercised end to end against live Arbitrum One oracle state in
  `contracts/test/GapTreaty.fork.t.sol`.
- The L2 Sequencer Uptime check is wired for Arbitrum One's feed
  (`0xFdB631F5EE196F0ed6FAa767959853A9F217697D`); the Sepolia deploy passes `address(0)`
  because Sepolia has no such feed.
- The treaty reads raw Chainlink equity feeds, so settlement uses the feed price directly.
- A layer whose Monday round never arrives within `GRACE` (3 days) of expiry can be
  cancelled: the buyer's premium is refunded in full and the writers' capital is released.
- Treaty and Capacity are source-verified on Sourcify (exact match, creation and runtime).

## Contributors

Built by aarav1656. The pricing model, the security fixes in
`SECURITY-REVIEW.md`, and the decision to state the 8.01x gas figure only for the
single-market call it was measured on, are all this author's calls.

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

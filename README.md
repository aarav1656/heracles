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

Live app: https://heracles-virid-seven.vercel.app (reads the book below from the chain; screenshots of the book, bind and write routes at 1440 and 390 px in `evidence/web-{book,bind,write}-{1440,390}.png`, and of `/replay` and `/quote` at 1440 px in `evidence/web-{replay,quote}-1440.png`).

## Deployed, Arbitrum Sepolia (421614)

| Contract | Address | Role |
|---|---|---|
| Treaty | [`0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807`](https://sepolia.arbiscan.io/address/0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807) | bind, setReference, voidReference, fix, voidFix, cancel, claim |
| USDG first-loss vault | [`0x80b50d73b87BE3ac7Cd0F2DF35bE74033f8E4cF3`](https://sepolia.arbiscan.io/address/0x80b50d73b87BE3ac7Cd0F2DF35bE74033f8E4cF3) | ERC-4626, takes the first 30% of every USDG layer |
| USDG senior vault | [`0x05DD502aa5ca21f97c0536e4164D609B38A632Bc`](https://sepolia.arbiscan.io/address/0x05DD502aa5ca21f97c0536e4164D609B38A632Bc) | ERC-4626, takes the other 70% |
| USDC first-loss vault | [`0xb293E54AffE056708FCc54D0D1d16A7B7aD1FebB`](https://sepolia.arbiscan.io/address/0xb293E54AffE056708FCc54D0D1d16A7B7aD1FebB) | ERC-4626, takes the first 30% of every USDC layer |
| USDC senior vault | [`0x510e4266C55a58879d3a77eC02e77CCF1602cA39`](https://sepolia.arbiscan.io/address/0x510e4266C55a58879d3a77eC02e77CCF1602cA39) | ERC-4626, takes the other 70% |
| Pricer (Rust/Stylus) | [`0xbe99217180a5fcb83372375b0928c971dfa71f88`](https://sepolia.arbiscan.io/address/0xbe99217180a5fcb83372375b0928c971dfa71f88) | on-chain premium, measured 8.01x less L2 execution gas than the Solidity twin |
| USDG (Paxos testnet) | [`0xFFC95faa3d63Cde504a05B567C600B78C0b41892`](https://sepolia.arbiscan.io/address/0xFFC95faa3d63Cde504a05B567C600B78C0b41892) | settlement asset of the USDG book |
| USDC (Circle testnet) | [`0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d`](https://sepolia.arbiscan.io/address/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d) | settlement asset of the USDC book |

The Treaty and its four vaults share one deploy tx,
[`0xe2402635...2b02c9b`](https://sepolia.arbiscan.io/tx/0xe24026352f7ba9c7073952c764f756f6ebc7641533b6140543fc777ef2b02c9b),
block 314,558,549, status success (2026-10-01). The Stylus Pricer is the 2026-09-28
deploy, tx
[`0x01a37192...b4ee945e7d`](https://sepolia.arbiscan.io/tx/0x01a37192c882dc7f856baf81bbee70679267b983723ca20e7b9460b4ee945e7d),
block 313,689,917: 25,765 bytes compressed, deployed as two fragments behind a 48-byte
root contract, constructed with table id `[2]` (SPY). The Treaty and all four vaults are
Sourcify-verified (`exact_match`, both creation and runtime, matchIds 54461151, 54461173,
54461177, 54461178 and 54461180, checked live via
`sourcify.dev/server/v2/contract/421614/<address>`).

Every wiring read on the Treaty checks out live: `pricer()` points at the Pricer above,
`firstLossVault(i)` and `seniorVault(i)` return the four vaults for book 0 (USDG) and book 1
(USDC), `markets(0)` is the SPY/USD feed, `juniorShareBps()` reads 3000 and
`minRateOnLineBps()` reads 50. The Pricer itself reads back its one configured market:
`tableIdAt(0)` returns `2` (SPY), `tableIdAt(1)` reverts `MissingTable`.

Live cycle on the USDC book (2026-10-01): a writer deposited 4.5 USDC into the first-loss vault
and 10.5 USDC into the senior vault, and layer 0 bound against the book, long 200 USDC of
SPY with retention 2 and limit 10 USDC (3 locked in the first-loss vault, 7 in the senior
vault) for a 0.195737 USDC premium, bind tx
[`0x770752c7...3b85b70`](https://sepolia.arbiscan.io/tx/0x770752c7522caf31ce5d493693e48f8bed71726607be0351b835669eb3b85b70).
The Friday reference opens Fri 2026-10-02 20:00 UTC and the Monday fix Mon 2026-10-05
13:30 UTC.

A live quote at
block 313,690,038, long 2,000,000 USDG of SPY with a 20,000 USDG retention and a 60,000
USDG limit, against the live SPY/USD feed
[`0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06`](https://sepolia.arbiscan.io/address/0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06)
at round id `18446744073709553978` (the Chainlink phase id sits in the upper bits of that
round, the same input shape that used to panic the earlier pricer): premium 1,676.722158
USDG, EL 1,051.190476 USDG, TVaR95 20,368 USDG.

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

Ostium and Gains Network gTrade are the named buyers, sized from their public TVL and
open-interest numbers above.

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
  the underlying stock's Monday 9:30am ET open), and covers no
  single-name gap (NVDA, AAPL, TSLA), because an index future cannot hedge one ticker's
  idiosyncratic weekend move.
- **Listed single-stock options** close at Friday's regular session close along with the
  underlying, so they cannot be bought or sold to cover a gap that has not happened yet
  without already being held going into the weekend, and CBOE has no standing
  Saturday/Sunday session to trade them in.

None of these four is a defined-risk, on-chain, permissionlessly-priced weekend put; all
of them either need a standing relationship, cover only part of the exposure, or use
capital that is also on the hook for every other risk the pool runs. That is the gap
Heracles fills.

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
bound, matching the live on-chain quote (1,676.722158 USDG) to the last cent. Against the
2,000,000 USDG position it covers, that is 8.38 bps of notional for one weekend.

**Who is already eating this gap today, unhedged:**

- **Aave started lending USDC against seven tokenized stocks (NVDA and AMZN among them)
  on 2026-09-25, capped at $21M. The price feeds hold Friday's close until 8pm Sunday ET
  while loans keep running, so the tokens trade all weekend on a frozen price and USDC
  lenders eat the Monday gap.**
  (@MoneyNomads1, 2026-09-28, https://x.com/MoneyNomads1/status/2104630009302290492) This
  is a major lending protocol structurally exposed to the same gap this treaty prices.
- **"Billion-dollar-plus days in Stock Token volume, 72% of it on weekends."** (Johann
  Kerbrat, SVP & GM Crypto and International, Robinhood, 2026-09-26,
  https://x.com/JohannKerbrat/status/2103874953053622694) The weekend is not the tail case
  for this asset class, it is the majority of flow.

## Replay and quote

`/replay` runs the weekend of Friday 25 September 2026 through the Treaty's layer math. The
vault is Ostium's LP vault, the other side of every trader. Open interest on SPX, NVDA, TSLA
and AAPL is read from TradingStorage at Arbitrum One block 508,866,731 (Friday 20:00:00 UTC),
each side valued at Ostium's last trade before the close. The Chainlink round in effect at the
close and the first round at or after Monday's 13:30 UTC open give the gap per name: SPY
-0.16%, NVDA +2.13%, TSLA -0.73%, AAPL +0.51%. The vault is long 817,560 of SPX and short
448,555 NVDA, 7,456 TSLA and 1,630 AAPL, so it loses 1,340.02 on SPX, 9,562.15 on NVDA and
8.24 on AAPL, 10,910.41 in all (the TSLA gain is not netted, as in `Treaty._settle`). A layer
with a 3,000 retention and a 20,000 limit pays 7,910.41: 6,000.00 from the first-loss
tranche, which pays in full, and 1,910.41 from the senior tranche. The Stylus pricer quotes
3,025.37 for that layer (expected payout 2,612.35, TVaR95 15,868.18) at Arbitrum Sepolia
block 314,660,728, and the native build of the same `pricer_core` returns the identical
triple. `scripts/replay_weekend.py` regenerates `web/src/data/replay.json` from the chain,
and `web/src/lib/replay.test.ts` recomputes the result from the stored rounds.

`/quote` takes a vault's net weekend exposure on the four names the pricer holds tables
for, prefilled from Ostium's live open interest (the same read as
`evidence/gap-tables/ostium-oi-by-group.json`, repeated in the browser, with a Refresh
button), plus a retention and a limit. It calls the deployed Stylus pricer for the premium,
the expected payout and TVaR95, quotes the first-loss slice of the limit separately for the
tranche split, and builds a plain-text `mailto:` quote that makes no network call.

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
outputs. Full numbers in `docs/pricing.md` under "Gas". The treaty gates on Arbitrum One's real L2
Sequencer Uptime feed and settles in real Paxos USDG on testnet
(`0xFFC95faa3d63Cde504a05B567C600B78C0b41892`).

### Why Stylus: gas of one `quote()` call at 1, 4 and 8 markets

Same call, same inputs, same block, both contracts live on Arbitrum Sepolia (the Stylus
pricer above and its Solidity twin). Arbitrum Sepolia block 314,661,533, `eth_estimateGas`;
L2 execution gas is the estimate less NodeInterface `gasEstimateL1Component` for the same
calldata. The two implementations return identical premium, expected loss and TVaR95 at
every size (asserted by the script).

| Markets | Stylus L2 gas | Solidity L2 gas | Gas saved | Ratio, L2 execution | Ratio, total gas |
|---|---|---|---|---|---|
| 1 | 578,996 | 4,633,423 | 4,054,427 | 8.00x | 7.95x |
| 4 | 1,283,484 | 6,941,890 | 5,658,406 | 5.41x | 5.39x |
| 8 | 2,214,375 | 9,497,423 | 7,283,048 | 4.29x | 4.28x |

Method: each contract is configured with one market on chain, so the per-market table
ids are set inside the call with an `eth_estimateGas` state override of the contract's own
table-id storage (Stylus slot 0, twin slot 252). The table ids are SPY, NVDA, AAPL, TSLA,
repeated for eight markets. Every market reads its own distinct Chainlink feed (SPY/USD,
LINK/USD, DAI/USD, ARB/USD, UNI/USD, AVAX/USD, LTC/USD, BNB/USD on Arbitrum Sepolia), and
both contracts walk the same eight rounds of each. The one-market row reproduces the earlier single-market figure (8.01x at block
313,704,736). Without the override the same call reverts `MissingTable` on both contracts,
which the script also asserts. Reproduce: `python3 scripts/measure_pricer_gas.py`; the raw
reads are in `evidence/gas/pricer-multimarket.json`.

## How it works

1. `bind(book, exposure[], retention, limit, maxPremium)`: the buyer picks a book (one
   settlement asset and its pair of vaults), declares a signed notional per market and
   locks a layer. `bind` only succeeds strictly before Thursday 19:30 UTC of that ISO week
   (the Friday 19:30 UTC anchor less `BIND_LEAD`, one day, computed on-chain from
   `block.timestamp` by `Treaty.weekWindow`), so the round that will be in effect at
   Friday's close has not printed when a layer binds. The buyer never chooses the cutoff
   or the expiry (always the following Monday 9:30am New York open, 13:30 UTC in summer
   and 14:30 UTC in winter), and a zero exposure or zero limit reverts outright.
   `maxPremium` is the buyer's own ceiling: if a feed round lands before the transaction
   and lifts the premium above it, `bind` reverts `PremiumTooHigh` instead of charging
   more than was quoted. The reference price is not the caller's spot:
   `setReference(id, marketIdx, roundId)` accepts only the round in effect at Friday's
   4:00pm New York close, in the feed's current phase, printed after the bind deadline and
   no more than 26h before the close. When a market's in-effect round can never serve as
   that reference (stale, in a superseded phase, already visible at bind, or carrying an
   out-of-range answer), anyone proves it with `voidReference`; when the first Monday
   round is out of range, anyone proves it with `voidFix`. Each proof is mutually
   exclusive with the call it replaces, and the layer then cancels with the premium
   refunded in full.
2. The Stylus `Pricer` runs each market's own 504-weekend gap table (chosen by an explicit
   per-market table id fixed at deploy; an unconfigured market reverts), scales it by that
   feed's realised volatility (never below 1.0x), computes
   `payout(s) = min(limit, max(0, loss(s) - retention))` per scenario, and returns
   `premium = EL + 0.03 * (TVaR95 - EL) + 0.04 * limit * 7/365`, floored at
   `minRateOnLineBps * limit / 1e4` (50 bps, immutable) so a zero quote can never bind.
   The Solidity twin computes the same quote bit for bit (`PricerParity.t.sol`).
   Deterministic, no owner-set price. Derivation: `docs/pricing.md`.
3. Writers deposit into one of a book's two ERC-4626 `Capacity` vaults: the first-loss
   vault, which absorbs the first `juniorShareBps` of every layer's limit (fixed at
   deploy), or the senior vault, which absorbs the rest. A bind locks each slice out of its
   own vault's free capital. The buyer approves the Treaty, which pulls the premium in and
   hands each vault its share; the share sits in `pendingPremium` (excluded from share
   pricing) until the layer settles, so a deposit made right before a bind gets none of its
   premium.
4. `fix(id, marketIdx, roundId)` per market takes the first round with
   `updatedAt >= expiry` whose predecessor is strictly before expiry. Once every market is
   fixed the layer settles: payout is the loss computed from the declared exposure and the
   feed's gap, above retention, clamped at the layer's own locked limit, never at the
   pool's total assets; the first-loss vault pays the first slice and the senior vault the
   rest. `Capacity.totalAssets()` nets out both `owed` (a settled-but-unclaimed payout) and
   `pendingPremium`, so withdrawals price pro rata across writers regardless of order;
   active `locked` capital is still counted at face value. A layer with no path left to
   settle (a dead feed, a phase change that strands every round, or a round proven
   unusable by `voidReference` or `voidFix`) is cancelled by anyone from three days after
   expiry, which refunds the buyer's premium and unlocks both vaults. A layer that `fix`
   can still settle with a valid round is never cancellable, however long it waits.
5. Buyer and writer both pull their own claim; nothing is pushed, a cancelled layer's
   premium refund included. `claimTo(id, to)` lets the claim owner redirect the payout or
   refund to another address (for a blocklisted buyer).
6. `bind`, `setReference`, `fix` and `cancel` all check a constructor-pinned L2 Sequencer Uptime
   feed (3600s grace period after restart) before trusting any oracle round.

Contracts: `Pricer` (Rust/Stylus, the deployed pricer), `Pricer.sol` (Solidity twin, used
for the parity check and as the fork/unit-test reference), `Treaty.sol` (bind, fix,
settle, claim), `Capacity.sol` (ERC-4626 writer vault, locked vs free capital vs pending
premium).

## Security fixes

`docs/SECURITY.md` summarises eight adversarial review rounds. Every
finding below is closed and asserted by a green test in `contracts/test/AttackReview.t.sol`.

Capacity permit-path, per-cutoff gate and v3 review rounds: `docs/SECURITY.md`.

| Finding | Issue | Fix |
|---|---|---|
| C1 | Zero-exposure bind froze writer capital for free, unbounded expiry | `bind` rejects `exposure == 0`/`limit == 0`; expiry is always computed, never caller-chosen |
| H1 | Caller-chosen expiry, bind allowed any time | Bind window closes at that week's Thursday 19:30 UTC; expiry is always the following Monday 9:30am New York open |
| H2 | High retention could quote a zero premium | Premium floors at `minRateOnLineBps * limit / 1e4` (50 bps) |
| H3 | First writer to withdraw escaped a realized loss at a stale price | `Capacity.totalAssets()` nets out `owed` and `pendingPremium`; share price always marked |
| M1 | JIT deposit around a bind skimmed the premium | Premium held in `pendingPremium`, excluded from share pricing until settle |
| M2 | No L2 sequencer uptime check | Constructor-pinned uptime feed, 3600s grace period, gates bind/setReference/fix |
| M3 | Phase change after expiry stranded the payout with writers | `cancel()` after grace refunds the buyer's premium; the buyer is still unpaid for any real weekend loss on that layer, since a dead round makes the true Monday price unrecoverable, not just delayed |
| L1 | Stylus pricer wrapped silently on overflow | `checked_mul`/`checked_add`/`checked_sub` in the scenario loop, returns an error |
| L3 | Stylus program can lapse after 365 days with no reactivation path documented | `pricer` is immutable; reactivation documented below |
| L4 | Blocklisted buyer had no way to redirect payout | `claimTo(id, to)`, callable only by the claim owner |
| v3 H-1 | A buyer could read the round that would be the Friday reference before choosing exposure's sign | Bind closes Thursday 19:30 UTC; `setReference` refuses and `voidReference` voids any round at or before that deadline |
| v3 L-1 | A cancel after 30 days refunded a layer `fix` could still settle | `cancel` always checks that no market is fixable; past the 30-day backstop a market feed that reverts or has no round reads as dead, so it cannot block the check |
| v3 L-2 | A round landing between quote and bind could raise the premium | `bind(..., maxPremium)` reverts `PremiumTooHigh` above the buyer's ceiling |
| L6-3 | A feed round with an out-of-range answer left a layer neither fixable nor cancellable | `voidReference` (Friday side) and `voidFix` (Monday side) prove it, and `cancel` then refunds in full |

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
less total gas, single-market call; see `docs/pricing.md` under "Gas"). The four and
eight market measurements are in "Why Stylus" above.

## What works

- Full local suite, 2026-10-01: 170 Foundry tests pass across 30 suites, 0 failed; the
  fork files skip without `FORK_TESTS=1`, and with it all 10 fork tests pass (includes
  `GapTreatyRealWeekendForkTest`, a full bind-reference-fix-claim lifecycle replayed
  against real Chainlink round data). This count moves as tests are added; verify with
  `forge test --summary` rather than trusting this number stale.
- Void-proof mutation checks (this build, nine mutants, each killed): removing the
  bad-answer proof from `voidReference` turns `test_V1_badInEffectRoundVoidsAndCancelsWithFullRefund`
  red; removing `voidFix`'s valid-answer guard turns
  `test_V2_validFirstMondayRoundCannotBeVoidedAndLaterBadRoundDoesNotUnlockCancel` red;
  restoring each returns the suite to green.
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
- The full bind -> setReference -> fix -> claim
  lifecycle is proven end to end on a pinned Arbitrum One fork against the real
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
- A layer with no path left to settle can be cancelled by anyone from `GRACE` (3 days)
  after expiry: the buyer's premium is refunded in full through a pull claim and the
  writers' capital is released. Every such layer has a proof that reaches that state: a
  dead feed ages out, an unusable reference round is voided by `voidReference`, an unusable
  first Monday round by `voidFix`.
- The Treaty and its four vaults are source-verified on Sourcify (exact match, creation and runtime).

## Contributors

Built by aarav1656. The pricing model, the security fixes in
`docs/SECURITY.md`, and the decision to state every gas figure with the block, the
method and the number of markets it was measured on, are all this author's calls.

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

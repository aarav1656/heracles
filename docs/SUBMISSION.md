# Heracles

## Tagline

Parametric weekend-gap cover for stock and RWA perp LP vaults, priced on-chain

## Description

Heracles is parametric excess-of-loss cover for the LP vaults behind stock and RWA perpetual exchanges on Arbitrum. The payout is worked out from the price feed and the position size the vault declares, not from the vault's own books. A vault's risk lead locks a per-market exposure list against a retention and a limit, and the treaty pays out from the first fresh Chainlink round after Monday's open if the market gapped against the vault over the weekend. Writers fund the layer in USDG through an ERC-4626 capacity vault and earn the premium.

Named for the hero whose labours carried a weight beyond his own strength, Heracles carries the slice of a weekend gap beyond what a vault chooses to keep itself. Pricing runs on chain in a Rust Stylus contract, re-run at every bind against 504 historical weekend gaps. There is no offchain price setter and no claims adjuster: a bind, a locked Chainlink round, and a payout that either exists or does not.

## Problem

When a stock, index or FX perp gaps over the weekend, someone on the venue holds first loss. On gTrade it is the gUSDC vault: "Vaults serve as a counterparty to all trades made on the platform" (docs.gains.trade). At Arbitrum One block 511,007,816 that vault was long 153,309 USDC of SPY and short 23,665 of NVDA, 10,093 of gold and 3,000 of EUR/USD, against 4,569,046 USDC of `totalAssets()` (gTrade Diamond `getPairOiAfterV10Collateral` and `getPairOisBeforeV10Collateral` for USDC, collateral 3). On Ostium it is the junior buffer posted by "Ostium affiliates and strategic partners", which absorbs trader PnL "first, in full" while directional flow is hedged offchain (docs.ostium.com/vault/overview). Ostium's OLP "is not a counterparty to directional flow" (docs.ostium.com/protocol/how-ostium-works).

gTrade carries $7,464,963 of Arbitrum TVL against $2,394,444 of open interest, and Ostium $8,589,418 against $10,298,257 (`api.llama.fi/protocol/<name>`, `api.llama.fi/summary/open-interest/<name>`, read 2026-10-02). Neither the gUSDC vault nor the buffer has a third party standing behind its weekend gap today. Heracles is that party: a portfolio layer bought by the holder of first loss, priced on chain, paid by itself at the Monday round.

## How it works

A buyer calls `bind(book, exposure[], retention, limit, maxPremium)`: a book (one settlement asset and its pair of vaults), a signed notional per market, and a ceiling on the premium. The bind window closes strictly before that ISO week's Thursday 19:30 UTC, one day ahead of the Friday 19:30 UTC anchor and computed on chain from `block.timestamp`, so the round that will be in effect at Friday's close has not printed when a layer binds. The buyer never chooses the cutoff or the expiry, which is always the following Monday 9:30am New York open (13:30 UTC in summer, 14:30 UTC in winter); a zero exposure or zero limit reverts outright, and a premium above `maxPremium` reverts `PremiumTooHigh` instead of charging more than the buyer quoted.

The Stylus `Pricer` runs each market's own 504-scenario weekend gap table, scaled by that feed's realised volatility with a floor of 1.0x (the scale can only push a quote up from the static historical table, never below it), and prices the layer at

```
premium = EL + 0.03 * (TVaR95 - EL) + 0.04 * limit * 7/365
```

the expected loss across all 504 scenarios, plus 3% of the tail mass above it (the worst 5%, TVaR95), plus a capital charge of 4% annualised on the locked limit for the real seven-day lock. The quote floors at 50 basis points of the limit, so a zero premium can never bind. A Solidity twin computes the identical formula for a parity check; the deployed pricer runs the Rust version.

Once bound, the reference price for each market is not the caller's spot. It is set via `setReference(id, marketIdx, roundId)`, which only accepts the round in effect at the Friday 4:00pm New York close, printed after the bind deadline and no more than 26 hours before the close. When that round can never serve as the reference (stale, in a superseded Chainlink phase, already visible at bind, or carrying an out-of-range answer), anyone proves it with `voidReference`, and an out-of-range first Monday round is proven the same way with `voidFix`; each proof is mutually exclusive with the call it replaces, and the layer then cancels with the premium refunded in full. A layer that `fix` can still settle with a valid round is never cancellable.

Writers deposit USDG into one of a book's two ERC-4626 `Capacity` vaults: the first-loss vault takes the first slice of every layer's limit (`juniorShareBps`, fixed at deploy) and the senior vault takes the rest. A bind locks each slice out of its own vault's free capital. The buyer approves the Treaty, which pulls the premium in and hands each vault its share; the share sits in `pendingPremium`, excluded from share pricing, until the layer settles. `fix(id, marketIdx, roundId)` takes the first round with `updatedAt >= expiry` per market, and once every market is fixed the layer settles: payout is the loss computed from the declared exposure and the feed's gap, above retention, clamped at the layer's own locked limit, with the first-loss vault paying the first slice. Buyer and writer both pull their own claim rather than being pushed a payment, a cancelled layer's refund included, and `claimTo` lets the claim owner redirect it to another address.

A venue wires its LP vault in with two more contracts. `OIGuard` is called before the venue accepts a position: it prices weekend cover on the vault's book after the trade with the same Stylus pricer and reverts `PremiumOverBudget(premium, budget, currentPremium)` above the owner's budget, while any trade that lowers the premium passes. `VaultCover` holds the vault's book itself. `open` asks the guard first; `close` only moves a market toward zero and never calls the pricer, so a stalled pricer cannot stop a vault from cutting risk. Once a week a keeper's `renewCover` binds a Treaty layer on the book as it stands at a capped premium, and until that layer's Monday open each covered leg stays within the size and side it bound (`BeyondCover`). The deployed VaultCover carries gTrade's gUSDC book, read from Arbitrum One block 511,007,816 and opened leg by leg through the live guard; a further 2,000,000 NVDA short was refused on chain with `PremiumOverBudget(6,684.63, 4,000, 153.42)`. `heracles-sdk` (`sdk/`) wraps all of it in typed viem calls and a `heracles-quote` CLI that prints the live quote and the guard's verdict.

## What is novel

Nexus Mutual, Sherlock, InsurAce and Unslashed all run pooled capital against smart-contract or depeg risk, with a governance vote, an arbitration panel, or a community/oracle-assisted process standing between a loss and a payout. Heracles has none of that: settlement is a pure function of the next Chainlink round after Monday's open. Neptune Mutual and Risk Harbor already proved the general shape of oracle-triggered, adjuster-free payout, so "no adjuster" alone is not the differentiator. What none of them do is price the specific instrument here: a per-market weekend gap, recomputed on chain from public historical data at every bind, rather than an off-chain-set underwriting rate. Three contracts read that price on chain: the Treaty when it binds, the OIGuard before a venue takes open interest, and VaultCover when it renews the week's cover.

Re Protocol, Nayms (rebranded OnRe), and Ensuro sell tokenized access to real, regulated reinsurance treaties, institutional capital backing an off-chain insurer's book that gets reported back on chain. Heracles is parametric, not an indemnity treaty. It pays from the price gap a Chainlink feed shows on the positions a vault declared, so there is no loss to adjust and no policy administrator's ledger to trust. The risk and the settlement data live in the same place, on Arbitrum.

## Stack

Contracts in Solidity (Foundry), with the pricing core ported to Rust and deployed as a Stylus program on Arbitrum. The writer side is an ERC-4626 vault (`Capacity`) taking Paxos USDG deposits, including gasless deposit via `depositWithPermit`. `bind`, `setReference`, `fix` and `cancel` gate on Arbitrum's L2 Sequencer Uptime feed before trusting any oracle round. The web app is Vite and TypeScript, reading deployed addresses from `contracts/deployments/`.

## Security evidence

Heracles went through five recorded review rounds, each re-reading the diff against the last verdict rather than a single pass.

The first round (commit cb574a1) found a critical bug in the new permit deposit path: `Capacity.totalAssets()` marked every locked USDG at zero, so a deposit made while a layer was live bought the pool near zero and redeemed the honest writers' capital on settle, measured at 2,000 USDG in and 201,999.999799 USDG out against a 100,000 USDG writer position. The fix marks locked capital correctly in `totalAssets()` and was ported into `contracts/test/CapacityC1.t.sol`.

The next round (b71cf94) found that the fix's own epoch gate could be held shut indefinitely by an honest weekly-rolling buyer, let alone an attacker, since one small bind every Monday kept `locked` nonzero forever and blocked every writer exit. The following round (96309c8) found a dead-feed freeze and a just-in-time deposit that diluted the premium incumbent writers had already underwritten. Round four (8f492a4) found that the original 7-day grace period let `cancel` pre-empt a fix that was still recoverable inside the documented five-day holiday search window, and that an entrant depositing between bind and cutoff could lose its premium share on a cancel it did not cause.

The most recent round (2026-09-28) found that the Stylus pricer panicked on every real Chainlink proxy round id, since `roundId` is a `uint80` (`phaseId << 64 | aggregatorRoundId`) that does not fit in a `u64` once a feed has gone through more than one phase, and that market-to-table selection was positional rather than explicit, so a configured deploy could silently price a market off the wrong table. Both are fixed: round-id arithmetic now runs entirely in `U80`, verified against a live Arbitrum One SPY/USD round id read 2026-09-28, and table selection now takes an explicit constructor-supplied id array that reverts (`BadTableId`, `MissingTable`) rather than falling back to a default on any unmapped or misconfigured market.

Every closed finding is asserted by a named test in `contracts/test/AttackReview.t.sol` or the round's own test file, not just described. Two mutation checks in the current build confirm this the direct way: deleting the premium floor turns `test_H2_premiumFloorPreventsZeroPremiumLayer` red, and deleting the liabilities subtraction in `Capacity.totalAssets()` turns `test_H3_lossSharedProRataRegardlessOfWithdrawOrder` red at a 546% relative error against a 1% tolerance; restoring both returns the suite to green. Separate coverage includes a Solidity/Rust cross-language parity suite (`PricerParity.t.sol`, exact equality plus a bounded fuzz run up to $5M exposure), a guard-mutation suite pairing every `onlyTreaty`/`WrongState` check with its own red-then-green mutation, and two invariant suites run at 256 runs and 128,000 calls each. On 2026-10-02 the full suite passed 196 tests in 34 suites with 0 failures, and the 17 fork tests in 6 suites passed against live Arbitrum Sepolia, Arbitrum One and Robinhood Chain state. Mutation runners back the newest code: 18 of 18 mutants on the six-table pricer change (`scripts/mutate_six_tables.py`, both Solidity and Rust) and 10 of 10 on VaultCover are killed.

## Team

Built by aarav1656.

## Live app

https://heracles-virid-seven.vercel.app

- `/replay`: the weekend of 25 September 2026 run through the layer math. The side opposite Ostium's traders, whose PnL Ostium's junior buffer pays first, loses 10,910.41 on the gap, a 3,000 retention and 20,000 limit layer pays 7,910.41 (6,000.00 first-loss, 1,910.41 senior), and the Stylus pricer quotes 3,025.37 for it.
- `/quote`: a risk lead's net weekend exposure, prefilled from the gTrade gUSDC vault's live book on Arbitrum One, priced by the deployed Stylus pricer with the tranche split and a plain-text quote to send.
- `/sdk`: the OIGuard's verdict on a position of your choosing, the exact text `heracles-quote` prints for it, and the live VaultCover: its book, the covered leg, the guard premium against budget, `renewCover` simulated from the owner, and every open and close with its transaction.

## Deployed (Arbitrum Sepolia)

| Contract | Address |
|---|---|
| Treaty | [0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807](https://sepolia.arbiscan.io/address/0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807) (Sourcify exact match) |
| USDG first-loss vault | [0x80b50d73b87BE3ac7Cd0F2DF35bE74033f8E4cF3](https://sepolia.arbiscan.io/address/0x80b50d73b87BE3ac7Cd0F2DF35bE74033f8E4cF3) (Sourcify exact match) |
| USDG senior vault | [0x05DD502aa5ca21f97c0536e4164D609B38A632Bc](https://sepolia.arbiscan.io/address/0x05DD502aa5ca21f97c0536e4164D609B38A632Bc) (Sourcify exact match) |
| USDC first-loss vault | [0xb293E54AffE056708FCc54D0D1d16A7B7aD1FebB](https://sepolia.arbiscan.io/address/0xb293E54AffE056708FCc54D0D1d16A7B7aD1FebB) (Sourcify exact match) |
| USDC senior vault | [0x510e4266C55a58879d3a77eC02e77CCF1602cA39](https://sepolia.arbiscan.io/address/0x510e4266C55a58879d3a77eC02e77CCF1602cA39) (Sourcify exact match) |
| Pricer (Rust/Stylus) | [0xbe99217180a5fcb83372375b0928c971dfa71f88](https://sepolia.arbiscan.io/address/0xbe99217180a5fcb83372375b0928c971dfa71f88) |
| Six-table pricer (Rust/Stylus) | [0x1674ecf8d236a91c484c11fd11a21601837f7e37](https://sepolia.arbiscan.io/address/0x1674ecf8d236a91c484c11fd11a21601837f7e37) |
| OIGuard | [0x96BE263EfD057167E01a212BBd076904391217Ce](https://sepolia.arbiscan.io/address/0x96be263efd057167e01a212bbd076904391217ce#code) (Arbiscan verified) |
| VaultCover | [0xe6085fF7Bf0d37c0Cd865072cA5B434F2c228997](https://sepolia.arbiscan.io/address/0xe6085ff7bf0d37c0cd865072ca5b434f2c228997#code) (Arbiscan verified) |
| USDG (Paxos testnet) | [0xFFC95faa3d63Cde504a05B567C600B78C0b41892](https://sepolia.arbiscan.io/address/0xFFC95faa3d63Cde504a05B567C600B78C0b41892) |
| USDC (Circle testnet) | [0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d](https://sepolia.arbiscan.io/address/0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d) |

Deploy transactions: Treaty and the four vaults [0xe2402635...2b02c9b](https://sepolia.arbiscan.io/tx/0xe24026352f7ba9c7073952c764f756f6ebc7641533b6140543fc777ef2b02c9b), Pricer [0x01a37192...b4ee945e7d](https://sepolia.arbiscan.io/tx/0x01a37192c882dc7f856baf81bbee70679267b983723ca20e7b9460b4ee945e7d).

USDG book: 100 USDG from the Paxos testnet faucet went in through `depositWithPermit`, 30 USDG to the first-loss vault ([0x6f699bc2...d113f2035](https://sepolia.arbiscan.io/tx/0x6f699bc27e533d009c68d814dbef5a13c43813d663e2f050a1f7aa3d113f2035)) and 60 USDG to the senior vault ([0x5c31098e...42bcfd68d](https://sepolia.arbiscan.io/tx/0x5c31098eb61c9834c7f608c1562e63d1378d0f7221fac7ece78078b42bcfd68d)); 10 USDG is VaultCover's premium budget.

Live layer on the USDC book: bound 2026-10-01, long 200 USDC of SPY, retention 2, limit 10 USDC, premium 0.195737 USDC, bind tx [0x770752c7...3b85b70](https://sepolia.arbiscan.io/tx/0x770752c7522caf31ce5d493693e48f8bed71726607be0351b835669eb3b85b70). Friday reference opens 2026-10-02 20:00 UTC, Monday fix 2026-10-05 13:30 UTC.

A live quote from the deployed Stylus pricer at block 313,690,038, long 2,000,000 USDG of SPY with a 20,000 USDG retention and a 60,000 USDG limit: premium 1,676.722158 USDG. The same call on the Solidity twin returns identical numbers; across one, four and eight markets the Stylus pricer uses 8.00x, 5.41x and 4.29x less L2 execution gas (block 314,661,533, `python3 scripts/measure_pricer_gas.py`).

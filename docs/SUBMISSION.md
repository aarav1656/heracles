# Heracles

## Tagline

Excess-of-loss reinsurance for stock and RWA perp LP vaults, priced on-chain

## Description

Heracles is an excess-of-loss reinsurance layer for the LP vaults behind stock and RWA perpetual exchanges on Arbitrum. A vault's risk lead locks a per-market exposure list against a retention and a limit, and the treaty pays out from the first fresh Chainlink round after Monday's open if the market gapped against the vault over the weekend. Writers fund the layer in USDG through an ERC-4626 capacity vault and earn the premium.

Named for the hero whose labours carried a weight beyond his own strength, Heracles carries the loss beyond a vault's own capital, the tail past a first-loss buffer. Pricing runs on chain in a Rust Stylus contract, re-run at every bind against 504 historical weekend gaps. There is no offchain price setter and no claims adjuster: a bind, a locked Chainlink round, and a payout that either exists or does not.

## Problem

Ostium's OLP and affiliate buffer carry $10,970,922 of Arbitrum TVL against $12,672,734 of Arbitrum open interest, and Gains Network's gTrade gUSDC vault carries $11,982,353 of Arbitrum TVL against $32,852,654 of all-chain open interest (`api.llama.fi/protocol/ostium`, `api.llama.fi/summary/open-interest/ostium`, `api.llama.fi/protocol/gains-network`, read 2026-09-26).

Ostium's open interest already runs 1.16x its Arbitrum TVL. A single concentrated weekend gap on one market can exceed the buffer that is supposed to absorb trader PnL first. Ostium's own docs describe exactly this failure mode: the buffer "absorbs trader PnL first, in full," and once it is gone the vault "enters UC state and automatically blocks new deposits" (docs.ostium.com/vault/overview). There is no third party standing behind that buffer today. Heracles is that party: a portfolio layer bought by the vault treasury itself, not a single-ticker note sold to a pool operator covering only its own inventory.

## How it works

A buyer calls `bind(exposure[], retention, limit)` with a signed notional per market. The bind window closes strictly before that ISO week's Friday 19:30 UTC cutoff, computed on chain from `block.timestamp`; the buyer never chooses the cutoff or the expiry, which is always the following Monday 13:30 UTC, and a zero exposure or zero limit reverts outright.

The Stylus `Pricer` runs each market's own 504-scenario weekend gap table, scaled by that feed's realised volatility with a floor of 1.0x (the scale can only push a quote up from the static historical table, never below it), and prices the layer at

```
premium = EL + 0.03 * (TVaR95 - EL) + 0.04 * limit * 7/365
```

the expected loss across all 504 scenarios, plus 3% of the tail mass above it (the worst 5%, TVaR95), plus a capital charge of 4% annualised on the locked limit for the real seven-day lock. The quote floors at 50 basis points of the limit, so a zero premium can never bind. A Solidity twin computes the identical formula for a parity check; the deployed pricer runs the Rust version.

Once bound, the reference price for each market is not the caller's spot. It is set via `setReference(id, marketIdx, roundId)`, which only accepts the first round at or after the Friday 4:00pm New York close, landing within 36h of it; a later first round lets anyone void that market, and the layer can then only be cancelled with the premium refunded. Writers deposit USDG into the ERC-4626 `Capacity` vault; a bind locks the limit out of free capacity and pulls the premium in the same transaction, but the premium sits in `pendingPremium`, excluded from share pricing, until the layer settles. `fix(id, marketIdx, roundId)` applies the same rule per market, the first round with `updatedAt >= expiry`, and once every market is fixed the layer settles: payout is the realized loss above retention, clamped at the layer's own locked limit. Buyer and writer both pull their own claim rather than being pushed a payment, and `claimTo` lets the claim owner redirect payout to another address.

## What is novel

Nexus Mutual, Sherlock, InsurAce and Unslashed all run pooled capital against smart-contract or depeg risk, with a governance vote, an arbitration panel, or a community/oracle-assisted process standing between a loss and a payout. Heracles has none of that: settlement is a pure function of the next Chainlink round after Monday's open. Neptune Mutual and Risk Harbor already proved the general shape of oracle-triggered, adjuster-free payout, so "no adjuster" alone is not the differentiator. What none of them do is price the specific instrument here: a per-market weekend gap, recomputed on chain from public historical data at every bind, rather than an off-chain-set underwriting rate.

Re Protocol, Nayms (rebranded OnRe), and Ensuro sell tokenized access to real, regulated reinsurance treaties, institutional capital backing an off-chain insurer's book that gets reported back on chain. Heracles backs an exposure that is already on chain: a Chainlink feed on an Arbitrum vault, not a policy administrator's ledger. The risk and the settlement data live in the same place.

## Stack

Contracts in Solidity (Foundry), with the pricing core ported to Rust and deployed as a Stylus program on Arbitrum. The writer side is an ERC-4626 vault (`Capacity`) taking Paxos USDG deposits, including gasless deposit via `depositWithPermit`. Both `bind` and the fixing path gate on Arbitrum's L2 Sequencer Uptime feed before trusting any oracle round. The web app is Vite and TypeScript, reading deployed addresses from `contracts/deployments/`.

## Security evidence

Heracles went through five recorded review rounds, each re-reading the diff against the last verdict rather than a single pass.

The first round (commit cb574a1) found a critical bug in the new permit deposit path: `Capacity.totalAssets()` marked every locked USDG at zero, so a deposit made while a layer was live bought the pool near zero and redeemed the honest writers' capital on settle, measured at 2,000 USDG in and 201,999.999799 USDG out against a 100,000 USDG writer position. The fix marks locked capital correctly in `totalAssets()` and was ported into `contracts/test/CapacityC1.t.sol`.

The next round (b71cf94) found that the fix's own epoch gate could be held shut indefinitely by an honest weekly-rolling buyer, let alone an attacker, since one small bind every Monday kept `locked` nonzero forever and blocked every writer exit. The following round (96309c8) found a dead-feed freeze and a just-in-time deposit that diluted the premium incumbent writers had already underwritten. Round four (8f492a4) found that the original 7-day grace period let `cancel` pre-empt a fix that was still recoverable inside the documented five-day holiday search window, and that an entrant depositing between bind and cutoff could lose its premium share on a cancel it did not cause.

The most recent round (2026-09-28) found that the Stylus pricer panicked on every real Chainlink proxy round id, since `roundId` is a `uint80` (`phaseId << 64 | aggregatorRoundId`) that does not fit in a `u64` once a feed has gone through more than one phase, and that market-to-table selection was positional rather than explicit, so a configured deploy could silently price a market off the wrong table. Both are fixed: round-id arithmetic now runs entirely in `U80`, verified against a live Arbitrum One SPY/USD round id read 2026-09-28, and table selection now takes an explicit constructor-supplied id array that reverts (`BadTableId`, `MissingTable`) rather than falling back to a default on any unmapped or misconfigured market.

Every closed finding is asserted by a named test in `contracts/test/AttackReview.t.sol` or the round's own test file, not just described. Two mutation checks in the current build confirm this the direct way: deleting the premium floor turns `test_H2_premiumFloorPreventsZeroPremiumLayer` red, and deleting the liabilities subtraction in `Capacity.totalAssets()` turns `test_H3_lossSharedProRataRegardlessOfWithdrawOrder` red at a 546% relative error against a 1% tolerance; restoring both returns the suite to green. Separate coverage includes a Solidity/Rust cross-language parity suite (`PricerParity.t.sol`, exact equality plus a bounded fuzz run up to $5M exposure), a guard-mutation suite pairing every `onlyTreaty`/`WrongState` check with its own red-then-green mutation, and two invariant suites run at 256 runs and 128,000 calls each. Exact current pass counts move as tests are added; verify with `forge test --summary` rather than trusting any number written down here.

## Team

Built by aarav1656, AI-assisted.

## Live app

https://heracles-virid-seven.vercel.app

## Deployed (Arbitrum Sepolia)

Addresses and live transactions are added after the redeploy.

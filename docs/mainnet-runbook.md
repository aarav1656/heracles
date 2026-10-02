# Arbitrum One runbook

Heracles goes to Arbitrum One as one Stylus pricer and three contracts, against the chain's own
Chainlink feeds, its L2 Sequencer Uptime feed and Paxos USDG. The whole wiring is rehearsed on a fork
of Arbitrum One by `contracts/test/ArbitrumOneRehearsal.fork.t.sol`, which runs the deploy script's own
`deploy` function.

## What goes on chain

| Step | Contract | How | Configuration |
|---|---|---|---|
| 1 | Six-table pricer (Rust/Stylus) | `cargo stylus deploy` | table ids `[0,1,2,3,4,5]`: NVDA, AAPL, SPY, TSLA, EUR/USD, XAU/USD |
| 2 | Treaty, with its USDG first-loss and senior vaults | `script/DeployArbitrumOne.s.sol` | the six feeds below, the real sequencer uptime feed, USDC/USD liveness feed, 50 bps floor, 30% first-loss |
| 3 | OIGuard | same script | the same pricer and feeds; layer 20,000 to 220,000 USDG, budget 4,000 USDG a week |
| 4 | VaultCover | same script | book 0 (USDG), every Treaty market covering the same book market; first layer keeps 100, covers 100, pays at most 10 USDG |

One pricer serves the Treaty, the guard and, through them, VaultCover, so all three share one market
order and VaultCover covers every leg of the book.

Addresses, each read live on Arbitrum One at block 511,120,266 (2026-10-02):

| Role | Address | Read |
|---|---|---|
| NVDA / USD | `0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F` | 8 decimals |
| AAPL / USD | `0x8d0CC5f38f9E802475f2CFf4F9fc7000C2E1557c` | 8 decimals |
| SPY / USD | `0x46306F3795342117721D8DEd50fbcF6DF2b3cc10` | 8 decimals |
| TSLA / USD | `0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3` | 8 decimals |
| EUR / USD | `0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84` | 8 decimals |
| XAU / USD | `0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c` | 8 decimals |
| L2 Sequencer Uptime Status Feed | `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` | answer 0, up |
| USDC / USD (liveness) | `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3` | prints through weekends |
| USDG (Paxos) | `0x004B506865409877C9fA29bfb1ebA929984B9bbC` | "Global Dollar", 6 decimals, 13,987,548 supply, EIP-2612 domain version "1" |

The USDG domain version is checked, not assumed: the separator recomputed with version "1" for chain
42161 equals `DOMAIN_SEPARATOR()` on chain (`0x7391a998...ce92aefa`), so `/write`'s permit deposit and
`scripts/permit-deposit.sh` work unchanged.

## Checks before any send

```
# the rehearsal: the deploy script's wiring on a fork of Arbitrum One
cd contracts && FORK_TESTS=1 forge test --match-path test/ArbitrumOneRehearsal.fork.t.sol
```

Five tests: the wiring reads back the six feeds, the real sequencer feed and USDG; 30 and 70 USDG of
real USDG deposit; a bind passes on the real sequencer feed (premium 5.414917 USDG for long 10,000
USDG of SPY, keep 100, cover 100); the same bind reverts `SequencerDown` when the feed reports the
sequencer down and when it is back up for under the one-hour grace; and VaultCover renews on the real
Treaty. Deploying the Treaty with no sequencer feed turns three of them red. The Solidity twin of the
pricer stands in for Stylus on the fork, since Forge's EVM does not execute WASM; `PricerParity.t.sol`
holds the two equal.

## Funding for the owner wallet

Gas on Arbitrum One read 0.02 gwei on 2026-10-02. Gas per step, from receipts of the same bytecode
on Arbitrum Sepolia and Robinhood Chain testnet:

| Step | Gas |
|---|---|
| Stylus pricer deploy | 4,899,539 |
| Stylus activation data fee | 0.000142 ETH on both testnets; budgeted at 0.0015 ETH |
| Treaty and vaults | at most 9,828,427 (the Sepolia deploy with two books; Arbitrum One has one) |
| OIGuard | 734,492 |
| VaultCover and its three setters | 1,438,514 + 191,574 |
| Two permit deposits | 2 x 173,050 |
| One bind on six markets | about 4,000,000 (1,650,831 on one market; two quotes a bind) |
| VaultCover open and renew | 1,772,323 + about 4,500,000 |
| Reference and fix on six markets, claim | about 1,700,000 |

That is about 29,300,000 gas: 0.00059 ETH at 0.02 gwei and 0.0029 ETH at 0.1 gwei, plus the
activation budget. **Fund the owner wallet `0x39ef83fbB0BA61A5b4169fF5ce21Fd89e25aab37` with 0.01 ETH
and 120 USDG on Arbitrum One.** The USDG is 30 first-loss and 70 senior capacity for a 100 USDG layer,
10 for the first bind's premium and 10 for VaultCover's first renew.

## Commands

```
# 1. pricer (key from a 600-mode file, never on the command line)
cd pricer && cargo stylus deploy --no-verify --endpoint https://arb1.arbitrum.io/rpc \
  --private-key-path "$KEYFILE" --constructor-args "[0,1,2,3,4,5]"
RPC=https://arb1.arbitrum.io/rpc scripts/stylus-program.sh <pricer>     # version, days left

# 2 to 4. Treaty, vaults, OIGuard, VaultCover; run refuses a pricer without table ids 0..5
cd contracts && ARB1_PRICER=<pricer> forge script script/DeployArbitrumOne.s.sol \
  --rpc-url https://arb1.arbitrum.io/rpc --broadcast --verify --verifier etherscan

# first cycle
RPC=https://arb1.arbitrum.io/rpc scripts/permit-deposit.sh <first-loss vault> 30000000
RPC=https://arb1.arbitrum.io/rpc scripts/permit-deposit.sh <senior vault> 70000000
cast send <USDG> 'transfer(address,uint256)' <VaultCover> 10000000 ...           # renew budget
cast send <VaultCover> 'open(uint256,int256)' 2 10000000000 ...                    # book: long 10,000 SPY
RPC=https://arb1.arbitrum.io/rpc scripts/renew-cover.sh <VaultCover>               # Monday to Thursday
RPC=https://arb1.arbitrum.io/rpc TREATY=<treaty> scripts/settle-layer.sh <id>      # Friday and Monday
```

## Checks after deploy

- `cast code` on each address; `tableIdAt(0..5)` reads `0..5`, `tableIdAt(6)` reverts `MissingTable`.
- `sequencerUptimeFeed()` reads `0xFdB6...697D`; `markets(i)` reads the six feeds in order; `bookAsset(0)` reads USDG.
- `OIGuard.check(book, 0, -2,000,000e6)` on a 2,000,000 NVDA short reverts `PremiumOverBudget`.
- Each send is checked by receipt status `0x1` and a read only that send could produce, as the scripts above do.

## The app on Arbitrum One

`web/scripts/sync-abi.mjs` reads `contracts/deployments/$HERACLES_CHAIN.json` (default `421614`).
Record the Arbitrum One deployment as `contracts/deployments/42161.json` in the same shape, then:

```
cd web && HERACLES_CHAIN=42161 npm run sync-abi && VITE_RPC_URL=https://arb1.arbitrum.io/rpc npm run build
```

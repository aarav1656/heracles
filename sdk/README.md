# heracles-sdk

Typed client for Heracles on Arbitrum Sepolia: the six-table Stylus pricer, the Treaty and the OIGuard. Every call is an `eth_call` the Arbitrum node executes, so the numbers come from the deployed Stylus WASM, and every result carries the block it was read at. Amounts are 6-decimal base units of the book asset.

## CLI

```
$ npx heracles-quote --exposure NVDA=1000000,EUR=-400000,XAU=250000 --retention 20000 --limit 200000 --open NVDA=600000
Heracles weekend-gap quote, Arbitrum Sepolia block 314943045
  pricer         0x1674ecf8d236a91c484c11fd11a21601837f7e37 (Stylus, six tables)
  book           NVDA long 1,000,000.00, EUR short 400,000.00, XAU long 250,000.00
  retention      20,000.00
  limit          200,000.00
  premium        3,817.10
  expected loss  2,423.87
  worst 5% avg   43,750.64

OIGuard 0x96BE263EfD057167E01a212BBd076904391217Ce, open NVDA long 600,000.00
  REFUSED        PremiumOverBudget: premium after the trade 7,780.37, budget 4,000.00, book today 3,817.10
```

Markets: `NVDA`, `AAPL`, `SPY`, `TSLA`, `EUR` (EUR/USD), `XAU` (gold). `--json` prints the same result for scripts, `--block` prices at a past block, `--rpc` picks the endpoint.

## Library

```ts
import { heraclesClient, quote, guardCheck, bindPreview, treatyState } from 'heracles-sdk';

const client = heraclesClient();
const book = { NVDA: 1_000_000_000_000n, EUR: -400_000_000_000n };

const q = await quote(client, { book, retention: 20_000_000_000n, limit: 200_000_000_000n });
// { premium, el, tvar95, blockNumber, pricer }

const g = await guardCheck(client, { book, market: 'NVDA', size: 600_000_000_000n });
// { ok: false, premium, budget, currentPremium, words, blockNumber, guard }

const b = await bindPreview(client, { account, exposure: [100_000_000_000n], retention: 1_000_000_000n, limit: 10_000_000_000n });
// { ok: true, id, maxPremium } or { ok: false, name: 'BadTiming', words: 'Too early or too late ...' }

const s = await treatyState(client);
// terms, layer count, markets and every vault's assets and locked capital at one block
```

| Function | Contract call |
|---|---|
| `quote` | `IPricer.quote` on the six-table Stylus pricer, markets in table order |
| `guardCheck` | `OIGuard.check`, decoding `PremiumOverBudget(premium, budget, currentPremium)` |
| `bindPreview` | simulates `Treaty.bind` from any account; `maxPremium` defaults to the premium the Treaty charges, floor included |
| `treatyState` | Treaty terms plus `totalAssets` and `locked` of all four vaults |
| `vaultCoverState` | the deployed VaultCover: book, covered legs and their bound, guard premium against budget, premium funds, `renewCover` simulated from the owner, every open and close |

ABIs are typed `as const` from the contract build, so argument and return types follow the Solidity signatures. They, the addresses and the plain-word error glosses are generated from `contracts/deployments/421614.json` and `contracts/out` by `web/scripts/sync-abi.mjs` and bundled at build time, the same source the web app reads.

## OIGuard

`contracts/src/OIGuard.sol`, deployed at [`0x96BE263EfD057167E01a212BBd076904391217Ce`](https://sepolia.arbiscan.io/address/0x96be263efd057167e01a212bbd076904391217ce#code). A perp venue calls `check(book, market, size)` before accepting a position, passing its LP vault's signed net exposure per market. The guard prices weekend-gap cover on the book after the trade and reverts `PremiumOverBudget` when that premium is above the budget the vault owner set. A trade that lowers the premium always passes, so a vault over budget can hedge back down.

## Tests

```
npm install
npm test     # builds, then runs test/live.test.ts against Arbitrum Sepolia
```

The suite asserts the quote is priced (`premium >= el > 0`), that a retention above the largest scenario loss gives `el = 0` and fails that same assertion, that the six-market vector matches the quote desk's per-call table override, that the guard's refusal carries the pricer's own numbers at the same block, and that a `Treaty.bind` simulation returns the custom error by name and in words.

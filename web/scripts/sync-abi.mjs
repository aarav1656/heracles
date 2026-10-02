// Source of truth for every address and ABI in this app.
//   Addresses: contracts/deployments/421614.json
//   Treaty / Capacity / IPricer / OIGuard ABIs: contracts/out/*/*.json (field "abi")
// Nothing in src/ may carry a hand-copied address. Run: npm run sync-abi
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..'); // repo root
const outDir = join(root, 'contracts', 'out');

function loadAbi(rel) {
  const raw = readFileSync(join(outDir, rel), 'utf8');
  const { abi } = JSON.parse(raw);
  if (!Array.isArray(abi)) throw new Error(`Expected field "abi" to be an array in ${rel}`);
  return abi;
}

const deployment = JSON.parse(
  readFileSync(join(root, 'contracts', 'deployments', '421614.json'), 'utf8'),
);

const treaty = deployment.contracts.Treaty.address;
const pricer = deployment.contracts.Pricer.address;
const quotePricer = deployment.contracts.PricerSixTables.address;
const oiGuard = deployment.contracts.OIGuard.address;
const feeds = deployment.contracts.Treaty.constructorArgs.feeds;
const books = deployment.books;
const rpc = deployment.rpc;
const chainId = deployment.chainId;

const isAddr = (a) => /^0x[0-9a-fA-F]{40}$/.test(a);
for (const [label, a] of Object.entries({ treaty, pricer, quotePricer, oiGuard })) {
  if (!isAddr(a)) throw new Error(`Bad ${label} address in 421614.json: ${a}`);
}
if (!Array.isArray(feeds) || feeds.length === 0) throw new Error('No feeds in 421614.json');
if (!Array.isArray(books) || books.length === 0) throw new Error('No books in 421614.json');
books.forEach((b, i) => {
  if (b.index !== i) throw new Error(`Book ${i} carries index ${b.index}`);
  for (const k of ['asset', 'firstLoss', 'senior']) if (!isAddr(b[k])) throw new Error(`Bad ${k} for book ${b.symbol}: ${b[k]}`);
  if (b.decimals !== 6) throw new Error(`Book ${b.symbol} has ${b.decimals} decimals; the UI formats 6`);
});

const treatyAbi = loadAbi(join('Treaty.sol', 'Treaty.json').replace(/\\/g, '/'));
const capacityAbi = loadAbi('Capacity.sol/Capacity.json');
const pricerAbi = loadAbi('IPricer.sol/IPricer.json');
const oiGuardAbi = loadAbi('OIGuard.sol/OIGuard.json');

const dest = join(here, '..', 'src', 'abi', 'generated.ts');
mkdirSync(dirname(dest), { recursive: true });

const body = `// Generated from contracts/deployments/421614.json and contracts/out/* - do not edit by hand.
// Regenerate with: npm run sync-abi
import type { Address } from 'viem';

export const CHAIN_ID = ${chainId} as const;
export const RPC_URL = ${JSON.stringify(rpc)} as const;
export const TREATY_ADDRESS = ${JSON.stringify(treaty)} as Address;
export const PRICER_ADDRESS = ${JSON.stringify(pricer)} as Address;
/** The six-table Stylus pricer the quote desk prices on: equities, EUR/USD and XAU/USD. */
export const QUOTE_PRICER_ADDRESS = ${JSON.stringify(quotePricer)} as Address;
export const FEED_ADDRESSES = ${JSON.stringify(feeds)} as Address[];
/** Open-interest guard over the six-table pricer, markets in its table order. */
export const OIGUARD_ADDRESS = ${JSON.stringify(oiGuard)} as Address;

export type BookConfig = {
  index: number;
  symbol: string;
  asset: Address;
  decimals: 6;
  /** EIP-2612 domain of the book asset, for depositWithPermit. */
  permit: { name: string; version: string };
  firstLoss: Address;
  senior: Address;
};
export const BOOKS: readonly BookConfig[] = ${JSON.stringify(books.map(({ index, symbol, asset, decimals, permit, firstLoss, senior }) => ({ index, symbol, asset, decimals, permit, firstLoss, senior })))};

export const treatyAbi = ${JSON.stringify(treatyAbi)} as const;
export const capacityAbi = ${JSON.stringify(capacityAbi)} as const;
export const pricerAbi = ${JSON.stringify(pricerAbi)} as const;
export const oiGuardAbi = ${JSON.stringify(oiGuardAbi)} as const;
`;
writeFileSync(dest, body);
console.log(
  `wrote src/abi/generated.ts (chain ${chainId}, treaty ${treatyAbi.length} + capacity ${capacityAbi.length} + pricer ${pricerAbi.length} + guard ${oiGuardAbi.length} ABI entries, ${feeds.length} feed(s), ${books.length} book(s))`,
);

// The four weekend-gap tables the first screen charts, copied in so web/ builds on its own.
const gapSrc = join(root, 'evidence', 'gap-tables');
const gapDest = join(here, '..', 'src', 'data', 'gap-tables');
mkdirSync(gapDest, { recursive: true });
for (const t of ['SPY', 'NVDA', 'AAPL', 'TSLA']) {
  writeFileSync(join(gapDest, `${t}.json`), readFileSync(join(gapSrc, `${t}.json`), 'utf8'));
}
console.log('copied gap tables SPY, NVDA, AAPL, TSLA into src/data/gap-tables');

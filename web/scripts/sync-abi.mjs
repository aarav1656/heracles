// Source of truth for every address and ABI in this app.
//   Addresses: contracts/deployments/421614.json
//   Treaty / Capacity / IPricer / OIGuard / VaultCover ABIs: contracts/out/*/*.json (field "abi")
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
  readFileSync(join(root, 'contracts', 'deployments', `${process.env.HERACLES_CHAIN ?? '421614'}.json`), 'utf8'),
);

const treaty = deployment.contracts.Treaty.address;
const pricer = deployment.contracts.Pricer.address;
const quotePricer = deployment.contracts.PricerSixTables.address;
const oiGuard = deployment.contracts.OIGuard.address;
const vaultCover = deployment.contracts.VaultCover;
const feeds = deployment.contracts.Treaty.constructorArgs.feeds;
const books = deployment.books;
const rh = JSON.parse(readFileSync(join(root, 'contracts', 'deployments', '46630.json'), 'utf8'));
const rhGuard = rh.contracts.OIGuard;
const rpc = deployment.rpc;
const chainId = deployment.chainId;

const isAddr = (a) => /^0x[0-9a-fA-F]{40}$/.test(a);
for (const [label, a] of Object.entries({ treaty, pricer, quotePricer, oiGuard, vaultCover: vaultCover.address })) {
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
const mockFeedRuntime = JSON.parse(readFileSync(join(outDir, 'MockFeed.sol', 'MockFeed.json'), 'utf8')).deployedBytecode.object;
const vaultCoverAbi = loadAbi('VaultCover.sol/VaultCover.json');

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
/** A perp LP vault's book wired to the OIGuard and the Treaty's USDG book. */
export const VAULT_COVER_ADDRESS = ${JSON.stringify(vaultCover.address)} as Address;
export const VAULT_COVER_DEPLOY_BLOCK = ${vaultCover.block}n;
/** The guard and VaultCover web/scripts/integrate-vault.sh deployed when it was run as written. */
export const GUIDE_RUN = ${JSON.stringify(deployment.integrationGuideRun)} as const;
/** Runtime of contracts/test/mocks/MockFeed.sol: the landing page places it on both chains in an eth_call
 * state override so the two deployed pricers price against the same feed (scripts/pricer_parity.py). */
export const MOCK_FEED_RUNTIME = ${JSON.stringify(mockFeedRuntime)} as \`0x\${string}\`;
export const RH_SIX_TABLE_PRICER = ${JSON.stringify(rh.contracts.PricerSixTables.address)} as Address;
/** The live cycle's transactions, for the landing tour: layer 0 on the USDC book and the USDG deposits. */
export const LIVE_CYCLE = ${JSON.stringify({ bindTx: deployment.liveCycle.txs.bind, bindBlock: deployment.liveCycle.bindBlock, referenceTx: deployment.liveCycle.txs.setReference, usdgDeposits: deployment.liveCycle.usdgBook.deposits.map(({ vault, tx, amount }) => ({ vault, tx, amount })), vaultCoverOpens: deployment.contracts.VaultCover.gusdcBookMirror.opens })} as const;
/** The OIGuard on Robinhood Chain testnet over the Stock Token mirror feeds, and its two recorded checks. */
export const RH_TESTNET = ${JSON.stringify({ chainId: rh.chainId, rpc: rh.rpc, explorer: 'https://explorer.testnet.chain.robinhood.com', guard: rhGuard.address, pricer: rhGuard.pricer, feeds: rhGuard.feeds, book: rhGuard.book, accepted: rhGuard.accepted, refused: rhGuard.refused })} as const;
/** The forced open the guard refused on chain (receipt status 0x0). */
export const VAULT_COVER_REFUSED = ${JSON.stringify(vaultCover.refusedOpen)} as const;

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
export const vaultCoverAbi = ${JSON.stringify(vaultCoverAbi)} as const;
`;
writeFileSync(dest, body);
console.log(
  `wrote src/abi/generated.ts (chain ${chainId}, treaty ${treatyAbi.length} + capacity ${capacityAbi.length} + pricer ${pricerAbi.length} + guard ${oiGuardAbi.length} + vault cover ${vaultCoverAbi.length} ABI entries, ${feeds.length} feed(s), ${books.length} book(s))`,
);

// The four weekend-gap tables the first screen charts, copied in so web/ builds on its own.
const gapSrc = join(root, 'evidence', 'gap-tables');
const gapDest = join(here, '..', 'src', 'data', 'gap-tables');
mkdirSync(gapDest, { recursive: true });
for (const t of ['SPY', 'NVDA', 'AAPL', 'TSLA']) {
  writeFileSync(join(gapDest, `${t}.json`), readFileSync(join(gapSrc, `${t}.json`), 'utf8'));
}
console.log('copied gap tables SPY, NVDA, AAPL, TSLA into src/data/gap-tables');

// The pricing method the /write caption links to, served by the site itself.
const docsDest = join(here, '..', 'public', 'docs');
mkdirSync(docsDest, { recursive: true });
writeFileSync(join(docsDest, 'pricing.md'), readFileSync(join(root, 'docs', 'pricing.md'), 'utf8'));
console.log('copied docs/pricing.md into public/docs');

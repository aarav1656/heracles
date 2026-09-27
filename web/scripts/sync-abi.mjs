// Source of truth for every address and ABI in this app.
//   Addresses: contracts/deployments/421614.json
//   Treaty / Capacity / IPricer ABIs: contracts/out/*/*.json (field "abi")
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
const capacity = deployment.contracts.Capacity.address;
const pricer = deployment.contracts.Pricer.address;
const usdg = deployment.usdg.address;
const feeds = deployment.contracts.Treaty.constructorArgs.feeds;
const rpc = deployment.rpc;
const chainId = deployment.chainId;

for (const [label, a] of Object.entries({ treaty, capacity, pricer, usdg })) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(a)) throw new Error(`Bad ${label} address in 421614.json: ${a}`);
}
if (!Array.isArray(feeds) || feeds.length === 0) throw new Error('No feeds in 421614.json');

const treatyAbi = loadAbi(join('Treaty.sol', 'Treaty.json').replace(/\\/g, '/'));
const capacityAbi = loadAbi('Capacity.sol/Capacity.json');
const pricerAbi = loadAbi('IPricer.sol/IPricer.json');

const dest = join(here, '..', 'src', 'abi', 'generated.ts');
mkdirSync(dirname(dest), { recursive: true });

const body = `// Generated from contracts/deployments/421614.json and contracts/out/* - do not edit by hand.
// Regenerate with: npm run sync-abi
import type { Address } from 'viem';

export const CHAIN_ID = ${chainId} as const;
export const RPC_URL = ${JSON.stringify(rpc)} as const;
export const TREATY_ADDRESS = ${JSON.stringify(treaty)} as Address;
export const CAPACITY_ADDRESS = ${JSON.stringify(capacity)} as Address;
export const PRICER_ADDRESS = ${JSON.stringify(pricer)} as Address;
export const USDG_ADDRESS = ${JSON.stringify(usdg)} as Address;
export const FEED_ADDRESSES = ${JSON.stringify(feeds)} as Address[];
export const USDG_DECIMALS = ${deployment.usdg.decimals} as const;

export const treatyAbi = ${JSON.stringify(treatyAbi)} as const;
export const capacityAbi = ${JSON.stringify(capacityAbi)} as const;
export const pricerAbi = ${JSON.stringify(pricerAbi)} as const;
`;
writeFileSync(dest, body);
console.log(
  `wrote src/abi/generated.ts (chain ${chainId}, treaty ${treatyAbi.length} + capacity ${capacityAbi.length} + pricer ${pricerAbi.length} ABI entries, ${feeds.length} feed(s))`,
);

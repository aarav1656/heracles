// Saves one live read of the gTrade gUSDC vault's book to src/data/gains-gusdc-book.json, the read
// /quote shows until its own live read lands. Run: npm run save-gains
import { writeFileSync } from 'node:fs';
import { readGains, GAINS_DIAMOND, GUSDC, USDC_COLLATERAL } from '../src/lib/gains.ts';

const r = await readGains(process.env.ARBITRUM_ONE_RPC || undefined);
const out = {
  chain: 'Arbitrum One (42161)',
  block: Number(r.block),
  readAt: new Date().toISOString(),
  diamond: GAINS_DIAMOND,
  gToken: GUSDC,
  collateralIndex: USDC_COLLATERAL,
  calls: 'pairs(i), getPairOiAfterV10Collateral(3, i) + getPairOisBeforeV10Collateral(3, i) on the Diamond; totalAssets() on gUSDC',
  vaultAssetsUsd: r.vaultAssetsUsd,
  pairs: r.pairs,
};
writeFileSync(new URL('../src/data/gains-gusdc-book.json', import.meta.url), `${JSON.stringify(out, null, 2)}\n`);
console.log(`gUSDC book at Arbitrum One block ${out.block}: ${r.pairs.map((p) => `${p.ticker} long ${p.longUsd.toFixed(2)} short ${p.shortUsd.toFixed(2)}`).join('; ')}; vault ${r.vaultAssetsUsd.toFixed(2)} USDC`);

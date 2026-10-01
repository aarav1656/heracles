// Ostium open interest by asset class, split from ostium.ts so node can test the grouping
// without a network or viem. The grouping is scripts/ostium_oi_by_group.py: equities (stocks,
// indices, etf), fx, gold_metals, commodities (non-metal), crypto.

export type Bucket = 'equities' | 'fx' | 'gold_metals' | 'commodities' | 'crypto' | 'other';
export type PairOi = { pairIndex: number; from: string; to: string; bucket: Bucket; longUsd: number; shortUsd: number };
export type GroupOi = { longUsd: number; shortUsd: number; netUsd: number; grossUsd: number; pairs: number };

const METALS = new Set(['XAU', 'XAG', 'XPT', 'XPD']);

export function bucketOf(group: string, base: string): Bucket {
  if (group === 'crypto') return 'crypto';
  if (group === 'stocks' || group === 'indices' || group === 'etf') return 'equities';
  if (group === 'forex') return 'fx';
  if (group === 'commodities') return METALS.has(base) ? 'gold_metals' : 'commodities';
  return 'other';
}

export function groupOi(pairs: PairOi[]): Partial<Record<Bucket, GroupOi>> {
  const out: Partial<Record<Bucket, GroupOi>> = {};
  for (const p of pairs) {
    const g = (out[p.bucket] ??= { longUsd: 0, shortUsd: 0, netUsd: 0, grossUsd: 0, pairs: 0 });
    g.longUsd += p.longUsd;
    g.shortUsd += p.shortUsd;
    g.netUsd += p.longUsd - p.shortUsd;
    g.grossUsd += p.longUsd + p.shortUsd;
    g.pairs += 1;
  }
  return out;
}

/**
 * Ostium's vault is the counterparty to every trader position, so the vault's own net position
 * in a market is the opposite of the traders' net. Heracles' sign: positive is long (loses when
 * the market falls), negative is short (loses when it rises).
 */
export const vaultExposureUsd = (traderLongUsd: number, traderShortUsd: number) => traderShortUsd - traderLongUsd;

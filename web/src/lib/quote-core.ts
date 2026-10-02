// The quote desk's pure pieces: which pricer table and asset class each market prices on, the storage word that
// sets the pricer's per-market table ids for one call, and the plain-text quote for a mail.

export type PricedClass = 'equities' | 'fx' | 'gold_metals';
export type PricedMarket = { ticker: 'SPY' | 'NVDA' | 'AAPL' | 'TSLA' | 'EUR' | 'XAU'; tableId: number; bucket: PricedClass; name: string };

/** The asset classes the pricer holds a scenario table for, in the order the quote desk lists them. */
export const PRICED_CLASSES: readonly { key: PricedClass; name: string }[] = [
  { key: 'equities', name: 'Equities and indices' },
  { key: 'fx', name: 'FX' },
  { key: 'gold_metals', name: 'Gold' },
];

/** Table ids as deployed in pricer/core: 0 NVDA, 1 AAPL, 2 SPY, 3 TSLA, 4 EUR/USD, 5 XAU/USD. */
export const PRICED_MARKETS: readonly PricedMarket[] = [
  { ticker: 'SPY', tableId: 2, bucket: 'equities', name: 'S&P 500 ETF' },
  { ticker: 'NVDA', tableId: 0, bucket: 'equities', name: 'NVIDIA' },
  { ticker: 'AAPL', tableId: 1, bucket: 'equities', name: 'Apple' },
  { ticker: 'TSLA', tableId: 3, bucket: 'equities', name: 'Tesla' },
  { ticker: 'EUR', tableId: 4, bucket: 'fx', name: 'Euro / US dollar' },
  { ticker: 'XAU', tableId: 5, bucket: 'gold_metals', name: 'Gold / US dollar' },
];

/** Highest table id the deployed pricer holds. */
export const MAX_TABLE_ID = 5;

/**
 * Storage slot 0 of the Stylus pricer is `table_ids`, a Solidity-layout `bytes`: for 31 bytes or
 * fewer the ids sit left-aligned and the last byte is length * 2. The six-table pricer holds
 * `0x000102030405 00..00 0c`; a quote over other markets sets this word in the call's state.
 */
export function tableIdsSlot(ids: readonly number[]): `0x${string}` {
  if (ids.length === 0 || ids.length > 31) throw new Error('1 to 31 markets');
  if (ids.some((i) => !Number.isInteger(i) || i < 0 || i > MAX_TABLE_ID)) throw new Error(`table ids are 0 to ${MAX_TABLE_ID}`);
  const data = ids.map((i) => i.toString(16).padStart(2, '0')).join('');
  return `0x${data.padEnd(62, '0')}${(ids.length * 2).toString(16).padStart(2, '0')}`;
}

export type QuoteMail = {
  rows: { ticker: string; exposureUsd: number }[];
  retention: number;
  limit: number;
  symbol: string;
  premium: number;
  expectedLoss: number;
  tvar95: number;
  firstLossPremium: number;
  seniorPremium: number;
  firstLossLimit: number;
  seniorLimit: number;
  pricer: string;
  block: string;
  page: string;
};

const usd = (v: number) => v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/** A short plain-text quote and the mailto link that carries it. No network call is made. */
export function composeQuoteMail(q: QuoteMail) {
  const lines = q.rows.map((r) => `  ${r.ticker}: ${r.exposureUsd >= 0 ? 'long' : 'short'} ${usd(Math.abs(r.exposureUsd))} ${q.symbol}`);
  const body = [
    'Weekend-gap cover quote (Heracles)',
    '',
    'Net weekend exposure:',
    ...lines,
    '',
    `Vault keeps the first ${usd(q.retention)} ${q.symbol} of weekend-gap loss`,
    `Heracles pays up to ${usd(q.limit)} ${q.symbol} above that`,
    '',
    `Premium for one weekend: ${usd(q.premium)} ${q.symbol}`,
    `Expected payout a weekend: ${usd(q.expectedLoss)} ${q.symbol}`,
    `Average in the worst 5% of weekends: ${usd(q.tvar95)} ${q.symbol}`,
    '',
    `First-loss tranche: ${usd(q.firstLossLimit)} ${q.symbol} of limit, premium ${usd(q.firstLossPremium)} ${q.symbol}`,
    `Senior tranche: ${usd(q.seniorLimit)} ${q.symbol} of limit, premium ${usd(q.seniorPremium)} ${q.symbol}`,
    '',
    `Priced on chain by the Stylus pricer ${q.pricer} at Arbitrum Sepolia block ${q.block}.`,
    q.page,
  ].join('\n');
  const subject = `Weekend-gap cover quote: ${usd(q.premium)} ${q.symbol} for ${usd(q.limit)} ${q.symbol} of limit`;
  return { subject, body, href: `mailto:?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}` };
}

// Guards the quote desk's pure pieces against the chain and the committed Ostium snapshot.
//   node --test --experimental-strip-types src/lib/quote.test.ts

import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

const { tableIdsSlot, composeQuoteMail, PRICED_MARKETS } = await import('./quote-core.ts');
const { bucketOf, groupOi, vaultExposureUsd } = await import('./ostium-core.ts');

test('table-id slot matches what the deployed pricer holds and what the override test priced', () => {
  // cast storage 0xbe99...1f88 0 on Arbitrum Sepolia, 2026-10-01: one market, SPY (id 2).
  assert.equal(tableIdsSlot([2]), '0x0200000000000000000000000000000000000000000000000000000000000002');
  // The four-table override used to price [SPY, NVDA, AAPL, TSLA] through the live pricer.
  assert.equal(tableIdsSlot([0, 1, 2, 3]), '0x0001020300000000000000000000000000000000000000000000000000000008');
  // cast storage 0x1674ecf8d236a91c484c11fd11a21601837f7e37 0 on Arbitrum Sepolia, 2026-10-02: the six-table pricer.
  assert.equal(tableIdsSlot([0, 1, 2, 3, 4, 5]), '0x000102030405000000000000000000000000000000000000000000000000000c');
  assert.equal(tableIdsSlot([4, 5]), '0x0405000000000000000000000000000000000000000000000000000000000004');
  assert.throws(() => tableIdsSlot([6]));
  assert.throws(() => tableIdsSlot([]));
});

test('priced markets map to the pricer table ids', () => {
  assert.deepEqual(PRICED_MARKETS.map((m) => [m.ticker, m.tableId]), [['SPY', 2], ['NVDA', 0], ['AAPL', 1], ['TSLA', 3], ['EUR', 4], ['XAU', 5]]);
  assert.deepEqual(PRICED_MARKETS.map((m) => m.bucket), ['equities', 'equities', 'equities', 'equities', 'fx', 'gold_metals']);
});

test('every priced market, FX and gold included, has an Ostium pair in the committed read with a non-zero vault side', () => {
  const snap = JSON.parse(readFileSync(new URL('../data/ostium-oi-by-group.json', import.meta.url), 'utf8'));
  for (const m of PRICED_MARKETS) {
    const p = snap.pairs.find((x: { from: string; subgraphGroup: string }) => x.from === m.ostium && bucketOf(x.subgraphGroup, x.from) === m.bucket);
    assert.ok(p, `${m.ticker}: no Ostium pair in bucket ${m.bucket}`);
    assert.notEqual(vaultExposureUsd(p.longOI_usd, p.shortOI_usd), 0, m.ticker);
  }
  const eur = snap.pairs.find((x: { from: string }) => x.from === 'EUR');
  assert.equal(Math.round(vaultExposureUsd(eur.longOI_usd, eur.shortOI_usd)), -2_483_100); // traders net long, vault short
});

test('grouping the committed Ostium snapshot reproduces its own group totals', () => {
  const snap = JSON.parse(readFileSync(new URL('../data/ostium-oi-by-group.json', import.meta.url), 'utf8'));
  assert.ok(snap.pairs.length >= 80, 'snapshot must hold the real pair list');
  const pairs = snap.pairs.map((p: { pairIndex: number; from: string; to: string; subgraphGroup: string; longOI_usd: number; shortOI_usd: number }) => ({
    pairIndex: p.pairIndex, from: p.from, to: p.to, bucket: bucketOf(p.subgraphGroup, p.from), longUsd: p.longOI_usd, shortUsd: p.shortOI_usd,
  }));
  const g = groupOi(pairs);
  for (const [name, want] of Object.entries(snap.groups) as [string, { net_usd: number; pairs: number }][]) {
    assert.ok(Math.abs((g as Record<string, { netUsd: number }>)[name].netUsd - want.net_usd) < 0.01, name);
    assert.equal((g as Record<string, { pairs: number }>)[name].pairs, want.pairs, name);
  }
  assert.equal(bucketOf('commodities', 'XAU'), 'gold_metals');
  assert.equal(bucketOf('commodities', 'BRENT'), 'commodities');
  assert.equal(bucketOf('etf', 'XLE'), 'equities');
});

test('the vault holds the opposite side of the traders', () => {
  assert.equal(vaultExposureUsd(453_222 + 1_278, 1_278), -453_222); // traders net long NVDA, vault short
  assert.equal(vaultExposureUsd(91_201, 524_812), 433_611); // traders net short SPX, vault long
});

test('the mail carries the figures and is a mailto link', () => {
  const m = composeQuoteMail({
    rows: [{ ticker: 'SPY', exposureUsd: 433_611 }, { ticker: 'NVDA', exposureUsd: -453_222 }],
    retention: 5_000, limit: 20_000, symbol: 'USDG', premium: 1_234.5, expectedLoss: 321.25, tvar95: 9_876.5,
    firstLossPremium: 700, seniorPremium: 534.5, firstLossLimit: 6_000, seniorLimit: 14_000,
    pricer: '0xbe99', block: '314,654,978', page: 'https://example.test/quote',
  });
  assert.ok(m.href.startsWith('mailto:?subject='));
  const body = decodeURIComponent(m.href.split('&body=')[1]);
  for (const s of ['SPY: long 433,611.00 USDG', 'NVDA: short 453,222.00 USDG', 'Premium for one weekend: 1,234.50 USDG', 'First-loss tranche: 6,000.00 USDG', 'block 314,654,978']) {
    assert.ok(body.includes(s), s);
  }
  assert.ok(!body.includes('—'));
});

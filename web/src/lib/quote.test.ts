// Guards the quote desk's pure pieces against the chain and the committed gUSDC book read.
//   node --test --experimental-strip-types src/lib/quote.test.ts

import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

const { tableIdsSlot, composeQuoteMail, PRICED_MARKETS } = await import('./quote-core.ts');
const { vaultExposureUsd, GAINS_PAIRS } = await import('./gains.ts');

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

test('every priced market has its gTrade pair in the committed gUSDC read', () => {
  const snap = JSON.parse(readFileSync(new URL('../data/gains-gusdc-book.json', import.meta.url), 'utf8'));
  assert.ok(snap.block > 511_000_000, 'an Arbitrum One block');
  assert.deepEqual(snap.pairs.map((p: { ticker: string }) => p.ticker), PRICED_MARKETS.map((m) => m.ticker));
  assert.deepEqual(GAINS_PAIRS.map((p) => [p.ticker, p.pairIndex]), [['SPY', 86], ['NVDA', 65], ['AAPL', 58], ['TSLA', 63], ['EUR', 21], ['XAU', 90]]);
  const side = (t: string) => {
    const p = snap.pairs.find((x: { ticker: string }) => x.ticker === t);
    return Math.round(vaultExposureUsd(p.longUsd, p.shortUsd));
  };
  // gTrade Diamond at Arbitrum One block 511,007,816: traders net short SPY, net long NVDA.
  assert.equal(side('SPY'), 153_309);
  assert.equal(side('NVDA'), -23_665);
  assert.ok(snap.vaultAssetsUsd > 1_000_000, 'gUSDC totalAssets');
});

test('the vault holds the opposite side of the traders', () => {
  assert.equal(vaultExposureUsd(453_222 + 1_278, 1_278), -453_222); // traders net long NVDA, vault short
  assert.equal(vaultExposureUsd(91_201, 524_812), 433_611); // traders net short SPY, vault long
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

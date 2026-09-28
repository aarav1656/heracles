// Guards the browser backtest against the deployed pricer: on the README reference layer the
// SPY table must reproduce the pricer's own recorded EL and TVaR95 (docs/pricing.md "Gas":
// EL 1,051,190,476 and TVaR95 20,368,000,000 base units). A sign flip, a wrong tail size or a
// wrong table order changes these, so this can fail.
//
//   node --test --experimental-strip-types src/lib/gaps.test.ts

import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

const spy = JSON.parse(readFileSync(new URL('../../../evidence/gap-tables/SPY.json', import.meta.url), 'utf8'));
const weekends = spy.gaps.map((g: { friday: string; monday: string; gap_bps: number }) => ({ friday: g.friday, monday: g.monday, gap: g.gap_bps }));

const { backtest, extremes } = await import('./gaps-core.ts');

test('SPY reference layer matches the pricer', () => {
  const b = backtest(weekends, 2_000_000, 20_000, 60_000);
  assert.equal(weekends.length, 504);
  assert.equal(b.el.toFixed(6), '1051.190476');
  assert.equal(b.tvar95, 20_368);
  assert.equal(b.paid, 36);
  assert.equal(b.exhausted, 2);
  assert.equal(b.attachBps, -100);
  assert.equal(b.exhaustBps, -400);
});

test('a short layer pays on up gaps', () => {
  const b = backtest(weekends, -2_000_000, 20_000, 60_000);
  assert.ok(b.attachBps > 0);
  assert.equal(b.paid, weekends.filter((w: { gap: number }) => w.gap > 100).length);
});

test('worst SPY weekend is the March 2020 reopen', () => {
  const e = extremes(weekends);
  assert.equal(e.down.gap, -1045);
  assert.equal(e.down.friday, '2020-03-13');
});

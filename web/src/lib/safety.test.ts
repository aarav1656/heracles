//   node --test --experimental-strip-types src/lib/safety.test.ts
import assert from 'node:assert/strict';
import test from 'node:test';

const { checkFreshness, MAX_ROUND_AGE_SECONDS } = await import('./safety-core.ts');
const { gridAxes, buildGrid, CURRENT } = await import('./grid-core.ts');

test('feed exactly at the bound is fresh, one second older is stale (contract: updatedAt + MAX < now reverts)', () => {
  const now = 1_800_000_000;
  const at = BigInt(now - MAX_ROUND_AGE_SECONDS);
  assert.equal(checkFreshness(at, now).fresh, true);
  assert.equal(checkFreshness(at - 1n, now).fresh, false);
  assert.match(checkFreshness(at - 1n, now).words, /signing is held/);
  assert.match(checkFreshness(BigInt(now - 600), now).words, /10 minutes ago/);
});

test('grid axes step 0.5x to 1.5x around the user terms', () => {
  const a = gridAxes(20_000_000_000n, 60_000_000_000n);
  assert.deepEqual(a.retentions, [10_000_000_000n, 15_000_000_000n, 20_000_000_000n, 25_000_000_000n, 30_000_000_000n]);
  assert.equal(a.limits[CURRENT], 60_000_000_000n);
  assert.equal(a.limits.length, 5);
});

test('grid cells carry premium, EL, rate and mark only the centre as current; floor lifts low premiums', () => {
  const axes = gridAxes(1000n, 4000n); // limits 2000..6000, floor at 50 bps = 10..30
  const quotes = axes.retentions.map((_, r) => axes.limits.map((_, l) => [BigInt(1 + (r * 5 + l) * 10), BigInt(r + l)] as const));
  const g = buildGrid(axes, quotes, 50n);
  assert.equal(g.length, 5);
  assert.ok(g.every((row) => row.length === 5));
  assert.equal(g.flat().filter((c) => c.current).length, 1);
  assert.equal(g[CURRENT][CURRENT].current, true);
  assert.equal(g[0][0].premium, 10n); // raw 1 lifted to the floor
  assert.equal(g[4][4].premium, 241n); // raw above floor kept
  assert.equal(g[4][4].el, 8n);
  assert.equal(g[4][4].rateBps, (241n * 10000n) / 6000n);
});

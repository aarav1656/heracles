// Recomputes the replay's layer math from the raw chain reads stored in replay.json, with the
// Treaty's own integer rules, so a wrong sign, a netted gain or a mis-split tranche changes a figure.
//   node --test --experimental-strip-types src/lib/replay.test.ts

import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';

const r = JSON.parse(readFileSync(new URL('../data/replay.json', import.meta.url), 'utf8'));
const tdiv = (a: bigint, b: bigint) => a / b; // BigInt division truncates toward zero, like Solidity int256

function settle(sign = 1n) {
  let loss = 0n;
  for (const m of r.markets) {
    const exp = BigInt(m.vaultExposureUsd6) * sign;
    const pnl = tdiv(exp * (BigInt(m.feed.fix.answer) - BigInt(m.feed.reference.answer)), BigInt(m.feed.reference.answer));
    if (pnl < 0n) loss -= pnl;
  }
  const ret = BigInt(r.layer.retentionUsd6), lim = BigInt(r.layer.limitUsd6), jun = BigInt(r.layer.juniorLimitUsd6);
  let p = loss - ret;
  if (p < 0n) p = 0n;
  if (p > lim) p = lim;
  const pj = p < jun ? p : jun;
  return { loss, p, pj, ps: p - pj };
}

test('the stored result is what Treaty._settle computes from the stored rounds', () => {
  const s = settle();
  assert.ok(r.markets.length === 4 && s.loss > 0n, 'non-empty replay');
  assert.equal(s.loss.toString(), String(r.result.lossUsd6));
  assert.equal(s.p.toString(), String(r.result.payoutUsd6));
  assert.equal(s.pj.toString(), String(r.result.payoutJuniorUsd6));
  assert.equal(s.ps.toString(), String(r.result.payoutSeniorUsd6));
  assert.equal(s.pj + s.ps, s.p);
});

test('first-loss fills before senior pays, and the sum of tranches is the payout', () => {
  assert.equal(BigInt(r.layer.juniorLimitUsd6) * 10000n / BigInt(r.layer.limitUsd6), 3000n);
  assert.ok(BigInt(r.result.payoutSeniorUsd6) > 0n ? BigInt(r.result.payoutJuniorUsd6) === BigInt(r.layer.juniorLimitUsd6) : true);
});

test('a flipped sign changes the loss (the check can fail)', () => {
  assert.notEqual(settle(-1n).loss.toString(), String(r.result.lossUsd6));
});

test('gains are not netted: the loss is the sum of the losing legs only', () => {
  const losing = r.markets.reduce((s: number, m: { lossUsd6: number }) => s + m.lossUsd6, 0);
  assert.equal(losing, r.result.lossUsd6);
  assert.ok(r.markets.some((m: { lossUsd6: number }) => m.lossUsd6 === 0), 'one leg moved in the vault\'s favour');
});

test('premium tranches add up and the pricer quote carries the cross-check', () => {
  assert.equal(r.premium.premiumJuniorUsd6 + r.premium.premiumSeniorUsd6, r.premium.premiumUsd6);
  assert.ok(r.premium.premiumUsd6 >= r.premium.floorUsd6);
  assert.ok(r.premium.nativeCrossCheck.startsWith('0x') && r.premium.nativeCrossCheck.length === 2 + 3 * 64);
});

// Live against Arbitrum Sepolia: every call is an eth_call the Arbitrum node executes, so the
// pricer numbers come from the deployed Stylus WASM, not a local model. Each test pins one block.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ERROR_WORDS, FEED_ADDRESSES, MARKETS, OIGUARD_ADDRESS, PRICER_ADDRESS, QUOTE_PRICER_ADDRESS, TREATY_ADDRESS,
  bindPreview, bookVector, guardCheck, heraclesClient, pricerAbi, quote, treatyAbi, treatyState, vaultCoverState, VAULT_COVER_ADDRESS,
} from '../dist/index.mjs';

const client = heraclesClient();
const book = { NVDA: 1_000_000_000_000n, EUR: -400_000_000_000n, XAU: 250_000_000_000n };
const RETENTION = 20_000_000_000n;
const LIMIT = 200_000_000_000n;
const OIGUARD_BLOCK = 314_941_446n;

/** A quote that prices real tail risk: a non-zero premium covering a non-zero expected loss. */
function assertPriced(q: { premium: bigint; el: bigint; tvar95: bigint }) {
  assert.ok(q.el > 0n, `expected loss is ${q.el}`);
  assert.ok(q.premium > 0n);
  assert.ok(q.premium >= q.el, `premium ${q.premium} below expected loss ${q.el}`);
  assert.ok(q.tvar95 >= q.el);
}

test('quote prices the live book on the Stylus pricer', async () => {
  const q = await quote(client, { book, retention: RETENTION, limit: LIMIT });
  assert.equal(q.pricer, QUOTE_PRICER_ADDRESS);
  assert.ok(q.blockNumber > OIGUARD_BLOCK);
  assertPriced(q);
});

test('a retention above the largest scenario loss leaves no expected loss, and the priced check fails on it', async () => {
  const q = await quote(client, { book, retention: 100_000_000_000_000n, limit: LIMIT });
  assert.equal(q.el, 0n);
  assert.equal(q.tvar95, 0n);
  assert.ok(q.premium > 0n, 'the capital charge on the limit remains');
  assert.throws(() => assertPriced(q), /expected loss is 0/);
});

test('book order matches the table ids the quote desk sets per call', async () => {
  // The quote desk prices only the markets it holds, writing their table ids into the pricer's
  // storage slot 0 for the call. Same numbers from the full six-market vector proves bookVector
  // puts each market on its own table.
  const blockNumber = await client.getBlockNumber();
  const full = await quote(client, { book, retention: RETENTION, limit: LIMIT, blockNumber });
  const ids = [0, 4, 5];
  const slot = `0x${ids.map((i) => i.toString(16).padStart(2, '0')).join('').padEnd(62, '0')}${(ids.length * 2).toString(16).padStart(2, '0')}` as const;
  const [premium, el, tvar95] = await client.readContract({
    address: QUOTE_PRICER_ADDRESS, abi: pricerAbi, functionName: 'quote',
    args: [[book.NVDA, book.EUR, book.XAU], ids.map(() => FEED_ADDRESSES[0]), RETENTION, LIMIT], blockNumber,
    stateOverride: [{ address: QUOTE_PRICER_ADDRESS, stateDiff: [{ slot: `0x${'0'.repeat(64)}`, value: slot }] }],
  });
  assert.deepEqual([full.premium, full.el, full.tvar95], [premium, el, tvar95]);
  assert.deepEqual(MARKETS, ['NVDA', 'AAPL', 'SPY', 'TSLA', 'EUR', 'XAU']);
  assert.throws(() => bookVector({ MSFT: 1n } as never), /No table for MSFT/);
});

test('guardCheck refuses a position that pushes the premium over budget, with the pricer numbers', async () => {
  const blockNumber = await client.getBlockNumber();
  const g = await guardCheck(client, { book, market: 'NVDA', size: 600_000_000_000n, blockNumber });
  const after = await quote(client, { book: { ...book, NVDA: book.NVDA + 600_000_000_000n }, retention: RETENTION, limit: LIMIT, blockNumber });
  const before = await quote(client, { book, retention: RETENTION, limit: LIMIT, blockNumber });
  assert.equal(g.guard, OIGUARD_ADDRESS);
  assert.equal(g.ok, false);
  assert.equal(g.premium, after.premium);
  assert.equal(g.currentPremium, before.premium);
  assert.ok(g.premium > g.budget);
  assert.equal(g.words, ERROR_WORDS.PremiumOverBudget);
});

test('guardCheck accepts a hedge that lowers the premium', async () => {
  const blockNumber = await client.getBlockNumber();
  const g = await guardCheck(client, { book, market: 'XAU', size: -200_000_000_000n, blockNumber });
  const after = await quote(client, { book: { ...book, XAU: 50_000_000_000n }, retention: RETENTION, limit: LIMIT, blockNumber });
  assert.equal(g.ok, true);
  assert.equal(g.premium, after.premium);
});

test('treatyState reads the v3 Treaty', async () => {
  const s = await treatyState(client);
  assert.equal(s.treaty, TREATY_ADDRESS);
  assert.equal(s.pricer.toLowerCase(), PRICER_ADDRESS.toLowerCase());
  assert.equal(s.minRateOnLineBps, 50n);
  assert.equal(s.juniorShareBps, 3_000n);
  assert.ok(s.layerCount >= 1n, `layerCount ${s.layerCount}`);
  assert.deepEqual(s.markets, FEED_ADDRESSES);
  assert.deepEqual(s.books.map((b) => b.symbol), ['USDG', 'USDC']);
  assert.ok(s.books.some((b) => b.vaults.some((v) => v.totalAssets > 0n)), 'some vault holds writer capital');
});

test('bindPreview decodes the Treaty revert into words', async () => {
  const account = '0x000000000000000000000000000000000000dEaD';
  const blockNumber = await client.getBlockNumber();

  const flat = await bindPreview(client, { account, exposure: [0n], retention: 0n, limit: 10_000_000n, blockNumber });
  assert.equal(flat.ok, false);
  assert.equal(flat.ok === false && flat.name, 'BadParams');
  assert.equal(flat.ok === false && flat.words, ERROR_WORDS.BadParams);

  // A real book: before Thursday 19:30 UTC the bind gets past the clock and fails on the dead
  // address's allowance; from the deadline to the week's end it fails on the clock.
  const { timestamp } = await client.getBlock({ blockNumber });
  const [cutoff] = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'weekWindow', args: [timestamp] });
  const real = await bindPreview(client, { account, exposure: [100_000_000_000n], retention: 1_000_000_000n, limit: 10_000_000_000n, blockNumber });
  assert.equal(real.ok, false);
  if (timestamp >= cutoff - 86_400n) assert.equal(real.ok === false && real.name, 'BadTiming');
  else assert.notEqual(real.ok === false && real.name, 'BadTiming');
  assert.ok(real.maxPremium >= (10_000_000_000n * 50n) / 10_000n);
});

test('vaultCoverState reads the deployed VaultCover: the gUSDC book, the covered SPY leg and the renew clock', async () => {
  const v = await vaultCoverState(client);
  assert.equal(v.net.length, 6);
  assert.equal(v.net[2], 153_309_000_000n, 'SPY leg mirrored from the gUSDC book');
  assert.deepEqual(v.coverIndex, [2n]);
  assert.deepEqual(v.coverExposure, [v.net[2]]);
  assert.ok(v.moves.filter((m) => m.kind === 'open').length >= 5, 'five legs opened through the guard');
  assert.ok(v.bookPremium > 0n && v.bookPremium <= v.budget);
  const { timestamp } = await client.getBlock({ blockNumber: v.block });
  const [cutoff] = await client.readContract({ address: '0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807', abi: treatyAbi, functionName: 'weekWindow', args: [timestamp] });
  const windowOpen = timestamp < cutoff - 86_400n && v.coveredUntil <= timestamp;
  if (!windowOpen) assert.equal(v.renew.ok === false && v.renew.name, v.coveredUntil > timestamp ? 'AlreadyCovered' : 'BadTiming');
  assert.equal(VAULT_COVER_ADDRESS, '0xe6085fF7Bf0d37c0Cd865072cA5B434F2c228997');
});

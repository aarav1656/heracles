// node --test --experimental-strip-types src/lib/wallets.test.ts

import assert from 'node:assert/strict';
import test from 'node:test';

const { filterAllowedConnectors } = await import('./wallets.ts');

const rabby = { rdns: 'io.rabby', name: 'Rabby' };
const metamask = { rdns: 'io.metamask', name: 'MetaMask' };
const coinbase = { rdns: 'com.coinbase.wallet', name: 'Coinbase Wallet' };
const phantom = { rdns: 'app.phantom', name: 'Phantom' };

test('keeps only allowlisted wallets', () => {
  const got = filterAllowedConnectors([
    rabby,
    { name: 'Unknown' },
    { rdns: 'io.unknown.wallet', name: 'Unknown' },
    metamask,
    { rdns: undefined, name: 'Legacy injected' },
  ]);
  assert.deepEqual(got, [rabby, metamask]);
});

test('orders by the allowlist rather than discovery order', () => {
  const got = filterAllowedConnectors([phantom, coinbase, metamask, rabby]);
  assert.deepEqual(
    got.map((c) => c.name),
    ['Rabby', 'MetaMask', 'Coinbase Wallet', 'Phantom'],
  );
});

test('empty input stays empty', () => {
  assert.deepEqual(filterAllowedConnectors([]), []);
});

test('real wagmi EIP-6963 connectors: rdns arrives as id, no rdns field', () => {
  const out = filterAllowedConnectors([{ id: 'app.phantom' }, { id: 'injected' }, { id: 'io.rabby' }]);
  assert.deepEqual(out.map((c) => c.id), ['io.rabby', 'app.phantom']);
});

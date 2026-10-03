import { test } from 'node:test';
import assert from 'node:assert/strict';
import { getContractEventsPaged } from './logs.ts';

test('windows never exceed the RPC cap, cover [from, to] exactly once, and keep order', async () => {
  const seen: [bigint, bigint][] = [];
  const client = {
    getContractEvents: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) => {
      assert.ok(toBlock - fromBlock + 1n <= 100_000n, `window ${fromBlock}..${toBlock} exceeds the cap`);
      seen.push([fromBlock, toBlock]);
      return [fromBlock];
    },
  };
  const out = await getContractEventsPaged(client as never, { address: '0x0', abi: [] as const, fromBlock: 1_000n, toBlock: 291_000n });
  assert.ok(seen.length > 1);
  assert.equal(seen[0][0], 1_000n);
  assert.equal(seen.at(-1)![1], 291_000n);
  seen.slice(1).forEach(([f], i) => assert.equal(f, seen[i][1] + 1n));
  assert.deepEqual(out, seen.map(([f]) => f));
});

// The OIGuard on Robinhood Chain testnet, read live: the Stock Token mirror feeds it prices on, the
// premium for the recorded book against the budget, and what the guard says right now about the
// position it refused on chain.
import { BaseError, ContractFunctionRevertedError, createPublicClient, defineChain, http } from 'viem';
import { RH_TESTNET, oiGuardAbi } from '../abi/generated';
import { aggregatorAbi } from '../abi';

export const robinhoodTestnet = defineChain({
  id: RH_TESTNET.chainId,
  name: 'Robinhood Chain testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RH_TESTNET.rpc] } },
  blockExplorers: { default: { name: 'Robinhood explorer', url: RH_TESTNET.explorer } },
});

export type RhFeed = { ticker: string; address: `0x${string}`; price: bigint; updatedAt: bigint };
export type RhGuardRead = {
  block: bigint;
  feeds: RhFeed[];
  bookPremium: bigint;
  budget: bigint;
  refusedNow: { premium: bigint; current: bigint } | { premium: bigint; accepted: true };
};

export async function readRhGuard(): Promise<RhGuardRead> {
  const client = createPublicClient({ chain: robinhoodTestnet, transport: http(RH_TESTNET.rpc) });
  const block = await client.getBlockNumber();
  const g = { address: RH_TESTNET.guard, abi: oiGuardAbi, blockNumber: block } as const;
  const book = RH_TESTNET.book.vector.map((v) => BigInt(v));
  const feeds = await Promise.all(Object.entries(RH_TESTNET.feeds).map(async ([ticker, address]) => {
    const [, answer, , updatedAt] = await client.readContract({ address, abi: aggregatorAbi, functionName: 'latestRoundData', blockNumber: block });
    return { ticker, address, price: answer, updatedAt };
  }));
  const [bookPremium, budget] = await Promise.all([
    client.readContract({ ...g, functionName: 'check', args: [book, 0n, 0n] }),
    client.readContract({ ...g, functionName: 'premiumBudget' }),
  ]);
  let refusedNow: RhGuardRead['refusedNow'];
  try {
    const premium = await client.readContract({ ...g, functionName: 'check', args: [book, 0n, -2_000_000_000_000n] });
    refusedNow = { premium, accepted: true };
  } catch (err) {
    const r = err instanceof BaseError ? err.walk((e) => e instanceof ContractFunctionRevertedError) : null;
    if (!(r instanceof ContractFunctionRevertedError) || r.data?.errorName !== 'PremiumOverBudget') throw err;
    const [premium, , current] = r.data.args as readonly [bigint, bigint, bigint];
    refusedNow = { premium, current };
  }
  return { block, feeds, bookPremium, budget, refusedNow };
}

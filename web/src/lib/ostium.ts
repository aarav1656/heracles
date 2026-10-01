// Ostium's open interest, read the way scripts/ostium_oi_by_group.py reads it: every pair's
// getPairOpeningInterestInfo on TradingStorage (Arbitrum One) at one block, each leg priced with the
// pair's lastTradePrice from Ostium's own subgraph (Ostium prices come from its own oracle network,
// not a per-pair Chainlink feed). Units and prices are 1e18 fixed point.
import { createPublicClient, http, parseAbi } from 'viem';
import { arbitrum } from 'viem/chains';
import { bucketOf, groupOi, type GroupOi, type Bucket, type PairOi } from './ostium-core';

export const TRADING_STORAGE = '0xcCd5891083A8acD2074690F65d3024E7D13d66E7' as const;
export const OSTIUM_SUBGRAPH = 'https://api.subgraph.ormilabs.com/api/public/67a599d5-c8d2-4cc4-9c4d-2975a97bc5d8/subgraphs/ost-prod/live/gn';
export const ARBITRUM_ONE_RPC = 'https://arb1.arbitrum.io/rpc';

const abi = parseAbi(['function getPairOpeningInterestInfo(uint16 pairIndex) view returns (uint256 longOI, uint256 shortOI, uint256 maxOI)']);
const client = createPublicClient({ chain: arbitrum, transport: http(ARBITRUM_ONE_RPC) });

export type OstiumRead = { block: bigint; pairs: PairOi[]; groups: Partial<Record<Bucket, GroupOi>> };

type SubgraphPair = { id: string; from: string; to: string; lastTradePrice: string; group: { name: string } };

async function subgraphPairs(): Promise<SubgraphPair[]> {
  const res = await fetch(OSTIUM_SUBGRAPH, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ query: '{ pairs(first: 200, orderBy: id) { id from to lastTradePrice group { name } } }' }),
  });
  if (!res.ok) throw new Error(`Ostium subgraph answered ${res.status}`);
  const body = (await res.json()) as { data?: { pairs: SubgraphPair[] }; errors?: unknown };
  if (!body.data?.pairs?.length) throw new Error('Ostium subgraph returned no pairs');
  return body.data.pairs;
}

export async function readOstium(): Promise<OstiumRead> {
  const [meta, block] = await Promise.all([subgraphPairs(), client.getBlockNumber()]);
  const oi = await client.multicall({
    blockNumber: block,
    allowFailure: false,
    contracts: meta.map((p) => ({ address: TRADING_STORAGE, abi, functionName: 'getPairOpeningInterestInfo', args: [Number(p.id)] }) as const),
  });
  const pairs: PairOi[] = meta.map((p, i) => {
    const [longRaw, shortRaw] = oi[i];
    const price = Number(BigInt(p.lastTradePrice)) / 1e18;
    return {
      pairIndex: Number(p.id), from: p.from, to: p.to, bucket: bucketOf(p.group.name, p.from),
      longUsd: (Number(longRaw) / 1e18) * price, shortUsd: (Number(shortRaw) / 1e18) * price,
    };
  });
  return { block, pairs, groups: groupOi(pairs) };
}

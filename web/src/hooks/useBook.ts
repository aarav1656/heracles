import type { Address, PublicClient } from 'viem';
import {
  TREATY_ADDRESS, CAPACITY_ADDRESS, PRICER_ADDRESS, USDG_ADDRESS, FEED_ADDRESSES,
  treatyAbi, capacityAbi, pricerAbi, erc20Abi, aggregatorAbi,
} from '../abi';
import { useAtBlock } from './useAtBlock';

export type Layer = {
  id: bigint;
  buyer: Address;
  fridayCutoff: number;
  expiry: number;
  referencedCount: number;
  fixedCount: number;
  state: number;
  buyerClaimed: boolean;
  retention: bigint;
  limit: bigint;
  premium: bigint;
  payout: bigint;
  exposure: bigint[];
  referenceSet: boolean[];
  marketFixed: boolean[];
  fridayPrice: bigint[];
  mondayPrice: bigint[];
};

export type MarketInfo = {
  address: Address;
  latest: { roundId: bigint; answer: bigint; updatedAt: bigint };
  decimals: number;
};

export type BookSnapshot = {
  markets: MarketInfo[];
  capacity: { totalAssets: bigint; locked: bigint; free: bigint; liabilities: bigint; pendingPremium: bigint; balance: bigint; myShares: bigint; myUsdg: bigint; myAllowance: bigint; maxRedeem: bigint };
  layers: Layer[];
  minRateBps: bigint;
};

function toLayer(id: bigint, raw: readonly unknown[], exposure: readonly bigint[], refSet: readonly boolean[], fixed: readonly boolean[], fri: readonly bigint[], mon: readonly bigint[]): Layer {
  const [buyer, fridayCutoff, expiry, referencedCount, fixedCount, state, buyerClaimed, retention, limit, premium, payout] = raw as unknown as [Address, number, number, number, number, number, boolean, bigint, bigint, bigint, bigint];
  return {
    id, buyer, fridayCutoff: Number(fridayCutoff), expiry: Number(expiry),
    referencedCount: Number(referencedCount),
    fixedCount: Number(fixedCount), state: Number(state), buyerClaimed,
    retention, limit, premium, payout,
    exposure: [...exposure], referenceSet: [...refSet], marketFixed: [...fixed], fridayPrice: [...fri], mondayPrice: [...mon],
  };
}

/** The whole treaty book pinned to one block: feeds, capacity, every layer with exposures and fixings. */
export function useBook(account: Address | undefined) {
  return useAtBlock(['book', TREATY_ADDRESS, account ?? 'none'], async (client: PublicClient): Promise<BookSnapshot> => {
    const me = account ?? '0x0000000000000000000000000000000000000000';
    const blockNumber = (await client.getBlock()).number;
    const nMarkets = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'marketsLength', blockNumber });
    const count = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'layerCount', blockNumber });

    const feedReads = FEED_ADDRESSES.flatMap((f) => [
      { address: f, abi: aggregatorAbi, functionName: 'latestRoundData' } as const,
      { address: f, abi: aggregatorAbi, functionName: 'decimals' } as const,
    ]);
    const feedRes = await client.multicall({ blockNumber, allowFailure: false, contracts: feedReads });
    const markets: MarketInfo[] = FEED_ADDRESSES.map((address, i) => {
      const latest = feedRes[i * 2] as unknown as readonly [bigint, bigint, bigint, bigint, bigint];
      return { address, latest: { roundId: latest[0], answer: latest[1], updatedAt: latest[3] }, decimals: Number(feedRes[i * 2 + 1]) };
    });

    const [totalAssets, locked, pendingPremium, capBalance, myShares, myUsdg, myAllowance, maxRedeem] = await client.multicall({
      blockNumber,
      allowFailure: false,
      contracts: [
        { address: CAPACITY_ADDRESS, abi: capacityAbi, functionName: 'totalAssets' },
        { address: CAPACITY_ADDRESS, abi: capacityAbi, functionName: 'locked' },
        { address: CAPACITY_ADDRESS, abi: capacityAbi, functionName: 'pendingPremium' },
        { address: USDG_ADDRESS, abi: erc20Abi, functionName: 'balanceOf', args: [CAPACITY_ADDRESS] },
        { address: CAPACITY_ADDRESS, abi: capacityAbi, functionName: 'balanceOf', args: [me] },
        { address: USDG_ADDRESS, abi: erc20Abi, functionName: 'balanceOf', args: [me] },
        { address: USDG_ADDRESS, abi: erc20Abi, functionName: 'allowance', args: [me, CAPACITY_ADDRESS] },
        { address: CAPACITY_ADDRESS, abi: capacityAbi, functionName: 'maxRedeem', args: [me] },
      ],
    }) as unknown as [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];

    const minRateBps = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'minRateOnLineBps', blockNumber }) as bigint;

    const ids = Array.from({ length: Number(count) }, (_, i) => BigInt(i));
    const layers: Layer[] = [];
    for (const id of ids) {
      const raw = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'layers', args: [id], blockNumber });
      const exposure = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'exposureOf', args: [id], blockNumber });
      const perMarket = await client.multicall({
        blockNumber,
        allowFailure: false,
        contracts: Array.from({ length: Number(nMarkets) }, (_, m) => ([
          { address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'referenceSet', args: [id, BigInt(m)] },
          { address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'marketFixed', args: [id, BigInt(m)] },
          { address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'fridayPrice', args: [id, BigInt(m)] },
          { address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'mondayPrice', args: [id, BigInt(m)] },
        ] as const)).flat(),
      });
      const refSet: boolean[] = [];
      const fixed: boolean[] = [];
      const fri: bigint[] = [];
      const mon: bigint[] = [];
      for (let m = 0; m < Number(nMarkets); m++) {
        refSet.push(perMarket[m * 4] as boolean);
        fixed.push(perMarket[m * 4 + 1] as boolean);
        fri.push(BigInt(perMarket[m * 4 + 2] as bigint));
        mon.push(BigInt(perMarket[m * 4 + 3] as bigint));
      }
      layers.push(toLayer(id, raw as unknown as readonly unknown[], exposure as readonly bigint[], refSet, fixed, fri, mon));
    }

    // Owed but unclaimed payouts: settled layers whose buyer has not pulled yet.
    // They stay reserved inside Capacity.locked until claim, so show them apart.
    const liabilities = layers.reduce(
      (sum, l) => (l.state === 2 && !l.buyerClaimed ? sum + l.payout : sum),
      0n,
    );

    return {
      markets,
      capacity: { totalAssets, locked, free: totalAssets, liabilities, pendingPremium, balance: capBalance, myShares, myUsdg, myAllowance, maxRedeem },
      layers,
      minRateBps,
    };
  }, true);
}

/** Live quote from the deployed Stylus pricer. Returns undefined while inputs are incomplete. */
export function quoteLive(client: PublicClient, exposure: bigint[], retention: bigint, limit: bigint) {
  return client.readContract({
    address: PRICER_ADDRESS, abi: pricerAbi,
    functionName: 'quote', args: [exposure, retention, limit],
  });
}

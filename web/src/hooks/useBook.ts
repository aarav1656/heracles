import type { Address, PublicClient } from 'viem';
import {
  TREATY_ADDRESS, PRICER_ADDRESS, FEED_ADDRESSES, BOOKS,
  treatyAbi, capacityAbi, pricerAbi, erc20Abi, aggregatorAbi,
  type BookConfig,
} from '../abi';
import { useAtBlock } from './useAtBlock';

export type Layer = {
  id: bigint;
  buyer: Address;
  fridayCutoff: number;
  expiry: number;
  book: number;
  referencedCount: number;
  fixedCount: number;
  state: number;
  buyerClaimed: boolean;
  retention: bigint;
  limit: bigint;
  juniorLimit: bigint;
  premium: bigint;
  premiumJunior: bigint;
  premiumSenior: bigint;
  payout: bigint;
  payoutJunior: bigint;
  payoutSenior: bigint;
  exposure: bigint[];
  referenceSet: boolean[];
  referenceVoid: boolean[];
  marketFixed: boolean[];
  fridayPrice: bigint[];
  mondayPrice: bigint[];
};

export type MarketInfo = {
  address: Address;
  latest: { roundId: bigint; answer: bigint; updatedAt: bigint };
  decimals: number;
};

/** One ERC-4626 vault of a book, read at the pinned block. `free` is what a writer can still take out. */
export type VaultView = {
  address: Address;
  totalAssets: bigint;
  locked: bigint;
  owed: bigint;
  pendingPremium: bigint;
  balance: bigint;
  free: bigint;
  gateActive: boolean;
  myShares: bigint;
  maxRedeem: bigint;
};

/** One book: a single asset backed by a first-loss vault and a senior vault. */
export type BookView = BookConfig & {
  firstLossVault: VaultView;
  seniorVault: VaultView;
  myAsset: bigint;
  /** The caller's allowance of the book asset to the Treaty (premium pulls). */
  myAllowance: bigint;
};

export type BookSnapshot = {
  markets: MarketInfo[];
  books: BookView[];
  layers: Layer[];
  minRateBps: bigint;
  /** Share of every layer's limit the first-loss vault takes, in bps (immutable at deploy). */
  juniorShareBps: bigint;
};

/** Both vaults of a book summed: what the book can promise and what it holds. */
export function bookTotals(b: BookView) {
  const v = [b.firstLossVault, b.seniorVault];
  const sum = (f: (x: VaultView) => bigint) => v.reduce((n, x) => n + f(x), 0n);
  return {
    totalAssets: sum((x) => x.totalAssets), locked: sum((x) => x.locked), owed: sum((x) => x.owed),
    pendingPremium: sum((x) => x.pendingPremium), balance: sum((x) => x.balance), free: sum((x) => x.free),
    gateActive: v.some((x) => x.gateActive),
  };
}

function toLayer(id: bigint, raw: readonly unknown[], exposure: readonly bigint[], refSet: readonly boolean[], refVoid: readonly boolean[], fixed: readonly boolean[], fri: readonly bigint[], mon: readonly bigint[]): Layer {
  const [buyer, fridayCutoff, expiry, book, referencedCount, fixedCount, state, buyerClaimed, retention, limit, juniorLimit, premium, premiumJunior, premiumSenior, payout, payoutJunior, payoutSenior] = raw as unknown as [Address, number, number, number, number, number, number, boolean, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint];
  return {
    id, buyer, fridayCutoff: Number(fridayCutoff), expiry: Number(expiry), book: Number(book),
    referencedCount: Number(referencedCount),
    fixedCount: Number(fixedCount), state: Number(state), buyerClaimed,
    retention, limit, juniorLimit, premium, premiumJunior, premiumSenior, payout, payoutJunior, payoutSenior,
    exposure: [...exposure], referenceSet: [...refSet], referenceVoid: [...refVoid], marketFixed: [...fixed], fridayPrice: [...fri], mondayPrice: [...mon],
  };
}

/** The whole treaty pinned to one block: feeds, every book's two vaults, every layer with exposures and fixings. */
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

    // Per book: asset balance and Treaty allowance of the caller, then 8 reads for each of the two vaults.
    const PER_VAULT = 8;
    const bookReads = BOOKS.flatMap((b) => [
      { address: b.asset, abi: erc20Abi, functionName: 'balanceOf', args: [me] } as const,
      { address: b.asset, abi: erc20Abi, functionName: 'allowance', args: [me, TREATY_ADDRESS] } as const,
      ...[b.firstLoss, b.senior].flatMap((v) => [
        { address: v, abi: capacityAbi, functionName: 'totalAssets' } as const,
        { address: v, abi: capacityAbi, functionName: 'locked' } as const,
        { address: v, abi: capacityAbi, functionName: 'owed' } as const,
        { address: v, abi: capacityAbi, functionName: 'pendingPremium' } as const,
        { address: b.asset, abi: erc20Abi, functionName: 'balanceOf', args: [v] } as const,
        { address: v, abi: capacityAbi, functionName: 'gateActive' } as const,
        { address: v, abi: capacityAbi, functionName: 'balanceOf', args: [me] } as const,
        { address: v, abi: capacityAbi, functionName: 'maxRedeem', args: [me] } as const,
      ]),
    ]);
    const bookRes = await client.multicall({ blockNumber, allowFailure: false, contracts: bookReads }) as unknown as (bigint | boolean)[];
    const stride = 2 + 2 * PER_VAULT;
    const books: BookView[] = BOOKS.map((b, i) => {
      const r = bookRes.slice(i * stride, (i + 1) * stride);
      const vault = (address: Address, o: number): VaultView => {
        const [totalAssets, locked, owed, pendingPremium, balance, gateActive, myShares, maxRedeem] = r.slice(2 + o, 2 + o + PER_VAULT) as [bigint, bigint, bigint, bigint, bigint, boolean, bigint, bigint];
        return { address, totalAssets, locked, owed, pendingPremium, balance, free: totalAssets > locked ? totalAssets - locked : 0n, gateActive, myShares, maxRedeem };
      };
      return { ...b, myAsset: r[0] as bigint, myAllowance: r[1] as bigint, firstLossVault: vault(b.firstLoss, 0), seniorVault: vault(b.senior, PER_VAULT) };
    });

    const minRateBps = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'minRateOnLineBps', blockNumber }) as bigint;
    const juniorShareBps = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'juniorShareBps', blockNumber }) as bigint;

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
          { address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'referenceVoid', args: [id, BigInt(m)] },
          { address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'marketFixed', args: [id, BigInt(m)] },
          { address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'fridayPrice', args: [id, BigInt(m)] },
          { address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'mondayPrice', args: [id, BigInt(m)] },
        ] as const)).flat(),
      });
      const refSet: boolean[] = [];
      const refVoid: boolean[] = [];
      const fixed: boolean[] = [];
      const fri: bigint[] = [];
      const mon: bigint[] = [];
      for (let m = 0; m < Number(nMarkets); m++) {
        refSet.push(perMarket[m * 5] as boolean);
        refVoid.push(perMarket[m * 5 + 1] as boolean);
        fixed.push(perMarket[m * 5 + 2] as boolean);
        fri.push(BigInt(perMarket[m * 5 + 3] as bigint));
        mon.push(BigInt(perMarket[m * 5 + 4] as bigint));
      }
      layers.push(toLayer(id, raw as unknown as readonly unknown[], exposure as readonly bigint[], refSet, refVoid, fixed, fri, mon));
    }

    return { markets, books, layers, minRateBps, juniorShareBps };
  }, true);
}

/** Live quote from the deployed Stylus pricer. Returns undefined while inputs are incomplete. */
export function quoteLive(client: PublicClient, exposure: bigint[], retention: bigint, limit: bigint, blockNumber?: bigint) {
  return client.readContract({
    address: PRICER_ADDRESS, abi: pricerAbi,
    functionName: 'quote', args: [exposure, FEED_ADDRESSES.slice(0, exposure.length), retention, limit],
    blockNumber,
  });
}

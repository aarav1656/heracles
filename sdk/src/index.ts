// Typed reads against the Heracles contracts on Arbitrum Sepolia: the six-table Stylus pricer, the
// Treaty, and the OIGuard a perp venue calls before accepting open interest. Every result carries
// the block it was read at. Amounts are 6-decimal fixed point (USDC/USDG base units).
import { createPublicClient, http, type Address, type PublicClient } from 'viem';
import { arbitrumSepolia } from 'viem/chains';
import {
  BOOKS,
  FEED_ADDRESSES,
  OIGUARD_ADDRESS,
  PRICER_ADDRESS,
  QUOTE_PRICER_ADDRESS,
  RPC_URL,
  TREATY_ADDRESS,
  capacityAbi,
  oiGuardAbi,
  pricerAbi,
  treatyAbi,
} from '../../web/src/abi/generated';
export { MARKETS, bookVector, guardCheck, quoteBook as quote, quoteText, type Book, type GuardCheck, type Quote, type Ticker } from '../../web/src/lib/book';
import { explainError, type Explained } from '../../web/src/lib/revert';
import { ERROR_WORDS } from '../../web/src/lib/treaty';

export { BOOKS, FEED_ADDRESSES, OIGUARD_ADDRESS, PRICER_ADDRESS, QUOTE_PRICER_ADDRESS, TREATY_ADDRESS };
export { capacityAbi, oiGuardAbi, pricerAbi, treatyAbi, ERROR_WORDS };
export type { Explained };
export { parseExposure, parseUsdg, fmtUsdg2 } from '../../web/src/lib/format';

export function heraclesClient(rpcUrl: string = RPC_URL): PublicClient {
  return createPublicClient({ chain: arbitrumSepolia, transport: http(rpcUrl) }) as PublicClient;
}

const at = async (client: PublicClient, blockNumber?: bigint) => blockNumber ?? (await client.getBlockNumber());

export type BookState = { symbol: string; asset: Address; vaults: { role: 'firstLoss' | 'senior'; address: Address; totalAssets: bigint; locked: bigint }[] };
export type TreatyState = {
  blockNumber: bigint;
  treaty: Address;
  pricer: Address;
  minRateOnLineBps: bigint;
  juniorShareBps: bigint;
  layerCount: bigint;
  markets: Address[];
  books: BookState[];
};

/** The Treaty's terms, layer count, markets and every vault's assets and locked capital at one block. */
export async function treatyState(client: PublicClient, { blockNumber }: { blockNumber?: bigint } = {}): Promise<TreatyState> {
  const block = await at(client, blockNumber);
  const read = <F extends 'pricer' | 'minRateOnLineBps' | 'juniorShareBps' | 'layerCount' | 'marketsLength'>(functionName: F) =>
    client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName, blockNumber: block });
  const [pricer, minRateOnLineBps, juniorShareBps, layerCount, marketsLength] = await Promise.all([
    read('pricer'), read('minRateOnLineBps'), read('juniorShareBps'), read('layerCount'), read('marketsLength'),
  ]);
  const markets = await Promise.all(
    Array.from({ length: Number(marketsLength) }, (_, i) =>
      client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'markets', args: [BigInt(i)], blockNumber: block })),
  );
  const books = await Promise.all(BOOKS.map(async (b) => ({
    symbol: b.symbol,
    asset: b.asset,
    vaults: await Promise.all((['firstLoss', 'senior'] as const).map(async (role) => {
      const address = b[role];
      const [totalAssets, locked] = await Promise.all([
        client.readContract({ address, abi: capacityAbi, functionName: 'totalAssets', blockNumber: block }),
        client.readContract({ address, abi: capacityAbi, functionName: 'locked', blockNumber: block }),
      ]);
      return { role, address, totalAssets, locked };
    })),
  })));
  return { blockNumber: block, treaty: TREATY_ADDRESS, pricer, minRateOnLineBps, juniorShareBps, layerCount, markets, books };
}

export type BindPreview =
  | { ok: true; id: bigint; maxPremium: bigint; blockNumber: bigint }
  | ({ ok: false; maxPremium: bigint; blockNumber: bigint } & Explained);

/**
 * Simulates `Treaty.bind` from `account` and returns the layer id it would get, or the revert as a
 * custom error name plus plain words. `exposure` follows the Treaty's own markets (`treatyState`).
 * `maxPremium` defaults to the premium the Treaty would charge: the pricer quote, floored at
 * `limit * minRateOnLineBps / 1e4`.
 */
export async function bindPreview(
  client: PublicClient,
  { account, book = 0, exposure, retention, limit, maxPremium, blockNumber }:
    { account: Address; book?: number; exposure: bigint[]; retention: bigint; limit: bigint; maxPremium?: bigint; blockNumber?: bigint },
): Promise<BindPreview> {
  const block = await at(client, blockNumber);
  let cap = maxPremium;
  if (cap === undefined) {
    const { minRateOnLineBps: minRate, markets } = await treatyState(client, { blockNumber: block });
    const floor = (limit * minRate) / 10_000n;
    try {
      const [p] = await client.readContract({
        address: PRICER_ADDRESS, abi: pricerAbi, functionName: 'quote', args: [exposure, markets, retention, limit], blockNumber: block,
      });
      cap = p > floor ? p : floor;
    } catch {
      // The Treaty reverts on these terms before it prices them; let the bind simulation name why.
      cap = floor;
    }
  }
  try {
    const { result } = await client.simulateContract({
      account, address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'bind',
      args: [BigInt(book), exposure, retention, limit, cap], blockNumber: block,
    });
    return { ok: true, id: result, maxPremium: cap, blockNumber: block };
  } catch (err) {
    return { ok: false, maxPremium: cap, blockNumber: block, ...explainError(err) };
  }
}

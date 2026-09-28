import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { quoteLive } from './useBook';
import { REFERENCE } from '../lib/gaps';

const U = 1_000_000n;

/** The README reference layer, re-quoted by the deployed Stylus pricer at the latest block. */
export function useReferenceQuote() {
  const client = usePublicClient() as PublicClient | undefined;
  return useQuery({
    queryKey: ['refQuote'],
    enabled: !!client,
    refetchInterval: 60_000,
    retry: 1,
    queryFn: async () => {
      const c = client as PublicClient;
      const block = await c.getBlockNumber();
      const [premium, el, tvar] = (await quoteLive(
        c, [BigInt(REFERENCE.exposure) * U], BigInt(REFERENCE.retention) * U, BigInt(REFERENCE.limit) * U, block,
      )) as unknown as [bigint, bigint, bigint];
      return { premium, el, tvar, block };
    },
  });
}

import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';

export type AtBlock<T> = { value: T; block: bigint; timestamp: bigint };

/**
 * Read a set of values pinned to one block. The block is fetched first, then every read inside
 * `fn` is made with that blockNumber, so "read at block N" is literally true for all of them.
 */
export function useAtBlock<T>(key: readonly unknown[], fn: (client: PublicClient, block: bigint) => Promise<T>, enabled = true) {
  const client = usePublicClient();
  return useQuery({
    queryKey: ['atBlock', ...key],
    enabled: enabled && !!client,
    refetchInterval: 15_000,
    retry: 1,
    queryFn: async (): Promise<AtBlock<T>> => {
      const c = client as PublicClient;
      const b = await c.getBlock();
      const value = await fn(c, b.number);
      return { value, block: b.number, timestamp: b.timestamp };
    },
  });
}

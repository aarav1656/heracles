import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import type { Address, PublicClient } from 'viem';
import { aggregatorAbi } from '../abi';

/** Latest round of a feed, re-read every 30 s so the age shown is what `bind` would see. */
export function useFeedAge(feed: Address) {
  const client = usePublicClient() as PublicClient | undefined;
  return useQuery({
    queryKey: ['feed-latest', feed],
    enabled: !!client,
    refetchInterval: 30_000,
    queryFn: async () => {
      const [roundId, , , updatedAt] = await (client as PublicClient).readContract({ address: feed, abi: aggregatorAbi, functionName: 'latestRoundData' });
      const block = await (client as PublicClient).getBlockNumber();
      return { roundId, updatedAt, block };
    },
  });
}

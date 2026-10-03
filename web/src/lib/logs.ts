import type { Abi, ContractEventName, GetContractEventsReturnType, PublicClient } from 'viem';

// Arbitrum's public RPC refuses a topic-filtered eth_getLogs over more than 100,000 blocks
// ("query spans N blocks ... only 100000 are allowed"), so a read from a deploy block fails once the chain outgrows that.
const MAX_SPAN = 90_000n;

/** Every event of `address` in [fromBlock, toBlock], fetched in RPC-sized windows in parallel and returned in log order. */
export async function getContractEventsPaged<const abi extends Abi>(
  client: PublicClient,
  args: { address: `0x${string}`; abi: abi; fromBlock: bigint; toBlock: bigint },
): Promise<GetContractEventsReturnType<abi, ContractEventName<abi> | undefined, undefined, bigint, bigint>> {
  const windows: Promise<GetContractEventsReturnType<abi, ContractEventName<abi> | undefined, undefined, bigint, bigint>>[] = [];
  // ponytail: window count grows with chain age (about 4 a day at 0.25 s blocks); move to an indexer or a moving start block if it passes ~30.
  for (let from = args.fromBlock; from <= args.toBlock; from += MAX_SPAN) {
    const to = from + MAX_SPAN - 1n < args.toBlock ? from + MAX_SPAN - 1n : args.toBlock;
    windows.push(client.getContractEvents({ address: args.address, abi: args.abi, fromBlock: from, toBlock: to }) as never);
  }
  return (await Promise.all(windows)).flat() as never;
}

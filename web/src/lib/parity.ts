// The six-table Stylus pricer on Arbitrum Sepolia and on Robinhood Chain testnet, asked the same
// question at the same moment: EUR/USD long 2,000,000, retention 2,000, limit 20,000. The two chains
// carry different feeds, so both calls put the same flat feed (MockFeed, nine rounds) at one address
// in an eth_call state override, as scripts/pricer_parity.py does. The table alone then sets the price,
// which scripts/fx_gold_fair_premium.py computes from the evidence file as 1,977.298772.
import { createPublicClient, encodeAbiParameters, http, keccak256, numberToHex, pad, type Address, type PublicClient } from 'viem';
import { MOCK_FEED_RUNTIME, QUOTE_PRICER_ADDRESS, RH_SIX_TABLE_PRICER, pricerAbi } from '../abi/generated';
import { robinhoodTestnet } from './rhGuard';

const FEED: Address = '0x00000000000000000000000000000000000feed1';
const EXPOSURE = [0n, 0n, 0n, 0n, 2_000_000_000_000n, 0n];
const RETENTION = 2_000_000_000n;
const LIMIT = 20_000_000_000n;
export const PYTHON_PREMIUM = 1_977_298_772n;

function feedOverride(now: bigint) {
  const slot = (i: bigint) => BigInt(keccak256(encodeAbiParameters([{ type: 'uint80' }, { type: 'uint256' }], [i, 0n])));
  const word = (v: bigint) => pad(numberToHex(v), { size: 32 });
  const stateDiff = [{ slot: word(1n), value: word(9n) }];
  for (let i = 1n; i <= 9n; i++) {
    stateDiff.push({ slot: word(slot(i)), value: word(500_00000000n) });
    stateDiff.push({ slot: word(slot(i) + 1n), value: word(now - (9n - i) * 3600n) });
  }
  return [{ address: FEED, code: MOCK_FEED_RUNTIME, stateDiff }];
}

export type ParityRead = { sepolia: readonly [bigint, bigint, bigint]; robinhood: readonly [bigint, bigint, bigint]; sepoliaBlock: bigint; robinhoodBlock: bigint };

export async function readParity(sepolia: PublicClient): Promise<ParityRead> {
  const rh = createPublicClient({ chain: robinhoodTestnet, transport: http(robinhoodTestnet.rpcUrls.default.http[0]) });
  const [sepoliaBlock, robinhoodBlock] = await Promise.all([sepolia.getBlockNumber(), rh.getBlockNumber()]);
  const { timestamp } = await sepolia.getBlock({ blockNumber: sepoliaBlock });
  const ask = (c: PublicClient, address: Address, blockNumber: bigint) => c.readContract({
    address, abi: pricerAbi, functionName: 'quote', args: [EXPOSURE, EXPOSURE.map(() => FEED), RETENTION, LIMIT],
    blockNumber, stateOverride: feedOverride(timestamp),
  });
  const [a, b] = await Promise.all([ask(sepolia, QUOTE_PRICER_ADDRESS, sepoliaBlock), ask(rh as PublicClient, RH_SIX_TABLE_PRICER, robinhoodBlock)]);
  return { sepolia: a, robinhood: b, sepoliaBlock, robinhoodBlock };
}

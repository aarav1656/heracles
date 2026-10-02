// The gTrade gUSDC vault's weekend book, read from gTrade's Diamond on Arbitrum One. Gains' docs:
// "Vaults serve as a counterparty to all trades made on the platform", so the gUSDC vault holds the
// opposite of what traders hold net on every pair. Open interest is kept per collateral; the gUSDC
// vault's book is the USDC collateral (index 3), the pre-v10 and v10 legs summed, as position size
// at open in USDC. Imports viem only, so node runs it for the saved read (scripts/save-gains-book.mjs).
import { createPublicClient, http, parseAbi } from 'viem';
import { arbitrum } from 'viem/chains';

export const GAINS_DIAMOND = '0xFF162c694eAA571f685030649814282eA457f169' as const;
export const GUSDC = '0xd3443ee1e91aF28e5FB858Fbd0D72A63bA8046E0' as const;
export const USDC_COLLATERAL = 3;
export const ARBITRUM_ONE_RPC = 'https://arb1.arbitrum.io/rpc';

/** gTrade's pair index for each priced market; every read checks it against `pairs(i)` on the Diamond. */
export const GAINS_PAIRS = [
  { ticker: 'SPY', pairIndex: 86 },
  { ticker: 'NVDA', pairIndex: 65 },
  { ticker: 'AAPL', pairIndex: 58 },
  { ticker: 'TSLA', pairIndex: 63 },
  { ticker: 'EUR', pairIndex: 21 },
  { ticker: 'XAU', pairIndex: 90 },
] as const;

const abi = parseAbi([
  'function getPairOiAfterV10Collateral(uint8 collateralIndex, uint16 pairIndex) view returns (uint128 oiLongCollateral, uint128 oiShortCollateral)',
  'function getPairOisBeforeV10Collateral(uint8 collateralIndex, uint16 pairIndex) view returns (uint256 longOi, uint256 shortOi)',
  'function pairs(uint256 index) view returns ((string from, string to, (address feed1, address feed2, uint8 feedCalculation, uint256 maxDeviationP) feed, uint256 spreadP, uint256 groupIndex, uint256 feeIndex))',
  'function totalAssets() view returns (uint256)',
]);

export type GainsPair = { ticker: string; pairIndex: number; longUsd: number; shortUsd: number };
export type GainsRead = { block: bigint; vaultAssetsUsd: number; pairs: GainsPair[] };

/** The vault's own position is the opposite of the traders' net. Positive is long (loses when the market falls). */
export const vaultExposureUsd = (traderLongUsd: number, traderShortUsd: number) => traderShortUsd - traderLongUsd;

const usdc = (v: bigint) => Number(v) / 1e6;

export async function readGains(rpcUrl: string = ARBITRUM_ONE_RPC): Promise<GainsRead> {
  const client = createPublicClient({ chain: arbitrum, transport: http(rpcUrl) });
  const block = await client.getBlockNumber();
  const [names, after, before, assets] = await Promise.all([
    client.multicall({ blockNumber: block, allowFailure: false, contracts: GAINS_PAIRS.map((p) => ({ address: GAINS_DIAMOND, abi, functionName: 'pairs', args: [BigInt(p.pairIndex)] }) as const) }),
    client.multicall({ blockNumber: block, allowFailure: false, contracts: GAINS_PAIRS.map((p) => ({ address: GAINS_DIAMOND, abi, functionName: 'getPairOiAfterV10Collateral', args: [USDC_COLLATERAL, p.pairIndex] }) as const) }),
    client.multicall({ blockNumber: block, allowFailure: false, contracts: GAINS_PAIRS.map((p) => ({ address: GAINS_DIAMOND, abi, functionName: 'getPairOisBeforeV10Collateral', args: [USDC_COLLATERAL, p.pairIndex] }) as const) }),
    client.readContract({ address: GUSDC, abi, functionName: 'totalAssets', blockNumber: block }),
  ]);
  const pairs = GAINS_PAIRS.map((p, i) => {
    const { from, to } = names[i];
    if (from !== p.ticker || to !== 'USD') throw new Error(`gTrade pair ${p.pairIndex} is ${from}/${to}, not ${p.ticker}/USD`);
    return {
      ticker: p.ticker, pairIndex: p.pairIndex,
      longUsd: usdc(after[i][0] + before[i][0]), shortUsd: usdc(after[i][1] + before[i][1]),
    };
  });
  return { block, vaultAssetsUsd: usdc(assets), pairs };
}

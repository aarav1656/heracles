// The landing tour's Arbitrum Sepolia read, all at one block: the USDG book's vaults, layer 0 of the
// USDC book (bound, referenced, then fixed on Monday), and the OIGuard's verdict on the VaultCover book
// plus 2,000,000 more NVDA short.
import { BaseError, ContractFunctionRevertedError, type PublicClient } from 'viem';
import { BOOKS, OIGUARD_ADDRESS, TREATY_ADDRESS, VAULT_COVER_ADDRESS, capacityAbi, oiGuardAbi, treatyAbi, vaultCoverAbi } from '../abi/generated';
import { LAYER_STATES } from './treaty';

export const PROBE_SIZE = -2_000_000_000_000n; // 2,000,000 more NVDA short, book market 0

export type GuardVerdict = { premium: bigint; budget: bigint; current: bigint; refused: boolean };

export async function guardVerdict(read: () => Promise<bigint>, budget: bigint): Promise<GuardVerdict> {
  try {
    const premium = await read();
    return { premium, budget, current: premium, refused: false };
  } catch (err) {
    const r = err instanceof BaseError ? err.walk((e) => e instanceof ContractFunctionRevertedError) : null;
    if (!(r instanceof ContractFunctionRevertedError) || r.data?.errorName !== 'PremiumOverBudget') throw err;
    const [premium, , current] = r.data.args as readonly [bigint, bigint, bigint];
    return { premium, budget, current, refused: true };
  }
}

export type TourRead = {
  block: bigint;
  timestamp: bigint;
  usdg: { firstLoss: bigint; senior: bigint };
  layer0: { state: (typeof LAYER_STATES)[number]; expiry: bigint; premium: bigint; payout: bigint; referenced: boolean; fridayPrice: bigint; mondayPrice: bigint };
  guard: GuardVerdict;
};

export async function readTour(client: PublicClient): Promise<TourRead> {
  const block = await client.getBlockNumber();
  const at = { blockNumber: block } as const;
  const usdg = BOOKS[0];
  const [{ timestamp }, firstLoss, senior, layer, referenced, fridayPrice, mondayPrice, net, budget] = await Promise.all([
    client.getBlock({ blockNumber: block }),
    client.readContract({ address: usdg.firstLoss, abi: capacityAbi, functionName: 'totalAssets', ...at }),
    client.readContract({ address: usdg.senior, abi: capacityAbi, functionName: 'totalAssets', ...at }),
    client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'layers', args: [0n], ...at }),
    client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'referenceSet', args: [0n, 0n], ...at }),
    client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'fridayPrice', args: [0n, 0n], ...at }),
    client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'mondayPrice', args: [0n, 0n], ...at }),
    client.readContract({ address: VAULT_COVER_ADDRESS, abi: vaultCoverAbi, functionName: 'net', ...at }),
    client.readContract({ address: OIGUARD_ADDRESS, abi: oiGuardAbi, functionName: 'premiumBudget', ...at }),
  ]);
  const guard = await guardVerdict(
    () => client.readContract({ address: OIGUARD_ADDRESS, abi: oiGuardAbi, functionName: 'check', args: [net, 0n, PROBE_SIZE], ...at }),
    budget,
  );
  // layers(): buyer, fridayCutoff, expiry, book, referencedCount, fixedCount, state, buyerClaimed, retention, limit,
  // juniorLimit, premium, premiumJunior, premiumSenior, payout, payoutJunior, payoutSenior
  const l = layer as readonly unknown[];
  return {
    block,
    timestamp,
    usdg: { firstLoss, senior },
    layer0: {
      state: LAYER_STATES[Number(l[6])], expiry: BigInt(l[2] as number | bigint), premium: l[11] as bigint, payout: l[14] as bigint,
      referenced, fridayPrice: BigInt(fridayPrice), mondayPrice: BigInt(mondayPrice),
    },
    guard,
  };
}

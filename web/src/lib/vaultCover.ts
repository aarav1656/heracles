// The live state of the VaultCover on Arbitrum Sepolia, read at one block: the vault's book, the
// leg the Treaty covers, the guard's premium for the book against its budget, the premium funds
// held, what renewCover would do right now, and every open and close since deploy.
import { erc20Abi, type Hash, type PublicClient } from 'viem';
import { OIGUARD_ADDRESS, VAULT_COVER_ADDRESS, VAULT_COVER_DEPLOY_BLOCK, oiGuardAbi, treatyAbi, vaultCoverAbi } from '../abi/generated';
import { explainError, type Explained } from './revert';

export type BookMove = { kind: 'open' | 'close'; market: number; delta: bigint; net: bigint; premium?: bigint; tx: Hash; block: bigint };

export type VaultCoverRead = {
  block: bigint;
  owner: `0x${string}`;
  net: readonly bigint[];
  coverIndex: readonly bigint[];
  coverExposure: readonly bigint[];
  retention: bigint;
  limit: bigint;
  maxPremium: bigint;
  funds: bigint;
  layers: readonly bigint[];
  /** The covered legs as the current layer bound them, and the Monday open they are held until. */
  bound: readonly bigint[];
  coveredUntil: bigint;
  bookPremium: bigint;
  budget: bigint;
  renew: { ok: true; id: bigint } | ({ ok: false } & Explained);
  moves: BookMove[];
};

export async function readVaultCover(client: PublicClient): Promise<VaultCoverRead> {
  const block = await client.getBlockNumber();
  const c = { address: VAULT_COVER_ADDRESS, abi: vaultCoverAbi, blockNumber: block } as const;
  const [owner, net, coverIndex, coverExposure, retention, limit, maxPremium, layers, asset, bound, coveredUntil] = await Promise.all([
    client.readContract({ ...c, functionName: 'owner' }),
    client.readContract({ ...c, functionName: 'net' }),
    client.readContract({ ...c, functionName: 'coverIndex' }),
    client.readContract({ ...c, functionName: 'coverExposure' }),
    client.readContract({ ...c, functionName: 'retention' }),
    client.readContract({ ...c, functionName: 'limit' }),
    client.readContract({ ...c, functionName: 'maxPremium' }),
    client.readContract({ ...c, functionName: 'layers' }),
    client.readContract({ ...c, functionName: 'asset' }),
    client.readContract({ ...c, functionName: 'bound' }),
    client.readContract({ ...c, functionName: 'coveredUntil' }),
  ]);
  const [funds, bookPremium, budget] = await Promise.all([
    client.readContract({ address: asset, abi: erc20Abi, functionName: 'balanceOf', args: [VAULT_COVER_ADDRESS], blockNumber: block }),
    // A zero-size check prices the book as it stands and never refuses it.
    client.readContract({ address: OIGUARD_ADDRESS, abi: oiGuardAbi, functionName: 'check', args: [net, 0n, 0n], blockNumber: block }),
    client.readContract({ address: OIGUARD_ADDRESS, abi: oiGuardAbi, functionName: 'premiumBudget', blockNumber: block }),
  ]);
  let renew: VaultCoverRead['renew'];
  try {
    // The Treaty's errors (BadTiming, PremiumTooHigh, ...) bubble up through renewCover, so decode with both ABIs.
    const { result } = await client.simulateContract({
      address: VAULT_COVER_ADDRESS, abi: [...vaultCoverAbi, ...treatyAbi], blockNumber: block, account: owner, functionName: 'renewCover',
    });
    renew = { ok: true, id: result };
  } catch (e) {
    renew = { ok: false, ...explainError(e) };
  }
  // ponytail: one getLogs from the deploy block; page it once the range outgrows the RPC's cap.
  const logs = await client.getContractEvents({
    address: VAULT_COVER_ADDRESS, abi: vaultCoverAbi, fromBlock: VAULT_COVER_DEPLOY_BLOCK, toBlock: block,
  });
  const moves: BookMove[] = [];
  for (const l of logs) {
    if (l.eventName === 'Opened') {
      moves.push({ kind: 'open', market: Number(l.args.market), delta: l.args.delta!, net: l.args.net!, premium: l.args.premium, tx: l.transactionHash, block: l.blockNumber });
    } else if (l.eventName === 'Closed') {
      moves.push({ kind: 'close', market: Number(l.args.market), delta: l.args.delta!, net: l.args.net!, tx: l.transactionHash, block: l.blockNumber });
    }
  }
  return { block, owner, net, coverIndex, coverExposure, retention, limit, maxPremium, funds, layers, bound, coveredUntil, bookPremium, budget, renew, moves };
}

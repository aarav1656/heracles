import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  decodeErrorResult,
  type Abi,
  type Hex,
  type PublicClient,
  type TransactionReceipt,
} from 'viem';
import { ERROR_WORDS } from './treaty';

export type Explained = { name: string; words: string };

/** Turn any thrown error from simulate/write into a custom error name plus plain words. */
export function explainError(err: unknown): Explained {
  if (err instanceof BaseError) {
    const rejected = err.walk((e) => e instanceof UserRejectedRequestError);
    if (rejected) return { name: 'Rejected', words: 'The wallet rejected the request.' };
    const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName ?? reverted.reason ?? 'Reverted';
      return { name, words: ERROR_WORDS[name] ?? reverted.shortMessage };
    }
    if (/insufficient funds/i.test(err.shortMessage)) {
      return { name: 'InsufficientFunds', words: 'The wallet holds too little ETH on Arbitrum Sepolia for gas.' };
    }
    return { name: err.name, words: err.shortMessage };
  }
  return { name: 'Error', words: err instanceof Error ? err.message : String(err) };
}

/** A mined-but-reverted tx carries no reason. Replay it as eth_call at its block and decode the custom error. */
export async function explainReceipt(client: PublicClient, abi: Abi, receipt: TransactionReceipt): Promise<Explained> {
  const tx = await client.getTransaction({ hash: receipt.transactionHash });
  try {
    await client.call({ account: tx.from, to: tx.to ?? undefined, data: tx.input, value: tx.value, blockNumber: receipt.blockNumber });
    return { name: 'Reverted', words: `The transaction reverted on chain but the replay at block ${receipt.blockNumber} succeeds. State moved between the two.` };
  } catch (err) {
    const data = (err instanceof BaseError ? (err.walk((e) => 'data' in (e as object)) as { data?: Hex } | null)?.data : undefined);
    if (data && data !== '0x') {
      try {
        const decoded = decodeErrorResult({ abi, data });
        return { name: decoded.errorName, words: ERROR_WORDS[decoded.errorName] ?? decoded.errorName };
      } catch {
        return { name: 'Reverted', words: `Reverted with undecodable data ${data.slice(0, 18)}…` };
      }
    }
    return explainError(err);
  }
}

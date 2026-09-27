import { useCallback, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { usePublicClient, useWriteContract } from 'wagmi';
import type { Abi, Address, Hash, PublicClient } from 'viem';
import { arbitrumSepolia } from '../chain';
import { explainError, explainReceipt, type Explained } from '../lib/revert';

export type TxStatus = 'idle' | 'simulating' | 'wallet' | 'mining' | 'done' | 'error';

export type TxCall = { address: Address; abi: Abi; functionName: string; args: readonly unknown[]; account: Address };

/**
 * simulate -> sign -> wait -> (if mined and reverted) replay for the custom error name.
 * Every failure surfaces as { name, words }; nothing is swallowed.
 */
export function useTx() {
  const client = usePublicClient() as PublicClient;
  const { writeContractAsync } = useWriteContract();
  const qc = useQueryClient();
  const [status, setStatus] = useState<TxStatus>('idle');
  const [hash, setHash] = useState<Hash>();
  const [error, setError] = useState<Explained>();

  const run = useCallback(async (call: TxCall): Promise<boolean> => {
    setError(undefined);
    setHash(undefined);
    try {
      setStatus('simulating');
      const { request } = await client.simulateContract({ ...call, chain: arbitrumSepolia } as Parameters<PublicClient['simulateContract']>[0]);
      setStatus('wallet');
      const h = await writeContractAsync(request as Parameters<typeof writeContractAsync>[0]);
      setHash(h);
      setStatus('mining');
      const receipt = await client.waitForTransactionReceipt({ hash: h });
      await qc.invalidateQueries({ queryKey: ['atBlock'] });
      if (receipt.status === 'reverted') {
        setError(await explainReceipt(client, call.abi, receipt));
        setStatus('error');
        return false;
      }
      setStatus('done');
      return true;
    } catch (err) {
      setError(explainError(err));
      setStatus('error');
      return false;
    }
  }, [client, writeContractAsync, qc]);

  const reset = useCallback(() => { setStatus('idle'); setHash(undefined); setError(undefined); }, []);
  return { run, status, hash, error, reset, busy: status === 'simulating' || status === 'wallet' || status === 'mining' };
}

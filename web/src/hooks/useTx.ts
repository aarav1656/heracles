import { useCallback, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { usePublicClient, useWriteContract } from 'wagmi';
import type { Abi, Address, Hash, PublicClient } from 'viem';
import { arbitrumSepolia } from '../chain';
import { explainError, explainReceipt, type Explained } from '../lib/revert';
import { useTxStatus } from '../components/TxStatus';

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
  const { report } = useTxStatus();
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
      report({ phase: 'wallet' });
      const h = await writeContractAsync(request as Parameters<typeof writeContractAsync>[0]);
      setHash(h);
      setStatus('mining');
      report({ phase: 'pending', hash: h });
      const receipt = await client.waitForTransactionReceipt({ hash: h });
      await qc.invalidateQueries({ queryKey: ['atBlock'] });
      if (receipt.status === 'reverted') {
        const explained = await explainReceipt(client, call.abi, receipt);
        setError(explained);
        setStatus('error');
        report({ phase: 'failed', hash: h, reason: explained.name });
        return false;
      }
      setStatus('done');
      report({ phase: 'confirmed', hash: h });
      return true;
    } catch (err) {
      const explained = explainError(err);
      setError(explained);
      setStatus('error');
      report({ phase: 'failed', reason: explained.name });
      return false;
    }
  }, [client, writeContractAsync, qc, report]);

  const reset = useCallback(() => { setStatus('idle'); setHash(undefined); setError(undefined); }, []);
  return { run, status, hash, error, reset, busy: status === 'simulating' || status === 'wallet' || status === 'mining' };
}

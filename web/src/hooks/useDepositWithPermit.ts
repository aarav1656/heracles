import { useCallback, useState } from 'react';
import { usePublicClient, useSignTypedData, useWriteContract } from 'wagmi';
import { hexToSignature, type Abi, type Address, type Hash, type PublicClient } from 'viem';
import { CAPACITY_ADDRESS, USDG_ADDRESS, capacityAbi, depositWithPermitAbi, erc20Abi } from '../abi';
import { arbitrumSepolia } from '../chain';
import { explainError, explainReceipt, type Explained } from '../lib/revert';
import type { TxStatus } from './useTx';

const PERMIT_TYPES = {
  Permit: [
    { name: 'owner', type: 'address' },
    { name: 'spender', type: 'address' },
    { name: 'value', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const;

const PERMIT_LIFETIME_SECONDS = 20n * 60n;

/**
 * L1r's frontend half (the security review, "Resolution 2"): deposit through
 * plain `deposit` whenever the caller's standing allowance to Capacity already covers `assets`,
 * requesting no signature at all. Only when the allowance falls short does this sign one
 * EIP-2612 permit for exactly `assets` and call `depositWithPermit`, so a signed permit is never
 * left sitting around for anyone to relay later (the contract-side half, `Capacity.
 * depositWithPermit`, always consumes whatever permit it is handed, so there is nothing left to
 * relay either way; this hook's job is to avoid making the caller sign one when it isn't needed).
 *
 * USDG's EIP-712 domain here (name "Global Dollar", version "1") was confirmed by recomputing the
 * domain separator and matching it byte for byte against the live `DOMAIN_SEPARATOR()` on
 * Arbitrum Sepolia for USDG_ADDRESS; re-check both if USDG_ADDRESS ever changes.
 */
export function useDepositWithPermit() {
  const client = usePublicClient() as PublicClient;
  const { signTypedDataAsync } = useSignTypedData();
  const { writeContractAsync } = useWriteContract();
  const [status, setStatus] = useState<TxStatus>('idle');
  const [hash, setHash] = useState<Hash>();
  const [error, setError] = useState<Explained>();

  const run = useCallback(async (assets: bigint, owner: Address, receiver: Address): Promise<boolean> => {
    setError(undefined);
    setHash(undefined);
    try {
      setStatus('simulating');
      const allowance = await client.readContract({
        address: USDG_ADDRESS, abi: erc20Abi, functionName: 'allowance', args: [owner, CAPACITY_ADDRESS],
      });

      let h: Hash;
      let revertAbi: Abi = capacityAbi;
      if (allowance >= assets) {
        const { request } = await client.simulateContract({
          address: CAPACITY_ADDRESS, abi: capacityAbi, functionName: 'deposit', args: [assets, receiver], account: owner, chain: arbitrumSepolia,
        });
        setStatus('wallet');
        h = await writeContractAsync(request as Parameters<typeof writeContractAsync>[0]);
      } else {
        const nonce = await client.readContract({ address: USDG_ADDRESS, abi: erc20Abi, functionName: 'nonces', args: [owner] });
        const deadline = BigInt(Math.floor(Date.now() / 1000)) + PERMIT_LIFETIME_SECONDS;
        setStatus('wallet');
        const signature = await signTypedDataAsync({
          domain: { name: 'Global Dollar', version: '1', chainId: arbitrumSepolia.id, verifyingContract: USDG_ADDRESS },
          types: PERMIT_TYPES,
          primaryType: 'Permit',
          message: { owner, spender: CAPACITY_ADDRESS, value: assets, nonce, deadline },
        });
        const { r, s, v } = hexToSignature(signature);
        revertAbi = depositWithPermitAbi;
        const { request } = await client.simulateContract({
          address: CAPACITY_ADDRESS, abi: depositWithPermitAbi, functionName: 'depositWithPermit',
          args: [assets, receiver, deadline, Number(v), r, s], account: owner, chain: arbitrumSepolia,
        });
        h = await writeContractAsync(request as Parameters<typeof writeContractAsync>[0]);
      }
      setHash(h);
      setStatus('mining');
      const receipt = await client.waitForTransactionReceipt({ hash: h });
      if (receipt.status === 'reverted') {
        setError(await explainReceipt(client, revertAbi, receipt));
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
  }, [client, signTypedDataAsync, writeContractAsync]);

  const reset = useCallback(() => { setStatus('idle'); setHash(undefined); setError(undefined); }, []);
  return { run, status, hash, error, reset, busy: status === 'simulating' || status === 'wallet' || status === 'mining' };
}

import { useCallback, useState } from 'react';
import { usePublicClient, useSignTypedData, useWriteContract } from 'wagmi';
import { hexToSignature, type Abi, type Address, type Hash, type PublicClient } from 'viem';
import { capacityAbi, erc20Abi, type BookConfig } from '../abi';
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
 * The EIP-712 domain comes from the book (`permit` in contracts/deployments/421614.json): USDG is
 * ("Global Dollar", "1") and USDC is ("USD Coin", "2"), each confirmed by recomputing the domain
 * separator and matching it byte for byte against the live `DOMAIN_SEPARATOR()` on Arbitrum Sepolia.
 */
export type DepositTarget = { book: BookConfig; vault: `0x${string}` };

export function useDepositWithPermit() {
  const client = usePublicClient() as PublicClient;
  const { signTypedDataAsync } = useSignTypedData();
  const { writeContractAsync } = useWriteContract();
  const [status, setStatus] = useState<TxStatus>('idle');
  const [hash, setHash] = useState<Hash>();
  const [error, setError] = useState<Explained>();

  const run = useCallback(async ({ book, vault }: DepositTarget, assets: bigint, owner: Address, receiver: Address): Promise<boolean> => {
    setError(undefined);
    setHash(undefined);
    try {
      setStatus('simulating');
      const allowance = await client.readContract({
        address: book.asset, abi: erc20Abi, functionName: 'allowance', args: [owner, vault],
      });

      let h: Hash;
      let revertAbi: Abi = capacityAbi;
      if (allowance >= assets) {
        const { request } = await client.simulateContract({
          address: vault, abi: capacityAbi, functionName: 'deposit', args: [assets, receiver], account: owner, chain: arbitrumSepolia,
        });
        setStatus('wallet');
        h = await writeContractAsync(request as Parameters<typeof writeContractAsync>[0]);
      } else {
        const nonce = await client.readContract({ address: book.asset, abi: erc20Abi, functionName: 'nonces', args: [owner] });
        const deadline = BigInt(Math.floor(Date.now() / 1000)) + PERMIT_LIFETIME_SECONDS;
        setStatus('wallet');
        const signature = await signTypedDataAsync({
          domain: { name: book.permit.name, version: book.permit.version, chainId: arbitrumSepolia.id, verifyingContract: book.asset },
          types: PERMIT_TYPES,
          primaryType: 'Permit',
          message: { owner, spender: vault, value: assets, nonce, deadline },
        });
        const { r, s, v } = hexToSignature(signature);
        const { request } = await client.simulateContract({
          address: vault, abi: capacityAbi, functionName: 'depositWithPermit',
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

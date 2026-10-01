import { createConfig, http } from 'wagmi';
import { defineChain } from 'viem';
import { injected, walletConnect } from 'wagmi/connectors';
import { CHAIN_ID, RPC_URL } from './abi/generated';

export const USDG_DECIMALS = 6;
export const EXPLORER_URL = 'https://sepolia.arbiscan.io';

const rpc = (import.meta.env.VITE_RPC_URL as string | undefined)?.trim() || RPC_URL;

export const arbitrumSepolia = defineChain({
  id: CHAIN_ID as number,
  name: 'Arbitrum Sepolia',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
  blockExplorers: { default: { name: 'Arbiscan Sepolia', url: EXPLORER_URL } },
  contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } },
});

const wcProjectId = (import.meta.env.VITE_WC_PROJECT_ID as string | undefined)?.trim();

export const wagmiConfig = createConfig({
  chains: [arbitrumSepolia],
  connectors: [
    injected(),
    ...(wcProjectId ? [walletConnect({ projectId: wcProjectId, showQrModal: true })] : []),
  ],
  // EIP-6963 discovery: each announced browser wallet becomes its own
  // connector carrying `rdns`, which the wallet menu filters by.
  multiInjectedProviderDiscovery: true,
  transports: { [arbitrumSepolia.id]: http() },
});

declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig;
  }
}

export const explorer = {
  address: (a: string) => `${EXPLORER_URL}/address/${a}`,
  tx: (h: string) => `${EXPLORER_URL}/tx/${h}`,
  block: (n: bigint) => `${EXPLORER_URL}/block/${n.toString()}`,
};

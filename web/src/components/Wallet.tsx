import { useState } from 'react';
import { useConnect, useConnection, useConnectors, useDisconnect, useSwitchChain } from 'wagmi';
import { arbitrumSepolia } from '../chain';
import { short } from '../lib/format';

/**
 * One "Connect wallet" CTA, GMX's own label and colour (gmx-trade study.md,
 * order-form CTA). Which wallet it means is the connector list underneath,
 * shown as a menu only when there is more than one to choose from.
 */
export function Wallet() {
  const conn = useConnection();
  const connectors = useConnectors();
  const { mutate: connect, isPending } = useConnect();
  const { mutate: disconnect } = useDisconnect();
  const { mutate: switchChain } = useSwitchChain();
  const [open, setOpen] = useState(false);

  if (!conn.isConnected) {
    const single = connectors.length <= 1;
    return (
      <div className="wallet-menu">
        <button
          className="btn"
          disabled={isPending || connectors.length === 0}
          onClick={() => (single ? connect({ connector: connectors[0] }) : setOpen((o) => !o))}
          aria-haspopup={single ? undefined : 'menu'}
          aria-expanded={single ? undefined : open}
        >
          Connect wallet
        </button>
        {!single && open && (
          <div className="wallet-menu-list" role="menu">
            {connectors.map((c) => (
              <button
                key={c.uid}
                className="key"
                role="menuitem"
                disabled={isPending}
                onClick={() => { connect({ connector: c }); setOpen(false); }}
              >
                {c.name === 'Injected' ? 'Browser wallet' : c.name}
              </button>
            ))}
          </div>
        )}
      </div>
    );
  }
  const wrong = conn.chainId !== arbitrumSepolia.id;
  return (
    <div className="wallet">
      {wrong && (
        <button className="key warn" onClick={() => switchChain({ chainId: arbitrumSepolia.id })}>
          wrong network, switch to Arbitrum Sepolia
        </button>
      )}
      <span className="tx">{conn.address ? short(conn.address) : 'reconnecting'}</span>
      <button className="key" onClick={() => disconnect()}>disconnect</button>
    </div>
  );
}

/** True when a wallet is connected on Arbitrum Sepolia (421614). */
export function useOnChain(): { address?: `0x${string}`; ready: boolean; reason?: string } {
  const conn = useConnection();
  if (!conn.isConnected) return { ready: false, reason: 'Connect a wallet to continue.' };
  if (conn.chainId !== arbitrumSepolia.id) {
    return { address: conn.address, ready: false, reason: `Wrong network. Switch the wallet to Arbitrum Sepolia (id ${arbitrumSepolia.id}).` };
  }
  return { address: conn.address, ready: true };
}

import { useEffect, useId, useRef, useState } from 'react';
import { useConnect, useConnection, useConnectors, useDisconnect, useSwitchChain } from 'wagmi';
import { arbitrumSepolia } from '../chain';
import { short } from '../lib/format';
import { WALLET_ALLOWLIST, filterAllowedConnectors } from '../lib/wallets';

export { filterAllowedConnectors };

/** Curated label for a connector: the allowlist name, never the raw id. */
function labelFor(c: { rdns?: string | readonly string[] | null; name: string }): string {
  const list = !c.rdns ? [] : Array.isArray(c.rdns) ? c.rdns : [c.rdns];
  const hit = WALLET_ALLOWLIST.find((w) => list.includes(w.rdns));
  return hit ? hit.label : c.name;
}

/**
 * One "Connect wallet" button opening the curated EIP-6963 menu.
 * Only discovered wallets on the allowlist are listed, in allowlist order.
 */
export function Wallet() {
  const conn = useConnection();
  const connectors = useConnectors();
  const { mutate: connect, isPending } = useConnect();
  const { mutate: disconnect } = useDisconnect();
  const { mutate: switchChain } = useSwitchChain();
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menuId = useId();

  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setOpen(false);
        trigger.current?.focus();
      }
    };
    document.addEventListener('pointerdown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('pointerdown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [open ]);

  if (!conn.isConnected) {
    const allowed = filterAllowedConnectors(connectors);
    return (
      <div className="wallet-menu" ref={box}>
        <button
          ref={trigger}
          className="btn"
          disabled={isPending}
          aria-busy={isPending || undefined}
          aria-haspopup="menu"
          aria-expanded={open}
          aria-controls={menuId}
          onClick={() => setOpen((o) => !o)}
        >
          Connect wallet
        </button>
        {open && (
          <div className="wallet-menu-list" role="menu" id={menuId} aria-label="Browser wallets">
            {allowed.length === 0 ? (
              <p className="note">
                No browser wallet found. <a href="https://rabby.io" target="_blank" rel="noreferrer">Get Rabby</a>
              </p>
            ) : (
              allowed.map((c) => (
                <button
                  key={c.uid}
                  className="key"
                  role="menuitem"
                  disabled={isPending}
                  onClick={() => { connect({ connector: c }); setOpen(false); }}
                >
                  {labelFor(c)}
                </button>
              ))
            )}
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
      <button className="key" onClick={() => disconnect()}>Disconnect</button>
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

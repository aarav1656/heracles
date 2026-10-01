import { useEffect, useSyncExternalStore } from 'react';
import { explorer } from '../chain';

export type TxPhase = 'idle' | 'wallet' | 'pending' | 'confirmed' | 'failed';

export type TxView = { phase: TxPhase; hash?: string; reason?: string };

/** The current write, shared by every writeContract call in the app. */
let view: TxView = { phase: 'idle' };
const listeners = new Set<() => void>();

function getView(): TxView {
  return view;
}

function subscribe(fn: () => void): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

/** Publish the current write. Last writer wins. */
export function reportTx(patch: TxView): void {
  view = patch;
  listeners.forEach((fn) => fn());
}

export function dismissTx(): void {
  reportTx({ phase: 'idle' });
}

/**
 * Read and publish the current write. Every writeContract path reports
 * wallet -> pending -> confirmed/failed here; the TxStatus panel renders it.
 */
export function useTxStatus(): TxView & { report: typeof reportTx; dismiss: typeof dismissTx } {
  const v = useSyncExternalStore(subscribe, getView);
  return { ...v, report: reportTx, dismiss: dismissTx };
}

const shortReason = (r?: string) => (r && r.length > 48 ? `${r.slice(0, 48)}…` : (r ?? 'the transaction failed'));

/** Fixed bottom-right panel: the current write from wallet confirm to receipt. */
export function TxStatus() {
  const { phase, hash, reason } = useTxStatus();

  useEffect(() => {
    if (phase !== 'confirmed') return;
    const t = setTimeout(() => dismissTx(), 8000);
    return () => clearTimeout(t);
  }, [phase, hash]);

  if (phase === 'idle') return null;

  const hashLink = hash ? (
    <>
      {' as '}
      <a href={explorer.tx(hash)} target="_blank" rel="noreferrer">
        {hash.slice(0, 10)}…
      </a>
    </>
  ) : null;

  return (
    <div className="txstatus" role="status" aria-live="polite">
      {phase === 'wallet' && <p className="prose">Confirm in your wallet</p>}
      {phase === 'pending' && (
        <p className="prose">
          Pending{hashLink}
        </p>
      )}
      {phase === 'confirmed' && (
        <p className="prose ok">
          Confirmed{hashLink}
        </p>
      )}
      {phase === 'failed' && (
        <p className="prose err">
          <b>Failed:</b> {shortReason(reason)}
          {hash ? (
            <>
              {' '}
              <a href={explorer.tx(hash)} target="_blank" rel="noreferrer">
                {hash.slice(0, 10)}…
              </a>
            </>
          ) : null}
        </p>
      )}
      <button className="key" type="button" onClick={dismissTx} aria-label="Dismiss transaction status">
        Dismiss
      </button>
    </div>
  );
}

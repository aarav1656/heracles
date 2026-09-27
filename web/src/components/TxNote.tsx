import { explorer } from '../chain';
import type { Explained } from '../lib/revert';

/** One-line tx state: simulating, wallet, mining, done with Arbiscan link, or the decoded error. */
export function TxNote({ status, hash, error }: { status: string; hash?: string; error?: Explained }) {
  if (status === 'idle') return null;
  if (status === 'simulating') return <p className="prose">Simulating against the treaty…</p>;
  if (status === 'wallet') return <p className="prose">Waiting for the wallet signature…</p>;
  if (status === 'mining') {
    return (
      <p className="prose">
        Mining{hash ? <> as <a className="tx" href={explorer.tx(hash)} target="_blank" rel="noreferrer">{hash.slice(0, 10)}…</a></> : null}…
      </p>
    );
  }
  if (status === 'done') {
    return (
      <p className="prose ok">
        Landed{hash ? <>: <a className="tx" href={explorer.tx(hash)} target="_blank" rel="noreferrer">{hash.slice(0, 10)}…</a></> : '.'}
      </p>
    );
  }
  return (
    <p className="prose err" role="alert">
      <b>{error?.name ?? 'Error'}</b> {error?.words ?? 'The transaction failed.'}
    </p>
  );
}

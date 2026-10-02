import type { ReactNode } from 'react';

export type Sim =
  | { kind: 'idle'; why: string }
  | { kind: 'running' }
  | { kind: 'ok'; rows: { k: string; v: ReactNode }[]; block: bigint }
  | { kind: 'revert'; name: string; words: string };

/** Dry run result shown above the sign button, in the ticket's own row vocabulary. */
export function SimPanel({ title, sim }: { title: string; sim: Sim }) {
  return (
    <div className="sim" aria-live="polite">
      <h3 className="label sub">{title}</h3>
      {sim.kind === 'idle' && <p className="note">{sim.why}</p>}
      {sim.kind === 'running' && <p className="note">Running the call against the chain without signing.</p>}
      {sim.kind === 'revert' && <p className="err" role="alert"><b>Would revert</b> {sim.words} <small>({sim.name})</small></p>}
      {sim.kind === 'ok' && (
        <>
          <div className="rows figs">
            {sim.rows.map((r) => <div className="row" key={r.k}><span className="k">{r.k}</span><span className="v">{r.v}</span></div>)}
          </div>
          <p className="src">Simulated from your account at block {sim.block.toLocaleString('en-US')}. Nothing was signed.</p>
        </>
      )}
    </div>
  );
}

import type { WeekWindow } from '../hooks/useWeekWindow';
import { fmtClock, fmtCountdown } from '../lib/format';

/**
 * One cover week as ledger rows, from the treaty's own calendar: binding closes Thursday 19:30 UTC,
 * the reference is the round in effect at Friday's close, and the layer fixes from the
 * first round after Monday's open. The row that comes next carries the "next" mark.
 */
export function WeekStrip({ win, now }: { win: WeekWindow; now: number }) {
  const when = (t: number) => (t > now ? `in ${fmtCountdown(t - now)}` : fmtCountdown(t - now));
  const rows = [
    { k: 'Last moment to buy', t: win.bindDeadline, note: 'cover for this weekend can be bought until here' },
    { k: 'Friday reference', t: win.ref, note: 'the feed round in effect at the 4pm New York close' },
    { k: 'Monday settlement', t: win.expiry, note: 'first feed round after the 9:30 open; the gap is the move between the two' },
  ];
  const next = rows.findIndex((r) => r.t > now);
  return (
    <div className="rows week">
      {rows.map((r, i) => (
        <div key={r.k} className={`row${i === next ? ' next' : ''}`}>
          <span className="k">{r.k}<small>{r.note}</small></span>
          <span className="v">{fmtClock(r.t)} UTC<small>{when(r.t)}</small></span>
        </div>
      ))}
    </div>
  );
}

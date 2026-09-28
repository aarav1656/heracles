import type { WeekWindow } from '../hooks/useWeekWindow';
import { fmtClock, fmtCountdown } from '../lib/format';

/**
 * One cover week on a line, from the treaty's own calendar: binding runs from Monday 00:00 UTC
 * to the Friday cutoff, the reference is the first round after Friday's close, the market is
 * shut over the weekend (the gap), and the layer fixes from the first round after Monday's open.
 */
export function WeekStrip({ win, now }: { win: WeekWindow; now: number }) {
  const from = win.cutoff - (4 * 86400 + 19.5 * 3600);
  const to = win.expiry + 8 * 3600;
  const pct = (t: number) => Math.min(100, Math.max(0, ((t - from) / (to - from)) * 100));
  const showNow = now >= from && now <= to;
  const when = (t: number) => (t > now ? `in ${fmtCountdown(t - now)}` : fmtCountdown(t - now));

  return (
    <div className="week">
      <div
        className="week-line"
        role="img"
        aria-label={`Binding closes ${fmtClock(win.cutoff)} UTC. Reference is the first round after Friday's close, ${fmtClock(win.ref)} UTC. Fixing from ${fmtClock(win.expiry)} UTC.`}
      >
        <span className="seg open" style={{ left: 0, width: `${pct(win.cutoff)}%` }}><em>binding open</em></span>
        <span className="seg shut" style={{ left: `${pct(win.ref)}%`, width: `${pct(win.expiry) - pct(win.ref)}%` }}><em>market shut: the gap</em></span>
        <span className="seg fix" style={{ left: `${pct(win.expiry)}%`, right: 0 }} />
        <i className="mark cut" style={{ left: `${pct(win.cutoff)}%` }} />
        <i className="mark fixm" style={{ left: `${pct(win.expiry)}%` }} />
        {showNow && <i className="mark now" style={{ left: `${pct(now)}%` }}><b>now</b></i>}
      </div>
      <ol className="week-key">
        <li>
          <span>Bind by</span>
          <b className="num">{fmtClock(win.cutoff)} UTC</b>
          <small>{when(win.cutoff)}</small>
        </li>
        <li>
          <span>Friday reference</span>
          <b className="num">{fmtClock(win.ref)} UTC</b>
          <small>{when(win.ref)}</small>
        </li>
        <li>
          <span>Monday settlement</span>
          <b className="num">{fmtClock(win.expiry)} UTC</b>
          <small>{when(win.expiry)}</small>
        </li>
      </ol>
      <p className="week-rule">
        The reference is the first feed round after Friday's 4pm New York close; the layer settles
        from the first round after Monday's 9:30 open. Everything between is the gap.
      </p>
    </div>
  );
}

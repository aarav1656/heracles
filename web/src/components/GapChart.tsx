import { useMemo, useState, type KeyboardEvent, type PointerEvent } from 'react';
import { backtest, extremes, fmtBps, fmtDay, type GapTable } from '../lib/gaps';

type LayerTerms = { exposure: number; retention: number; limit: number };

const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });

/**
 * Every weekend in a market's pricing table as one bar: Friday's close to the next open, in
 * percent. With a layer, the band across the plot is the slice of loss the layer pays; bars
 * that reach into it are the weekends it would have paid, bars through it are the weekends
 * that used the whole limit. Pointer or arrow keys walk the weekends.
 */
export function GapChart({ table, layer }: { table: GapTable; layer?: LayerTerms }) {
  const ws = table.weekends;
  const ext = useMemo(() => extremes(ws), [ws]);
  const bt = useMemo(() => (layer ? backtest(ws, layer.exposure, layer.retention, layer.limit) : undefined), [ws, layer]);

  const lossSideDown = !layer || layer.exposure >= 0;
  const worst = lossSideDown ? ext.down : ext.up;
  const worstIdx = ws.indexOf(worst);
  const [sel, setSel] = useState<number>();
  const at = sel ?? worstIdx;

  // Vertical domain: the data, stretched to show the band when it sits a little past the
  // record, but never so far that a thin layer on a tiny exposure flattens the bars.
  const reach = (b: number | undefined, edge: number) => (b === undefined ? edge : Math.sign(b) === Math.sign(edge) || edge === 0 ? Math.sign(edge) * Math.min(Math.abs(b), Math.abs(edge) * 1.6) : edge);
  const lo = Math.min(-100, ext.down.gap, reach(bt && bt.exhaustBps < 0 ? bt.exhaustBps : undefined, ext.down.gap)) * 1.08;
  const hi = Math.max(100, ext.up.gap, reach(bt && bt.exhaustBps > 0 ? bt.exhaustBps : undefined, ext.up.gap)) * 1.08;
  const y = (b: number) => ((hi - b) / (hi - lo)) * 100;
  const clampY = (b: number) => Math.min(100, Math.max(0, y(b)));

  const step = Math.abs(hi - lo) > 1600 ? 500 : Math.abs(hi - lo) > 800 ? 250 : 100;
  const ticks: number[] = [];
  for (let t = Math.ceil(lo / step) * step; t <= hi; t += step) ticks.push(t);

  const years = useMemo(() => {
    const out: { year: string; i: number }[] = [];
    ws.forEach((w, i) => {
      const yr = w.friday.slice(0, 4);
      if (!out.length || out[out.length - 1].year !== yr) out.push({ year: yr, i });
    });
    return out.slice(1);
  }, [ws]);

  const kind = (i: number) => {
    if (!bt) return 'k';
    const p = bt.payouts[i];
    if (p >= (layer?.limit ?? Infinity) && p > 0) return 'x';
    if (p > 0) return 'p';
    const loss = -(layer!.exposure * ws[i].gap);
    return loss > 0 ? 'k' : 'g';
  };

  const pick = (e: PointerEvent<HTMLDivElement>) => {
    const field = e.currentTarget.querySelector('.gap-field');
    if (!field) return;
    const r = field.getBoundingClientRect();
    setSel(Math.min(ws.length - 1, Math.max(0, Math.floor(((e.clientX - r.left) / r.width) * ws.length))));
  };
  const keys = (e: KeyboardEvent<HTMLDivElement>) => {
    const d = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : e.key === 'PageUp' ? 52 : e.key === 'PageDown' ? -52 : 0;
    if (e.key === 'Home') setSel(0);
    else if (e.key === 'End') setSel(ws.length - 1);
    else if (d) setSel(Math.min(ws.length - 1, Math.max(0, at + d)));
    else return;
    e.preventDefault();
  };

  const w = ws[at];
  const pay = bt?.payouts[at];
  const summary = bt
    ? `${table.ticker}: ${ws.length} weekends from ${fmtDay(ws[0].friday)}. The layer starts paying at a ${fmtBps(bt.attachBps)} gap and pays its full limit at ${fmtBps(bt.exhaustBps)}. It would have paid on ${bt.paid} weekends, the full limit on ${bt.exhausted}.`
    : `${table.ticker}: ${ws.length} weekend gaps. Worst ${fmtBps(ext.down.gap)} on ${fmtDay(ext.down.friday)}.`;

  return (
    <div className="gap">
      <p className="gap-read" aria-live="polite">
        <span className="gap-when">{fmtDay(w.friday)} close <span aria-hidden="true">→</span> {fmtDay(w.monday)} open</span>
        <span className={`num gap-move ${w.gap < 0 ? 'dn' : w.gap > 0 ? 'up' : ''}`}>{fmtBps(w.gap)}</span>
        {bt && pay !== undefined && (
          <span className="gap-pay">
            {pay > 0
              ? <>layer pays <b className="num">{usd0.format(pay)}</b> USDG{pay >= layer!.limit ? ', the full limit' : ''}</>
              : 'inside the retention or a gain: layer pays nothing'}
          </span>
        )}
        {sel === undefined && <span className="gap-hint">{lossSideDown ? 'worst down weekend' : 'worst up weekend'} on record</span>}
      </p>

      <div
        className="gap-plot"
        role="slider"
        tabIndex={0}
        aria-label={summary}
        aria-valuemin={1}
        aria-valuemax={ws.length}
        aria-valuenow={at + 1}
        aria-valuetext={`${fmtDay(w.friday)}, ${fmtBps(w.gap)}`}
        onPointerMove={pick}
        onPointerDown={pick}
        onPointerLeave={() => setSel(undefined)}
        onKeyDown={keys}
      >
        <div className="gap-axis" aria-hidden="true">
          {ticks.map((t) => (
            <span key={t} style={{ top: `${y(t)}%` }}>{t === 0 ? '0%' : fmtBps(t).replace('.00', '')}</span>
          ))}
        </div>
        <div className="gap-field">
          <svg viewBox={`0 0 ${ws.length} 100`} preserveAspectRatio="none" aria-hidden="true">
            {ticks.map((t) => (
              <line key={t} className={t === 0 ? 'zero' : 'grid'} x1={0} x2={ws.length} y1={y(t)} y2={y(t)} vectorEffect="non-scaling-stroke" />
            ))}
            {bt && (
              <>
                <rect className="band" x={0} width={ws.length} y={Math.min(clampY(bt.attachBps), clampY(bt.exhaustBps))} height={Math.abs(clampY(bt.exhaustBps) - clampY(bt.attachBps))} />
                <line className="edge-line" x1={0} x2={ws.length} y1={clampY(bt.attachBps)} y2={clampY(bt.attachBps)} vectorEffect="non-scaling-stroke" />
                <line className="edge-line" x1={0} x2={ws.length} y1={clampY(bt.exhaustBps)} y2={clampY(bt.exhaustBps)} vectorEffect="non-scaling-stroke" />
              </>
            )}
            {/* Paid weekends drawn last and wider, so 36 of 504 read as marks, not hairlines. */}
            {[false, true].map((hot) =>
              ws.map((wk, i) => {
                const kd = kind(i);
                if ((kd === 'p' || kd === 'x') !== hot) return null;
                const top = Math.min(y(0), y(wk.gap));
                const wd = hot ? 2.4 : 0.72;
                return <rect key={wk.friday} className={`bar ${kd}`} x={i + 0.5 - wd / 2} width={wd} y={top} height={Math.max(0.35, Math.abs(y(wk.gap) - y(0)))} />;
              }),
            )}
            <line className="cursor" x1={at + 0.5} x2={at + 0.5} y1={0} y2={100} vectorEffect="non-scaling-stroke" />
          </svg>
          {bt && (
            <div className={`gap-edges${Math.abs(clampY(bt.attachBps) - clampY(bt.exhaustBps)) < 12 ? ' tight' : ''}`} aria-hidden="true">
              <span className="edge" style={{ top: `${clampY(bt.attachBps)}%` }}>
                <b className="num">{fmtBps(bt.attachBps)}</b><span className="w">layer starts</span>
              </span>
              <span className="gap-mid" style={{ top: `${(clampY(bt.attachBps) + clampY(bt.exhaustBps)) / 2}%` }}>the layer</span>
              <span className="edge" style={{ top: `${clampY(bt.exhaustBps)}%` }}>
                <b className="num">{fmtBps(bt.exhaustBps)}</b><span className="w">limit used up</span>
              </span>
            </div>
          )}
        </div>
        <div className="gap-years" aria-hidden="true">
          {years.map((yr) => (
            <span key={yr.year} style={{ left: `${(yr.i / ws.length) * 100}%` }}>{yr.year}</span>
          ))}
        </div>
      </div>

      <div className="gap-key">
        {bt ? (
          <>
            <span><i className="sw p" />layer pays <b className="num">{bt.paid}</b></span>
            <span><i className="sw x" />full limit <b className="num">{bt.exhausted}</b></span>
            <span><i className="sw k" />vault keeps it</span>
            <span><i className="sw g" />gain for this side</span>
          </>
        ) : (
          <span><i className="sw k" />Friday close to next open, one bar per weekend</span>
        )}
        <span className="gap-src">
          {ws.length} weekends, {fmtDay(ws[0].friday)} to {fmtDay(ws[ws.length - 1].friday)} · <code>{table.file}</code> from {table.source}, fetched {table.fetchDate}
        </span>
      </div>
    </div>
  );
}

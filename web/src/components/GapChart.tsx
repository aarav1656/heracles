import { useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent, type PointerEvent } from 'react';
import { backtest, extremes, fmtBps, fmtDay, type GapTable } from '../lib/gaps';

type LayerTerms = { exposure: number; retention: number; limit: number };

const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const LEFT = 52;
const TOP = 10;
const BOTTOM = 30;

/**
 * Every weekend in a market's pricing table as one bar: Friday's close to the next open. With a
 * layer, a teal band marks the slice of loss the layer pays (retention to retention + limit);
 * the part of each weekend's bar inside the band is the payout, filled teal. Drawn in real
 * pixels (the SVG is measured), so labels are true 12px. Pointer or arrow keys walk the weekends.
 */
export function GapChart({ table, layer, notes = true }: { table: GapTable; layer?: LayerTerms; notes?: boolean }) {
  const ws = table.weekends;
  const ext = useMemo(() => extremes(ws), [ws]);
  const bt = useMemo(() => (layer ? backtest(ws, layer.exposure, layer.retention, layer.limit) : undefined), [ws, layer]);

  const box = useRef<HTMLDivElement>(null);
  const [W, setW] = useState(820);
  useLayoutEffect(() => {
    const el = box.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => setW(Math.round(e.contentRect.width)));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const [entering, setEntering] = useState(true);
  useEffect(() => { const t = setTimeout(() => setEntering(false), 1500); return () => clearTimeout(t); }, []);

  const wide = W >= 700;
  const H = wide ? 380 : 260;
  const RIGHT = wide && bt && notes ? 176 : 8;
  const pw = Math.max(40, W - LEFT - RIGHT);
  const ph = H - TOP - BOTTOM;

  const lossSideDown = !layer || layer.exposure >= 0;
  const worst = lossSideDown ? ext.down : ext.up;
  const worstIdx = ws.indexOf(worst);
  const [sel, setSel] = useState<number>();
  const at = sel ?? worstIdx;

  // Vertical domain: the data, stretched to show the band when it sits a little past the
  // record, never so far that a thin layer on a tiny exposure flattens the bars.
  const reach = (b: number | undefined, edge: number) => (b === undefined ? edge : Math.sign(b) === Math.sign(edge) || edge === 0 ? Math.sign(edge) * Math.min(Math.abs(b), Math.abs(edge) * 1.6) : edge);
  const lo = Math.min(-100, ext.down.gap, reach(bt && bt.exhaustBps < 0 ? bt.exhaustBps : undefined, ext.down.gap)) * 1.06;
  const hi = Math.max(100, ext.up.gap, reach(bt && bt.exhaustBps > 0 ? bt.exhaustBps : undefined, ext.up.gap)) * 1.06;
  const y = (b: number) => TOP + ((hi - b) / (hi - lo)) * ph;
  const cy = (b: number) => Math.min(TOP + ph, Math.max(TOP, y(b)));
  const slot = pw / ws.length;
  const x = (i: number) => LEFT + (i + 0.5) * slot;

  const step = Math.abs(hi - lo) > 1600 ? 500 : Math.abs(hi - lo) > 800 ? 250 : 100;
  const ticks: number[] = [];
  for (let t = Math.ceil(lo / step) * step; t <= hi; t += step) ticks.push(t);
  const years = useMemo(() => ws.flatMap((w, i) => (i > 0 && w.friday.slice(0, 4) !== ws[i - 1].friday.slice(0, 4) ? [{ year: w.friday.slice(0, 4), i }] : [])), [ws]);
  const yearEvery = wide ? 1 : 2;

  const pick = (e: PointerEvent<HTMLDivElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    const i = Math.floor(((e.clientX - r.left - LEFT) / pw) * ws.length);
    if (i >= 0 && i < ws.length) setSel(i);
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

  const bandTop = bt ? Math.min(cy(bt.attachBps), cy(bt.exhaustBps)) : 0;
  const bandBot = bt ? Math.max(cy(bt.attachBps), cy(bt.exhaustBps)) : 0;
  const barW = Math.max(1, slot * 0.62);
  const sliceW = Math.max(2.2, slot * 1.35);
  const tr = (p: Record<string, number | string>) => p as CSSProperties;

  const worstPay = bt?.payouts[worstIdx] ?? 0;
  const worstLeft = x(worstIdx) > LEFT + pw * 0.62;
  const worstY = cy(worst.gap);

  return (
    <div className={`gc${entering ? ' enter' : ''}${lossSideDown ? '' : ' up'}`}>
      <p className="gc-read" aria-live="polite">
        <span>{fmtDay(w.friday)} close to {fmtDay(w.monday)} open</span>
        <b className={w.gap < 0 ? 'dn' : undefined}>{fmtBps(w.gap)}</b>
        {bt && pay !== undefined && (
          <span className="gc-pay">
            {pay > 0 ? <>the layer pays <b>{usd0.format(pay)}</b> USDG{pay >= layer!.limit ? ', its full limit' : ''}</> : 'inside the retention or a gain: the layer pays nothing'}
          </span>
        )}
        {sel === undefined && <span className="gc-hint">{lossSideDown ? 'the worst down weekend' : 'the worst up weekend'}</span>}
      </p>

      <div
        ref={box}
        className="gc-plot"
        style={{ height: H }}
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
        <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`} aria-hidden="true">
          {years.map((yr, k) => (
            <g key={yr.year}>
              <line className="gc-year" x1={LEFT + yr.i * slot} x2={LEFT + yr.i * slot} y1={TOP} y2={TOP + ph} />
              {k % yearEvery === 0 && <text className="gc-lab" x={LEFT + yr.i * slot + 3} y={H - 9}>{yr.year}</text>}
            </g>
          ))}
          {ticks.map((t) => (
            <g key={t}>
              <line className={t === 0 ? 'gc-zero' : 'gc-grid'} x1={LEFT} x2={LEFT + pw} y1={y(t)} y2={y(t)} />
              <text className="gc-lab" x={LEFT - 8} y={y(t) + 4} textAnchor="end">{t === 0 ? '0%' : fmtBps(t).replace('.00', '').replace('.50', '.5')}</text>
            </g>
          ))}
          {bt && (
            <g className="gc-band">
              <rect className="gc-wash" x={LEFT} width={pw} style={tr({ y: bandTop, height: Math.max(1, bandBot - bandTop) })} />
              <line className="gc-edge" x1={LEFT} x2={LEFT + pw} y1={0} y2={0} style={tr({ transform: `translateY(${cy(bt.attachBps)}px)` })} />
              <line className="gc-edge" x1={LEFT} x2={LEFT + pw} y1={0} y2={0} style={tr({ transform: `translateY(${cy(bt.exhaustBps)}px)` })} />
            </g>
          )}
          <g className="gc-bars">
            {ws.map((wk, i) => {
              const gain = layer ? -(layer.exposure * wk.gap) <= 0 : wk.gap >= 0;
              const top = Math.min(y(0), cy(wk.gap));
              return <rect key={wk.friday} className={gain ? 'gc-g' : 'gc-k'} x={x(i) - barW / 2} width={barW} y={top} height={Math.max(0.8, Math.abs(cy(wk.gap) - y(0)))} />;
            })}
          </g>
          {bt && (
            <g className="gc-slices">
              {ws.map((wk, i) => {
                if (!(bt.payouts[i] > 0)) return null;
                const a = cy(bt.attachBps);
                const b = cy(Math.abs(wk.gap) < Math.abs(bt.exhaustBps) ? wk.gap : bt.exhaustBps);
                const depth = (Math.abs(b - a) / Math.max(1, bandBot - bandTop));
                return <rect key={wk.friday} className="gc-slice" style={{ animationDelay: `${460 + depth * 600}ms` }} x={x(i) - sliceW / 2} width={sliceW} y={Math.min(a, b)} height={Math.max(1.5, Math.abs(b - a))} />;
              })}
            </g>
          )}
          {sel !== undefined && <line className="gc-cursor" x1={x(at)} x2={x(at)} y1={TOP} y2={TOP + ph} />}
        </svg>

        {bt && notes && wide && (
          <div className="gc-notes" aria-hidden="true" style={{ left: LEFT + pw + 16 }}>
            {[
              { b: bt.attachBps, words: `the vault keeps the first ${usd0.format(layer!.retention)}` },
              { b: bt.exhaustBps, words: 'its limit is used up' },
            ].map((n) => (
              <span key={n.words} className={`gc-note${cy(n.b) === bandTop ? ' above' : ''}`} style={{ top: cy(n.b) }}>
                <b>{fmtBps(n.b)}</b> {n.words}
              </span>
            ))}
            {bandBot - bandTop >= 40 && (
              <span className="gc-note layer" style={{ top: (bandTop + bandBot) / 2 }}>the layer pays the next {usd0.format(layer!.limit)}</span>
            )}
          </div>
        )}
        {bt && notes && wide && worstPay > 0 && (
          <span
            className={`gc-pin${worstLeft ? ' left' : ''}`}
            aria-hidden="true"
            style={{ left: x(worstIdx) + (worstLeft ? -10 : 10), top: Math.min(worstY, TOP + ph - 28) }}
          >
            {fmtDay(worst.friday)}, {fmtBps(worst.gap)}: the layer paid {worstPay >= layer!.limit ? `its full ${usd0.format(layer!.limit)}` : usd0.format(worstPay)}
          </span>
        )}
      </div>

      <div className="gc-key">
        {bt ? (
          <>
            <span><i className="sw layer" />paid on <b>{bt.paid}</b> of {ws.length} weekends, the full limit on <b>{bt.exhausted}</b></span>
            <span className="gc-hint">Point at a weekend, or focus the chart and use the arrow keys.</span>
            {!wide && notes && <span>band: {fmtBps(bt.attachBps)} to {fmtBps(bt.exhaustBps)}, the vault keeps the first {usd0.format(layer!.retention)}, the layer pays the next {usd0.format(layer!.limit)}</span>}
          </>
        ) : (
          <span>Friday close to next open, one bar per weekend</span>
        )}
      </div>
      <p className="src">
        {ws.length} weekends, {fmtDay(ws[0].friday)} to {fmtDay(ws[ws.length - 1].friday)}. Source: <span className="file">{table.file}</span> in the repo, from {table.source}, fetched {fmtDay(table.fetchDate)}.
      </p>
    </div>
  );
}

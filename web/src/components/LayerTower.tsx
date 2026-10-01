import { useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { fmtUsdg } from '../lib/format';
import { BAND_MIN_PX, PLOT_PX, PLOT_PX_NARROW, exposureVerdict, towerGeometry } from './tower-geometry';
import type { LabelBox } from './tower-geometry';

export type TowerLayer = {
  name: string;
  who?: ReactNode;
  exposure: bigint;
  retention: bigint;
  limit: bigint;
  premium: bigint;
  payout?: bigint;
  /** Book asset symbol the amounts are in. */
  unit: string;
  tag?: string;
  state?: 'bound' | 'settled' | 'cancelled';
};

const NARROW_AT = 560;

/**
 * The layer diagram. Loss runs up the page: the vault keeps everything below
 * the retention, the treaty owns the band from retention to retention plus
 * limit, everything above that is uncovered. Band heights are the book asset the
 * contract reported, so the declared exposure marker either lands inside the
 * band the reader bought or in the uncovered space above it.
 *
 * A band thinner than its own label cannot hold that label, so the label moves
 * to a column beside the tower and reaches back on a leader line. A thin band
 * is still drawn to a minimum height, and the axis says so with a break, so the
 * drawing never claims a proportion it is not keeping.
 */
export function LayerTower(l: TowerLayer) {
  const [narrow, setNarrow] = useState(false);
  useEffect(() => {
    const read = () => setNarrow(window.innerWidth <= NARROW_AT);
    read();
    window.addEventListener('resize', read);
    return () => window.removeEventListener('resize', read);
  }, []);

  const u = l.unit;
  const rate = l.limit > 0n ? ((Number(l.premium) / Number(l.limit)) * 100).toFixed(2) : null;
  const settled = l.state === 'settled';
  const cancelled = l.state === 'cancelled';
  const range = `${fmtUsdg(l.retention)} to ${fmtUsdg(l.retention + l.limit)} ${u}`;

  // A band label is a name, a range and at most two notes. The line count is
  // known before the drawing is measured, so the boxes can be reserved at the
  // right height and no figure can grow into the label above it.
  const keepBody: ReactNode[] = [
    <span key="n" className="swatch-name">
      <span className="swatch keep" />
      the vault keeps
    </span>,
    <b key="r">0 to {fmtUsdg(l.retention)} {u}</b>,
  ];
  const layerBody: ReactNode[] = cancelled
    ? [
        <span key="n" className="swatch-name">
          <span className="swatch layer" />
          cancelled
        </span>,
        <b key="r">no layer in force</b>,
      ]
    : [
        <span key="n" className="swatch-name">
          <span className="swatch layer" />
          the layer
        </span>,
        <b key="r">{range}</b>,
        <em key="p">{settled ? `paid ${fmtUsdg(l.payout ?? 0n)} ${u}` : `${fmtUsdg(l.premium)} ${u} premium`}</em>,
        ...(rate ? [<em key="r">{rate}% rate on line</em>] : []),
      ];
  const exposureBody: ReactNode[] = [
    'declared exposure',
    <b key="v">{fmtUsdg(l.exposure < 0n ? -l.exposure : l.exposure)} {u}</b>,
  ];
  const lineCount = { keep: keepBody.length, layer: layerBody.length, open: 3, exposure: exposureBody.length };

  const g = useMemo(
    () =>
      towerGeometry({
        exposure: l.exposure,
        retention: l.retention,
        limit: l.limit,
        payout: l.payout,
        state: settled ? 2 : cancelled ? 3 : 1,
        plotPx: narrow ? PLOT_PX_NARROW : PLOT_PX,
        lines: lineCount,
      }),
    [l.exposure, l.retention, l.limit, l.payout, l.state, narrow, lineCount.keep, lineCount.layer, lineCount.exposure],
  );

  const uncovered = g.openValue > 0n ? fmtUsdg(g.openValue) : null;
  const exposure = fmtUsdg(g.exposure);
  const verdict = exposureVerdict({ exposure: l.exposure, retention: l.retention, limit: l.limit });
  const gap =
    verdict === 'below'
      ? 'declared exposure sits below the retention'
      : verdict === 'inside'
        ? 'declared exposure lands inside the layer'
        : `${fmtUsdg(g.exposure - l.retention - l.limit)} ${u} of the declared exposure lands uncovered`;

  const openBody: ReactNode[] = [
    <span key="n" className="swatch-name">
      <span className="swatch open" />
      uncovered
    </span>,
    <b key="r">{uncovered} {u}</b>,
    <em key="a">above the limit</em>,
  ];
  const bodies: Record<LabelBox['id'], ReactNode[]> = { keep: keepBody, layer: layerBody, open: openBody, exposure: exposureBody };
  // A band keeps its own label when it was tall enough. That box sits where the
  // geometry measured it, which is the middle of the band.
  const inBand = new Map(g.labels.filter((x) => x.col === 'shaft').map((x) => [x.id, x]));
  const beside = g.labels.filter((x) => x.col === 'leader');

  return (
    <figure className="tower">
      <div className="tower-head">
        <span className="name">{l.name}</span>
        {l.who && <span className="who">{l.who}</span>}
        {l.tag && <span className={`tag ${l.tag}`}>{l.tag}</span>}
      </div>

      <div
        className={`tower-plot${g.hasLeaders ? ' lead' : ''}${g.broken ? ' broken' : ''}`}
        style={
          {
            ['--plot-h']: `${g.plotPx}px`,
            ...(g.broken ? { ['--break-lo']: `${g.breakLo}px`, ['--break-hi']: `${g.breakHi}px` } : null),
          } as Record<string, string>
        }
        role="img"
        aria-label={`Layer diagram. Loss from 0 to ${fmtUsdg(l.retention)} ${u} is the vault's own. From ${fmtUsdg(l.retention)} to ${fmtUsdg(l.retention + l.limit)} ${u} is the layer, premium ${fmtUsdg(l.premium)} ${u}. ${uncovered ? `${uncovered} ${u} above that is uncovered.` : 'Nothing above the limit is uncovered because the declared exposure stays inside the layer.'} The declared exposure is ${exposure} ${u}.${g.broken ? ` The axis is broken: a band under ${BAND_MIN_PX} pixels is drawn at ${BAND_MIN_PX}, so the bands are not in proportion to the scale.` : ''}`}
      >
        <div className="tower-gutter">
          {g.ticks.map((t) => (
            <span key={t.id} className="tick" style={{ top: `${t.top}px`, height: `${t.height}px` }}>
              <b>{fmtUsdg(t.value ?? 0n)}</b> {u}
            </span>
          ))}
        </div>

        <div className="tower-stack">
          <div className="tower-shaft">
            {g.bands.map((b) => {
              const box = inBand.get(b.kind);
              return (
                <div
                  key={b.kind}
                  className={`band ${b.kind}${b.broken ? ' broken' : ''}${b.kind === 'layer' && g.settled ? ' spent' : ''}${b.kind === 'layer' && g.cancelled ? ' void' : ''}`}
                  style={{
                    flex: `0 0 ${b.height}px`,
                    ...(b.kind === 'layer' && g.settled ? ({ ['--paid']: `${g.paidPct.toFixed(1)}%` } as Record<string, string>) : null),
                  }}
                >
                  {box && (
                    <span className="band-label in" style={{ top: `${(box.top - b.top).toFixed(2)}px`, height: `${box.height}px` }}>
                      {bodies[b.kind]}
                    </span>
                  )}
                </div>
              );
            })}
            {g.exposureTop !== null && <span className="exposure-mark" style={{ top: `${g.exposureTop}px` }} />}
          </div>

          <div className="tower-leaders" aria-hidden="true">
            {beside.map((x) => (
              <div key={x.id} className="leader" style={{ top: `${x.top}px`, height: `${x.height}px` }}>
                <i className="leader-out" style={{ top: `${(x.from - x.top).toFixed(2)}px` }} />
                <i
                  className="leader-join"
                  style={{ top: `${(Math.min(x.from, x.mid) - x.top).toFixed(2)}px`, height: `${Math.abs(x.mid - x.from).toFixed(2)}px` }}
                />
                <span className="band-label">{bodies[x.id]}</span>
              </div>
            ))}
          </div>
        </div>

        <div className="tower-axis">
          <span>0</span>
          <span>loss, {u} · scale top {fmtUsdg(BigInt(Math.round(g.ceiling)))}</span>
        </div>

        {g.broken && (
          <p className="tower-break" title={`Axis broken: a band under ${BAND_MIN_PX}px is drawn to ${BAND_MIN_PX}px so it stays visible.`}>
            <i />
            <i />
          </p>
        )}
      </div>

      <dl className="tower-key">
        <div>
          <dt>declared exposure</dt>
          <dd>
            {exposure}
            <small>{u}</small>
          </dd>
        </div>
        <div>
          <dt>retention, vault keeps</dt>
          <dd>
            {fmtUsdg(l.retention)}
            <small>{u}</small>
          </dd>
        </div>
        <div>
          <dt>limit, writers cover</dt>
          <dd>
            {fmtUsdg(l.limit)}
            <small>{u}</small>
          </dd>
        </div>
        <div>
          <dt>premium</dt>
          <dd>
            {fmtUsdg(l.premium)}
            <small>{u}</small>
          </dd>
        </div>
        {rate && (
          <div>
            <dt>rate on line</dt>
            <dd>{rate}%</dd>
          </div>
        )}
        {l.payout !== undefined && (
          <div>
            <dt>payout</dt>
            <dd>
              {fmtUsdg(l.payout)}
              <small>{u}</small>
            </dd>
          </div>
        )}
        <div className="hit">
          <dt>exposure against the layer</dt>
          <dd>{gap}</dd>
        </div>
      </dl>
    </figure>
  );
}

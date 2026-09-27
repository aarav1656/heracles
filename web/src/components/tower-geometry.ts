// Geometry of the layer diagram. Loss runs up: the vault keeps 0 to retention,
// the treaty owns retention to retention plus limit, the rest is uncovered.
// Pure layout and nothing else, so a change to the drawing can be checked here
// without a browser. Every figure and every word belongs to the caller.
//
// Two things the arithmetic on its own would get wrong, and what is done:
//
//   A band thinner than a few pixels is still a band. Every non-zero band is
//   drawn to BAND_MIN_PX, and the floor is taken back out of the tallest band,
//   so the stack is always exactly the plot height. A band drawn off the scale
//   is reported as broken along with the range it distorts, so the caller can
//   break the axis there and say so. The drawing never claims a proportion it
//   is not keeping, and the true share of every band is handed back.
//
//   A band thinner than its own label cannot hold that label. The label goes to
//   a column beside the tower and reaches back on a leader line. Boxes are
//   reserved at the line count the caller declares, so a longer figure can
//   never be pushed into its neighbour. The column is stacked against those
//   heights, pushed clear of the box above, then pulled back inside the plot,
//   so no two boxes can land on one another at any ratio of the three inputs.

const u = (v: bigint) => Number(v);
const clamp = (v: number, lo: number, hi: number) => (v < lo ? lo : v > hi ? hi : v);
const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0);
const r2 = (n: number) => Math.round(n * 100) / 100;

export type BandKind = 'keep' | 'layer' | 'open';
export type LabelId = BandKind | 'exposure';
/**
 * Which column of the plot a box sits in. Boxes are only ever placed against
 * boxes in their own column, so a gutter axis label and a band label are never
 * asked not to overlap: they are 96px apart on the paper.
 */
export type LabelCol = 'gutter' | 'shaft' | 'leader';

export type TowerInput = {
  exposure: bigint;
  retention: bigint;
  limit: bigint;
  /** 0 settled, 1 bound, 3 cancelled. Any other value is treated as bound. */
  state?: number;
  payout?: bigint;
  /**
   * Lines the caller will draw in each label box, the most it can ever be. A
   * box is reserved at this height whatever is written in it, so a short figure
   * cannot grow into the box above. The defaults are the widest the slip
   * allows: a name, a range and two notes.
   */
  lines?: Partial<Record<LabelId, number>>;
  /** Plot height in px. The caller passes PLOT_PX or PLOT_PX_NARROW. */
  plotPx?: number;
};

export type LabelBox = {
  id: LabelId;
  col: LabelCol;
  /** Top edge, px from the top of the plot. */
  top: number;
  height: number;
  /** Centre, px from the top of the plot. Where a leader line lands. */
  mid: number;
  /** Leader boxes: the band edge the line leaves from, px from the top. */
  from: number;
  /** The figure an axis label prints. */
  value?: bigint;
};

export type PlacedBand = {
  kind: BandKind;
  /** The figure the contract reported for this band, raw units. */
  value: bigint;
  /** Height as drawn, px. Never under BAND_MIN_PX while value is above zero. */
  height: number;
  /** Top edge, px from the top of the plot. */
  top: number;
  /** Middle, px from the top of the plot. */
  mid: number;
  /** Height this figure alone earns on the true scale, px. */
  trueHeight: number;
  /** Drawn taller than the scale allows, so the axis breaks across it. */
  broken: boolean;
  /** Share of the true scale, to two decimals. The honest proportion. */
  sharePct: number;
};

export type TowerGeometry = {
  /** Drawn top of the stack first, the base of the plot last. */
  bands: PlacedBand[];
  /** Height to draw the plot at, after the label column asked for the room. */
  plotPx: number;
  /** Scale ceiling, raw units. The larger of retention plus limit and the exposure. */
  ceiling: number;
  /** The uncovered band, raw units. Zero when the exposure stays inside the layer. */
  openValue: bigint;
  /** Axis labels for the boundaries that have room for one, top first. */
  ticks: LabelBox[];
  /** Band labels, plus the exposure callout. Sorted top of the plot first. */
  labels: LabelBox[];
  /** True when a label had to leave its band, so a column is drawn. */
  hasLeaders: boolean;
  /** The declared exposure, always positive. */
  exposure: bigint;
  /** Exposure marker, px from the top of the plot. Null at zero exposure. */
  exposureTop: number | null;
  /** True when at least one band had to be drawn off the scale. */
  broken: boolean;
  /** Top of the range the drawn scale does not keep, px from the plot top. */
  breakLo: number;
  /** Bottom of that range, px from the plot top. */
  breakHi: number;
  paidPct: number;
  settled: boolean;
  cancelled: boolean;
};

/** Plot height in px. Matches --plot-h on the plot row. */
export const PLOT_PX = 244;
/** Plot height at the narrow breakpoint, where the key wraps under the tower. */
export const PLOT_PX_NARROW = 208;
/** The plot grows to this if the label column cannot fit in what it asked for. */
export const PLOT_MAX_PX = 420;
/** Shortest edge a non-zero band is drawn with, px. */
export const BAND_MIN_PX = 22;
/** One rendered line inside a label box, px. */
export const LABEL_LINE_PX = 16;
/** Above and below the lines inside a label box, px. */
export const LABEL_PAD_PX = 4;
/** Room between two label boxes in the column, px. */
export const LABEL_GAP_PX = 6;
/** Room a band must have to spare before it holds its own label, px. */
export const INSIDE_PAD_PX = 8;
/** Height reserved for an axis label, px. */
export const TICK_PX = 16;
/** Clear space kept between two axis labels, px. */
export const TICK_CLEAR_PX = 4;
/** An axis label nearer the base than this is dropped rather than clipped, px. */
export const TICK_FLOOR_PX = 9;

const DEFAULT_LINES: Record<LabelId, number> = { keep: 2, layer: 4, open: 3, exposure: 2 };

/**
 * Who loses their box first when even a grown plot cannot hold them all. The
 * exposure callout is the only label on the dashed marker and the only figure
 * not repeated in the key, so it goes last.
 */
const DROP_FIRST: Record<LabelId, number> = { open: 0, layer: 1, keep: 2, exposure: 3 };

const boxPx = (lines: number) => Math.max(1, lines) * LABEL_LINE_PX + LABEL_PAD_PX * 2;

/**
 * Heights for the stack. Proportional first, then a floor under every non-zero
 * band, then the floors are paid for out of whichever band has the most room
 * above its own floor. The result always sums to the plot height.
 */
function bandHeights(values: number[], ceiling: number, px: number): number[] {
  const drawn = values.map((v) => (ceiling > 0 ? (v / ceiling) * px : 0));
  for (let k = 0; k < drawn.length; k += 1) if (values[k] > 0) drawn[k] = Math.max(drawn[k], BAND_MIN_PX);
  let surplus = sum(drawn) - px;
  while (surplus > 0.001) {
    let tallest = -1;
    let room = 0.001;
    for (let k = 0; k < drawn.length; k += 1) {
      const head = drawn[k] - BAND_MIN_PX;
      if (head > room) {
        room = head;
        tallest = k;
      }
    }
    if (tallest < 0) break;
    const take = Math.min(surplus, room);
    drawn[tallest] -= take;
    surplus -= take;
  }
  return drawn;
}

/**
 * Tops for a run of boxes down a column, px from the top of the plot. Each box
 * starts where its own anchor wants it, is pushed clear of the box above, then
 * the whole run is pulled back inside the plot. If a box ends up above the top
 * the run is laid from the top instead, which is always safe. Returns null when
 * even one box is taller than the plot, so the caller can give it more height.
 */
function stackColumn(boxes: { height: number; mid: number }[], px: number): number[] | null {
  const n = boxes.length;
  if (n === 0) return [];
  const total = sum(boxes.map((b) => b.height));
  if (total > px) return null;
  const gap = n > 1 ? Math.min(LABEL_GAP_PX, (px - total) / (n - 1)) : 0;
  const tops = boxes.map((b) => clamp(b.mid - b.height / 2, 0, px - b.height));
  let floor = 0;
  for (let k = 0; k < n; k += 1) {
    tops[k] = Math.max(tops[k], floor);
    floor = tops[k] + boxes[k].height + gap;
  }
  for (let k = n - 1; k >= 0; k -= 1) {
    const limit = k === n - 1 ? px - boxes[k].height : tops[k + 1] - gap - boxes[k].height;
    tops[k] = Math.min(tops[k], limit);
  }
  if (tops[0] < 0) {
    let y = 0;
    for (let k = 0; k < n; k += 1) {
      tops[k] = y;
      y += boxes[k].height + gap;
    }
  }
  return tops;
}

type Built = {
  px: number;
  stack: PlacedBand[];
  labels: LabelBox[];
  ticks: LabelBox[];
  mark: number | null;
  need: number;
  broken: boolean;
  breakLo: number;
  breakHi: number;
};

export function towerGeometry(i: TowerInput): TowerGeometry {
  const ret = u(i.retention);
  const lim = u(i.limit);
  const exp = u(i.exposure < 0n ? -i.exposure : i.exposure);
  const top = ret + lim;
  const ceiling = Math.max(top, exp) || 1;
  const openV = Math.max(ceiling - top, 0);
  const settled = i.state === 2;
  const cancelled = i.state === 3;
  const lines: Record<LabelId, number> = { ...DEFAULT_LINES, ...i.lines };
  const base = Math.max(i.plotPx ?? PLOT_PX, 1);

  // Base of the plot first, because that is the order loss stacks in.
  const spec: { kind: BandKind; value: number }[] = [];
  if (ret > 0) spec.push({ kind: 'keep', value: ret });
  if (lim > 0) spec.push({ kind: 'layer', value: lim });
  if (openV > 0) spec.push({ kind: 'open', value: openV });

  function build(px: number): Built {
    const heights = bandHeights(
      spec.map((s) => s.value),
      ceiling,
      px,
    );

    let acc = 0;
    const stack = spec.map((s, k) => {
      const trueHeight = (s.value / ceiling) * px;
      const topPx = px - acc - heights[k];
      const band: PlacedBand = {
        kind: s.kind,
        value: BigInt(Math.round(s.value)),
        height: r2(heights[k]),
        top: r2(topPx),
        mid: r2(topPx + heights[k] / 2),
        trueHeight: r2(trueHeight),
        broken: heights[k] - trueHeight > 0.5,
        sharePct: r2((s.value / ceiling) * 100),
      };
      acc += heights[k];
      return band;
    });

    // A band that can hold its own label keeps it, centred on the band. One
    // that cannot hands it to the column, which remembers where it left from.
    const labels: LabelBox[] = [];
    const column: { id: LabelId; height: number; mid: number }[] = [];
    for (const band of stack) {
      const h = boxPx(lines[band.kind]);
      if (band.height >= h + INSIDE_PAD_PX) {
        labels.push({
          id: band.kind,
          col: 'shaft',
          top: r2(band.top + (band.height - h) / 2),
          height: r2(h),
          mid: band.mid,
          from: 0,
        });
      } else {
        column.push({ id: band.kind, height: h, mid: band.mid });
      }
    }
    const mark = exp > 0 ? r2(px * (1 - exp / ceiling)) : null;
    if (mark !== null) column.push({ id: 'exposure', height: boxPx(lines.exposure), mid: mark });
    column.sort((a, b) => a.mid - b.mid);
    // What the column needs before anything is given up, so a caller that can
    // give it more room does that first.
    const need = column.length > 1 ? sum(column.map((c) => c.height)) + (column.length - 1) * LABEL_GAP_PX : 0;

    let tops = stackColumn(column, px);
    while (tops === null && column.length > 1) {
      let worst = 0;
      for (let k = 1; k < column.length; k += 1) if (DROP_FIRST[column[k].id] < DROP_FIRST[column[worst].id]) worst = k;
      column.splice(worst, 1);
      tops = stackColumn(column, px);
    }
    column.forEach((c, k) => {
      const top = tops ? tops[k] : 0;
      labels.push({ id: c.id, col: 'leader', top: r2(top), height: r2(c.height), mid: r2(top + c.height / 2), from: c.mid });
    });
    labels.sort((a, b) => a.top - b.top || a.col.localeCompare(b.col));

    // An axis label sits on the boundary it names. Two that would land on one
    // another are pulled apart by a computed offset, the way a drafter would.
    // A boundary too near the base to hold a legible label is dropped: its
    // figure is on the band and in the key.
    const wanted: { id: BandKind; value: bigint; top: number }[] = [];
    const layer = stack.find((b) => b.kind === 'layer');
    const keep = stack.find((b) => b.kind === 'keep');
    if (layer) wanted.push({ id: 'layer', value: i.retention + i.limit, top: layer.top });
    if (keep) wanted.push({ id: 'keep', value: i.retention, top: keep.top });
    wanted.sort((a, b) => a.top - b.top);
    const ticks: LabelBox[] = [];
    let lastTop = -Infinity;
    for (const t of wanted) {
      const clear = lastTop + TICK_PX + TICK_CLEAR_PX;
      const at = lastTop === -Infinity ? t.top : Math.max(t.top, clear);
      if (at < TICK_FLOOR_PX) continue;
      lastTop = at;
      ticks.push({ id: t.id, col: 'gutter', top: r2(at - TICK_PX / 2), height: TICK_PX, mid: r2(at), from: 0, value: t.value });
    }

    const off = stack.filter((b) => b.broken);
    return {
      px,
      stack,
      labels,
      ticks,
      mark,
      need,
      broken: off.length > 0,
      breakLo: off.length > 0 ? r2(Math.min(...off.map((b) => b.top))) : 0,
      breakHi: off.length > 0 ? r2(Math.max(...off.map((b) => b.top + b.height))) : 0,
    };
  }

  let built = build(base);
  // The column asked for more room than the caller gave the plot. Take it, up
  // to a ceiling, and measure again: a taller plot only ever gives more room.
  if (built.need > base) built = build(Math.min(PLOT_MAX_PX, Math.max(base, built.need)));

  return {
    bands: built.stack.slice().reverse(),
    plotPx: built.px,
    ceiling,
    openValue: BigInt(Math.round(openV)),
    ticks: built.ticks,
    labels: built.labels,
    hasLeaders: built.labels.some((b) => b.col === 'leader'),
    exposure: i.exposure < 0n ? -i.exposure : i.exposure,
    exposureTop: built.mark,
    broken: built.broken,
    breakLo: built.breakLo,
    breakHi: built.breakHi,
    paidPct: settled && lim > 0 ? Math.min(100, Math.max(0, (u(i.payout ?? 0n) / lim) * 100)) : 0,
    settled,
    cancelled,
  };
}

/** Where a declared exposure lands against the band that was bought. */
export function exposureVerdict(i: TowerInput): string {
  const ret = u(i.retention);
  const lim = u(i.limit);
  const exp = u(i.exposure < 0n ? -i.exposure : i.exposure);
  const top = ret + lim;
  if (exp <= ret) return 'below';
  if (exp <= top) return 'inside';
  return 'uncovered';
}

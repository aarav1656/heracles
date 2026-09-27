// The defect this guards: with realistic numbers the retention and layer bands
// are a few pixels tall, so their labels landed on each other and the retention
// band could not be seen at all. Two properties have to hold at every ratio of
// retention, limit and exposure:
//
//   every non-zero band is drawn to a floor, and the drawing says so; and
//   no two label boxes in the same column share a pixel.
//
// The second is checked against the box heights the component reserves, not
// against a nominal row, so a label with a long figure in it is caught too.
//
//   node --test --experimental-strip-types src/components/tower-geometry.test.ts

import assert from 'node:assert/strict';
import test from 'node:test';
import {
  BAND_MIN_PX,
  INSIDE_PAD_PX,
  LABEL_GAP_PX,
  LABEL_LINE_PX,
  LABEL_PAD_PX,
  PLOT_PX,
  PLOT_PX_NARROW,
  exposureVerdict,
  towerGeometry,
} from './tower-geometry.ts';
import type { LabelBox, TowerGeometry, TowerInput } from './tower-geometry.ts';

const usdg = (n: number) => BigInt(Math.round(n * 1_000_000));

/** The line counts LayerTower passes, which are the widest figures it prints. */
const LINES = { keep: 2, layer: 4, open: 3, exposure: 2 };
const boxPx = (lines: number) => lines * LABEL_LINE_PX + LABEL_PAD_PX * 2;

const draw = (i: TowerInput, plotPx = PLOT_PX) => towerGeometry({ ...i, plotPx, lines: LINES });

/** Every label box, grouped by the column it is drawn in. */
const columns = (g: TowerGeometry) => {
  const cols = new Map<string, LabelBox[]>();
  for (const b of [...g.labels, ...g.ticks]) {
    const list = cols.get(b.col) ?? [];
    list.push(b);
    cols.set(b.col, list);
  }
  for (const list of cols.values()) list.sort((a, b) => a.top - b.top);
  return cols;
};

const hits = (g: TowerGeometry) => {
  const found: string[] = [];
  for (const [col, list] of columns(g)) {
    for (let a = 0; a < list.length; a += 1) {
      for (let b = a + 1; b < list.length; b += 1) {
        const A = list[a];
        const B = list[b];
        if (A.top < B.top + B.height - 1e-9 && B.top < A.top + A.height - 1e-9) found.push(`${col}: ${A.id} and ${B.id}`);
      }
    }
  }
  return found;
};

const CASES = [
  { name: 'exposure 100, retention 2, limit 10', retention: 2, limit: 10, exposure: 100, bands: ['open', 'layer', 'keep'] },
  { name: 'exposure 60, retention 10, limit 50', retention: 10, limit: 50, exposure: 60, bands: ['layer', 'keep'] },
  { name: 'exposure 100, retention 0, limit 100', retention: 0, limit: 100, exposure: 100, bands: ['layer'] },
  { name: 'exposure 1000, retention 50, limit 10', retention: 50, limit: 10, exposure: 1000, bands: ['open', 'layer', 'keep'] },
] as const;

for (const c of CASES) {
  for (const plotPx of [PLOT_PX, PLOT_PX_NARROW]) {
    const input = { exposure: usdg(c.exposure), retention: usdg(c.retention), limit: usdg(c.limit) };

    test(`${c.name}, ${plotPx}px plot: no two label boxes share a pixel`, () => {
      const g = draw(input, plotPx);
      assert.deepEqual(hits(g), [], `overlapping labels: ${hits(g).join(', ')}`);
      const drawn = new Set<string>(g.bands.map((b) => b.kind));
      // The exposure callout is a label on the dashed marker, not on a band.
      const named = new Set<string>(g.labels.filter((b) => b.id !== 'exposure').map((b) => b.id));
      for (const kind of c.bands) {
        assert.ok(drawn.has(kind), `${kind} band is drawn`);
        assert.ok(named.has(kind), `${kind} band has a label`);
      }
      assert.equal(named.size, c.bands.length, `one label per band, got ${[...named].join(', ')}`);
    });

    test(`${c.name}, ${plotPx}px plot: every box sits inside the plot and holds its own lines`, () => {
      const g = draw(input, plotPx);
      for (const b of [...g.labels, ...g.ticks]) {
        assert.ok(b.top >= -1e-9, `${b.id} box runs off the top of the plot at ${b.top}px`);
        assert.ok(b.top + b.height <= g.plotPx + 1e-9, `${b.id} box runs off the base at ${b.top + b.height - g.plotPx}px`);
      }
      for (const b of g.labels) {
        const want = boxPx(LINES[b.id]);
        assert.ok(b.height >= want - 1e-9, `${b.id} box is ${b.height}px, its own ${want}px of lines do not fit`);
      }
    });

    test(`${c.name}, ${plotPx}px plot: every non-zero band clears the floor`, () => {
      const g = draw(input, plotPx);
      assert.deepEqual(g.bands.map((b) => b.kind), [...c.bands], 'bands drawn top of the stack first');
      for (const b of g.bands) {
        assert.ok(b.value > 0n, `${b.kind} is drawn, so it is not zero`);
        assert.ok(b.height >= BAND_MIN_PX - 1e-9, `${b.kind} band is ${b.height}px, under the ${BAND_MIN_PX}px floor`);
      }
    });

    test(`${c.name}, ${plotPx}px plot: the stack is exactly the plot height`, () => {
      const g = draw(input, plotPx);
      assert.equal(g.plotPx, plotPx, 'no extra height was needed');
      const total = g.bands.reduce((s, b) => s + b.height, 0);
      assert.ok(Math.abs(total - plotPx) < 0.02, `stack is ${total}px, want ${plotPx}px`);
      const base = g.bands[g.bands.length - 1];
      assert.ok(Math.abs(base.top + base.height - plotPx) < 0.02, 'the bottom band sits on zero');
    });

    test(`${c.name}, ${plotPx}px plot: a broken band is marked and the axis says so`, () => {
      const g = draw(input, plotPx);
      const off = g.bands.filter((b) => b.broken);
      assert.equal(g.broken, off.length > 0, 'the break is reported when a band is off the scale');
      if (off.length === 0) {
        assert.equal(g.breakHi - g.breakLo, 0, 'no break, no range to mark');
        return;
      }
      assert.ok(g.breakLo < g.breakHi, 'the break names a range');
      assert.ok(g.breakLo >= -1e-9 && g.breakHi <= g.plotPx + 1e-9, 'the break range is inside the plot');
      for (const b of off) {
        assert.ok(b.height > b.trueHeight, `${b.kind} is drawn above its true ${b.trueHeight}px`);
        assert.ok(b.top >= g.breakLo - 1e-9 && b.top + b.height <= g.breakHi + 1e-9, `${b.kind} sits inside the break it caused`);
        assert.ok(b.sharePct > 0 && b.sharePct <= 100, 'the true share is handed back so the caller can print it');
      }
    });

    test(`${c.name}, ${plotPx}px plot: a label only leaves its band when the band is too thin`, () => {
      const g = draw(input, plotPx);
      for (const b of g.bands) {
        const box = g.labels.find((x) => x.id === b.kind);
        assert.ok(box, `${b.kind} has a label box`);
        const fits = b.height >= boxPx(LINES[b.kind]) + INSIDE_PAD_PX;
        assert.equal(box.col === 'shaft', fits, `${b.kind} band is ${b.height}px, its label needs ${boxPx(LINES[b.kind])}px`);
        if (fits) {
          assert.ok(Math.abs(box.mid - (b.top + b.height / 2)) < 0.02, `${b.kind} label is centred on its band`);
        } else {
          assert.equal(box.col, 'leader', `${b.kind} label went to the column`);
        }
      }
    });

    test(`${c.name}, ${plotPx}px plot: a leader line leaves its own band and lands on its box`, () => {
      const g = draw(input, plotPx);
      for (const box of g.labels) {
        if (box.col !== 'leader' || box.id === 'exposure') continue;
        const band = g.bands.find((b) => b.kind === box.id);
        assert.ok(band, `${box.id} names a band that is drawn`);
        assert.ok(box.from >= band.top - 0.02 && box.from <= band.top + band.height + 0.02, `${box.id} line leaves its own band`);
        assert.ok(Math.abs(box.mid - (box.top + box.height / 2)) < 0.02, `${box.id} line lands on the middle of its box`);
      }
    });
  }
}

test('a zero band draws no band and no label, and no axis label at zero', () => {
  const g = draw({ exposure: usdg(100), retention: 0n, limit: usdg(100) });
  assert.deepEqual(g.bands.map((b) => b.kind), ['layer']);
  assert.deepEqual(g.labels.map((b) => b.id), ['exposure', 'layer'], 'the exposure callout and the layer label');
  assert.equal(g.ticks.filter((t) => t.value === 0n).length, 0, 'no axis label at zero');
  assert.equal(g.broken, false, 'a full-height layer band needs no floor');
  assert.equal(g.labels.find((b) => b.id === 'layer')?.col, 'shaft', 'a 244px band holds its own label');
});

test('the figures the reader sees are the figures the contract reported', () => {
  const g = draw({ exposure: usdg(100), retention: usdg(2), limit: usdg(10) });
  assert.deepEqual(g.bands.map((b) => b.value), [88_000_000n, 10_000_000n, 2_000_000n], 'uncovered, limit, retention');
  assert.equal(g.ceiling, 100_000_000);
  assert.equal(g.openValue, 88_000_000n);
  assert.equal(g.exposure, 100_000_000n);
  assert.equal(g.exposureTop, 0, 'the declared exposure sits at the top of the scale');
  assert.deepEqual(g.bands.map((b) => b.sharePct), [88, 10, 2], 'the honest proportions');
});

test('both layer boundaries keep an axis label, and each sits on the line it names', () => {
  const g = draw({ exposure: usdg(100), retention: usdg(2), limit: usdg(10) });
  assert.deepEqual(g.ticks.map((t) => t.value), [12_000_000n, 2_000_000n], 'the layer boundary and the retention, both readable');
  const layer = g.bands.find((b) => b.kind === 'layer')!;
  const keep = g.bands.find((b) => b.kind === 'keep')!;
  assert.ok(Math.abs(g.ticks[0].mid - layer.top) < 0.02, 'the layer tick sits on the layer edge');
  assert.ok(Math.abs(g.ticks[1].mid - keep.top) < 0.02, 'the retention tick sits on the retention edge');
});

test('no exposure is no marker, and a boundary too near the base is dropped not clipped', () => {
  assert.equal(draw({ exposure: usdg(0), retention: usdg(2), limit: usdg(10) }).exposureTop, null);
  const g = draw({ exposure: usdg(100), retention: usdg(1), limit: usdg(100) });
  for (const t of g.ticks) assert.ok(t.mid >= 9, 'an axis label never hangs off the base of the plot');
  for (let a = 1; a < g.ticks.length; a += 1) {
    assert.ok(g.ticks[a - 1].top + g.ticks[a - 1].height <= g.ticks[a].top + 1e-9, 'survivors are nudged clear');
  }
});

test('a signed exposure draws the same band as its magnitude', () => {
  const long = draw({ exposure: usdg(100), retention: usdg(2), limit: usdg(10) });
  const short = draw({ exposure: usdg(-100), retention: usdg(2), limit: usdg(10) });
  assert.deepEqual(short.bands, long.bands);
  assert.equal(short.exposure, 100_000_000n);
  assert.equal(exposureVerdict({ exposure: usdg(-100), retention: usdg(2), limit: usdg(10) }), 'uncovered');
});

test('a settled layer pays out of the band, a cancelled one is an empty outline', () => {
  const settled = draw({ exposure: usdg(100), retention: usdg(2), limit: usdg(10), payout: usdg(4), state: 2 });
  assert.equal(settled.settled, true);
  assert.equal(settled.paidPct, 40);
  const cancelled = draw({ exposure: usdg(100), retention: usdg(2), limit: usdg(10), state: 3 });
  assert.equal(cancelled.cancelled, true);
  assert.equal(cancelled.paidPct, 0);
  assert.equal(cancelled.broken, true, 'a cancelled band is still held to the floor, and says so');
});

test('the column grows the plot rather than dropping a label, and still never overlaps', () => {
  const wide = { keep: 4, layer: 4, open: 4, exposure: 4 };
  const g = towerGeometry({ exposure: usdg(100), retention: usdg(2), limit: usdg(10), plotPx: PLOT_PX_NARROW, lines: wide });
  assert.ok(g.plotPx > PLOT_PX_NARROW, `plot grew to ${g.plotPx}px to hold the column`);
  assert.deepEqual(hits(g), [], `overlapping labels: ${hits(g).join(', ')}`);
  // Four lines a box is far more than any of them needs, so nothing may be
  // thrown away to make room: all three bands and the exposure callout survive.
  assert.deepEqual(
    g.labels.map((b) => b.id).sort(),
    ['exposure', 'keep', 'layer', 'open'],
    'nothing was dropped to make the column fit',
  );
  // The uncovered band is the tall one, so it is the one that can still hold its
  // own label in place. The two thin bands and the callout are what move out.
  assert.deepEqual(
    g.labels.filter((b) => b.col === 'shaft').map((b) => b.id),
    ['open'],
    'only a band too thin for its label hands it to the column',
  );
  const column = g.labels.filter((b) => b.col === 'leader');
  assert.equal(column.length, 3, 'the exposure callout, the layer and the retention are in the column');
  for (let k = 1; k < column.length; k += 1) {
    assert.ok(column[k - 1].top + column[k - 1].height <= column[k].top + 1e-9, 'boxes are pushed clear of one another');
  }
});

test('the column keeps the exposure callout before any band label', () => {
  const g = towerGeometry({ exposure: usdg(100), retention: usdg(2), limit: usdg(10), plotPx: 40, lines: LINES });
  assert.ok(g.labels.some((b) => b.id === 'exposure'), 'the exposure callout survives: it is the one label not repeated in the key');
  assert.deepEqual(hits(g), [], `overlapping labels: ${hits(g).join(', ')}`);
});

test('a gap is kept between two boxes in the column wherever they can sit', () => {
  const g = draw({ exposure: usdg(100), retention: usdg(2), limit: usdg(10) });
  const column = g.labels.filter((b) => b.col === 'leader').sort((a, b) => a.top - b.top);
  assert.ok(column.length > 1, 'this ratio does put boxes in the column');
  for (let k = 1; k < column.length; k += 1) {
    const gap = column[k].top - (column[k - 1].top + column[k - 1].height);
    assert.ok(gap >= LABEL_GAP_PX - 1e-9, `gap of ${gap.toFixed(2)}px between ${column[k - 1].id} and ${column[k].id}`);
  }
});

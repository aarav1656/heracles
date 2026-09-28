// Pure pricing helpers, split from gaps.ts so node can test them without the JSON imports.
export type Weekend = { friday: string; monday: string; gap: number };

/** Pricer tail size: the worst 25 of 504 scenarios (docs/pricing.md, TAIL). */
const TAIL = 25;

export type Backtest = {
  payouts: number[];
  el: number;
  tvar95: number;
  paid: number;
  exhausted: number;
  /** Gap, in bps, where the layer starts paying and where it runs out. Signed toward the loss side. */
  attachBps: number;
  exhaustBps: number;
};

/**
 * Pricer.priceCore for one market at volatility scale 1.0x: loss = -exposure * gap / 10,000
 * (a long loses on a down gap), payout = min(limit, max(0, loss - retention)).
 * Amounts in whole USDG. Exposure is signed: positive long, negative short.
 */
export function backtest(weekends: Weekend[], exposure: number, retention: number, limit: number): Backtest {
  const payouts = weekends.map((w) => Math.min(limit, Math.max(0, (-exposure * w.gap) / 10_000 - retention)));
  const sorted = [...payouts].sort((a, b) => b - a);
  const mean = (xs: number[]) => (xs.length ? xs.reduce((s, x) => s + x, 0) / xs.length : 0);
  const side = exposure >= 0 ? -1 : 1;
  const mag = Math.abs(exposure) || 1;
  return {
    payouts,
    el: mean(payouts),
    tvar95: mean(sorted.slice(0, TAIL)),
    paid: payouts.filter((p) => p > 0).length,
    exhausted: limit > 0 ? payouts.filter((p) => p >= limit).length : 0,
    attachBps: (side * retention * 10_000) / mag,
    exhaustBps: (side * (retention + limit) * 10_000) / mag,
  };
}

export function extremes(weekends: Weekend[]) {
  let down = weekends[0];
  let up = weekends[0];
  for (const w of weekends) {
    if (w.gap < down.gap) down = w;
    if (w.gap > up.gap) up = w;
  }
  return { down, up, beyond1pct: weekends.filter((w) => Math.abs(w.gap) >= 100).length };
}

/** 2020-03-13 -> "13 Mar 2020". */
export function fmtDay(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  return `${d} ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1]} ${y}`;
}

/** -1045 -> "−10.45%", 52 -> "+0.52%". */
export function fmtBps(bps: number): string {
  const s = (Math.abs(bps) / 100).toFixed(2);
  return `${bps < 0 ? '−' : bps > 0 ? '+' : ''}${s}%`;
}

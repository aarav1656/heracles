// Mockup data: the committed SPY table and the pricer's payout rule (lib/gaps-core.ts), plus the
// last live quote read by the app (block printed). Static mockups only; the app reads live.
export const QUOTE = { premium: 1676.72, el: 1051.19, tvar: 20368.0, block: 313814630 };
export const REF = { exposure: 2_000_000, retention: 20_000, limit: 60_000 };
export async function load() {
  const t = await (await fetch('/src/data/gap-tables/SPY.json')).json();
  const ws = t.gaps.map((g) => ({ friday: g.friday, monday: g.monday, gap: g.gap_bps }));
  const pay = ws.map((w) => Math.min(REF.limit, Math.max(0, (-REF.exposure * w.gap) / 10000 - REF.retention)));
  const attach = (-REF.retention * 10000) / REF.exposure; // -100 bps
  const exhaust = (-(REF.retention + REF.limit) * 10000) / REF.exposure; // -400 bps
  let worst = 0; ws.forEach((w, i) => { if (w.gap < ws[worst].gap) worst = i; });
  return { ws, pay, attach, exhaust, worst, paid: pay.filter((p) => p > 0).length, full: pay.filter((p) => p >= REF.limit).length };
}
const M = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
export const day = (iso) => { const [y, m, d] = iso.split('-').map(Number); return `${d} ${M[m - 1]} ${y}`; };
export const pct = (b) => `${b < 0 ? '−' : b > 0 ? '+' : ''}${(Math.abs(b) / 100).toFixed(2)}%`;
export const n0 = (v) => Math.round(v).toLocaleString('en-US');

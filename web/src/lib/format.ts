import { formatUnits } from 'viem';

const usd6 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 6 });
const usd2 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/** USDG 6dp -> "1,234.56". */
export const fmtUsdg = (v: bigint) => usd6.format(Number(formatUnits(v, 6)));
/** Chainlink 8dp -> "771.02". */
export const fmtPx = (v: bigint) => usd2.format(Number(formatUnits(v, 8)));

/** "100.5" typed by a user in USDG units -> raw 6dp. Throws on bad input. */
export function parseUsdg(s: string): bigint {
  const t = s.trim();
  if (!/^\d+(\.\d{1,6})?$/.test(t)) throw new Error('Enter an amount like 10 or 2.50.');
  const [whole, frac = ''] = t.split('.');
  return BigInt(whole) * 1_000_000n + BigInt((frac + '000000').slice(0, 6));
}

/** Signed exposure in USDG units -> raw int256 in 6dp fixed point. */
export function parseExposure(s: string): bigint {
  const t = s.trim();
  if (!/^-?\d+(\.\d{1,6})?$/.test(t)) throw new Error('Enter a signed amount like -100 or 250.75.');
  const neg = t.startsWith('-');
  const body = neg ? t.slice(1) : t;
  const [whole, frac = ''] = body.split('.');
  const mag = BigInt(whole) * 1_000_000n + BigInt((frac + '000000').slice(0, 6));
  return neg ? -mag : mag;
}

export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const pad = (n: number) => String(n).padStart(2, '0');

/** "Fri 3 Oct 19:30" in UTC. */
export function fmtClock(sec: bigint | number): string {
  const d = new Date(Number(sec) * 1000);
  return `${DAYS[d.getUTCDay()]} ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
}

/** "2026-09-25 19:30:00 UTC". */
export function fmtStamp(sec: bigint | number): string {
  if (Number(sec) === 0) return 'never';
  return new Date(Number(sec) * 1000).toISOString().replace('T', ' ').slice(0, 19) + ' UTC';
}

/** Signed countdown: "2d 04h 12m" or "04h 12m 05s", past times end with "ago". */
export function fmtCountdown(deltaSec: number): string {
  const neg = deltaSec < 0;
  let s = Math.abs(Math.floor(deltaSec));
  const d = Math.floor(s / 86400); s -= d * 86400;
  const h = Math.floor(s / 3600); s -= h * 3600;
  const m = Math.floor(s / 60); s -= m * 60;
  const body = d > 0 ? `${d}d ${pad(h)}h ${pad(m)}m` : `${pad(h)}h ${pad(m)}m ${pad(s)}s`;
  return neg ? `${body} ago` : body;
}

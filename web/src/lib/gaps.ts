// The four 504-weekend gap tables the pricer is built from, read straight from the committed
// evidence files (docs/pricing.md "Data provenance"), and the pricer's own payout rule run over
// them in the browser. Nothing here is a new number: every figure is one of these rows, or the
// Pricer.priceCore formula applied to them at the neutral 1.0x volatility scale.
import spy from '../../../evidence/gap-tables/SPY.json';
import nvda from '../../../evidence/gap-tables/NVDA.json';
import aapl from '../../../evidence/gap-tables/AAPL.json';
import tsla from '../../../evidence/gap-tables/TSLA.json';

import type { Weekend } from './gaps-core';
export * from './gaps-core';
export type Ticker = 'SPY' | 'NVDA' | 'AAPL' | 'TSLA';
export type GapTable = { ticker: Ticker; file: string; source: string; fetchDate: string; weekends: Weekend[] };

type Raw = { ticker: string; fetch_date: string; source: string; gaps: { friday: string; monday: string; gap_bps: number }[] };

const load = (r: Raw): GapTable => ({
  ticker: r.ticker as Ticker,
  file: `evidence/gap-tables/${r.ticker}.json`,
  source: new URL(r.source).host,
  fetchDate: r.fetch_date,
  weekends: r.gaps.map((g) => ({ friday: g.friday, monday: g.monday, gap: g.gap_bps })),
});

/** SPY first: it is the one market the Sepolia pricer holds (tableIdAt(0) = 2, README). */
export const TABLES: GapTable[] = [spy, nvda, aapl, tsla].map((r) => load(r as Raw));

/**
 * The layer the README quotes live (block 313,690,038): long 2,000,000 USDG of SPY, retention
 * 20,000, limit 60,000. The app re-quotes it at the current block; RECORDED is the fallback.
 */
export const REFERENCE = { exposure: 2_000_000, retention: 20_000, limit: 60_000 } as const;
export const RECORDED = { premium: 1_676.722158, el: 1_051.190476, tvar: 20_368, block: 313_690_038n } as const;


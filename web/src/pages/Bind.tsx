import { useEffect, useMemo, useState } from 'react';
import { useConnection, usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { FEED_ADDRESSES, PRICER_ADDRESS } from '../abi';
import { explorer } from '../chain';
import { useBook } from '../hooks/useBook';
import { useLiveQuote, termsKey, type Terms } from '../hooks/useLiveQuote';
import { useNow } from '../hooks/useNow';
import { useWeekWindow } from '../hooks/useWeekWindow';
import { Money } from '../components/Money';
import { GapChart } from '../components/GapChart';
import { BuyCover, charged } from '../components/BuyCover';
import { fmtClock, fmtCountdown, fmtUsdg, parseExposure, parseUsdg, short } from '../lib/format';
import { TABLES, backtest } from '../lib/gaps';

const spy = TABLES[0];
const toUsd = (v: bigint) => Number(v) / 1e6;
const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const usd2 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

/** The same bind as the cover page, with every term typed in USDG instead of set on a band. */
export function Bind() {
  useEffect(() => { document.title = 'Heracles: exact cover terms'; }, []);
  const conn = useConnection();
  const client = usePublicClient() as PublicClient | undefined;
  const book = useBook(conn.address);
  const now = useNow();
  const win = useWeekWindow(client, now);

  const [exposures, setExposures] = useState<string[]>(() => FEED_ADDRESSES.map(() => '2,000,000'));
  const [retention, setRetention] = useState('20,000');
  const [limit, setLimit] = useState('60,000');

  const parsed = useMemo((): { terms?: Terms; error?: string } => {
    try {
      const exp = exposures.map((x) => parseExposure(x.replace(/,/g, '')));
      const ret = parseUsdg(retention.replace(/,/g, ''));
      const lim = parseUsdg(limit.replace(/,/g, ''));
      if (exp.every((e) => e === 0n)) return { error: 'At least one position must be non-zero. A zero-exposure bind reverts with BadParams.' };
      if (lim === 0n) return { error: 'The limit must be above zero. A zero limit binds nothing.' };
      return { terms: { exp, ret, lim } };
    } catch (e) {
      return { error: e instanceof Error ? e.message : String(e) };
    }
  }, [exposures, retention, limit]);
  const terms = parsed.terms;
  const live = useLiveQuote(terms);
  const quote = live.quote;
  const same = quote !== undefined && termsKey(quote.terms) === termsKey(terms);
  const minRateBps = book.data?.value.minRateBps;
  const price = terms && quote && minRateBps !== undefined ? charged(quote.premium, quote.terms.lim, minRateBps) : undefined;
  const stale = live.quoting || (quote !== undefined && !same);

  const layer = useMemo(
    () => (terms ? { exposure: toUsd(terms.exp[0] ?? 0n), retention: toUsd(terms.ret), limit: toUsd(terms.lim) } : undefined),
    [terms],
  );
  const bt = useMemo(() => (layer ? backtest(spy.weekends, layer.exposure, layer.retention, layer.limit) : undefined), [layer]);
  const closed = win !== undefined && now >= win.cutoff && now < win.expiry;

  return (
    <div className="page form-first">
      <div className="lead">
        <h1 className="hero">Exact <span>terms</span></h1>
        <div className="meta">
          <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)} ↗</a>
          <span><i />Arbitrum Sepolia</span>
          <span><i className="t" />Stylus pricer</span>
          <span><i />USDG</span>
        </div>
        <p className="desc">
          Type the position your vault declared, the loss it keeps and the most Heracles pays, all in USDG. The payout
          is the Monday gap on the feed times the declared position, minus what the vault keeps, capped at the limit.
        </p>
        <div className="kpi" aria-live="polite">
          <div>
            <p>Premium</p>
            <strong className={stale ? 'stale' : undefined}>{price ? usd2.format(toUsd(price.premium)) : '…'}<span> USDG</span></strong>
            <small>
              {parsed.error ? parsed.error
                : live.error ? <>Quote failed: {live.error}</>
                : quote ? <>{stale ? 'Re-quoting' : price?.floored ? 'Minimum price' : 'Live quote'}, block <a href={explorer.block(quote.block)} target="_blank" rel="noreferrer">{quote.block.toLocaleString('en-US')}</a></>
                : 'Quoting from the Stylus pricer'}
            </small>
          </div>
          <div>
            <p>Cover pays up to</p>
            <strong>{terms ? usd0.format(toUsd(terms.lim)) : '…'}<span> USDG</span></strong>
            <small>after the vault keeps {terms ? usd0.format(toUsd(terms.ret)) : '…'}</small>
          </div>
          <div>
            <p>Weekends it would have paid</p>
            <strong>{bt ? bt.paid : '…'}<span> of {spy.weekends.length}</span></strong>
            <small>{bt ? `${bt.exhausted} at the full limit` : ' '}</small>
          </div>
        </div>
      </div>

      <aside className="panel" aria-label="Your terms">
        <div className="box form">
          {FEED_ADDRESSES.map((f, i) => (
            <div className="field" key={f}>
              <label htmlFor={`exp-${i}`}>Vault's net SPY position, USDG</label>
              <input id={`exp-${i}`} inputMode="decimal" autoComplete="off" value={exposures[i] ?? ''} onChange={(e) => setExposures((xs) => xs.map((x, j) => (j === i ? e.target.value : x)))} />
              <span className="hint">Positive if net long, negative if net short. Feed <a href={explorer.address(f)} target="_blank" rel="noreferrer">{short(f)}</a>.</span>
            </div>
          ))}
          <div className="two">
            <div className="field">
              <label htmlFor="ret">Vault keeps first</label>
              <input id="ret" inputMode="decimal" autoComplete="off" value={retention} onChange={(e) => setRetention(e.target.value)} />
            </div>
            <div className="field">
              <label htmlFor="lim">Heracles pays up to</label>
              <input id="lim" inputMode="decimal" autoComplete="off" value={limit} onChange={(e) => setLimit(e.target.value)} />
            </div>
          </div>
          {parsed.error && <p className="err" role="alert"><b>Check</b> {parsed.error}</p>}
        </div>

        <div className="box">
          {quote && same ? (
            <>
              <div className="rw">Average payout a weekend<b><Money v={toUsd(quote.el)} /></b></div>
              <div className="rw">Average of the worst 25 weekends<b><Money v={toUsd(quote.tvar)} /></b></div>
              {price?.floored && <div className="rw">Pricer quoted<b>{fmtUsdg(quote.premium)}</b></div>}
            </>
          ) : (
            <div className="rw">{live.error ? 'Quote failed' : 'Quoting'}<b>{live.error ?? '…'}</b></div>
          )}
          <div className="rw">Buy until<b>{win ? (closed ? 'closed this weekend' : `${fmtClock(win.cutoff)} UTC, in ${fmtCountdown(win.cutoff - now)}`) : '…'}</b></div>
          <div className={`rw pr${stale ? ' stale' : ''}`}>Premium<b>{price ? `${usd2.format(toUsd(price.premium))} USDG` : '…'}</b></div>
        </div>

        <BuyCover terms={terms} quote={quote} book={book.data} win={win} now={now} />
        <p className="wn">
          Pays on the Monday price gap only, worked out from the feed; it does not cover hacks or the vault's own trading.
          The price never falls below {minRateBps !== undefined ? `${(Number(minRateBps) / 100).toFixed(1)}%` : 'the minimum share'} of the cap.
        </p>
      </aside>

      <div className="body">
        <section className="cc" aria-labelledby="bchart-h">
          <div className="ch">
            <div>
              <p>Your cover across every SPY weekend since 2016</p>
              <h2 id="bchart-h">{bt ? bt.paid : '…'} of {spy.weekends.length}<span> weekends paid</span></h2>
            </div>
          </div>
          {layer ? <GapChart table={spy} layer={layer} /> : <p className="cn">{parsed.error}</p>}
        </section>
      </div>
    </div>
  );
}

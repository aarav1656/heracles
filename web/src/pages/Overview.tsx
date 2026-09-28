import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useConnection, usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { CAPACITY_ADDRESS, PRICER_ADDRESS, TREATY_ADDRESS, USDG_ADDRESS } from '../abi';
import { explorer } from '../chain';
import { useBook, type BookSnapshot, type Layer } from '../hooks/useBook';
import { useNow } from '../hooks/useNow';
import { useReferenceQuote } from '../hooks/useReferenceQuote';
import { useWeekWindow } from '../hooks/useWeekWindow';
import { Stamp } from '../components/Stamp';
import { SettleItem, ClaimRow } from '../components/SettlePanel';
import { LayerTower } from '../components/LayerTower';
import { GapChart } from '../components/GapChart';
import { WeekStrip } from '../components/WeekStrip';
import { fmtClock, fmtCountdown, fmtPx, fmtStamp, fmtUsdg, short } from '../lib/format';
import { LAYER_STATES } from '../lib/treaty';
import { explainError } from '../lib/revert';
import { RECORDED, REFERENCE, TABLES, backtest, extremes, fmtBps, fmtDay, type Ticker } from '../lib/gaps';

const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const usd2 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const toUsd = (v: bigint) => Number(v) / 1e6;
const age = (s: number) => (s >= 86400 ? `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h` : s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m` : `${Math.max(0, Math.floor(s / 60))}m`);

export function Overview() {
  useEffect(() => { document.title = 'Heracles: weekend-gap cover for perp LP vaults'; }, []);
  const conn = useConnection();
  const client = usePublicClient() as PublicClient | undefined;
  const now = useNow();
  const q = useBook(conn.address);
  const quote = useReferenceQuote();
  const win = useWeekWindow(client, now);
  const [ticker, setTicker] = useState<Ticker>('SPY');
  const table = TABLES.find((t) => t.ticker === ticker)!;
  const ext = useMemo(() => extremes(table.weekends), [table]);
  const bt = useMemo(() => backtest(table.weekends, REFERENCE.exposure, REFERENCE.retention, REFERENCE.limit), [table]);
  const spyFeed = q.data?.value.markets[0];
  const book = q.data?.value;

  return (
    <>
      <header className="lead">
        <h1>Weekend-gap cover for perp LP vaults</h1>
        <p>
          When a stock reopens on Monday away from Friday's close, the vault keeps the first loss
          and a Heracles layer pays the next slice. Priced on chain from 504 recorded weekends.
        </p>
      </header>

      <div className="mbar">
        <div className="mtabs" role="tablist" aria-label="Market">
          {TABLES.map((t) => (
            <button
              key={t.ticker}
              role="tab"
              type="button"
              aria-selected={t.ticker === ticker}
              className={t.ticker === ticker ? 'on' : undefined}
              onClick={() => setTicker(t.ticker)}
            >
              {t.ticker}
            </button>
          ))}
        </div>
        <dl className="mstats">
          <div>
            <dt>Worst weekend</dt>
            <dd><span className="num dn">{fmtBps(ext.down.gap)}</span><small>{fmtDay(ext.down.friday)}</small></dd>
          </div>
          <div>
            <dt>Biggest up gap</dt>
            <dd><span className="num up">{fmtBps(ext.up.gap)}</span><small>{fmtDay(ext.up.friday)}</small></dd>
          </div>
          <div>
            <dt>Gaps past 1%</dt>
            <dd><span className="num">{ext.beyond1pct}</span><small>of {table.weekends.length} weekends</small></dd>
          </div>
          <div>
            <dt>{ticker === 'SPY' ? <>SPY/USD feed <em className="live">live</em></> : `${ticker} feed`}</dt>
            <dd>
              {ticker !== 'SPY' ? (
                <small>not on Sepolia; fork-tested</small>
              ) : spyFeed ? (
                <><span className="num">{fmtPx(spyFeed.latest.answer)}</span><small title={fmtStamp(spyFeed.latest.updatedAt)}>round {age(now - Number(spyFeed.latest.updatedAt))} old</small></>
              ) : q.error ? (
                <small>read failed</small>
              ) : (
                <small>reading</small>
              )}
            </dd>
          </div>
        </dl>
      </div>

      <div className="desk">
        <section className="panel" aria-labelledby="chart-h">
          <div className="panel-head">
            <h2 id="chart-h">{ticker}: every weekend since {fmtDay(table.weekends[0].friday).slice(-4)}, and the layer across it</h2>
          </div>
          <GapChart table={table} layer={REFERENCE} />
        </section>

        <aside className="panel ticket" aria-labelledby="ticket-h">
          <h2 id="ticket-h" className="ticket-h">Reference layer</h2>
          <p className="terms">
            A vault long <b className="num">{usd0.format(REFERENCE.exposure)}</b> USDG of {ticker} keeps the
            first <b className="num">{usd0.format(REFERENCE.retention)}</b> of a weekend loss; the layer pays the
            next <b className="num">{usd0.format(REFERENCE.limit)}</b>.
          </p>
          {ticker === 'SPY' ? (
            <SpyQuote quote={quote} bt={bt} />
          ) : (
            <>
              <p className="prose tight">
                Not quotable on this deploy: the Sepolia pricer holds the SPY table only
                (<code>tableIdAt(1)</code> reverts <code>MissingTable</code>). The same layer
                run over <code>{table.file}</code> at the neutral 1.0x volatility scale:
              </p>
              <span className="fig">{usd2.format(bt.el)}<small>USDG expected loss</small></span>
              <dl className="tk">
                <dt>TVaR95</dt><dd className="num">{usd2.format(bt.tvar95)}</dd>
                <dt>Weekends it pays</dt><dd><span className="num">{bt.paid}</span> of 504</dd>
                <dt>Full limit</dt><dd><span className="num">{bt.exhausted}</span> of 504</dd>
              </dl>
            </>
          )}
          <div className="ticket-cta">
            <Link className="btn" to="/bind">Price your own layer</Link>
            <Link className="btn ghost" to="/write">Write capacity</Link>
          </div>
        </aside>
      </div>

      <div className="desk lower">
        <section className="panel" aria-labelledby="week-h">
          <div className="panel-head"><h2 id="week-h">This cover week</h2></div>
          {win ? <WeekStrip win={win} now={now} /> : <p className="prose">Reading the week window from the treaty.</p>}
        </section>

        <section className="panel" aria-labelledby="book-h">
          <div className="panel-head">
            <h2 id="book-h">The book</h2>
            {q.data && <span className="right"><Stamp block={q.data.block} label="read at" /></span>}
          </div>
          {q.error ? (
            <p className="prose err" role="alert"><b>{explainError(q.error).name}</b> {explainError(q.error).words}</p>
          ) : !book ? (
            <p className="prose">Reading the treaty book at the latest block.</p>
          ) : (
            <>
              <dl className="tk">
                <dt>Layers bound</dt><dd className="num">{book.layers.length}</dd>
                <dt>Writer capacity</dt><dd><span className="num">{fmtUsdg(book.capacity.balance)}</span> USDG</dd>
                <dt>Free to bind</dt><dd><span className="num">{fmtUsdg(book.capacity.free)}</span> USDG</dd>
              </dl>
              {book.capacity.balance === 0n && book.layers.length === 0 && (
                <p className="prose">
                  Nothing is bound on this deployment yet, and no writer has deposited, so a layer
                  cannot bind until one does. <Link to="/write">Be the first writer</Link>.
                </p>
              )}
            </>
          )}
        </section>
      </div>

      {book && book.layers.length > 0 && (
        <section className="panel" aria-label="Layers on the book" style={{ marginTop: 16 }}>
          <div className="panel-head"><h2>Layers on the book</h2></div>
          <div className="ltable">
            <div className="ltable-head" role="row">
              <span>Market</span>
              <span>Exposure</span>
              <span>Retention / Limit</span>
              <span>Premium</span>
              <span>Fixing countdown</span>
              <span>State</span>
            </div>
            {book.layers.map((l) => (
              <LayerRow key={l.id.toString()} layer={l} book={book} now={now} />
            ))}
          </div>
        </section>
      )}

      <p className="contracts">
        Arbitrum Sepolia: treaty <a className="tx" href={explorer.address(TREATY_ADDRESS)} target="_blank" rel="noreferrer">{short(TREATY_ADDRESS)}</a>
        {' '}· capacity <a className="tx" href={explorer.address(CAPACITY_ADDRESS)} target="_blank" rel="noreferrer">{short(CAPACITY_ADDRESS)}</a>
        {' '}· pricer <a className="tx" href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a>
        {' '}· USDG <a className="tx" href={explorer.address(USDG_ADDRESS)} target="_blank" rel="noreferrer">{short(USDG_ADDRESS)}</a>
      </p>
    </>
  );
}

type QuoteQ = ReturnType<typeof useReferenceQuote>;

/** The live Stylus quote on the reference layer, cross-checked against the table in the browser. */
function SpyQuote({ quote, bt }: { quote: QuoteQ; bt: ReturnType<typeof backtest> }) {
  if (quote.isLoading) return <p className="prose">Quoting the Stylus pricer at the latest block.</p>;
  const live = quote.data;
  const premium = live ? toUsd(live.premium) : RECORDED.premium;
  const el = live ? toUsd(live.el) : RECORDED.el;
  const tvar = live ? toUsd(live.tvar) : RECORDED.tvar;
  const agrees = Math.abs(el - bt.el) < 0.000001 * REFERENCE.limit;
  return (
    <>
      <span className="fig hero">{usd2.format(premium)}<small>USDG premium</small></span>
      <p className="ratio"><b className="num">{((premium / REFERENCE.limit) * 100).toFixed(2)}%</b> of the limit, for one weekend</p>
      <dl className="tk">
        <dt>Expected loss</dt><dd className="num">{usd2.format(el)}</dd>
        <dt>TVaR95</dt><dd className="num">{usd2.format(tvar)}</dd>
        <dt>Weekends it pays</dt><dd><span className="num">{bt.paid}</span> of 504</dd>
        <dt>Full limit</dt><dd><span className="num">{bt.exhausted}</span> of 504</dd>
      </dl>
      {live ? (
        <p className="src">
          Stylus pricer <a className="tx" href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a> at
          block <a className="num" href={explorer.block(live.block)} target="_blank" rel="noreferrer">#{live.block.toLocaleString('en-US')}</a>.
          {agrees
            ? ' Rerun in this browser over SPY.json, the expected loss matches.'
            : ` Browser rerun at 1.0x volatility gives ${usd2.format(bt.el)}; the gap is the live volatility scale.`}
          {' '}The same call costs 8.01x less L2 execution gas in Stylus than in its Solidity twin
          (block <a className="num" href={explorer.block(313_704_736n)} target="_blank" rel="noreferrer">#313,704,736</a>, <code>docs/pricing.md</code>).
        </p>
      ) : (
        <p className="src err-inline">
          Live quote failed ({quote.error ? explainError(quote.error).name : 'no client'}); showing the recorded quote at
          block 313,690,038 (README).
        </p>
      )}
    </>
  );
}

/**
 * One row of the book: the GMX pools/positions table shape (column header
 * strip, rounded card rows, a market icon). Settlement lives in the State
 * column, an expand toggle onto the same actions the layer used to get a
 * separate "Settlement" card for (SettleItem for a live layer, ClaimRow once
 * it is settled or cancelled), not a second table.
 */
function LayerRow({ layer, book, now }: { layer: Layer; book: BookSnapshot; now: number }) {
  const [open, setOpen] = useState(false);
  const stateName = LAYER_STATES[layer.state];
  const exp = layer.exposure[0] ?? 0n;
  const dir = exp < 0n ? 'short' : 'long';
  const fixing = layer.state === 1 ? (now >= layer.expiry ? 'fixing open' : fmtCountdown(layer.expiry - now)) : '-';

  return (
    <div className="ltable-row">
      <div className="ltable-grid">
        <span className="cell market">
          <span className="market-icon" aria-hidden="true">S</span>SPY
        </span>
        <span className="cell exposure">
          <span className="cell-lab">Exposure</span>
          <span className="num">{fmtUsdg(exp < 0n ? -exp : exp)}</span>
          <span className="dir">{dir}</span>
        </span>
        <span className="cell">
          <span className="cell-lab">Retention / limit</span>
          <span className="num">{fmtUsdg(layer.retention)} / {fmtUsdg(layer.limit)}</span>
        </span>
        <span className="cell">
          <span className="cell-lab">Premium</span>
          <span className="num">{fmtUsdg(layer.premium)}</span>
        </span>
        <span className="cell">
          <span className="cell-lab">Fixing countdown</span>
          <span className="num">{fixing}</span>
        </span>
        <span className="cell state">
          <span className="cell-lab">State</span>
          <span className={`tag ${stateName}`}>{stateName}</span>
          <button type="button" className="details-btn" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
            {open ? 'Hide' : 'Details'}
          </button>
        </span>
      </div>
      {open && (
        <div className="ltable-expand">
          <LayerTower
            name={`Layer #${layer.id.toString()}`}
            who={<>buyer {short(layer.buyer)} · cutoff {fmtClock(layer.fridayCutoff)} · expiry {fmtClock(layer.expiry)}</>}
            exposure={exp}
            retention={layer.retention}
            limit={layer.limit}
            premium={layer.premium}
            payout={layer.payout}
            tag={stateName}
            state={layer.state === 2 ? 'settled' : layer.state === 3 ? 'cancelled' : 'bound'}
          />
          {layer.state === 1 ? <SettleItem layer={layer} book={book} now={now} /> : <ClaimRow layer={layer} />}
        </div>
      )}
    </div>
  );
}

/**
 * The pool split into what it has promised and what it has not. Both sides are
 * direct contract reads: limits locked, payouts owed but unclaimed (still
 * reserved inside locked until claim), and free.
 */
export function CapacityStrip({ locked, owed, free, balance, pending }: { locked: bigint; owed: bigint; free: bigint; balance: bigint; pending: bigint }) {
  const l = Number(locked);
  const o = Math.min(Number(owed), l);
  const f = Number(free);
  const total = l + f || 1;
  const owedPart = o > 0 ? (o / total) * 100 : 0;
  const lockedPart = l > 0 ? (l / total) * 100 - owedPart : 0;
  const freePart = f > 0 ? (f / total) * 100 : 0;
  const summary = `${fmtUsdg(owed)} USDG of the ${fmtUsdg(locked)} USDG locked is owed but unclaimed; ${fmtUsdg(free)} USDG is free.`;

  return (
    <div className="strip">
      <div className="strip-bar" role="img" aria-label={summary}>
        {owedPart > 0 && <i className="owed" style={{ width: `${owedPart.toFixed(2)}%` }} />}
        {lockedPart > 0 && <i className="locked" style={{ width: `${lockedPart.toFixed(2)}%` }} />}
        {freePart > 0 && <i className="free" style={{ width: `${freePart.toFixed(2)}%` }} />}
      </div>
      <dl className="strip-key">
        <div>
          <dt><span className="swatch free" />free</dt>
          <dd className="num">{fmtUsdg(free)} USDG</dd>
        </div>
        <div>
          <dt><span className="swatch lock" />locked</dt>
          <dd className="num">{fmtUsdg(locked)} USDG</dd>
        </div>
        <div>
          <dt><span className="swatch owed" />owed, unclaimed</dt>
          <dd className="num">{fmtUsdg(owed)} USDG</dd>
        </div>
        <div>
          <dt>pending premium</dt>
          <dd className="num">{fmtUsdg(pending)} USDG</dd>
        </div>
        <div>
          <dt>pool balance</dt>
          <dd className="num">{fmtUsdg(balance)} USDG</dd>
        </div>
      </dl>
    </div>
  );
}


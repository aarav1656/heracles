import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useConnection, usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { PRICER_ADDRESS } from '../abi';
import { explorer } from '../chain';
import { useBook, bookTotals, type BookSnapshot, type Layer } from '../hooks/useBook';
import { useNow } from '../hooks/useNow';
import { useReferenceQuote } from '../hooks/useReferenceQuote';
import { useWeekWindow } from '../hooks/useWeekWindow';
import { Stamp } from '../components/Stamp';
import { Money } from '../components/Money';
import { SettleItem, ClaimRow } from '../components/SettlePanel';
import { LayerTower } from '../components/LayerTower';
import { GapChart } from '../components/GapChart';
import { WeekStrip } from '../components/WeekStrip';
import { fmtClock, fmtCountdown, fmtPx, fmtStamp, fmtUsdg, short } from '../lib/format';
import { LAYER_STATES } from '../lib/treaty';
import { explainError } from '../lib/revert';
import { RECORDED, REFERENCE, TABLES, backtest, type Ticker } from '../lib/gaps';

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
  const bt = useMemo(() => backtest(table.weekends, REFERENCE.exposure, REFERENCE.retention, REFERENCE.limit), [table]);
  const spyFeed = q.data?.value.markets[0];
  const book = q.data?.value;

  return (
    <>
      <div className="desk">
        <div className="main-col">
          <header className="argument">
            <h1 className="display">Cover for the weekend gap</h1>
            <p className="lede">
              If a stock opens Monday far from Friday's close, Heracles pays a perp exchange's LP vault a set
              amount, worked out from the price feed and the position size the vault declared.
            </p>
            <Link className="btn only-narrow" to="/bind">Price cover for your vault</Link>
          </header>

          <section className="exhibit" aria-labelledby="chart-h">
            <div className="exhibit-head">
              <h2 id="chart-h" className="chart-title">{ticker}, every weekend since 2016</h2>
              <div className="markets" role="tablist" aria-label="Market">
                {TABLES.map((t) => (
                  <button key={t.ticker} role="tab" type="button" aria-selected={t.ticker === ticker} onClick={() => setTicker(t.ticker)}>
                    {t.ticker}
                  </button>
                ))}
              </div>
            </div>
            <p className="caveat">Each bar is one weekend, from Friday's close to Monday's open. Teal marks the weekends the example cover would have paid on.</p>
            <GapChart key={ticker} table={table} layer={REFERENCE} simple />
          </section>
        </div>

        <aside className="ticket" aria-labelledby="ticket-h">
          <h2 id="ticket-h" className="label"><i className="sw layer" />Example cover, {ticker}</h2>
          {ticker === 'SPY' ? (
            <SpyQuote quote={quote} bt={bt} />
          ) : (
            <>
              <p className="terms">
                A vault that is net long {usd0.format(REFERENCE.exposure)} USDG of {ticker}. The treaty on this testnet lists SPY;
                the <Link to="/quote">quote page</Link> prices {ticker} with the same pricer.
              </p>
              <details className="more">
                <summary>What it would have paid since 2016</summary>
                <div className="rows figs">
                  <div className="row"><span className="k">Average payout per weekend</span><span className="v"><Money v={bt.el} /></span></div>
                  <div className="row"><span className="k">Average of the worst 5% of weekends</span><span className="v"><Money v={bt.tvar95} /></span></div>
                  <div className="row"><span className="k">Weekends it would have paid on</span><span className="v">{bt.paid} of 504</span></div>
                </div>
                <p className="note">Run in this browser over {table.file} at the neutral 1.0x volatility scale (the Sepolia pricer holds the SPY table only; <span className="file">tableIdAt(1)</span> reverts MissingTable).</p>
              </details>
            </>
          )}
          <div className="acts">
            <Link className="btn" to="/bind">Price cover for your vault</Link>
          </div>
          <p className="note">No wallet needed to see a price; connect one to buy.</p>
          {ticker === 'SPY' && quote.data && (
            <p className="src">Live quote from the Stylus pricer at block <a href={explorer.block(quote.data.block)} target="_blank" rel="noreferrer">#{quote.data.block.toLocaleString('en-US')}</a>.</p>
          )}
          <p className="note">Have USDG? <Link to="/write">Back this cover and earn its premium</Link>.</p>
          <p className="note">Run a perp venue? <Link to="/sdk">Wire your LP vault's book to the guard and a weekly cover</Link>.</p>
        </aside>
      </div>

      <div className="desk doc">
        <div className="main-col">
          <section aria-labelledby="week-h">
            <h2 id="week-h" className="section">This cover week</h2>
            {win ? <WeekStrip win={win} now={now} /> : <p className="note">Reading the week window from the treaty.</p>}
          </section>

          <section aria-labelledby="priced-h">
            <h2 id="priced-h" className="section">How the price is worked out</h2>
            <p className="prose">
              The example's price is one read of the Stylus pricer <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a>:
              it runs the cover over the same 504 SPY weekends drawn above, scaled by the live volatility, and returns the
              price, the average payout and the average of the worst 25 weekends. At settlement the payout comes from the
              same kind of arithmetic: the Monday gap on the feed times the position the vault declared, minus the part the vault
              keeps (the retention), capped at the limit. The call costs <span className="fig">4.29x</span> to <span className="fig">8.00x</span> less
              L2 execution gas in Stylus than in its Solidity twin, from eight markets down to one, measured at block <a href={explorer.block(314_661_533n)} target="_blank" rel="noreferrer">#314,661,533</a> (<span className="file">scripts/measure_pricer_gas.py</span>).
            </p>
            {spyFeed && (
              <p className="note">
                SPY/USD feed on chain: <span className="fig">{fmtPx(spyFeed.latest.answer)}</span>, round {age(now - Number(spyFeed.latest.updatedAt))} old
                ({fmtStamp(spyFeed.latest.updatedAt)}). The feed pauses over the weekend; that silence is the gap.
              </p>
            )}
            <p className="src">The chart: {table.weekends.length} weekends from <span className="file">{table.file}</span> in the repo, from {table.source}, fetched {table.fetchDate}.</p>
          </section>
        </div>

        <section className="book" aria-labelledby="book-h">
          <h2 id="book-h" className="section">The book</h2>
          {q.error ? (
            <p className="err" role="alert"><b>{explainError(q.error).name}</b> {explainError(q.error).words}</p>
          ) : !book ? (
            <p className="note">Reading the treaty book at the latest block.</p>
          ) : (
            <>
              <div className="rows figs">
                <div className="row"><span className="k">Covers bought</span><span className="v">{book.layers.length}</span></div>
              </div>
              {book.books.map((b) => {
                const t = bookTotals(b);
                return (
                  <div key={b.symbol}>
                    <h3 className="label sub">{b.symbol} book</h3>
                    <div className="rows figs">
                      <div className="row"><span className="k">{b.symbol} backing cover</span><span className="v"><Money v={toUsd(t.balance)} /> {b.symbol}</span></div>
                      <div className="row"><span className="k">Free for new cover</span><span className="v"><Money v={toUsd(t.free)} /> {b.symbol}</span></div>
                    </div>
                  </div>
                );
              })}
              {book.books.every((b) => bookTotals(b).balance === 0n) && book.layers.length === 0 && (
                <p className="note">
                  No cover has been bought on this deployment yet and no writer has deposited, so new cover cannot be
                  bought until one does. <Link to="/write">Be the first writer</Link>.
                </p>
              )}
              <p className="src"><Stamp block={q.data!.block} label="Read at block" /></p>
            </>
          )}
        </section>
      </div>

      {book && book.layers.length > 0 && (
        <section className="positions" aria-labelledby="layers-h">
          <h2 id="layers-h" className="section">Cover on the book</h2>
          <div className="ledger" role="table" aria-label="Layers on the book">
            <div className="ledger-head" role="row">
              <span role="columnheader">Market</span>
              <span role="columnheader">Exposure</span>
              <span role="columnheader">Retention / limit</span>
              <span role="columnheader">Premium</span>
              <span role="columnheader">Fixing</span>
              <span role="columnheader">State</span>
            </div>
            {book.layers.map((l) => <LayerRow key={l.id.toString()} layer={l} book={book} now={now} />)}
          </div>
        </section>
      )}
    </>
  );
}

type QuoteQ = ReturnType<typeof useReferenceQuote>;

/** The live Stylus quote on the reference layer, set inside the terms sentence, cross-checked in the browser. */
function SpyQuote({ quote, bt }: { quote: QuoteQ; bt: ReturnType<typeof backtest> }) {
  const live = quote.data;
  const premium = live ? toUsd(live.premium) : RECORDED.premium;
  const el = live ? toUsd(live.el) : RECORDED.el;
  const tvar = live ? toUsd(live.tvar) : RECORDED.tvar;
  const agrees = Math.abs(el - bt.el) < 0.000001 * REFERENCE.limit;
  return (
    <>
      <p className="terms">
        A vault that is net long {usd0.format(REFERENCE.exposure)} USDG of SPY pays{' '}
        {quote.isLoading ? <span className="pending">(the pricer is quoting it now)</span> : <b title={live ? `Live quote from the Stylus pricer at block ${live.block.toLocaleString('en-US')}` : 'Recorded quote, block 313,690,038'}><Money v={premium} /> USDG</b>}{' '}
        for one weekend of cover.
      </p>
      <p className="note">
        If SPY opens Monday more than 1% below Friday's close, Heracles pays the vault a set amount for each further step of the
        gap, up to a cap. The payout is worked out from the price feed and the declared position, not from the vault's books.
      </p>
      <details className="more">
        <summary>What it would have paid since 2016</summary>
        <div className="rows figs">
          <div className="row"><span className="k">Weekends it would have paid on</span><span className="v">{bt.paid} of 504</span></div>
          <div className="row"><span className="k">Pays per further 1% of gap</span><span className="v">{usd0.format(REFERENCE.exposure / 100)}</span></div>
          <div className="row"><span className="k">Most it pays (the limit)</span><span className="v">{usd0.format(REFERENCE.limit)}</span></div>
          <div className="row"><span className="k">Average payout per weekend (expected loss)</span><span className="v"><Money v={el} /></span></div>
          <div className="row"><span className="k">Average of the worst 5% of weekends (TVaR95)</span><span className="v"><Money v={tvar} /></span></div>
          <div className="row"><span className="k">Price as a share of the 60,000 cap</span><span className="v">{((premium / REFERENCE.limit) * 100).toFixed(2)}%</span></div>
        </div>
        <p className="note">
          {agrees
            ? `Rerun in this browser over SPY.json, the expected payout matches the pricer's (${usd2.format(bt.el)}).`
            : `Rerun in this browser at 1.0x volatility gives ${usd2.format(bt.el)}; the difference is the pricer's live volatility scale.`}
          {live && <> Quoted by the Stylus pricer at block <a href={explorer.block(live.block)} target="_blank" rel="noreferrer">#{live.block.toLocaleString('en-US')}</a>.</>}
        </p>
      </details>
      {!live && !quote.isLoading && (
        <p className="err" role="status">
          <b>Live quote failed</b> {quote.error ? explainError(quote.error).name : 'no client'}; showing the recorded quote at block 313,690,038 (README).
        </p>
      )}
    </>
  );
}

/** One layer on the book as a ledger row, with its settle or claim actions behind a toggle. */
function LayerRow({ layer, book, now }: { layer: Layer; book: BookSnapshot; now: number }) {
  const [open, setOpen] = useState(false);
  const stateName = LAYER_STATES[layer.state];
  const unit = book.books[layer.book]?.symbol ?? '';
  const exp = layer.exposure[0] ?? 0n;
  const dir = exp < 0n ? 'short' : 'long';
  const fixing = layer.state === 1 ? (now >= layer.expiry ? 'fixing open' : fmtCountdown(layer.expiry - now)) : '-';

  return (
    <div className="ledger-row" role="row">
      <div className="ledger-grid">
        <span role="cell" data-k="Market">SPY</span>
        <span role="cell" data-k="Exposure">{fmtUsdg(exp < 0n ? -exp : exp)} {unit} {dir}</span>
        <span role="cell" data-k="Retention / limit">{fmtUsdg(layer.retention)} / {fmtUsdg(layer.limit)} {unit}</span>
        <span role="cell" data-k="Premium">{fmtUsdg(layer.premium)} {unit}</span>
        <span role="cell" data-k="Fixing">{fixing}</span>
        <span role="cell" data-k="State" className="state">
          {stateName}
          <button type="button" className="key" onClick={() => setOpen((o) => !o)} aria-expanded={open}>{open ? 'Hide' : 'Details'}</button>
        </span>
      </div>
      {open && (
        <div className="ledger-expand">
          <LayerTower
            name={`Layer #${layer.id.toString()}`}
            who={<>buyer {short(layer.buyer)} · cutoff {fmtClock(layer.fridayCutoff)} · expiry {fmtClock(layer.expiry)}</>}
            exposure={exp}
            retention={layer.retention}
            limit={layer.limit}
            premium={layer.premium}
            payout={layer.payout}
            unit={unit}
            tag={stateName}
            state={layer.state === 2 ? 'settled' : layer.state === 3 ? 'cancelled' : 'bound'}
          />
          {layer.state === 1 ? <SettleItem layer={layer} book={book} now={now} /> : <ClaimRow layer={layer} unit={unit} />}
        </div>
      )}
    </div>
  );
}

/**
 * The pool split into what it has promised and what it has not. Both sides are direct contract
 * reads: limits locked, payouts owed but unclaimed (still reserved inside locked until claim), and free.
 */
export function CapacityStrip({ symbol, locked, owed, free, balance, pending }: { symbol: string; locked: bigint; owed: bigint; free: bigint; balance: bigint; pending: bigint }) {
  const l = Number(locked);
  const o = Number(owed);
  const f = Number(free);
  const total = l + f + o || 1;
  const owedPart = (o / total) * 100;
  const lockedPart = (l / total) * 100;
  const freePart = (f / total) * 100;
  const summary = `${fmtUsdg(locked)} ${symbol} is locked under bound limits, ${fmtUsdg(owed)} ${symbol} is owed but unclaimed, ${fmtUsdg(free)} ${symbol} is free.`;

  return (
    <div className="strip">
      <div className="strip-bar" role="img" aria-label={summary}>
        {owedPart > 0 && <i className="owed" style={{ width: `${owedPart.toFixed(2)}%` }} />}
        {lockedPart > 0 && <i className="locked" style={{ width: `${lockedPart.toFixed(2)}%` }} />}
        {freePart > 0 && <i className="free" style={{ width: `${freePart.toFixed(2)}%` }} />}
      </div>
      <div className="rows figs">
        <div className="row"><span className="k"><i className="sw free" />Free</span><span className="v">{fmtUsdg(free)} {symbol}</span></div>
        <div className="row"><span className="k"><i className="sw locked" />Locked under bound limits</span><span className="v">{fmtUsdg(locked)} {symbol}</span></div>
        <div className="row"><span className="k"><i className="sw owed" />Owed, unclaimed</span><span className="v">{fmtUsdg(owed)} {symbol}</span></div>
        <div className="row"><span className="k">Pending premium</span><span className="v">{fmtUsdg(pending)} {symbol}</span></div>
        <div className="row"><span className="k">Vault balance</span><span className="v">{fmtUsdg(balance)} {symbol}</span></div>
      </div>
    </div>
  );
}

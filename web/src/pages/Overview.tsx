import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useConnection, usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { PRICER_ADDRESS } from '../abi';
import { explorer } from '../chain';
import { useBook, type BookSnapshot, type Layer } from '../hooks/useBook';
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
            <h1 className="display">Reinsurance for the Monday gap</h1>
            <p className="lede">
              When a stock reopens on Monday away from Friday's close, a perp exchange's LP vault
              takes the loss. The vault keeps the first slice; a Heracles layer pays the next,
              priced on chain from 504 recorded weekends.
            </p>
          </header>

          <section className="exhibit" aria-labelledby="chart-h">
            <div className="exhibit-head">
              <h2 id="chart-h" className="chart-title">{ticker}, every weekend since September 2016 <span>and the layer across it</span></h2>
              <div className="markets" role="tablist" aria-label="Market">
                {TABLES.map((t) => (
                  <button key={t.ticker} role="tab" type="button" aria-selected={t.ticker === ticker} onClick={() => setTicker(t.ticker)}>
                    {t.ticker}
                  </button>
                ))}
              </div>
            </div>
            <p className="caveat">Friday close to next open, one bar per weekend. Where a bar reaches the band, the reference layer would have paid; the teal part is what it paid.</p>
            <GapChart key={ticker} table={table} layer={REFERENCE} />
          </section>
        </div>

        <aside className="ticket" aria-labelledby="ticket-h">
          <h2 id="ticket-h" className="label"><i className="sw layer" />Reference layer, {ticker}</h2>
          {ticker === 'SPY' ? (
            <SpyQuote quote={quote} bt={bt} />
          ) : (
            <>
              <p className="terms">
                A vault long {usd0.format(REFERENCE.exposure)} USDG of {ticker} keeps the first {usd0.format(REFERENCE.retention)} of
                a weekend loss; writers cover the next {usd0.format(REFERENCE.limit)}.
              </p>
              <p className="note">
                Not quotable on this deploy: the Sepolia pricer holds the SPY table only (<span className="file">tableIdAt(1)</span> reverts
                MissingTable). The same layer run over {table.file} at the neutral 1.0x volatility scale:
              </p>
              <div className="rows figs">
                <div className="row"><span className="k">Expected loss</span><span className="v"><Money v={bt.el} /></span></div>
                <div className="row"><span className="k">TVaR95</span><span className="v"><Money v={bt.tvar95} /></span></div>
                <div className="row"><span className="k">Weekends it pays</span><span className="v">{bt.paid} of 504</span></div>
              </div>
            </>
          )}
          <div className="acts">
            <Link className="btn" to="/bind">Price your own layer</Link>
            <Link className="btn line" to="/write">Write capacity</Link>
          </div>
          {win && (
            <p className="src">
              {now < win.cutoff
                ? <>Binding for this weekend closes {fmtClock(win.cutoff)} UTC, in {fmtCountdown(win.cutoff - now)}.</>
                : <>Binding for this weekend closed {fmtClock(win.cutoff)} UTC; next week's cover opens Monday 00:00 UTC.</>}
            </p>
          )}
        </aside>
      </div>

      <div className="desk doc">
        <div className="main-col">
          <section aria-labelledby="week-h">
            <h2 id="week-h" className="section">This cover week</h2>
            {win ? <WeekStrip win={win} now={now} /> : <p className="note">Reading the week window from the treaty.</p>}
          </section>

          <section aria-labelledby="priced-h">
            <h2 id="priced-h" className="section">How the quote is made</h2>
            <p className="prose">
              The reference layer's premium is one read of the Stylus pricer <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a>:
              it runs the layer over the same 504 SPY weekends drawn above, scaled by the live volatility, and returns the
              premium, the expected loss and the mean of the worst 25 weekends (TVaR95). The call costs <span className="fig">8.01x</span> less
              L2 execution gas in Stylus than in its Solidity twin, measured at block <a href={explorer.block(313_704_736n)} target="_blank" rel="noreferrer">#313,704,736</a> (<span className="file">docs/pricing.md</span>, "Gas").
            </p>
            {spyFeed && (
              <p className="note">
                SPY/USD feed on chain: <span className="fig">{fmtPx(spyFeed.latest.answer)}</span>, round {age(now - Number(spyFeed.latest.updatedAt))} old
                ({fmtStamp(spyFeed.latest.updatedAt)}). The feed pauses over the weekend; that silence is the gap.
              </p>
            )}
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
                <div className="row"><span className="k">Layers bound</span><span className="v">{book.layers.length}</span></div>
                <div className="row"><span className="k">Writer capacity</span><span className="v"><Money v={toUsd(book.capacity.balance)} /> USDG</span></div>
                <div className="row"><span className="k">Free to bind</span><span className="v"><Money v={toUsd(book.capacity.free)} /> USDG</span></div>
              </div>
              {book.capacity.balance === 0n && book.layers.length === 0 && (
                <p className="note">
                  Nothing is bound on this deployment yet and no writer has deposited, so a layer cannot bind until one
                  does. <Link to="/write">Write the first capacity</Link>.
                </p>
              )}
              <p className="src"><Stamp block={q.data!.block} label="Read at block" /></p>
            </>
          )}
        </section>
      </div>

      {book && book.layers.length > 0 && (
        <section className="positions" aria-labelledby="layers-h">
          <h2 id="layers-h" className="section">Layers on the book</h2>
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
        A vault long {usd0.format(REFERENCE.exposure)} USDG of SPY keeps the first {usd0.format(REFERENCE.retention)} of a
        weekend loss; writers cover the next {usd0.format(REFERENCE.limit)}.{' '}
        {quote.isLoading ? <span className="pending">The pricer is quoting it now.</span> : <>That cover costs <b><Money v={premium} /> USDG</b> for one weekend.</>}
      </p>
      <div className="rows figs">
        <div className="row"><span className="k">Rate on line</span><span className="v">{((premium / REFERENCE.limit) * 100).toFixed(2)}%</span></div>
        <div className="row"><span className="k">Expected loss</span><span className="v"><Money v={el} /></span></div>
        <div className="row"><span className="k">Weekends it pays</span><span className="v">{bt.paid} of 504</span></div>
      </div>
      <details className="more">
        <summary>Tail and source</summary>
        <div className="rows figs">
          <div className="row"><span className="k">TVaR95, worst 25 weekends</span><span className="v"><Money v={tvar} /></span></div>
          <div className="row"><span className="k">Full limit paid</span><span className="v">{bt.exhausted} of 504</span></div>
        </div>
        <p className="note">
          {agrees
            ? `Rerun in this browser over SPY.json, the expected loss matches the pricer's (${usd2.format(bt.el)}).`
            : `Rerun in this browser at 1.0x volatility gives ${usd2.format(bt.el)}; the difference is the pricer's live volatility scale.`}
        </p>
      </details>
      {live ? (
        <p className="src">
          Quoted by the Stylus pricer at block <a href={explorer.block(live.block)} target="_blank" rel="noreferrer">#{live.block.toLocaleString('en-US')}</a>.
        </p>
      ) : !quote.isLoading ? (
        <p className="err" role="status">
          <b>Live quote failed</b> {quote.error ? explainError(quote.error).name : 'no client'}; showing the recorded quote at block 313,690,038 (README).
        </p>
      ) : null}
    </>
  );
}

/** One layer on the book as a ledger row, with its settle or claim actions behind a toggle. */
function LayerRow({ layer, book, now }: { layer: Layer; book: BookSnapshot; now: number }) {
  const [open, setOpen] = useState(false);
  const stateName = LAYER_STATES[layer.state];
  const exp = layer.exposure[0] ?? 0n;
  const dir = exp < 0n ? 'short' : 'long';
  const fixing = layer.state === 1 ? (now >= layer.expiry ? 'fixing open' : fmtCountdown(layer.expiry - now)) : '-';

  return (
    <div className="ledger-row" role="row">
      <div className="ledger-grid">
        <span role="cell" data-k="Market">SPY</span>
        <span role="cell" data-k="Exposure">{fmtUsdg(exp < 0n ? -exp : exp)} {dir}</span>
        <span role="cell" data-k="Retention / limit">{fmtUsdg(layer.retention)} / {fmtUsdg(layer.limit)}</span>
        <span role="cell" data-k="Premium">{fmtUsdg(layer.premium)}</span>
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
 * The pool split into what it has promised and what it has not. Both sides are direct contract
 * reads: limits locked, payouts owed but unclaimed (still reserved inside locked until claim), and free.
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
      <div className="rows figs">
        <div className="row"><span className="k"><i className="sw free" />Free</span><span className="v">{fmtUsdg(free)} USDG</span></div>
        <div className="row"><span className="k"><i className="sw locked" />Locked under bound limits</span><span className="v">{fmtUsdg(locked)} USDG</span></div>
        <div className="row"><span className="k"><i className="sw owed" />Owed, unclaimed</span><span className="v">{fmtUsdg(owed)} USDG</span></div>
        <div className="row"><span className="k">Pending premium</span><span className="v">{fmtUsdg(pending)} USDG</span></div>
        <div className="row"><span className="k">Pool balance</span><span className="v">{fmtUsdg(balance)} USDG</span></div>
      </div>
    </div>
  );
}

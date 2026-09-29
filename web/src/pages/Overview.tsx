import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useConnection, usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { PRICER_ADDRESS } from '../abi';
import { explorer } from '../chain';
import { useBook, type BookSnapshot, type Layer } from '../hooks/useBook';
import { useLiveQuote, termsKey, type Terms } from '../hooks/useLiveQuote';
import { useNow } from '../hooks/useNow';
import { useWeekWindow, type WeekWindow } from '../hooks/useWeekWindow';
import { Stamp } from '../components/Stamp';
import { Money } from '../components/Money';
import { SettleItem, ClaimRow } from '../components/SettlePanel';
import { LayerTower } from '../components/LayerTower';
import { GapChart } from '../components/GapChart';
import { WeekStrip } from '../components/WeekStrip';
import { BuyCover, charged } from '../components/BuyCover';
import { fmtClock, fmtCountdown, fmtPx, fmtStamp, fmtUsdg, parseUsdg, short } from '../lib/format';
import { LAYER_STATES } from '../lib/treaty';
import { explainError } from '../lib/revert';
import { REFERENCE, TABLES, backtest, type Ticker } from '../lib/gaps';

const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const usd2 = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const toUsd = (v: bigint) => Number(v) / 1e6;
const pct = (bps: number) => `${(bps / 100).toFixed(2).replace(/\.?0+$/, '')}%`;
const age = (s: number) => (s >= 86400 ? `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h` : s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m` : `${Math.max(0, Math.floor(s / 60))}m`);
const DAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const day = (sec: number) => { const d = new Date(sec * 1000); return `${DAY[d.getUTCDay()]} ${d.getUTCDate()} ${MON[d.getUTCMonth()]}`; };

/** Cover band limits, in basis points of the declared position. */
const BAND_MIN = 25;
const BAND_MAX = 1200;
const BAND_STEP = 25;

type Side = 'long' | 'short';
type Tab = 'weekends' | 'week' | 'pricer' | 'book';
const TABS: { id: Tab; name: string }[] = [
  { id: 'weekends', name: 'Weekends' },
  { id: 'week', name: 'This week' },
  { id: 'pricer', name: 'Pricer' },
  { id: 'book', name: 'Book' },
];

/** "2000000" or "2,000,000.5" -> "2,000,000.5" as the user types. */
function group(s: string) {
  const [w, f] = s.replace(/[^\d.]/g, '').split('.');
  const whole = w.replace(/^0+(?=\d)/, '').replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return f === undefined ? whole : `${whole}.${f.slice(0, 6)}`;
}

export function Overview() {
  useEffect(() => { document.title = 'Heracles: SPY weekend cover for perp LP vaults'; }, []);
  const conn = useConnection();
  const client = usePublicClient() as PublicClient | undefined;
  const now = useNow();
  const q = useBook(conn.address);
  const win = useWeekWindow(client, now);

  const [position, setPosition] = useState(group(String(REFERENCE.exposure)));
  const [side, setSide] = useState<Side>('long');
  const [attach, setAttach] = useState(Math.round((REFERENCE.retention / REFERENCE.exposure) * 10_000));
  const [exhaust, setExhaust] = useState(Math.round(((REFERENCE.retention + REFERENCE.limit) / REFERENCE.exposure) * 10_000));
  const [ticker, setTicker] = useState<Ticker>('SPY');
  const [tab, setTab] = useState<Tab>('weekends');

  const parsed = useMemo((): { terms?: Terms; error?: string } => {
    try {
      const abs = parseUsdg(position.replace(/,/g, ''));
      if (abs === 0n) return { error: 'Enter the position your vault declared.' };
      const ret = (abs * BigInt(attach)) / 10_000n;
      const lim = (abs * BigInt(exhaust - attach)) / 10_000n;
      if (lim === 0n) return { error: 'This position is too small for the band.' };
      return { terms: { exp: [side === 'long' ? abs : -abs], ret, lim } };
    } catch (e) {
      return { error: e instanceof Error ? e.message : String(e) };
    }
  }, [position, side, attach, exhaust]);
  const terms = parsed.terms;
  const live = useLiveQuote(terms);

  const layer = useMemo(() => (terms ? { exposure: toUsd(terms.exp[0]), retention: toUsd(terms.ret), limit: toUsd(terms.lim) } : undefined), [terms]);
  const counts = useMemo(
    () => TABLES.map((t) => ({ ticker: t.ticker, bt: layer ? backtest(t.weekends, layer.exposure, layer.retention, layer.limit) : undefined })),
    [layer],
  );
  const spyBt = counts[0].bt;
  const order = [counts[0], ...counts.slice(1).sort((a, b) => (b.bt?.paid ?? 0) - (a.bt?.paid ?? 0))];
  const table = TABLES.find((t) => t.ticker === ticker)!;

  const book = q.data?.value;
  const quote = live.quote;
  const price = terms && quote && book ? charged(quote.premium, quote.terms.lim, book.minRateBps) : undefined;
  const stale = live.quoting || (quote !== undefined && termsKey(quote.terms) !== termsKey(terms));
  const dir = side === 'long' ? 'down' : 'up';
  const band = `${pct(attach)} to ${pct(exhaust)} ${dir}`;
  const unbacked = terms !== undefined && book !== undefined && terms.lim > book.capacity.free;

  return (
    <div className="page cover">
      <div className="lead">
        <h1 className="hero">SPY weekend <span>cover</span> <em className="badge">Parametric</em></h1>
        <div className="meta">
          <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)} ↗</a>
          <span><i />Arbitrum Sepolia</span>
          <span><i className="t" />Stylus pricer</span>
          <span><i />USDG</span>
        </div>
        <p className="desc">
          For the LP vaults of stock perp exchanges. If SPY opens Monday more than{' '}
          {pct(attach)} {side === 'long' ? 'below' : 'above'} Friday's close, Heracles pays the vault an amount set by the price feed and
          the position it declared, never by its books.
        </p>

        <div className="kpi" aria-live="polite">
          <div>
            <p>Premium</p>
            <strong className={stale ? 'stale' : undefined}>{price ? usd2.format(toUsd(price.premium)) : '…'}<span> USDG</span></strong>
            <small>
              {parsed.error ? parsed.error
                : live.error ? <>Quote failed: {live.error}</>
                : quote ? <><span className="wide-only">{stale ? 'Stylus pricer, re-quoting' : price?.floored ? 'Stylus pricer minimum' : 'Stylus pricer, live'} at </span>block <a href={explorer.block(quote.block)} target="_blank" rel="noreferrer">{quote.block.toLocaleString('en-US')}</a></>
                : 'Quoting from the Stylus pricer'}
            </small>
          </div>
          <div>
            <p>Cover pays up to</p>
            <strong>{terms ? usd0.format(toUsd(terms.lim)) : '…'}<span> USDG</span></strong>
            <small>Band you set: SPY {band}</small>
          </div>
          <div>
            <p>Weekends it would have paid</p>
            <strong>{spyBt ? spyBt.paid : '…'}<span> of {TABLES[0].weekends.length}</span></strong>
            <small>{spyBt ? `SPY weekends since 2016, ${spyBt.exhausted} at the cap` : ' '}</small>
          </div>
        </div>

        <div className="tabs" role="tablist" aria-label="Cover details">
          {TABS.map((t) => (
            <button key={t.id} type="button" role="tab" id={`tab-${t.id}`} aria-controls="tabpanel" aria-selected={tab === t.id} onClick={() => setTab(t.id)}>{t.name}</button>
          ))}
        </div>
      </div>

      <aside className="panel" id="buy" aria-label="Buy cover">
        <div className="box">
          <label className="bh" htmlFor="position">Vault's declared position (USDG)<i aria-hidden="true" /></label>
          <input
            id="position"
            className="amt"
            inputMode="decimal"
            autoComplete="off"
            value={position}
            onChange={(e) => setPosition(group(e.target.value))}
            aria-describedby="position-hint"
          />
          <div className="bf">
            <span id="position-hint">{parsed.error ?? `SPY, net ${side}`}</span>
            <span className="seg" role="radiogroup" aria-label="Side">
              {(['long', 'short'] as const).map((s) => (
                <button key={s} type="button" role="radio" aria-checked={side === s} onClick={() => setSide(s)}>{s === 'long' ? 'Long' : 'Short'}</button>
              ))}
            </span>
          </div>
        </div>

        <div className="box">
          <div className="bh"><span>Cover band</span><b>{band}</b></div>
          <BandSlider attach={attach} exhaust={exhaust} setAttach={setAttach} setExhaust={setExhaust} dir={dir} />
          <div className="rw">Vault keeps the first<b>{terms ? usd0.format(toUsd(terms.ret)) : '…'} USDG</b></div>
          <div className="rw">Cover period<b>{win ? <>{day(win.ref)} close → {day(win.expiry)} open</> : '…'}</b></div>
          <div className="rw">Payout set by<b>Price feed × declared size</b></div>
          <div className={`rw pr${stale ? ' stale' : ''}`}>Premium<b>{price ? `${usd2.format(toUsd(price.premium))} USDG` : '…'}</b></div>
        </div>

        <BuyCover terms={terms} quote={quote} book={q.data} win={win} now={now} />

        <div className="claim">
          <p>
            <b>No loss to prove.</b> Monday's feed and the position the vault declared fix the payout; nobody
            reads its books. Once the week settles, the vault collects in one transaction.
          </p>
        </div>
        {!unbacked && <p className="wn">Writers back this cover with USDG and earn its premium. <Link to="/write">Write cover</Link></p>}
      </aside>

      <div className="body" id="tabpanel" role="tabpanel" aria-labelledby={`tab-${tab}`}>
        {tab === 'weekends' && (
          <section className="cc" aria-labelledby="chart-h">
            <div className="ch">
              <div>
                <p>Monday open vs Friday close</p>
                <h2 id="chart-h">{ticker}<span>, every weekend</span></h2>
              </div>
              <div className="ctl">
                <p id="cmp-h">Weekends it would have paid, of 504</p>
                <div className="sg" role="tablist" aria-labelledby="cmp-h">
                  {order.map((c) => (
                    <button key={c.ticker} type="button" role="tab" aria-selected={c.ticker === ticker} onClick={() => setTicker(c.ticker)}>
                      {c.ticker} <b>{c.bt ? c.bt.paid : '…'}</b>
                    </button>
                  ))}
                </div>
              </div>
            </div>
            {ticker !== 'SPY' && <p className="cn">The same cover drawn over {ticker}. The testnet pricer quotes SPY only, so the premium above is SPY's.</p>}
            {layer ? <GapChart key={ticker} table={table} layer={layer} compact /> : <p className="cn">{parsed.error}</p>}
          </section>
        )}
        {tab === 'week' && <WeekTab win={win} now={now} book={book} />}
        {tab === 'pricer' && <PricerTab live={live} terms={terms} layerEl={spyBt?.el} />}
        {tab === 'book' && <BookTab q={q} now={now} />}
      </div>

      <div className="bar">
        <div>{unbacked ? 'No writer backing yet' : <>Premium<b>{price ? `${usd2.format(toUsd(price.premium))} USDG` : '…'}</b></>}</div>
        {unbacked ? <button className="buy" disabled>Buy cover</button> : <a className="buy" href="#buy">Buy cover</a>}
      </div>
    </div>
  );
}

/** Two native range inputs on one track: where the cover starts paying and where it pays its cap. */
function BandSlider({ attach, exhaust, setAttach, setExhaust, dir }: { attach: number; exhaust: number; setAttach: (n: number) => void; setExhaust: (n: number) => void; dir: string }) {
  const at = (v: number) => (v - BAND_MIN) / (BAND_MAX - BAND_MIN);
  return (
    <div className="band-slider" style={{ ['--a' as string]: at(attach), ['--b' as string]: at(exhaust) }}>
      <input
        type="range" min={BAND_MIN} max={BAND_MAX} step={BAND_STEP} value={attach}
        aria-label={`Cover starts paying at a gap of this size, ${dir}`}
        aria-valuetext={`${pct(attach)} ${dir}`}
        onChange={(e) => setAttach(Math.min(Number(e.target.value), exhaust - BAND_STEP))}
      />
      <input
        type="range" min={BAND_MIN} max={BAND_MAX} step={BAND_STEP} value={exhaust}
        aria-label={`Cover pays its cap at a gap of this size, ${dir}`}
        aria-valuetext={`${pct(exhaust)} ${dir}`}
        onChange={(e) => setExhaust(Math.max(Number(e.target.value), attach + BAND_STEP))}
      />
      <div className="band-scale" aria-hidden="true"><span>{pct(BAND_MIN)}</span><span>{pct(BAND_MAX)}</span></div>
    </div>
  );
}

function WeekTab({ win, now, book }: { win: WeekWindow | undefined; now: number; book: BookSnapshot | undefined }) {
  const spyFeed = book?.markets[0];
  return (
    <section className="doc" aria-label="This cover week">
      {win ? <WeekStrip win={win} now={now} /> : <p className="note">Reading the week window from the treaty.</p>}
      {spyFeed && (
        <p className="note">
          SPY/USD feed on chain: <span className="fig">{fmtPx(spyFeed.latest.answer)}</span>, round {age(now - Number(spyFeed.latest.updatedAt))} old
          ({fmtStamp(spyFeed.latest.updatedAt)}). The feed pauses over the weekend; that silence is the gap.
        </p>
      )}
    </section>
  );
}

function PricerTab({ live, terms, layerEl }: { live: ReturnType<typeof useLiveQuote>; terms: Terms | undefined; layerEl: number | undefined }) {
  const quote = live.quote;
  const same = quote && termsKey(quote.terms) === termsKey(terms);
  return (
    <section className="doc" aria-label="How the price is worked out">
      <p className="prose">
        The premium is one read of the Stylus pricer <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a>,
        made again each time the position or the band changes. It runs the cover over the same 504 SPY weekends drawn
        on the chart, scaled by the live volatility, and returns the price, the average payout and the average of the
        worst 25 weekends. At settlement the payout is the same arithmetic on one weekend: the Monday gap on the feed
        times the declared position, minus the part the vault keeps, capped at the limit. The call costs{' '}
        <span className="fig">8.01x</span> less L2 execution gas in Stylus than in its Solidity twin, measured at
        block <a href={explorer.block(313_704_736n)} target="_blank" rel="noreferrer">313,704,736</a>.
      </p>
      {quote && same && (
        <div className="rows figs">
          <div className="row"><span className="k">Average payout a weekend (expected loss)</span><span className="v"><Money v={toUsd(quote.el)} /></span></div>
          <div className="row"><span className="k">Average of the worst 25 weekends (TVaR95)</span><span className="v"><Money v={toUsd(quote.tvar)} /></span></div>
          {layerEl !== undefined && <div className="row"><span className="k">Same average rerun in this browser at 1.0x volatility</span><span className="v"><Money v={layerEl} /></span></div>}
          <div className="row"><span className="k">Quoted at block</span><span className="v"><Stamp block={quote.block} label="" /></span></div>
        </div>
      )}
      <p className="src">Weekends: <span className="file">{TABLES[0].file}</span> in the repo, from {TABLES[0].source}, fetched {TABLES[0].fetchDate}.</p>
    </section>
  );
}

function BookTab({ q, now }: { q: ReturnType<typeof useBook>; now: number }) {
  const book = q.data?.value;
  if (q.error) return <p className="err" role="alert"><b>{explainError(q.error).name}</b> {explainError(q.error).words}</p>;
  if (!book) return <p className="note">Reading the treaty book at the latest block.</p>;
  return (
    <section className="doc" aria-label="The book">
      <div className="rows figs">
        <div className="row"><span className="k">Covers bought</span><span className="v">{book.layers.length}</span></div>
        <div className="row"><span className="k">USDG backing cover</span><span className="v"><Money v={toUsd(book.capacity.balance)} /> USDG</span></div>
        <div className="row"><span className="k">Free for new cover</span><span className="v"><Money v={toUsd(book.capacity.free)} /> USDG</span></div>
      </div>
      {book.capacity.balance === 0n && book.layers.length === 0 && (
        <p className="note">
          No cover has been bought on this deployment yet and no writer has deposited USDG, so new cover cannot be
          bought until one does. <Link to="/write">Be the first writer</Link>.
        </p>
      )}
      <p className="src"><Stamp block={q.data!.block} label="Read at block" /></p>
      {book.layers.length > 0 && (
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
      )}
    </section>
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

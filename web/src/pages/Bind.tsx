import { useEffect, useMemo, useState } from 'react';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { CAPACITY_ADDRESS, FEED_ADDRESSES, PRICER_ADDRESS, TREATY_ADDRESS, USDG_ADDRESS, erc20Abi, treatyAbi } from '../abi';
import { explorer } from '../chain';
import { useBook, quoteLive } from '../hooks/useBook';
import { useNow } from '../hooks/useNow';
import { useTx } from '../hooks/useTx';
import { useOnChain } from '../components/Wallet';
import { Stamp } from '../components/Stamp';
import { TxNote } from '../components/TxNote';
import { GapChart } from '../components/GapChart';
import { WeekStrip } from '../components/WeekStrip';
import { useWeekWindow, reopensAt as reopenOf } from '../hooks/useWeekWindow';
import { Link } from 'react-router-dom';
import { TABLES, backtest, fmtBps } from '../lib/gaps';

const spy = TABLES[0];
import { fmtClock, fmtCountdown, fmtUsdg, parseExposure, parseUsdg, short } from '../lib/format';
import { explainError } from '../lib/revert';
import { useConnection } from 'wagmi';

type Quote = { premium: bigint; el: bigint; tvar: bigint; block: bigint };
export function Bind() {
  useEffect(() => { document.title = 'Heracles: price and bind a layer'; }, []);
  const conn = useConnection();
  const me = useOnChain();
  const client = usePublicClient() as PublicClient | undefined;
  const book = useBook(conn.address);
  const tx = useTx();
  const approveTx = useTx();
  const now = useNow();
  const win = useWeekWindow(client, now);

  const [exposures, setExposures] = useState<string[]>(() => FEED_ADDRESSES.map(() => '2000000'));
  const [retention, setRetention] = useState('20000');
  const [limit, setLimit] = useState('60000');
  const [formError, setFormError] = useState<string>();
  const [quote, setQuote] = useState<Quote>();
  const [quoteError, setQuoteError] = useState<string>();
  const [quoting, setQuoting] = useState(false);

  const closed = win !== undefined && now >= win.cutoff && now < win.expiry;
  // Binding reopens when the next ISO week begins (Monday 00:00 UTC), not at `win.expiry`
  // (Monday 13:30 UTC, the fixing time for layers bound in a prior week). Friday 19:30 UTC
  // + 2 days 4.5 hours = the following Monday 00:00 UTC.
  const reopensAt = win !== undefined ? reopenOf(win) : undefined;

  const parsed = useMemo(() => {
    try {
      const exp = exposures.map(parseExposure);
      const ret = parseUsdg(retention);
      const lim = parseUsdg(limit);
      if (exp.every((e) => e === 0n)) return { error: 'At least one exposure must be non-zero. A zero-exposure bind reverts with BadParams.' };
      if (lim === 0n) return { error: 'The limit must be above zero. A zero limit binds nothing.' };
      return { exp, ret, lim };
    } catch (e) {
      return { error: e instanceof Error ? e.message : String(e) };
    }
  }, [exposures, retention, limit]);

  useEffect(() => {
    setFormError(parsed.error);
  }, [parsed]);

  useEffect(() => {
    if (!client || parsed.error || !parsed.exp) {
      setQuote(undefined);
      setQuoteError(undefined);
      return;
    }
    setQuoting(true);
    const t = setTimeout(async () => {
      try {
        const [premium, el, tvar] = await quoteLive(client, parsed.exp!, parsed.ret!, parsed.lim!) as unknown as [bigint, bigint, bigint];
        const block = await client.getBlockNumber();
        setQuote({ premium, el, tvar, block });
        setQuoteError(undefined);
      } catch (e) {
        setQuote(undefined);
        setQuoteError(explainError(e).words);
      } finally {
        setQuoting(false);
      }
    }, 450);
    return () => clearTimeout(t);
  }, [client, parsed]);

  const minRateBps = book.data?.value.minRateBps ?? 50n;
  const floor = parsed.lim !== undefined ? (parsed.lim * minRateBps) / 10000n : undefined;
  const quoted = quote?.premium;
  const effective = quoted !== undefined && floor !== undefined ? (quoted >= floor ? quoted : floor) : undefined;
  const floorApplies = quoted !== undefined && floor !== undefined && quoted < floor;
  const floorPct = (Number(minRateBps) / 100).toFixed(1);

  const allowance = book.data?.value.capacity.myAllowance ?? 0n;
  const needsApprove = effective !== undefined ? allowance < effective && effective > 0n : false;

  const approve = () =>
    me.address && effective !== undefined
      ? approveTx.run({ address: USDG_ADDRESS, abi: erc20Abi, functionName: 'approve', args: [CAPACITY_ADDRESS, effective], account: me.address })
      : undefined;

  const bind = () => {
    if (!me.address || !parsed.exp || parsed.ret === undefined || parsed.lim === undefined) return;
    tx.run({
      address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'bind',
      args: [parsed.exp, parsed.ret, parsed.lim],
      account: me.address,
    });
  };

  const terms = useMemo(
    () => (parsed.exp && parsed.ret !== undefined && parsed.lim !== undefined
      ? { exposure: Number(parsed.exp[0] ?? 0n) / 1e6, retention: Number(parsed.ret) / 1e6, limit: Number(parsed.lim) / 1e6 }
      : undefined),
    [parsed],
  );
  const bt = useMemo(() => (terms ? backtest(spy.weekends, terms.exposure, terms.retention, terms.limit) : undefined), [terms]);

  return (
    <>
      <header className="lead">
        <h1>Price a layer</h1>
        <p>
          Declare the vault's Friday net exposure, the retention it keeps, and the limit writers
          cover. The band on the chart is what you are buying; the deployed Stylus pricer quotes it
          live, and bind pulls the premium into capacity in the same transaction.
        </p>
      </header>

      <div className="desk">
        <div className="stack">
          <section className="panel" aria-labelledby="bchart-h">
            <div className="panel-head">
              <h2 id="bchart-h">Your layer across 504 SPY weekends</h2>
              {book.data && <span className="right"><Stamp block={book.data.block} label="book at" /></span>}
            </div>
            {terms ? (
              <GapChart table={spy} layer={terms} />
            ) : (
              <p className="prose">Fill in exposure, retention and limit to draw the layer.</p>
            )}
          </section>

          <section className="panel" aria-labelledby="bweek-h">
            <div className="panel-head"><h2 id="bweek-h">This cover week</h2></div>
            {!win ? (
              <p className="prose">Reading the week window from the treaty.</p>
            ) : (
              <>
                <WeekStrip win={win} now={now} />
                {closed && (
                  <p className="prose" role="status">
                    Binding for this weekend closed at <span className="num">{fmtClock(win.cutoff)} UTC</span>. Cover for
                    next week opens Monday 00:00 UTC, in <span className="num">{fmtCountdown((reopensAt ?? win.expiry) - now)}</span>.
                  </p>
                )}
              </>
            )}
          </section>
        </div>

        <aside className="panel ticket" aria-labelledby="terms-h">
          <h2 id="terms-h" className="ticket-h">Terms</h2>
          <div className="form">
            {FEED_ADDRESSES.map((f, i) => (
              <div className="field" key={f}>
                <label htmlFor={`exp-${i}`}>SPY net exposure, USDG</label>
                <input
                  id={`exp-${i}`}
                  inputMode="decimal"
                  value={exposures[i] ?? ''}
                  onChange={(e) => setExposures((xs) => xs.map((x, j) => (j === i ? e.target.value : x)))}
                />
                <span className="hint">Positive is long and loses on a down gap; negative is short. Feed <a className="tx" href={explorer.address(f)} target="_blank" rel="noreferrer">{short(f)}</a>.</span>
              </div>
            ))}
            <div className="field two">
              <div className="field">
                <label htmlFor="ret">Retention, vault keeps</label>
                <input id="ret" inputMode="decimal" value={retention} onChange={(e) => setRetention(e.target.value)} />
              </div>
              <div className="field">
                <label htmlFor="lim">Limit, writers cover</label>
                <input id="lim" inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value)} />
              </div>
            </div>
            {formError && <p className="prose err" role="alert"><b>Check</b> {formError}</p>}
          </div>

          <div className="quote" aria-live="polite">
            <span className="lab">Premium, live</span>
            {quoting ? (
              <span className="prose tight">Quoting the Stylus pricer.</span>
            ) : quoteError ? (
              <span className="prose err" role="alert"><b>Quote</b> {quoteError}</span>
            ) : quote && effective !== undefined && floor !== undefined ? (
              <>
                <span className="fig hero" title={`${fmtUsdg(effective)} USDG`}>{(Number(effective) / 1e6).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}<small>USDG premium</small></span>
                <dl className="tk">
                  <dt>Expected loss</dt><dd className="num">{fmtUsdg(quote.el)}</dd>
                  <dt>TVaR95</dt><dd className="num">{fmtUsdg(quote.tvar)}</dd>
                  {bt && <><dt>Starts paying at</dt><dd className="num">{fmtBps(bt.attachBps)}</dd></>}
                  {bt && <><dt>Weekends it pays</dt><dd><span className="num">{bt.paid}</span> of 504</dd></>}
                </dl>
                <p className="src">
                  {floorApplies
                    ? `The ${floorPct}% rate-on-line floor applies (pricer quoted ${fmtUsdg(quote.premium)}). `
                    : `Pricer quote applies (floor ${fmtUsdg(floor)}). `}
                  Pricer <a className="tx" href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a> at
                  block <span className="num">#{quote.block.toLocaleString('en-US')}</span>.
                </p>
              </>
            ) : (
              <span className="prose tight">Fill in exposure, retention and limit to quote.</span>
            )}
          </div>

          {book.data && parsed.lim !== undefined && parsed.lim > book.data.value.capacity.free && (
            <p className="prose err" role="alert">
              <b>CapacityExceeded</b> The limit is larger than the free writer capacity
              ({fmtUsdg(book.data.value.capacity.free)} USDG at block #{book.data.block.toLocaleString('en-US')}). <Link to="/write">Write capacity</Link> first.
            </p>
          )}

          {closed ? null : (
            <div className="bindbox">
              {!me.ready && <p className="prose tight">{me.reason}</p>}
              {effective !== undefined && effective > 0n && (
                <dl className="tk">
                  <dt>Premium due</dt><dd><span className="num">{fmtUsdg(effective)}</span> USDG</dd>
                  <dt>Your allowance</dt><dd><span className="num">{fmtUsdg(allowance)}</span> USDG</dd>
                </dl>
              )}
              <div className="actions">
                {needsApprove && (
                  <button className="btn ghost" disabled={!me.ready || approveTx.busy} onClick={approve}>
                    Approve {effective !== undefined ? fmtUsdg(effective) : ''} USDG
                  </button>
                )}
                <button className="btn wide" disabled={!me.ready || tx.busy || !!formError || effective === undefined || needsApprove} onClick={bind}>
                  Bind layer
                </button>
              </div>
              <TxNote status={approveTx.status} hash={approveTx.hash} error={approveTx.error} />
              <TxNote status={tx.status} hash={tx.hash} error={tx.error} />
            </div>
          )}
          <p className="fine">
            Tail cover on a weekend gap, not smart-contract cover. The premium never falls below
            0.5% of the limit.
          </p>
        </aside>
      </div>
    </>
  );
}

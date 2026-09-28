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
import { LayerTower } from '../components/LayerTower';
import { fmtClock, fmtCountdown, fmtUsdg, parseExposure, parseUsdg, short } from '../lib/format';
import { explainError } from '../lib/revert';
import { useConnection } from 'wagmi';

type Quote = { premium: bigint; el: bigint; tvar: bigint; block: bigint };
type Window = { cutoff: number; expiry: number; ref: number };

/**
 * The week's take cutoff, Friday reference (`fridayCloseOf`), and Monday fixing, all read from
 * the contract's own calendar so the DST-aware close/expiry math is never duplicated here.
 */
function useWeekWindow(client: PublicClient | undefined, now: number): Window | undefined {
  const [win, setWin] = useState<Window>();
  useEffect(() => {
    if (!client) return;
    let live = true;
    client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'weekWindow', args: [BigInt(now)] })
      .then(async (r) => {
        const [cutoff, expiry] = r as unknown as [bigint, bigint];
        const ref = await client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'fridayCloseOf', args: [cutoff] });
        if (!live) return;
        setWin({ cutoff: Number(cutoff), expiry: Number(expiry), ref: Number(ref as bigint) });
      })
      .catch(() => { if (live) setWin(undefined); });
    return () => { live = false; };
  }, [client, Math.floor(now / 30)]);
  return win;
}

export function Bind() {
  useEffect(() => { document.title = 'Heracles: treaty'; }, []);
  const conn = useConnection();
  const me = useOnChain();
  const client = usePublicClient() as PublicClient | undefined;
  const book = useBook(conn.address);
  const tx = useTx();
  const approveTx = useTx();
  const now = useNow();
  const win = useWeekWindow(client, now);

  const [exposures, setExposures] = useState<string[]>(() => FEED_ADDRESSES.map(() => '-100'));
  const [retention, setRetention] = useState('2');
  const [limit, setLimit] = useState('10');
  const [formError, setFormError] = useState<string>();
  const [quote, setQuote] = useState<Quote>();
  const [quoteError, setQuoteError] = useState<string>();
  const [quoting, setQuoting] = useState(false);

  const closed = win !== undefined && now >= win.cutoff && now < win.expiry;
  // Binding reopens when the next ISO week begins (Monday 00:00 UTC), not at `win.expiry`
  // (Monday 13:30 UTC, the fixing time for layers bound in a prior week). Friday 19:30 UTC
  // + 2 days 4.5 hours = the following Monday 00:00 UTC.
  const reopensAt = win !== undefined ? win.cutoff + 2 * 86400 + 4.5 * 3600 : undefined;

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

  return (
    <>
      <div className="title-block">
        <span className="item">01</span>
        <div>
          <h1>Bind a treaty</h1>
          <p>
            Declare the vault's Friday net exposure per market, a retention the vault keeps,
            and the limit writers cover. The contract sets the Friday 19:30 UTC cutoff and
            the Monday 13:30 UTC expiry itself. The premium is quoted live by the deployed
            pricer and pulled into capacity in the same transaction.
          </p>
          {book.data && <p className="stamp" style={{ marginTop: 10 }}><Stamp block={book.data.block} label="read at" /></p>}
        </div>
      </div>

      <div className="sheet trade">
        <div>
          <section className="sec block" aria-label="The layer being priced">
            <div className="sec-head">
              <span className="item">02</span>
              <h2>The layer you are pricing</h2>
            </div>
            <div className="sec-body">
              {quoting ? (
                <p className="prose">Quoting the Stylus pricer…</p>
              ) : quoteError ? (
                <p className="prose err" role="alert"><b>Quote</b> {quoteError}</p>
              ) : parsed.error ? (
                <p className="prose">Fill in exposure, retention, and limit to draw the layer.</p>
              ) : (
                <LayerTower
                  name="New layer"
                  who={<>take closes {win ? fmtClock(win.cutoff) : 'pending'} UTC · fixing {win ? fmtClock(win.expiry) : 'pending'} UTC</>}
                  exposure={parsed.exp![0] ?? 0n}
                  retention={parsed.ret!}
                  limit={parsed.lim!}
                  premium={effective ?? quote?.premium ?? 0n}
                  tag="quoted"
                />
              )}
            </div>
          </section>
        </div>

        <div className="rail">
          <section className="sec block" aria-label="Exposure and terms">
            <div className="sec-head">
              <span className="item">03</span>
              <h2>Exposure and terms</h2>
            </div>
            <div className="sec-body">
              <div className="form">
                {FEED_ADDRESSES.map((f, i) => (
                  <div className="field" key={f}>
                    <label htmlFor={`exp-${i}`}>SPY net notional, USDG (negative is short)</label>
                    <input
                      id={`exp-${i}`}
                      inputMode="decimal"
                      value={exposures[i] ?? ''}
                      onChange={(e) => setExposures((xs) => xs.map((x, j) => (j === i ? e.target.value : x)))}
                    />
                    <span className="hint">Signed: a short vault loses when the market rises. Feed <a className="tx" href={explorer.address(f)} target="_blank" rel="noreferrer">{short(f)}</a>.</span>
                  </div>
                ))}
                <div className="field two">
                  <span className="lab">Layer, USDG</span>
                  <div className="field">
                    <label htmlFor="ret">Retention (vault keeps)</label>
                    <input id="ret" inputMode="decimal" value={retention} onChange={(e) => setRetention(e.target.value)} />
                  </div>
                  <div className="field">
                    <label htmlFor="lim">Limit (writers cover)</label>
                    <input id="lim" inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value)} />
                  </div>
                </div>
                {formError && <p className="prose err" role="alert"><b>Check</b> {formError}</p>}
              </div>

              <div className="quote" aria-live="polite">
                <span className="lab">Live premium</span>
                {quoting ? (
                  <span className="prose">Quoting the Stylus pricer…</span>
                ) : quoteError ? (
                  <span className="prose err" role="alert"><b>Quote</b> {quoteError}</span>
                ) : quote && effective !== undefined && floor !== undefined ? (
                  <>
                    <span className="fig">{fmtUsdg(effective)}<small>USDG</small></span>
                    <span className="prose">
                      {floorApplies
                        ? `${floorPct}% rate-on-line floor applies (pricer quoted ${fmtUsdg(quote.premium)}).`
                        : `Pricer quote applies (floor is ${fmtUsdg(floor)}).`}{' '}
                      Expected loss <span className="num">{fmtUsdg(quote.el)}</span> ·
                      TVaR95 <span className="num">{fmtUsdg(quote.tvar)}</span> ·
                      quoted at block <span className="num">#{quote.block.toLocaleString('en-US')}</span>.
                    </span>
                  </>
                ) : (
                  <span className="prose">Fill in exposure, retention, and limit to quote.</span>
                )}
              </div>
              <p className="fine">
                Pricer <a className="tx" href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a>,
                priced on-chain by the Rust (Stylus) pricer, measured at 8.01x less L2 execution gas
                than its Solidity twin on the same call.
              </p>
              <p className="prose">
                The premium never falls below 0.5% of the limit. This is excess-of-loss tail cover on
                a weekend gap, not smart-contract cover.
              </p>
            </div>
          </section>

          <section className="sec block" aria-label="Week clock">
            <div className="sec-head">
              <span className="item">04</span>
              <h2>Week clock</h2>
            </div>
            <div className="sec-body">
              {!win ? (
                <p className="prose">Reading the week window from the treaty…</p>
              ) : (
                <>
                  <WeekClock win={win} now={now} />
                  {closed ? (
                    <p className="prose" role="status">
                      Cover for next week opens Monday 00:00 UTC, in <span className="num">{fmtCountdown((reopensAt ?? win.expiry) - now)}</span>.
                      The take window for this week closed Friday at <span className="num">{fmtClock(win.cutoff)} UTC</span>.
                    </p>
                  ) : (
                    <p className="prose" role="status">
                      Take closes Friday at <span className="num">{fmtClock(win.cutoff)} UTC</span> (in <span className="num">{fmtCountdown(win.cutoff - now)}</span>).
                      Fixing opens Monday at <span className="num">{fmtClock(win.expiry)} UTC</span> (in <span className="num">{fmtCountdown(win.expiry - now)}</span>).
                    </p>
                  )}
                </>
              )}
            </div>
          </section>

          {closed ? null : (
            <section className="sec block" aria-label="Bind">
              <div className="sec-head">
                <span className="item">05</span>
                <h2>Bind</h2>
              </div>
              <div className="sec-body">
                <div className="cell">
                  {!me.ready && <p className="prose">{me.reason}</p>}
                  {effective !== undefined && effective > 0n && (
                    <dl className="kv">
                      <dt>premium due</dt><dd><span className="num">{fmtUsdg(effective)} USDG</span></dd>
                      <dt>your allowance</dt><dd><span className="num">{fmtUsdg(allowance)} USDG</span> <span className="muted">to capacity</span></dd>
                    </dl>
                  )}
                  <div className="actions" style={{ marginTop: 11 }}>
                    {needsApprove && (
                      <button className="btn ghost" disabled={!me.ready || approveTx.busy} onClick={approve}>
                        approve {effective !== undefined ? fmtUsdg(effective) : ''} USDG
                      </button>
                    )}
                    <button className="btn" disabled={!me.ready || tx.busy || !!formError || effective === undefined || needsApprove} onClick={bind}>
                      bind layer
                    </button>
                  </div>
                  {!needsApprove && effective !== undefined && effective > 0n && (
                    <p className="prose">Allowance covers the premium. Binding pulls it into capacity in the same transaction.</p>
                  )}
                  <TxNote status={approveTx.status} hash={approveTx.hash} error={approveTx.error} />
                  <TxNote status={tx.status} hash={tx.hash} error={tx.error} />
                </div>
              </div>
            </section>
          )}

          <section className="sec block" aria-label="Capacity headroom">
            <div className="sec-head">
              <span className="item">06</span>
              <h2>Capacity headroom</h2>
            </div>
            <div className="sec-body">
              {book.isLoading ? (
                <p className="prose">Reading capacity…</p>
              ) : book.error ? (
                <p className="prose err" role="alert"><b>{explainError(book.error).name}</b> {explainError(book.error).words}</p>
              ) : book.data ? (
                <dl className="kv">
                  <dt>free</dt><dd><span className="num">{fmtUsdg(book.data.value.capacity.free)} USDG</span></dd>
                  <dt>locked</dt><dd><span className="num">{fmtUsdg(book.data.value.capacity.locked)} USDG</span></dd>
                  <dt>owed, unclaimed</dt><dd><span className="num">{fmtUsdg(book.data.value.capacity.liabilities)} USDG</span></dd>
                </dl>
              ) : null}
              {book.data && parsed.lim !== undefined && parsed.lim > book.data.value.capacity.free && (
                <p className="prose err" role="alert"><b>CapacityExceeded</b> The limit is larger than the free writer capacity.</p>
              )}
            </div>
          </section>
        </div>
      </div>
    </>
  );
}

/** The treaty calendar as a span: take cutoff, reference opens, fixing, and where now sits. */
function WeekClock({ win, now }: { win: Window; now: number }) {
  const from = win.cutoff;
  const to = win.expiry + 2 * 86400;
  const span = to - from || 1;
  const at = (t: number) => `${Math.min(100, Math.max(0, ((t - from) / span) * 100)).toFixed(2)}%`;
  const showNow = now >= from && now <= to;
  return (
    <div className="clock">
      <div className="clock-plot" role="img" aria-label={`Take closes ${fmtClock(win.cutoff)} UTC, reference opens at Friday's close ${fmtClock(win.ref)} UTC, fixing ${fmtClock(win.expiry)} UTC.`}>
        <i className="cut" style={{ left: at(win.cutoff) }} />
        <i className="ref" style={{ left: at(win.ref) }} />
        <i className="fix" style={{ left: at(win.expiry) }} />
        {showNow && <i className="now" style={{ left: at(now) }} />}
      </div>
      <dl className="clock-key">
        <div>
          <dt>take closes</dt>
          <dd className="num">{fmtClock(win.cutoff)} UTC</dd>
        </div>
        <div>
          <dt>reference opens</dt>
          <dd className="num">{fmtClock(win.ref)} UTC</dd>
        </div>
        <div>
          <dt>fixing</dt>
          <dd className="num">{fmtClock(win.expiry)} UTC</dd>
        </div>
      </dl>
    </div>
  );
}

import { useEffect, useMemo, useState } from 'react';
import { useConnection } from 'wagmi';
import { formatUnits } from 'viem';
import { CAPACITY_ADDRESS, capacityAbi } from '../abi';
import { useBook } from '../hooks/useBook';
import { useTx } from '../hooks/useTx';
import { useDepositWithPermit } from '../hooks/useDepositWithPermit';
import { Wallet, useOnChain } from '../components/Wallet';
import { Stamp } from '../components/Stamp';
import { Money } from '../components/Money';
import { TxNote } from '../components/TxNote';
import { fmtUsdg, parseUsdg, short } from '../lib/format';
import { explorer } from '../chain';
import { explainError } from '../lib/revert';
import { CapacityStrip } from './Overview';
import { useReferenceQuote } from '../hooks/useReferenceQuote';
import { RECORDED, REFERENCE, TABLES, backtest, fmtDay } from '../lib/gaps';

export function Write() {
  useEffect(() => { document.title = 'Heracles: back the cover, earn the premium'; }, []);
  const conn = useConnection();
  const me = useOnChain();
  const book = useBook(conn.address);
  const permitTx = useDepositWithPermit();
  const exitTx = useTx();

  const [amount, setAmount] = useState('');
  const [exitAmount, setExitAmount] = useState('');
  const [exitError, setExitError] = useState<string>();

  const cap = book.data?.value.capacity;

  let parsed: bigint | undefined;
  try {
    parsed = parseUsdg(amount);
  } catch {
    parsed = undefined;
  }
  const amountError = (() => {
    if (amount.trim() === '') return undefined;
    try {
      const v = parseUsdg(amount);
      if (v === 0n) return 'The deposit must be above zero.';
      return undefined;
    } catch (e) {
      return e instanceof Error ? e.message : String(e);
    }
  })();

  const deposit = () => {
    if (!me.address || parsed === undefined) return;
    void permitTx.run(parsed, me.address, me.address);
  };

  const withdraw = () => {
    if (!me.address) return;
    try {
      const v = parseUsdg(exitAmount);
      if (v === 0n) {
        setExitError('The withdrawal must be above zero.');
        return;
      }
      setExitError(undefined);
      void exitTx.run({ address: CAPACITY_ADDRESS, abi: capacityAbi, functionName: 'withdraw', args: [v, me.address, me.address], account: me.address });
    } catch (e) {
      setExitError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div className="page form-first">
      <div className="lead">
        <h1 className="hero">Write <span>cover</span></h1>
        <div className="meta">
          <a href={explorer.address(CAPACITY_ADDRESS)} target="_blank" rel="noreferrer">{short(CAPACITY_ADDRESS)} ↗</a>
          <span><i />Arbitrum Sepolia</span>
          <span><i className="t" />SPY weekend cover</span>
          <span><i />USDG</span>
        </div>
        <p className="desc">
          Deposit USDG into the pool that backs the cover. Each cover bought pays the pool its premium; when a Monday
          gap reaches a cover's band, the pool pays the vault the amount the feed and the declared position set.
        </p>
        <div className="kpi" aria-live="polite">
          <div>
            <p>Backing the cover</p>
            <strong>{cap ? <>{usd0.format(toUsd(cap.balance))}<span> USDG</span></> : '…'}</strong>
            <small>{book.data ? <Stamp block={book.data.block} label="Read at block" /> : 'Reading the pool'}</small>
          </div>
          <div>
            <p>Free for new cover</p>
            <strong>{cap ? <>{usd0.format(toUsd(cap.free))}<span> USDG</span></> : '…'}</strong>
            <small>{cap ? `${usd0.format(toUsd(cap.locked))} locked under bound covers` : ' '}</small>
          </div>
          <div>
            <p>Premium waiting</p>
            <strong>{cap ? <>{usd0.format(toUsd(cap.pendingPremium))}<span> USDG</span></> : '…'}</strong>
            <small>paid in by covers not yet settled</small>
          </div>
        </div>
      </div>

      <aside className="panel" aria-label="Deposit and withdraw">
        <div className="box form">
          <div className="field">
            <label htmlFor="dep">Deposit USDG</label>
            <input id="dep" inputMode="decimal" autoComplete="off" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
            <span className={`hint${amountError ? ' bad' : ''}`}>
              {amountError ?? (cap ? `Your balance is ${fmtUsdg(cap.myUsdg)} USDG.` : 'Reading your USDG balance from the chain.')}
            </span>
            {cap && cap.myUsdg > 0n && (
              <div className="fills">
                {[25, 50, 75].map((pct) => (
                  <button key={pct} type="button" onClick={() => setAmount(formatUnits((cap.myUsdg * BigInt(pct)) / 100n, 6))}>
                    {pct}%
                  </button>
                ))}
                <button type="button" onClick={() => setAmount(formatUnits(cap.myUsdg, 6))}>Max</button>
              </div>
            )}
          </div>
        </div>
        {me.address ? (
          <button className="buy" disabled={!me.ready || permitTx.busy || !!amountError || !parsed} onClick={deposit}>Deposit USDG</button>
        ) : (
          <Wallet label="Connect to deposit" className="buy" />
        )}
        {me.address && !me.ready && <p className="wn">{me.reason}</p>}
        <TxNote status={permitTx.status} hash={permitTx.hash} error={permitTx.error} />

        <div className="box form sub">
          <div className="field">
            <label htmlFor="exit">Withdraw free USDG</label>
            <input id="exit" inputMode="decimal" autoComplete="off" value={exitAmount} onChange={(e) => setExitAmount(e.target.value)} placeholder="0.00" />
            <span className={`hint${exitError ? ' bad' : ''}`}>
              {exitError ?? (cap ? `At most ${fmtUsdg(cap.free)} USDG is free. Your redeemable max is ${fmtUsdg(cap.maxRedeem)} USDG.` : 'Reading the free balance from the chain.')}
            </span>
            {cap && cap.free > 0n && (
              <div className="fills">
                <button type="button" onClick={() => setExitAmount(formatUnits(cap.free, 6))}>Free</button>
                <button type="button" onClick={() => setExitAmount(formatUnits(cap.maxRedeem, 6))}>Max</button>
              </div>
            )}
          </div>
          <button className="btn line" disabled={!me.ready || exitTx.busy} onClick={withdraw}>Withdraw</button>
          <TxNote status={exitTx.status} hash={exitTx.hash} error={exitTx.error} />
        </div>
        <p className="wn">Only free USDG can leave while covers are live; the part under a bound cover stays until it settles.</p>
      </aside>

      <div className="body">
        <section className="cc" aria-labelledby="path-h">
          <div className="ch">
            <div>
              <p>In-sample backtest, not a forecast</p>
              <h2 id="path-h">A writer on the example cover<span>, every SPY weekend</span></h2>
            </div>
          </div>
          <p className="cn">The pricer is fit to these same weekends, so the line ends above zero by construction. Read it for the path: how deep a bad month cuts.</p>
          <WriterPath />
        </section>

        <section className="doc pool" aria-labelledby="pool-h">
          <h2 id="pool-h" className="section">The pool</h2>
          {book.isLoading ? (
            <p className="note">Reading the pool at the latest block.</p>
          ) : book.error ? (
            <p className="err" role="alert"><b>{explainError(book.error).name}</b> {explainError(book.error).words}</p>
          ) : cap && cap.balance === 0n && cap.myShares === 0n ? (
            <p className="prose">
              Empty: no writer has deposited on this deployment yet, so nothing is locked and no
              premium is pending. The first deposit sets the share price one to one.
            </p>
          ) : cap ? (
            <>
              <CapacityStrip locked={cap.locked} owed={cap.liabilities} free={cap.free} balance={cap.balance} pending={cap.pendingPremium} />
              <div className="rows figs">
                <div className="row"><span className="k">Your shares</span><span className="v">{fmtUsdg(cap.myShares)} gtUSDG</span></div>
                <div className="row"><span className="k">Your USDG</span><span className="v">{fmtUsdg(cap.myUsdg)} USDG</span></div>
              </div>
            </>
          ) : null}
          {book.data && <p className="src"><Stamp block={book.data.block} label="Read at block" /></p>}
        </section>
      </div>
    </div>
  );
}

const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const toUsd = (v: bigint) => Number(v) / 1e6;
const k = (v: number) => `${v < 0 ? '−' : v > 0 ? '+' : ''}${usd0.format(Math.abs(Math.round(v / 1000)))}k`;

/**
 * A writer's running result on the reference layer if it had been written every weekend in the
 * SPY table at today's live premium. The pricer is fit to these same weekends, so the end figure
 * is positive by construction; what the line shows is the path, how hard a bad Monday cuts.
 */
function WriterPath() {
  const quote = useReferenceQuote();
  const spy = TABLES[0];
  const w = spy.weekends;
  const premium = quote.data ? Number(quote.data.premium) / 1e6 : RECORDED.premium;
  const { cum, lo, hi, worst, dd } = useMemo(() => {
    const bt = backtest(w, REFERENCE.exposure, REFERENCE.retention, REFERENCE.limit);
    let run = 0;
    let peak = 0;
    let dd = { depth: 0, from: 0, to: 0 };
    let peakAt = 0;
    const cum = bt.payouts.map((p, i) => {
      run += premium - p;
      if (run > peak) { peak = run; peakAt = i; }
      if (peak - run > dd.depth) dd = { depth: peak - run, from: peakAt, to: i };
      return run;
    });
    const top = Math.max(...bt.payouts);
    const worst = bt.payouts.flatMap((p, i) => (p === top ? [i] : []));
    return { cum, lo: Math.min(0, ...cum), hi: Math.max(...cum), worst, dd };
  }, [w, premium]);
  const y = (v: number) => 4 + ((hi - v) / (hi - lo || 1)) * 92;
  const x = (i: number) => ((i + 0.5) / cum.length) * 100;
  const pts = cum.map((v, i) => `${i + 0.5},${y(v).toFixed(2)}`).join(' ');
  const end = cum[cum.length - 1];
  const step = hi - lo > 250_000 ? 100_000 : 50_000;
  const ticks: number[] = [];
  for (let t = Math.ceil(lo / step) * step; t <= hi; t += step) ticks.push(t);
  const years = w.flatMap((wk, i) => (i > 0 && wk.friday.slice(0, 4) !== w[i - 1].friday.slice(0, 4) ? [{ year: wk.friday.slice(0, 4), i }] : []));

  return (
    <div className="path">
      <p className="gc-read">
        <span>
          Each weekend adds today's premium, <b><Money v={premium} /></b> USDG on a {usd0.format(REFERENCE.limit)} cap
          (live at block {quote.data ? `#${quote.data.block.toLocaleString('en-US')}` : '313,690,038, recorded in the README'}), and subtracts what the cover paid.
        </span>
      </p>
      <div className="path-plot">
        <div className="path-axis" aria-hidden="true">
          {ticks.map((t) => <span key={t} style={{ top: `${y(t)}%` }}>{t === 0 ? '0' : k(t)}</span>)}
        </div>
        <div className="path-field">
          <svg viewBox={`0 0 ${cum.length} 100`} preserveAspectRatio="none" role="img"
            aria-label={`Running result from 0 to ${usd0.format(end)} USDG over ${cum.length} weekends; deepest drawdown ${usd0.format(dd.depth)} USDG, ${fmtDay(w[dd.from].friday)} to ${fmtDay(w[dd.to].friday)}.`}>
            {ticks.map((t) => <line key={t} className={t === 0 ? 'zero' : 'grid'} x1={0} x2={cum.length} y1={y(t)} y2={y(t)} vectorEffect="non-scaling-stroke" />)}
            <rect className="dd" x={dd.from + 0.5} width={Math.max(1, dd.to - dd.from)} y={0} height={100} />
            <polyline points={pts} vectorEffect="non-scaling-stroke" />
          </svg>
          {worst.map((i) => (
            <i key={i} className="hit-dot" style={{ left: `${x(i)}%`, top: `${y(cum[i] + (REFERENCE.limit - premium))}%` }} />
          ))}
          <span className="path-end" style={{ top: `${y(end)}%` }}>{k(end)}</span>
        </div>
        <div className="path-years" aria-hidden="true">
          {years.map((yr) => <span key={yr.year} style={{ left: `${(yr.i / cum.length) * 100}%` }}>{yr.year}</span>)}
        </div>
      </div>
      <div className="gc-key">
        <span><i className="sw layer" /><b>−{usd0.format(REFERENCE.limit - premium)}</b> on each of {worst.map((i) => fmtDay(w[i].friday)).join(' and ')}: the cover paid its cap</span>
        <span><i className="sw dd" /><b>−{usd0.format(dd.depth)}</b> deepest drawdown, {fmtDay(w[dd.from].friday)} to {fmtDay(w[dd.to].friday)}</span>
      </div>
      <p className="src">Each of the {w.length} weekends in <span className="file">{spy.file}</span>, oldest first.</p>
    </div>
  );
}

import { useEffect, useMemo, useState } from 'react';
import { useConnection } from 'wagmi';
import { formatUnits } from 'viem';
import { CAPACITY_ADDRESS, capacityAbi } from '../abi';
import { useBook } from '../hooks/useBook';
import { useTx } from '../hooks/useTx';
import { useDepositWithPermit } from '../hooks/useDepositWithPermit';
import { useOnChain } from '../components/Wallet';
import { Stamp } from '../components/Stamp';
import { TxNote } from '../components/TxNote';
import { fmtUsdg, parseUsdg } from '../lib/format';
import { explainError } from '../lib/revert';
import { CapacityStrip } from './Overview';
import { useReferenceQuote } from '../hooks/useReferenceQuote';
import { RECORDED, REFERENCE, TABLES, backtest, fmtDay } from '../lib/gaps';

export function Write() {
  useEffect(() => { document.title = 'Heracles: write weekend-gap capacity'; }, []);
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
    <>
      <header className="argument row">
        <h1 className="title">Write capacity</h1>
        <p className="lede">Earn the premium on every layer bound; pay its loss when a Monday gap reaches it.</p>
      </header>

      <div className="desk">
        <section className="main-col exhibit" aria-labelledby="path-h">
          <div className="exhibit-head">
            <h2 id="path-h" className="chart-title">A writer on the reference layer, every SPY weekend since 2016</h2>
          </div>
          <p className="caveat">In-sample backtest, not a forecast. The pricer is fit to these same weekends, so the line ends above zero by construction; read it for the path, for how deep a bad month cuts.</p>
          <WriterPath />
        </section>

        <aside className="ticket" aria-label="Deposit and withdraw">
          <h2 className="label">Deposit USDG</h2>
          <div className="form">
            <div className="field">
              <label htmlFor="dep">Amount, USDG</label>
              <input id="dep" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              <span className={`hint${amountError ? ' bad' : ''}`}>
                {amountError ?? (cap ? `Your balance is ${fmtUsdg(cap.myUsdg)} USDG.` : 'Your USDG balance reads with the book.')}
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
          {!me.ready && <p className="note">{me.reason}</p>}
          <div className="acts">
            <button className="btn" disabled={!me.ready || permitTx.busy || !!amountError || !parsed} onClick={deposit}>
              Deposit
            </button>
          </div>
          <TxNote status={permitTx.status} hash={permitTx.hash} error={permitTx.error} />

          <h2 className="label sub">Withdraw free capital</h2>
          <div className="form">
            <div className="field">
              <label htmlFor="exit">Amount, USDG</label>
              <input id="exit" inputMode="decimal" value={exitAmount} onChange={(e) => setExitAmount(e.target.value)} placeholder="0.00" />
              <span className={`hint${exitError ? ' bad' : ''}`}>
                {exitError ?? (cap ? `At most ${fmtUsdg(cap.free)} USDG is free. Your redeemable max is ${fmtUsdg(cap.maxRedeem)} USDG.` : 'The free balance reads with the book.')}
              </span>
              {cap && cap.free > 0n && (
                <div className="fills">
                  <button type="button" onClick={() => setExitAmount(formatUnits(cap.free, 6))}>Free</button>
                  <button type="button" onClick={() => setExitAmount(formatUnits(cap.maxRedeem, 6))}>Max</button>
                </div>
              )}
            </div>
          </div>
          <div className="acts">
            <button className="btn line" disabled={!me.ready || exitTx.busy} onClick={withdraw}>
              Withdraw
            </button>
          </div>
          <TxNote status={exitTx.status} hash={exitTx.hash} error={exitTx.error} />
        </aside>
      </div>

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
    </>
  );
}

const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
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
          Each weekend adds today's premium, <b>{usd0.format(premium)}</b> USDG on a {usd0.format(REFERENCE.limit)} limit
          (live at block {quote.data ? `#${quote.data.block.toLocaleString('en-US')}` : '313,690,038, recorded in the README'}), and subtracts what the layer paid.
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
        <span><i className="sw layer" /><b>−{usd0.format(REFERENCE.limit - premium)}</b> on each of {worst.map((i) => fmtDay(w[i].friday)).join(' and ')}: the layer paid its full limit</span>
        <span><i className="sw dd" /><b>−{usd0.format(dd.depth)}</b> deepest drawdown, {fmtDay(w[dd.from].friday)} to {fmtDay(w[dd.to].friday)}</span>
      </div>
      <p className="src">Each of the {w.length} weekends in <span className="file">{spy.file}</span>, oldest first.</p>
    </div>
  );
}

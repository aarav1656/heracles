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

  const [amount, setAmount] = useState('50');
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
      <header className="lead">
        <h1>Write capacity</h1>
        <p>
          Writers deposit USDG into one ERC-4626 pool. Each bind locks its limit out of the free
          balance and pays its premium into the pool for every share; withdrawals can only touch
          what is free. The pool is one contract, readable on Arbiscan in one call.
        </p>
      </header>

      <div className="desk">
        <section className="panel" aria-labelledby="path-h">
          <div className="panel-head">
            <h2 id="path-h">Writing the reference layer every weekend since 2016</h2>
          </div>
          <WriterPath />
        </section>

        <aside className="panel ticket" aria-label="Deposit and withdraw">
          <h2 className="ticket-h">Deposit USDG</h2>
          <div className="form">
            <div className="field">
              <label htmlFor="dep">Amount, USDG</label>
              <input id="dep" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} />
              <span className={`hint${amountError ? ' err' : ''}`}>
                {amountError ?? (cap ? `Your balance is ${fmtUsdg(cap.myUsdg)} USDG.` : 'Your USDG balance reads with the book.')}
              </span>
              {cap && cap.myUsdg > 0n && (
                <div className="chips">
                  {[25, 50, 75].map((pct) => (
                    <button key={pct} type="button" className="chip" onClick={() => setAmount(formatUnits((cap.myUsdg * BigInt(pct)) / 100n, 6))}>
                      {pct}%
                    </button>
                  ))}
                  <button type="button" className="chip" onClick={() => setAmount(formatUnits(cap.myUsdg, 6))}>Max</button>
                </div>
              )}
            </div>
          </div>
          {!me.ready && <p className="prose tight">{me.reason}</p>}
          <div className="actions">
            <button className="btn wide" disabled={!me.ready || permitTx.busy || !!amountError} onClick={deposit}>
              Deposit
            </button>
          </div>
          <TxNote status={permitTx.status} hash={permitTx.hash} error={permitTx.error} />

          <h2 className="ticket-h sub">Withdraw free capital</h2>
          <div className="form">
            <div className="field">
              <label htmlFor="exit">Amount, USDG</label>
              <input id="exit" inputMode="decimal" value={exitAmount} onChange={(e) => setExitAmount(e.target.value)} placeholder="0.00" />
              <span className={`hint${exitError ? ' err' : ''}`}>
                {exitError ?? (cap ? `At most ${fmtUsdg(cap.free)} USDG is free. Your redeemable max is ${fmtUsdg(cap.maxRedeem)} USDG.` : 'The free balance reads with the book.')}
              </span>
              {cap && cap.free > 0n && (
                <div className="chips">
                  <button type="button" className="chip" onClick={() => setExitAmount(formatUnits(cap.free, 6))}>Free</button>
                  <button type="button" className="chip" onClick={() => setExitAmount(formatUnits(cap.maxRedeem, 6))}>Max</button>
                </div>
              )}
            </div>
          </div>
          <div className="actions">
            <button className="btn ghost wide" disabled={!me.ready || exitTx.busy} onClick={withdraw}>
              Withdraw
            </button>
          </div>
          <TxNote status={exitTx.status} hash={exitTx.hash} error={exitTx.error} />
        </aside>
      </div>

      <section className="panel" aria-labelledby="pool-h" style={{ marginTop: 16 }}>
        <div className="panel-head">
          <h2 id="pool-h">The pool</h2>
          {book.data && <span className="right"><Stamp block={book.data.block} label="read at" /></span>}
        </div>
        {book.isLoading ? (
          <p className="prose">Reading the pool at the latest block.</p>
        ) : book.error ? (
          <p className="prose err" role="alert"><b>{explainError(book.error).name}</b> {explainError(book.error).words}</p>
        ) : cap ? (
          <>
            <CapacityStrip locked={cap.locked} owed={cap.liabilities} free={cap.free} balance={cap.balance} pending={cap.pendingPremium} />
            <dl className="tk">
              <dt>Your shares</dt><dd><span className="num">{fmtUsdg(cap.myShares)}</span> gtUSDG</dd>
              <dt>Your USDG</dt><dd><span className="num">{fmtUsdg(cap.myUsdg)}</span> USDG</dd>
            </dl>
            {cap.balance === 0n && (
              <p className="prose">No writer has deposited on this deployment yet. The first deposit sets the share price one to one.</p>
            )}
          </>
        ) : null}
      </section>
    </>
  );
}

const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });

/**
 * A writer's running result on the reference layer if it had been written every weekend in the
 * SPY table at today's live premium. The pricer is fit to these same weekends, so the end figure
 * is positive by construction; what the line shows is the path, how hard a bad Monday cuts.
 */
function WriterPath() {
  const quote = useReferenceQuote();
  const spy = TABLES[0];
  const premium = quote.data ? Number(quote.data.premium) / 1e6 : RECORDED.premium;
  const { cum, lo, hi, worst, dd } = useMemo(() => {
    const bt = backtest(spy.weekends, REFERENCE.exposure, REFERENCE.retention, REFERENCE.limit);
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
  }, [spy, premium]);
  const y = (v: number) => 4 + ((hi - v) / (hi - lo || 1)) * 92;
  const pts = cum.map((v, i) => `${i + 0.5},${y(v).toFixed(2)}`).join(' ');
  const end = cum[cum.length - 1];
  const w = spy.weekends;

  return (
    <div className="path">
      <div className="path-figs">
        <div>
          <span className="lab">Premium per weekend, live</span>
          <span className="fig">{usd0.format(premium)}<small>USDG on a {usd0.format(REFERENCE.limit)} limit</small></span>
        </div>
        <div>
          <span className="lab">Worst weekend for the writer</span>
          <span className="fig dn">−{usd0.format(REFERENCE.limit - premium)}<small>{worst.length > 1 ? `${worst.length} times: ` : ''}{worst.map((i) => fmtDay(w[i].friday)).join(', ')}</small></span>
        </div>
        <div>
          <span className="lab">Deepest run of losses</span>
          <span className="fig dn">−{usd0.format(dd.depth)}<small>{fmtDay(w[dd.from].friday).slice(-8)} to {fmtDay(w[dd.to].friday).slice(-8)}</small></span>
        </div>
      </div>
      <div className="path-plot">
        <svg viewBox={`0 0 ${cum.length} 100`} preserveAspectRatio="none" role="img"
          aria-label={`Running result from ${usd0.format(0)} to ${usd0.format(end)} USDG over ${cum.length} weekends; deepest drawdown ${usd0.format(dd.depth)} USDG.`}>
          <line className="zero" x1={0} x2={cum.length} y1={y(0)} y2={y(0)} vectorEffect="non-scaling-stroke" />
          <rect className="dd" x={dd.from + 0.5} width={Math.max(1, dd.to - dd.from)} y={0} height={100} />
          <polyline points={pts} vectorEffect="non-scaling-stroke" />
        </svg>
        <span className="path-end num" style={{ top: `${y(end)}%` }}>+{usd0.format(end)}</span>
      </div>
      <p className="src">
        Today's quote (block {quote.data ? `#${quote.data.block.toLocaleString('en-US')}` : '313,690,038, recorded'}) against each of the {w.length} weekends
        in <code>{spy.file}</code>. In sample by construction: the pricer is fit to these weekends,
        so the end figure is not a forecast. The shaded span is the deepest drawdown.
      </p>
    </div>
  );
}

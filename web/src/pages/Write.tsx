import { useEffect, useState } from 'react';
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

export function Write() {
  useEffect(() => { document.title = 'Heracles: capacity'; }, []);
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
      <div className="title-block">
        <h1>Write capacity</h1>
        <p>
          Deposit USDG into the writer pool. Each bind locks its limit out of the free
          balance; premiums land here as yield on every share. Withdrawals can only ever
          touch what is free. This pool's capital is visible onchain in the pool cell
          opposite, checkable on Arbiscan in one call, unlike a reinsurer's balance sheet.
        </p>
        {book.data && <p className="stamp" style={{ marginTop: 10 }}><Stamp block={book.data.block} label="pool read at" /></p>}
      </div>

      <div className="sheet">
        <div>
          <section className="sec block" aria-label="Deposit">
            <div className="sec-head">
              <span className="item">02</span>
              <h2>Deposit USDG</h2>
            </div>
            <div className="sec-body">
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
              {!me.ready && <p className="prose">{me.reason}</p>}
              <div className="actions" style={{ marginTop: 11 }}>
                <button className="btn" disabled={!me.ready || permitTx.busy || !!amountError} onClick={deposit}>
                  deposit
                </button>
              </div>
              <TxNote status={permitTx.status} hash={permitTx.hash} error={permitTx.error} />
            </div>
          </section>

          <section className="sec block" aria-label="Withdraw">
            <div className="sec-head">
              <span className="item">03</span>
              <h2>Withdraw free capital</h2>
            </div>
            <div className="sec-body">
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
              <div className="actions" style={{ marginTop: 11 }}>
                <button className="btn ghost" disabled={!me.ready || exitTx.busy} onClick={withdraw}>
                  withdraw
                </button>
              </div>
              <TxNote status={exitTx.status} hash={exitTx.hash} error={exitTx.error} />
            </div>
          </section>
        </div>

        <div className="rail">
          <section className="sec block" aria-label="Pool">
            <div className="sec-head">
              <span className="item">04</span>
              <h2>Pool</h2>
            </div>
            <div className="sec-body">
              {book.isLoading ? (
                <p className="prose">Reading the pool at the latest block…</p>
              ) : book.error ? (
                <p className="prose err" role="alert"><b>{explainError(book.error).name}</b> {explainError(book.error).words}</p>
              ) : cap ? (
                <div className="cell">
                  <CapacityStrip
                    locked={cap.locked}
                    owed={cap.liabilities}
                    free={cap.free}
                    balance={cap.balance}
                    pending={cap.pendingPremium}
                  />
                  <dl className="kv">
                    <dt>your shares</dt><dd><span className="num">{fmtUsdg(cap.myShares)}</span> <span className="muted">gtUSDG</span></dd>
                    <dt>your USDG</dt><dd><span className="num">{fmtUsdg(cap.myUsdg)} USDG</span></dd>
                  </dl>
                  {cap.balance === 0n && (
                    <p className="prose">The pool is empty. The first deposit sets the share price one to one.</p>
                  )}
                </div>
              ) : null}
            </div>
          </section>
        </div>
      </div>
    </>
  );
}

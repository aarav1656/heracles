import { useEffect, useMemo, useState } from 'react';
import { useConnection } from 'wagmi';
import { formatUnits } from 'viem';
import { BOOKS, PRICER_ADDRESS, capacityAbi } from '../abi';
import { useBook, type VaultView } from '../hooks/useBook';
import { useTx } from '../hooks/useTx';
import { useDepositWithPermit } from '../hooks/useDepositWithPermit';
import { useOnChain } from '../components/Wallet';
import { Stamp } from '../components/Stamp';
import { Money } from '../components/Money';
import { TxNote } from '../components/TxNote';
import { fmtUsdg, parseUsdg, short } from '../lib/format';
import { explorer } from '../chain';
import { explainError } from '../lib/revert';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { erc20Abi } from '../abi';
import { SimPanel, type Sim } from '../components/SimPanel';
import { CapacityStrip } from './Overview';
import { useReferenceQuote } from '../hooks/useReferenceQuote';
import { RECORDED, REFERENCE, TABLES, backtest, fmtDay } from '../lib/gaps';

type Tranche = 'firstLoss' | 'senior';

export function Write() {
  useEffect(() => { document.title = 'Heracles: back the cover, earn the premium'; }, []);
  const conn = useConnection();
  const me = useOnChain();
  const book = useBook(conn.address);
  const permitTx = useDepositWithPermit();
  const exitTx = useTx();

  const [bookIdx, setBookIdx] = useState(0);
  const [tranche, setTranche] = useState<Tranche>('firstLoss');
  const cfg = BOOKS[bookIdx];
  const sym = cfg.symbol;
  const vaultAddr = tranche === 'firstLoss' ? cfg.firstLoss : cfg.senior;
  const bv = book.data?.value.books[bookIdx];
  const vault: VaultView | undefined = bv ? (tranche === 'firstLoss' ? bv.firstLossVault : bv.seniorVault) : undefined;
  const juniorPct = book.data ? Number(book.data.value.juniorShareBps) / 100 : 30;

  const [amount, setAmount] = useState('');
  const [exitAmount, setExitAmount] = useState('');
  const [exitError, setExitError] = useState<string>();

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

  const client = usePublicClient() as PublicClient | undefined;
  const [sim, setSim] = useState<Sim>({ kind: 'idle', why: 'Enter an amount to simulate the deposit.' });
  useEffect(() => {
    if (!client || parsed === undefined || parsed === 0n) { setSim({ kind: 'idle', why: 'Enter an amount to simulate the deposit.' }); return; }
    if (!me.address) { setSim({ kind: 'idle', why: 'Connect a wallet to simulate this deposit from your account.' }); return; }
    const owner = me.address;
    const assets = parsed;
    let live = true;
    setSim({ kind: 'running' });
    const t = setTimeout(async () => {
      try {
        const allowance = await client.readContract({ address: cfg.asset, abi: erc20Abi, functionName: 'allowance', args: [owner, vaultAddr] });
        const block = await client.getBlockNumber();
        let shares: bigint;
        let how: string;
        if (allowance >= assets) {
          const r = await client.simulateContract({ address: vaultAddr, abi: capacityAbi, functionName: 'deposit', args: [assets, owner], account: owner });
          shares = r.result as bigint;
          how = 'Your standing allowance covers it, so no signature is requested.';
        } else {
          if (bv && bv.myAsset < assets) throw Object.assign(new Error('balance'), { balance: true });
          shares = (await client.readContract({ address: vaultAddr, abi: capacityAbi, functionName: 'previewDeposit', args: [assets] })) as bigint;
          how = 'The wallet asks for one permit signature, then deposits in a single transaction.';
        }
        if (live) setSim({ kind: 'ok', block, rows: [
          { k: 'Shares minted', v: fmtUsdg(shares) },
          { k: 'Deposit', v: `${fmtUsdg(assets)} ${sym}` },
          { k: 'Signing', v: how },
        ] });
      } catch (e) {
        const x = (e as { balance?: boolean }).balance ? { name: 'ERC20InsufficientBalance', words: 'Your balance of this asset is too low for this amount.' } : explainError(e);
        if (live) setSim({ kind: 'revert', name: x.name, words: x.words });
      }
    }, 350);
    return () => { live = false; clearTimeout(t); };
  }, [client, parsed, me.address, cfg.asset, vaultAddr, bv?.myAsset]); // eslint-disable-line react-hooks/exhaustive-deps

  const deposit = () => {
    if (!me.address || parsed === undefined) return;
    void permitTx.run({ book: cfg, vault: vaultAddr }, parsed, me.address, me.address);
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
      void exitTx.run({ address: vaultAddr, abi: capacityAbi, functionName: 'withdraw', args: [v, me.address, me.address], account: me.address });
    } catch (e) {
      setExitError(e instanceof Error ? e.message : String(e));
    }
  };

  const trancheWords = tranche === 'firstLoss'
    ? `First loss: pays the first ${juniorPct}% of every layer, so it earns the premium its own slice is priced at.`
    : `Senior: pays the rest of every layer, so it earns the remainder of the premium.`;

  return (
    <>
      <header className="argument row">
        <h1 className="title">Back the cover, earn the premium</h1>
        <p className="lede">Deposit USDG or USDC into the vault that pays out. Each cover bought pays its vault the price of its slice; when a Monday gap reaches a cover's band, the vaults pay it.</p>
      </header>

      <div className="desk">
        <section className="main-col exhibit" aria-labelledby="path-h">
          <div className="exhibit-head">
            <h2 id="path-h" className="chart-title">A writer backing the example cover, every SPY weekend since 2016</h2>
          </div>
          <p className="caveat">
            The writer's running result on the example cover, long {usd0.format(REFERENCE.exposure)} of SPY with a {usd0.format(REFERENCE.retention)} retention
            and a {usd0.format(REFERENCE.limit)} limit, across all {SPY_WEEKENDS.length} SPY weekends recorded from {fmtDay(SPY_WEEKENDS[0].friday)} to{' '}
            {fmtDay(SPY_WEEKENDS[SPY_WEEKENDS.length - 1].friday)}, Friday close to Monday open (<span className="file">evidence/gap-tables/SPY.json</span>).
            The premium is the Stylus pricer <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a>'s
            quote at the latest block, priced from these same weekends: their average payout, a load on the worst 5% and a capital charge on the
            limit (<a href="/docs/pricing.md" target="_blank" rel="noreferrer">method</a>).
            The line is the path a writer takes through them: each drawdown and the weekends that paid the most.
          </p>
          <WriterPath />
        </section>

        <aside className="ticket" aria-label="Deposit and withdraw">
          <h2 className="label">Deposit {sym}</h2>
          <div className="markets" role="tablist" aria-label="Book">
            {BOOKS.map((b) => (
              <button key={b.symbol} role="tab" type="button" aria-selected={b.index === bookIdx} onClick={() => setBookIdx(b.index)}>
                {b.symbol}
              </button>
            ))}
          </div>
          <div className="markets" role="tablist" aria-label="Vault">
            <button role="tab" type="button" aria-selected={tranche === 'firstLoss'} onClick={() => setTranche('firstLoss')}>First loss</button>
            <button role="tab" type="button" aria-selected={tranche === 'senior'} onClick={() => setTranche('senior')}>Senior</button>
          </div>
          <p className="hint">{trancheWords}</p>
          <div className="form">
            <div className="field">
              <label htmlFor="dep">Amount, {sym}</label>
              <input id="dep" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              <span className={`hint${amountError ? ' bad' : ''}`}>
                {amountError ?? (bv ? `Your balance is ${fmtUsdg(bv.myAsset)} ${sym}.` : `Reading your ${sym} balance from the chain.`)}
              </span>
              {bv && bv.myAsset > 0n && (
                <div className="fills">
                  {[25, 50, 75].map((pct) => (
                    <button key={pct} type="button" onClick={() => setAmount(formatUnits((bv.myAsset * BigInt(pct)) / 100n, 6))}>
                      {pct}%
                    </button>
                  ))}
                  <button type="button" onClick={() => setAmount(formatUnits(bv.myAsset, 6))}>Max</button>
                </div>
              )}
            </div>
          </div>
          {!me.ready && <p className="note">{me.reason}</p>}
          {vault?.gateActive && <p className="note" role="status">Deposits and withdrawals in this vault are closed until this weekend's covers settle.</p>}
          <SimPanel title="Simulation before you sign" sim={sim} />
          <div className="acts">
            <button className="btn" disabled={!me.ready || permitTx.busy || !!amountError || !parsed || vault?.gateActive || sim.kind === 'revert'} onClick={deposit}>
              Deposit {sym}
            </button>
          </div>
          <TxNote status={permitTx.status} hash={permitTx.hash} error={permitTx.error} />

          <h2 className="label sub">Withdraw free {sym}</h2>
          <div className="form">
            <div className="field">
              <label htmlFor="exit">Amount, {sym}</label>
              <input id="exit" inputMode="decimal" value={exitAmount} onChange={(e) => setExitAmount(e.target.value)} placeholder="0.00" />
              <span className={`hint${exitError ? ' bad' : ''}`}>
                {exitError ?? (vault ? `At most ${fmtUsdg(vault.free)} ${sym} is free. Your redeemable max is ${fmtUsdg(vault.maxRedeem)} shares.` : 'Reading the free balance from the chain.')}
              </span>
              {vault && vault.free > 0n && (
                <div className="fills">
                  <button type="button" onClick={() => setExitAmount(formatUnits(vault.free, 6))}>Free</button>
                  <button type="button" onClick={() => setExitAmount(formatUnits(vault.maxRedeem, 6))}>Max</button>
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
        <h2 id="pool-h" className="section">The {sym} book</h2>
        {book.isLoading ? (
          <p className="note">Reading the book at the latest block.</p>
        ) : book.error ? (
          <p className="err" role="alert"><b>{explainError(book.error).name}</b> {explainError(book.error).words}</p>
        ) : bv ? (
          <>
            {([['First loss', bv.firstLossVault], ['Senior', bv.seniorVault]] as const).map(([name, v]) => (
              <div key={name}>
                <h3 className="label sub">{name}</h3>
                {v.balance === 0n && v.myShares === 0n ? (
                  <p className="prose">Empty: no writer has deposited in this vault yet, so nothing is locked and no premium is pending. The first deposit sets the share price one to one.</p>
                ) : (
                  <>
                    <CapacityStrip symbol={sym} locked={v.locked} owed={v.owed} free={v.free} balance={v.balance} pending={v.pendingPremium} />
                    <div className="rows figs">
                      <div className="row"><span className="k">Your shares</span><span className="v">{fmtUsdg(v.myShares)}</span></div>
                      <div className="row"><span className="k">Gate</span><span className="v">{v.gateActive ? 'closed until the covers settle' : 'open'}</span></div>
                    </div>
                  </>
                )}
              </div>
            ))}
            <div className="rows figs">
              <div className="row"><span className="k">Your {sym}</span><span className="v">{fmtUsdg(bv.myAsset)} {sym}</span></div>
            </div>
          </>
        ) : null}
        {book.data && <p className="src"><Stamp block={book.data.block} label="Read at block" /></p>}
      </section>
    </>
  );
}

const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });
const SPY_WEEKENDS = TABLES[0].weekends;
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

import { useEffect, useMemo, useState } from 'react';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { BOOKS, FEED_ADDRESSES, PRICER_ADDRESS, TREATY_ADDRESS, erc20Abi, treatyAbi } from '../abi';
import { explorer } from '../chain';
import { useBook, quoteLive } from '../hooks/useBook';
import { useNow } from '../hooks/useNow';
import { useTx } from '../hooks/useTx';
import { Wallet, useOnChain } from '../components/Wallet';
import { Stamp } from '../components/Stamp';
import { Money } from '../components/Money';
import { TxNote } from '../components/TxNote';
import { GapChart } from '../components/GapChart';
import { useWeekWindow, reopensAt as reopenOf } from '../hooks/useWeekWindow';
import { Link } from 'react-router-dom';
import { TABLES, backtest } from '../lib/gaps';

const spy = TABLES[0];
const usd2 = (v: bigint) => (Number(v) / 1e6).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
import { fmtClock, fmtCountdown, fmtUsdg, parseExposure, parseUsdg, short } from '../lib/format';
import { explainError } from '../lib/revert';
import { checkFreshness } from '../lib/safety-core';
import { useFeedAge } from '../hooks/useFeedAge';
import { SimPanel, type Sim } from '../components/SimPanel';
import { useConnection } from 'wagmi';

type Quote = { premium: bigint; premiumJunior: bigint; el: bigint; tvar: bigint; block: bigint };
export function Bind() {
  useEffect(() => { document.title = 'Heracles: price cover for your vault'; }, []);
  const conn = useConnection();
  const me = useOnChain();
  const client = usePublicClient() as PublicClient | undefined;
  const book = useBook(conn.address);
  const tx = useTx();
  const approveTx = useTx();
  const now = useNow();
  const win = useWeekWindow(client, now);

  const [bookIdx, setBookIdx] = useState(0);
  const cfg = BOOKS[bookIdx];
  const sym = cfg.symbol;
  const [exposures, setExposures] = useState<string[]>(() => FEED_ADDRESSES.map(() => '2,000,000'));
  const [retention, setRetention] = useState('20,000');
  const [limit, setLimit] = useState('60,000');
  const [formError, setFormError] = useState<string>();
  const [quote, setQuote] = useState<Quote>();
  const [quoteError, setQuoteError] = useState<string>();
  const [quoting, setQuoting] = useState(false);

  // Binding closes Thursday 19:30 UTC (`win.bindDeadline`) and reopens when the next ISO week
  // begins (Monday 00:00 UTC), not at `win.expiry` (Monday 13:30 UTC, the fixing time for layers
  // bound in a prior week). Friday 19:30 UTC + 2 days 4.5 hours = the following Monday 00:00 UTC.
  const reopensAt = win !== undefined ? reopenOf(win) : undefined;
  const closed = win !== undefined && reopensAt !== undefined && now >= win.bindDeadline && now < reopensAt;

  const parsed = useMemo(() => {
    try {
      const exp = exposures.map((x) => parseExposure(x.replace(/,/g, '')));
      const ret = parseUsdg(retention.replace(/,/g, ''));
      const lim = parseUsdg(limit.replace(/,/g, ''));
      if (exp.every((e) => e === 0n)) return { error: 'At least one exposure must be non-zero. A zero-exposure bind reverts with BadParams.' };
      if (lim === 0n) return { error: 'The limit must be above zero. A zero limit binds nothing.' };
      const jun = (lim * (book.data?.value.juniorShareBps ?? 3000n)) / 10000n;
      if (jun === 0n || lim - jun === 0n) return { error: 'The limit is too small to split into a first-loss and a senior slice.' };
      return { exp, ret, lim, jun };
    } catch (e) {
      return { error: e instanceof Error ? e.message : String(e) };
    }
  }, [exposures, retention, limit, book.data?.value.juniorShareBps]);

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
        const [total, junior] = await Promise.all([
          quoteLive(client, parsed.exp!, parsed.ret!, parsed.lim!) as unknown as Promise<[bigint, bigint, bigint]>,
          quoteLive(client, parsed.exp!, parsed.ret!, parsed.jun!) as unknown as Promise<[bigint, bigint, bigint]>,
        ]);
        const block = await client.getBlockNumber();
        setQuote({ premium: total[0], premiumJunior: junior[0], el: total[1], tvar: total[2], block });
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

  const bv = book.data?.value.books[bookIdx];
  const allowance = bv?.myAllowance ?? 0n;
  const needsApprove = effective !== undefined ? allowance < effective && effective > 0n : false;

  const approve = () =>
    me.address && effective !== undefined
      ? approveTx.run({ address: cfg.asset, abi: erc20Abi, functionName: 'approve', args: [TREATY_ADDRESS, effective], account: me.address })
      : undefined;

  const feedAge = useFeedAge(FEED_ADDRESSES[0]);
  const freshness = feedAge.data ? checkFreshness(feedAge.data.updatedAt, now) : undefined;
  const stale = freshness !== undefined && !freshness.fresh;

  const [sim, setSim] = useState<Sim>({ kind: 'idle', why: 'Fill in the cover to simulate it.' });
  useEffect(() => {
    if (closed) { setSim({ kind: 'idle', why: 'Binding is closed for this weekend, so there is nothing to simulate.' }); return; }
    if (!client || !parsed.exp || parsed.ret === undefined || parsed.lim === undefined || parsed.jun === undefined || effective === undefined) {
      setSim({ kind: 'idle', why: 'Fill in the cover to simulate it.' }); return;
    }
    if (!me.address) { setSim({ kind: 'idle', why: 'Connect a wallet to simulate this bind from your account.' }); return; }
    if (needsApprove) { setSim({ kind: 'idle', why: `Approve ${fmtUsdg(effective)} ${sym} first. The bind is simulated as soon as the allowance is in place.` }); return; }
    let live = true;
    setSim({ kind: 'running' });
    const { exp, ret, lim, jun } = parsed;
    (async () => {
      try {
        await client.simulateContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'bind', args: [BigInt(bookIdx), exp, ret, lim, effective], account: me.address });
        const block = await client.getBlockNumber();
        const jp = quote && quote.premiumJunior < effective ? quote.premiumJunior : effective;
        if (live) setSim({ kind: 'ok', block, rows: [
          { k: 'Premium charged', v: `${fmtUsdg(effective)} ${sym}` },
          { k: 'First-loss slice', v: `${fmtUsdg(jun)} ${sym} of limit, earns ${fmtUsdg(jp)}` },
          { k: 'Senior slice', v: `${fmtUsdg(lim - jun)} ${sym} of limit, earns ${fmtUsdg(effective - jp)}` },
        ] });
      } catch (e) {
        const x = explainError(e);
        const words = x.name === 'BadTiming' && win ? `Bind closes ${fmtClock(win.bindDeadline)} UTC; this call is outside that window.` : x.words;
        if (live) setSim({ kind: 'revert', name: x.name, words });
      }
    })();
    return () => { live = false; };
  }, [client, parsed, effective, needsApprove, me.address, bookIdx, closed, win?.bindDeadline, quote?.block]); // eslint-disable-line react-hooks/exhaustive-deps

  const bind = () => {
    if (!me.address || !parsed.exp || parsed.ret === undefined || parsed.lim === undefined || effective === undefined) return;
    tx.run({
      // The premium shown is the ceiling, so a round landing before the tx cannot raise the charge.
      address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'bind',
      args: [BigInt(bookIdx), parsed.exp, parsed.ret, parsed.lim, effective],
      account: me.address,
    });
  };

  const shortBy = bv && parsed.lim !== undefined && parsed.jun !== undefined
    ? (parsed.jun > bv.firstLossVault.free ? { vault: 'first-loss', need: parsed.jun, have: bv.firstLossVault.free }
      : parsed.lim - parsed.jun > bv.seniorVault.free ? { vault: 'senior', need: parsed.lim - parsed.jun, have: bv.seniorVault.free } : undefined)
    : undefined;
  const terms = useMemo(
    () => (parsed.exp && parsed.ret !== undefined && parsed.lim !== undefined
      ? { exposure: Number(parsed.exp[0] ?? 0n) / 1e6, retention: Number(parsed.ret) / 1e6, limit: Number(parsed.lim) / 1e6 }
      : undefined),
    [parsed],
  );
  const bt = useMemo(() => (terms ? backtest(spy.weekends, terms.exposure, terms.retention, terms.limit) : undefined), [terms]);

  return (
    <>
      <header className="argument row">
        <h1 className="title">Price cover for your vault</h1>
        <p className="lede">Declare the vault's position and how much of a gap it keeps; the band shows which weekends the cover would have paid.</p>
      </header>

      <div className="desk">
        <div className="main-col">
          <section className="exhibit" aria-labelledby="bchart-h">
            <div className="exhibit-head">
              <h2 id="bchart-h" className="chart-title">Your cover across 504 SPY weekends</h2>
            </div>
            <p className="caveat">What the vault keeps sets where the band starts; adding the most Heracles pays sets where it ends. A short position moves the band to the up-gap side.</p>
            {terms ? (
              <GapChart table={spy} layer={terms} />
            ) : (
              <p className="note">Fill in exposure, retention and limit to draw the layer.</p>
            )}
          </section>

        </div>

        <aside className="ticket" aria-labelledby="terms-h">
          <h2 id="terms-h" className="label"><i className="sw layer" />Your cover</h2>
          <div className="markets" role="tablist" aria-label="Book">
            {BOOKS.map((b) => (
              <button key={b.symbol} role="tab" type="button" aria-selected={b.index === bookIdx} onClick={() => setBookIdx(b.index)}>
                {b.symbol}
              </button>
            ))}
          </div>
          <div className="form">
            {FEED_ADDRESSES.map((f, i) => (
              <div className="field" key={f}>
                <label htmlFor={`exp-${i}`}>Vault's net SPY position, {sym}</label>
                <input
                  id={`exp-${i}`}
                  inputMode="decimal"
                  value={exposures[i] ?? ''}
                  onChange={(e) => setExposures((xs) => xs.map((x, j) => (j === i ? e.target.value : x)))}
                />
                <span className="hint">Positive if the vault is net long (a lower Monday open is the risk), negative if net short. Price feed <a href={explorer.address(f)} target="_blank" rel="noreferrer">{short(f)}</a>.</span>
              </div>
            ))}
            <div className="two">
              <div className="field">
                <label htmlFor="ret">Vault keeps first</label>
                <input id="ret" inputMode="decimal" value={retention} onChange={(e) => setRetention(e.target.value)} />
              </div>
              <div className="field">
                <label htmlFor="lim">Heracles pays up to</label>
                <input id="lim" inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value)} />
              </div>
            </div>
            <p className="hint">Both in {sym}, on the loss worked out from the feed: the Monday gap times the declared position.</p>
            {formError && <p className="err" role="alert"><b>Check</b> {formError}</p>}
          </div>

          <div className="quote" aria-live="polite">
            {quoting ? (
              <p className="terms pending">The on-chain pricer is quoting this cover.</p>
            ) : quoteError ? (
              <p className="err" role="alert"><b>Quote</b> {quoteError}</p>
            ) : quote && effective !== undefined && floor !== undefined ? (
              <>
                <p className="terms">This cover costs <b><Money v={Number(effective) / 1e6} /> {sym}</b> for one weekend.</p>
                <div className="rows figs">
                  <div className="row"><span className="k" title="Expected loss">Average payout a weekend</span><span className="v"><Money v={Number(quote.el) / 1e6} /></span></div>
                  <div className="row"><span className="k" title="TVaR95: the mean payout over the worst 25 of 504 weekends">Average in the worst 5% of weekends</span><span className="v"><Money v={Number(quote.tvar) / 1e6} /></span></div>
                  {bt && <div className="row"><span className="k">Weekends it would have paid on</span><span className="v">{bt.paid} of 504</span></div>}
                  <div className="row"><span className="k" title="The first-loss vault takes the first 30% of the limit and earns the premium its own slice is priced at">First-loss vault earns</span><span className="v">{fmtUsdg(quote.premiumJunior > effective ? effective : quote.premiumJunior)} {sym}</span></div>
                  <div className="row"><span className="k" title="The senior vault takes the rest of the limit and earns the remainder, including any lift from the minimum price">Senior vault earns</span><span className="v">{fmtUsdg(effective - (quote.premiumJunior > effective ? effective : quote.premiumJunior))} {sym}</span></div>
                </div>
              </>
            ) : (
              <p className="note">Fill in exposure, retention and limit to quote.</p>
            )}
          </div>

          <div className="sim">
            <h3 className="label sub">Price feed</h3>
            {freshness ? (
              <p className={stale ? 'err' : 'note'} role={stale ? 'alert' : undefined}>
                {stale && <b>Held</b>} {freshness.words}
              </p>
            ) : (
              <p className="note">Reading the feed's latest round.</p>
            )}
            {feedAge.data && <p className="src">Latest round of feed <a href={explorer.address(FEED_ADDRESSES[0])} target="_blank" rel="noreferrer">{short(FEED_ADDRESSES[0])}</a>, read at block {feedAge.data.block.toLocaleString('en-US')}.</p>}
          </div>
          <SimPanel title="Simulation before you sign" sim={sim} />

          {closed && win ? (
            <p className="err" role="status">
              <b>Closed</b> Buying cover for this weekend closed at {fmtClock(win.bindDeadline)} UTC. Cover for
              next week opens Monday 00:00 UTC, in {fmtCountdown((reopensAt ?? win.expiry) - now)}.
            </p>
          ) : (
            <div className="bindbox">
              {!me.address && <Wallet />}
              {me.ready && effective !== undefined && effective > 0n && (
                <div className="rows figs">
                  <div className="row"><span className="k">Premium due</span><span className="v">{fmtUsdg(effective)} {sym}</span></div>
                  <div className="row"><span className="k">Your allowance</span><span className="v">{fmtUsdg(allowance)} {sym}</span></div>
                </div>
              )}
              <div className="acts">
                {me.ready && needsApprove && (
                  <button className="btn line" disabled={!me.ready || approveTx.busy} onClick={approve}>
                    Approve {effective !== undefined ? fmtUsdg(effective) : ''} {sym} for the price
                  </button>
                )}
                <button className="btn" disabled={!me.ready || tx.busy || !!formError || effective === undefined || needsApprove || !!shortBy || stale || sim.kind === 'revert'} onClick={bind}>
                  {shortBy ? `Not enough ${sym} backing yet` : stale ? 'Held: price feed is stale' : 'Buy this cover for the coming weekend'}
                </button>
              </div>
              {!me.ready && <p className="note">{me.reason}</p>}
              {shortBy ? (
                <p className="note" role="status">
                  This cover needs {usd2(shortBy.need)} {sym} of free backing in the {shortBy.vault} vault; it has {usd2(shortBy.have)} at
                  block {book.data!.block.toLocaleString('en-US')}. <Link to="/write">Back cover with {sym}</Link>.
                </p>
              ) : null}
              <TxNote status={approveTx.status} hash={approveTx.hash} error={approveTx.error} />
              <TxNote status={tx.status} hash={tx.hash} error={tx.error} />
            </div>
          )}
          {quote && effective !== undefined && floor !== undefined && !quoting && !quoteError && (
            <p className="src">
              {floorApplies
                ? `Raised to the minimum price, ${floorPct}% of the cap; the pricer quoted ${fmtUsdg(quote.premium)}. `
                : `Above the minimum price of ${usd2(floor)} USDG (${floorPct}% of the cap). `}
              Quoted by the Stylus pricer <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a> at
              block <a href={explorer.block(quote.block)} target="_blank" rel="noreferrer">#{quote.block.toLocaleString('en-US')}</a>.
            </p>
          )}
          {win && !closed && (
            <p className="src">Cover for this weekend can be bought until {fmtClock(win.bindDeadline)} UTC, in {fmtCountdown(win.bindDeadline - now)}.</p>
          )}
          {book.data && <p className="src"><Stamp block={book.data.block} label="Book read at block" /></p>}
          <p className="note">
            Pays on the Monday price gap only, worked out from the feed; it does not cover hacks or the vault's
            own trading. The price never falls below 0.5% of the cap.
          </p>
        </aside>
      </div>
    </>
  );
}

import { useEffect, useMemo, useState } from 'react';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { OIGUARD_ADDRESS, QUOTE_PRICER_ADDRESS, oiGuardAbi } from '../abi';
import { explorer } from '../chain';
import { Stamp } from '../components/Stamp';
import { MARKETS, guardCheck, quoteBook, quoteText, type Book, type GuardCheck, type Quote, type Ticker } from '../lib/book';
import { fmtUsdg2, parseExposure, short } from '../lib/format';
import { PRICED_MARKETS } from '../lib/quote-core';
import { explainError } from '../lib/revert';

/** The vault book the guard is asked about: long NVIDIA and gold, short the euro. */
const BOOK: Book = { NVDA: 1_000_000_000_000n, EUR: -400_000_000_000n, XAU: 250_000_000_000n };
const FILLS: [Ticker, string][] = [['NVDA', '600000'], ['XAU', '-200000'], ['SPY', '25000']];

const name = (t: Ticker) => PRICED_MARKETS.find((m) => m.ticker === t)!.name;
const whole = (v: bigint) => Math.round(Number(v < 0n ? -v : v) / 1e6).toLocaleString('en-US');
const side = (v: bigint) => `${v < 0n ? 'short' : 'long'} ${whole(v)}`;
const usdArg = (v: bigint) => (Number(v) / 1e6).toString();

type Read = { retention: bigint; limit: bigint; before: Quote; verdict: GuardCheck; open: [Ticker, bigint] };

export function SdkPage() {
  useEffect(() => { document.title = 'Heracles: SDK and open-interest guard'; }, []);
  const client = usePublicClient() as PublicClient | undefined;
  const [market, setMarket] = useState<Ticker>('NVDA');
  const [size, setSize] = useState('600000');
  const parsed = useMemo(() => {
    try { return { v: parseExposure(size) }; } catch (e) { return { err: (e as Error).message }; }
  }, [size]);

  const [read, setRead] = useState<Read>();
  const [err, setErr] = useState<string>();
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!client || parsed.v === undefined) return;
    const delta = parsed.v;
    let live = true;
    setBusy(true);
    const t = setTimeout(async () => {
      try {
        const blockNumber = await client.getBlockNumber();
        const [retention, limit] = await Promise.all([
          client.readContract({ address: OIGUARD_ADDRESS, abi: oiGuardAbi, functionName: 'retention', blockNumber }),
          client.readContract({ address: OIGUARD_ADDRESS, abi: oiGuardAbi, functionName: 'limit', blockNumber }),
        ]);
        const [before, verdict] = await Promise.all([
          quoteBook(client, { book: BOOK, retention, limit, blockNumber }),
          guardCheck(client, { book: BOOK, market, size: delta, blockNumber }),
        ]);
        if (live) { setRead({ retention, limit, before, verdict, open: [market, delta] }); setErr(undefined); }
      } catch (e) {
        if (live) setErr(explainError(e).words);
      } finally {
        if (live) setBusy(false);
      }
    }, 400);
    return () => { live = false; clearTimeout(t); };
  }, [client, market, parsed.v]);

  const v = read?.verdict;
  const after = v?.premium ?? 0n;
  const today = read?.before.premium ?? 0n;
  const budget = v?.budget ?? 0n;
  const top = [after, today, budget].reduce((a, b) => (a > b ? a : b), 1n);
  const pct = (x: bigint) => `${((Number(x) / Number(top)) * 88).toFixed(3)}%`;
  const afterBook: Book = read ? { ...BOOK, [read.open[0]]: (BOOK[read.open[0]] ?? 0n) + read.open[1] } : BOOK;

  const command = read && [
    `$ npx heracles-quote --exposure ${MARKETS.filter((t) => BOOK[t]).map((t) => `${t}=${usdArg(BOOK[t]!)}`).join(',')}`,
    ` --retention ${usdArg(read.retention)} --limit ${usdArg(read.limit)} --open ${read.open[0]}=${usdArg(read.open[1])}`,
  ].join(' \\\n  ');

  return (
    <>
      <header className="argument row">
        <h1 className="title">Refuse the trade the vault cannot cover</h1>
        <p className="lede">
          OIGuard is a second contract on the Stylus pricer. A perp venue calls it before it opens a position: it prices weekend-gap cover
          on its LP vault's book after the trade and reverts when that premium passes the budget the vault owner set.
          The reads behind this page ship as heracles-sdk, with a CLI that prints them.
        </p>
      </header>

      <div className="desk">
        <div className="main-col">
          <section className="exhibit" aria-labelledby="pos-h">
            <div className="exhibit-head">
              <h2 id="pos-h" className="chart-title">The vault's book and the next position</h2>
            </div>
            <p className="caveat">
              The vault is the other side of every trader. A trader opening a long leaves the vault short, so the size below is the change
              to the vault's own exposure: positive adds long, negative adds short.
            </p>
            <div className="rows figs">
              {MARKETS.filter((t) => BOOK[t] || afterBook[t]).map((t) => (
                <div className="row" key={t}>
                  <span className="k">{t}<small>{name(t)}</small></span>
                  <span className="v">
                    {side(BOOK[t] ?? 0n)}
                    {afterBook[t] !== BOOK[t] && <small>after the trade {side(afterBook[t] ?? 0n)}</small>}
                  </span>
                </div>
              ))}
            </div>
            <div className="two xterms">
              <div className="field">
                <label htmlFor="g-mkt">Market</label>
                <select id="g-mkt" value={market} onChange={(e) => setMarket(e.target.value as Ticker)}>
                  {MARKETS.map((t) => <option key={t} value={t}>{t}, {name(t)}</option>)}
                </select>
              </div>
              <div className="field">
                <label htmlFor="g-size">Change to the vault, USD</label>
                <input id="g-size" inputMode="decimal" value={size} onChange={(e) => setSize(e.target.value)} />
              </div>
            </div>
            {parsed.err && <p className="hint bad">{parsed.err}</p>}
            <div className="fills">
              {FILLS.map(([t, s]) => (
                <button type="button" key={t} onClick={() => { setMarket(t); setSize(s); }}>
                  {t} {s.startsWith('-') ? '−' : '+'}{Number(s.replace('-', '')).toLocaleString('en-US')}
                </button>
              ))}
            </div>

            {v && read && (
              <div className={`ladder meter${v.ok ? '' : ' over'}`} aria-busy={busy}>
                <div className="ladder-mark" style={{ left: pct(budget) }}>
                  <b>{fmtUsdg2(budget)}</b>
                  <span>owner's budget</span>
                </div>
                <div
                  className="meter-bar" role="img"
                  aria-label={`Weekend cover premium: ${fmtUsdg2(today)} for the book today, ${fmtUsdg2(after)} after the trade, against a budget of ${fmtUsdg2(budget)}.`}
                >
                  <i className="now" style={{ width: pct(today) }} />
                  <i className="after" style={{ width: pct(after) }} />
                  <i className="ladder-line" style={{ left: pct(budget) }} />
                </div>
                <div className="ladder-scale" aria-hidden="true">
                  <span style={{ left: 0 }}>0</span>
                  <span style={{ left: '100%' }}>premium for one weekend, USD</span>
                </div>
                <dl className="ladder-key">
                  <div><dt><i className="swatch layerline" />Book today</dt><dd>{fmtUsdg2(today)}</dd></div>
                  <div><dt><i className={`swatch ${v.ok ? 'layer' : 'ink'}`} />After the trade</dt><dd>{fmtUsdg2(after)}</dd></div>
                </dl>
              </div>
            )}
            {err && <p className="err"><b>Read failed.</b>{err}</p>}
          </section>

          <section aria-labelledby="cli-h">
            <h2 id="cli-h" className="section">The same check from a terminal</h2>
            <p className="prose">
              <span className="file">sdk/</span> in the repository is heracles-sdk: typed <span className="file">quote</span>,{' '}
              <span className="file">guardCheck</span>, <span className="file">bindPreview</span> and <span className="file">treatyState</span> over viem,
              and the <span className="file">heracles-quote</span> CLI. Asked about this position at this block, it prints:
            </p>
            {read && v ? (
              <pre className="term" aria-live="polite">
                <span className="cmd">{command}</span>
                {'\n\n'}
                {quoteText({ quote: read.before, book: BOOK, retention: read.retention, limit: read.limit, open: read.open, guard: v })}
              </pre>
            ) : <p className="pending">Reading the guard…</p>}
          </section>

          <section aria-labelledby="code-h">
            <h2 id="code-h" className="section">From a venue's contract</h2>
            <p className="prose">
              The venue passes the vault's net exposure in the pricer's market order ({MARKETS.join(', ')}) and the change the trade makes to it.
              A trade that lowers the premium always passes, so a vault over budget can hedge back down.
            </p>
            <pre className="term">{`// before the venue books the trade
int256[] memory book = vaultNetExposure();   // six markets, table order
guard.check(book, marketIndex, -traderSize); // reverts PremiumOverBudget(premium, budget, currentPremium)`}</pre>
          </section>
        </div>

        <aside className="ticket" aria-labelledby="gt-h">
          <h2 id="gt-h" className="label"><i className="sw layer" />OIGuard, live</h2>
          {v && read ? (
            <>
              <p className="terms">
                {v.ok ? (
                  <>Accepted. Covering the book after this trade costs <b>{fmtUsdg2(after)}</b> a weekend,{' '}
                    {after <= budget ? <>inside the owner's budget of {fmtUsdg2(budget)}.</> : <>less than the {fmtUsdg2(today)} it costs today.</>}</>
                ) : (
                  <>Refused. Covering the book after this trade costs <b>{fmtUsdg2(after)}</b> a weekend, over the owner's budget of{' '}
                    {fmtUsdg2(budget)} and above the {fmtUsdg2(v.currentPremium!)} it costs today.</>
                )}
              </p>
              <div className="rows figs">
                <div className="row"><span className="k">Vault keeps first<small>retention</small></span><span className="v">{fmtUsdg2(read.retention)}</span></div>
                <div className="row"><span className="k">Cover up to<small>limit</small></span><span className="v">{fmtUsdg2(read.limit)}</span></div>
                <div className="row"><span className="k">Expected payout a weekend<small>book today</small></span><span className="v">{fmtUsdg2(read.before.el)}</span></div>
                <div className="row"><span className="k">Worst 5% of weekends<small>book today</small></span><span className="v">{fmtUsdg2(read.before.tvar95)}</span></div>
              </div>
              <Stamp block={v.blockNumber} />
            </>
          ) : <p className="terms pending">Reading the guard…</p>}
          <p className="src">
            Guard <a href={`${explorer.address(OIGUARD_ADDRESS)}#code`} target="_blank" rel="noreferrer">{short(OIGUARD_ADDRESS)}</a>, source verified on Arbiscan,
            priced by the six-table Stylus pricer <a href={explorer.address(QUOTE_PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(QUOTE_PRICER_ADDRESS)}</a> with
            SPY/USD volatility. Every figure here is an <span className="file">eth_call</span> at the stamped block.
          </p>
        </aside>
      </div>
    </>
  );
}

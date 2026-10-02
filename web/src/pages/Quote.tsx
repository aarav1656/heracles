import { useEffect, useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { FEED_ADDRESSES, QUOTE_PRICER_ADDRESS, TREATY_ADDRESS, pricerAbi, treatyAbi } from '../abi';
import { explorer } from '../chain';
import { Money } from '../components/Money';
import { fmtUsdg, fmtUsdg2, parseExposure, parseUsdg, short } from '../lib/format';
import { explainError } from '../lib/revert';
import { gridAxes, buildGrid, type GridCell } from '../lib/grid-core';
import { GAINS_DIAMOND, GUSDC, readGains, vaultExposureUsd, type GainsRead } from '../lib/gains';
import { PRICED_CLASSES, PRICED_MARKETS, composeQuoteMail, tableIdsSlot, type PricedClass, type PricedMarket } from '../lib/quote-core';
import snapshot from '../data/gains-gusdc-book.json';
import weekends from '../data/gusdc-weekends.json';
import { fmtDay } from '../lib/gaps-core';

const SNAPSHOT: GainsRead = { block: BigInt(snapshot.block), vaultAssetsUsd: snapshot.vaultAssetsUsd, pairs: snapshot.pairs };

const whole = (v: number) => Math.round(v).toLocaleString('en-US');
const usd = (v: bigint) => Number(v) / 1e6;

/** Exposure inputs for the priced markets from one gUSDC book read: the vault's side, whole dollars. */
function prefill(read: GainsRead): string[] {
  return PRICED_MARKETS.map((m) => {
    const p = read.pairs.find((x) => x.ticker === m.ticker);
    return whole(p ? vaultExposureUsd(p.longUsd, p.shortUsd) : 0);
  });
}

/** Starting terms: the vault keeps about a quarter of one percent of what it carries, the layer is 2%. */
function defaultTerms(exposures: string[]) {
  const gross = exposures.reduce((s, x) => s + Math.abs(Number(x.replace(/,/g, '')) || 0), 0);
  const round = (v: number, to: number) => Math.max(to, Math.round(v / to) * to);
  return { retention: whole(round(gross * 0.0025, 100)), limit: whole(round(gross * 0.02, 1000)) };
}

type ClassQuote = { key: PricedClass; name: string; premium: bigint; el: bigint; exposure: bigint };
type Quote = { premium: bigint; premiumJunior: bigint; el: bigint; tvar: bigint; block: bigint; floor: bigint; jun: bigint; classes: ClassQuote[] };

export function QuotePage() {
  useEffect(() => { document.title = 'Heracles: quote a weekend layer'; }, []);
  const client = usePublicClient() as PublicClient | undefined;

  const book = useQuery({ queryKey: ['gains-gusdc-book'], queryFn: () => readGains(), staleTime: Infinity, retry: 1, refetchOnWindowFocus: false });
  const read = book.data ?? SNAPSHOT;
  const live = !!book.data;

  const [exposures, setExposures] = useState<string[]>(() => prefill(SNAPSHOT));
  const [retention, setRetention] = useState(() => defaultTerms(prefill(SNAPSHOT)).retention);
  const [limit, setLimit] = useState(() => defaultTerms(prefill(SNAPSHOT)).limit);
  const [filledFrom, setFilledFrom] = useState<bigint>(SNAPSHOT.block);

  // The live read replaces the snapshot's figures once, and again each time "Refresh" re-reads it.
  useEffect(() => {
    if (!book.data || book.data.block === filledFrom) return;
    const next = prefill(book.data);
    const t = defaultTerms(next);
    setExposures(next);
    setRetention(t.retention);
    setLimit(t.limit);
    setFilledFrom(book.data.block);
  }, [book.data, filledFrom]);

  const terms = useQuery({
    queryKey: ['treaty-terms'],
    enabled: !!client,
    staleTime: Infinity,
    queryFn: async () => {
      const c = client as PublicClient;
      const [juniorShareBps, minRateBps] = await Promise.all([
        c.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'juniorShareBps' }),
        c.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'minRateOnLineBps' }),
      ]);
      return { juniorShareBps: juniorShareBps as bigint, minRateBps: minRateBps as bigint };
    },
  });

  const parsed = useMemo(() => {
    try {
      const exp = exposures.map((x) => parseExposure(x.replace(/,/g, '')));
      const ret = parseUsdg(retention.replace(/,/g, ''));
      const lim = parseUsdg(limit.replace(/,/g, ''));
      if (exp.every((e) => e === 0n)) return { error: 'Enter a non-zero exposure for at least one market.' };
      if (lim === 0n) return { error: 'The limit must be above zero.' };
      const share = terms.data?.juniorShareBps ?? 3000n;
      const jun = (lim * share) / 10000n;
      if (jun === 0n || lim - jun === 0n) return { error: 'The limit is too small to split into a first-loss and a senior tranche.' };
      return { exp, ret, lim, jun };
    } catch (e) {
      return { error: e instanceof Error ? e.message : String(e) };
    }
  }, [exposures, retention, limit, terms.data]);

  const [quote, setQuote] = useState<Quote>();
  const [quoteError, setQuoteError] = useState<string>();
  const [quoting, setQuoting] = useState(false);

  useEffect(() => {
    if (!client || parsed.error || !parsed.exp) { setQuote(undefined); setQuoteError(undefined); return; }
    const used = parsed.exp.map((e, i) => ({ e, m: PRICED_MARKETS[i] })).filter((x) => x.e !== 0n);
    // The deployed pricer holds its six table ids on chain; each call sets the ids for the markets it quotes.
    const price = (subset: { e: bigint; m: PricedMarket }[], block: bigint, limitArg: bigint) =>
      client.readContract({
        address: QUOTE_PRICER_ADDRESS, abi: pricerAbi, functionName: 'quote',
        args: [subset.map((x) => x.e), subset.map(() => FEED_ADDRESSES[0]), parsed.ret!, limitArg], blockNumber: block,
        stateOverride: [{ address: QUOTE_PRICER_ADDRESS, stateDiff: [{ slot: `0x${'0'.repeat(64)}` as const, value: tableIdsSlot(subset.map((x) => x.m.tableId)) }] }],
      });
    setQuoting(true);
    const t = setTimeout(async () => {
      try {
        const block = await client.getBlockNumber();
        const present = PRICED_CLASSES.map((c) => ({ ...c, subset: used.filter((x) => x.m.bucket === c.key) })).filter((c) => c.subset.length > 0);
        const [total, junior, ...byClass] = await Promise.all([
          price(used, block, parsed.lim!), price(used, block, parsed.jun!), ...present.map((c) => price(c.subset, block, parsed.lim!)),
        ]);
        const floor = (parsed.lim! * (terms.data?.minRateBps ?? 50n)) / 10000n;
        const classes = present.map((c, i) => ({
          key: c.key, name: c.name, premium: byClass[i][0] >= floor ? byClass[i][0] : floor, el: byClass[i][1],
          exposure: c.subset.reduce((sum, x) => sum + (x.e < 0n ? -x.e : x.e), 0n),
        }));
        setQuote({ premium: total[0], premiumJunior: junior[0], el: total[1], tvar: total[2], block, floor, jun: parsed.jun!, classes });
        setQuoteError(undefined);
      } catch (e) {
        setQuote(undefined);
        setQuoteError(explainError(e).words);
      } finally {
        setQuoting(false);
      }
    }, 450);
    return () => clearTimeout(t);
  }, [client, parsed, terms.data]);

  const [grid, setGrid] = useState<{ cells: GridCell[][]; block: bigint }>();
  const [gridError, setGridError] = useState<string>();
  const [gridMode, setGridMode] = useState<'premium' | 'pct'>('premium');
  useEffect(() => {
    if (!client || parsed.error || !parsed.exp || parsed.ret === undefined || parsed.lim === undefined) { setGrid(undefined); return; }
    const { exp, ret, lim } = parsed;
    const used = exp.map((e, i) => ({ e, m: PRICED_MARKETS[i] })).filter((x) => x.e !== 0n);
    let live = true;
    const t = setTimeout(async () => {
      try {
        const axes = gridAxes(ret, lim);
        const block = await client.getBlockNumber();
        // The pricer is a view with no batch entry point, so the 25 cells go out as concurrent eth_calls pinned to one block.
        const quotes = await Promise.all(axes.retentions.map((r) => Promise.all(axes.limits.map(async (l) => {
          const out = await client.readContract({
            address: QUOTE_PRICER_ADDRESS, abi: pricerAbi, functionName: 'quote',
            args: [used.map((x) => x.e), used.map(() => FEED_ADDRESSES[0]), r, l], blockNumber: block,
            stateOverride: [{ address: QUOTE_PRICER_ADDRESS, stateDiff: [{ slot: `0x${'0'.repeat(64)}` as const, value: tableIdsSlot(used.map((x) => x.m.tableId)) }] }],
          });
          return [out[0], out[1]] as const;
        }))));
        if (live) { setGrid({ cells: buildGrid(axes, quotes, terms.data?.minRateBps ?? 50n), block }); setGridError(undefined); }
      } catch (e) {
        if (live) { setGrid(undefined); setGridError(explainError(e).words); }
      }
    }, 600);
    return () => { live = false; clearTimeout(t); };
  }, [client, parsed, terms.data]);

  const premium = quote ? (quote.premium >= quote.floor ? quote.premium : quote.floor) : undefined;
  const premiumJunior = quote && premium !== undefined ? (quote.premiumJunior > premium ? premium : quote.premiumJunior) : undefined;
  const mail = useMemo(() => {
    if (!quote || premium === undefined || premiumJunior === undefined || !parsed.exp || parsed.lim === undefined || parsed.ret === undefined) return undefined;
    return composeQuoteMail({
      rows: parsed.exp.map((e, i) => ({ ticker: PRICED_MARKETS[i].ticker, exposureUsd: usd(e) })).filter((r) => r.exposureUsd !== 0),
      retention: usd(parsed.ret), limit: usd(parsed.lim), symbol: 'USDG',
      premium: usd(premium), expectedLoss: usd(quote.el), tvar95: usd(quote.tvar),
      firstLossPremium: usd(premiumJunior), seniorPremium: usd(premium - premiumJunior),
      firstLossLimit: usd(quote.jun), seniorLimit: usd(parsed.lim - quote.jun),
      pricer: QUOTE_PRICER_ADDRESS, block: quote.block.toLocaleString('en-US'), page: `${window.location.origin}/quote`,
    });
  }, [quote, premium, premiumJunior, parsed]);

  const status = book.isFetching ? 'Reading gTrade' : book.isError ? 'gTrade read failed' : null;

  return (
    <>
      <header className="argument row">
        <h1 className="title">Quote a weekend layer</h1>
        <p className="lede">Enter what the vault carries into the weekend and the part it keeps. The Stylus pricer on chain returns the premium, the expected payout and the split between the two tranches.</p>
      </header>

      <div className="desk">
        <div className="main-col">
          <section aria-labelledby="exp-h">
            <div className="exhibit-head">
              <h2 id="exp-h" className="chart-title">Net weekend exposure</h2>
              <button type="button" className="key" onClick={() => book.refetch()} disabled={book.isFetching}>
                {book.isFetching ? 'Reading gTrade…' : 'Refresh from gTrade'}
              </button>
            </div>
            <p className="caveat">
              gTrade's gUSDC vault is the counterparty to every trade on gTrade, so it holds the opposite of what traders hold net.
              Positive is long (a lower Monday open is the risk), negative is short. The figures start from the vault's book on
              Arbitrum One and you can set your own.
            </p>
            <div className="xrows">
              {PRICED_MARKETS.map((m, i) => {
                const p = read.pairs.find((x) => x.ticker === m.ticker);
                const first = PRICED_MARKETS.findIndex((x) => x.bucket === m.bucket) === i;
                return (
                  <div className="xrow" key={m.ticker}>
                    {first && <h3 className="xclass">{PRICED_CLASSES.find((c) => c.key === m.bucket)?.name}</h3>}
                    <div className="field">
                      <label htmlFor={`x-${m.ticker}`}>{m.ticker} <span className="xname">{m.name}</span></label>
                      <input
                        id={`x-${m.ticker}`} inputMode="decimal" value={exposures[i]}
                        onChange={(e) => setExposures((xs) => xs.map((x, j) => (j === i ? e.target.value : x)))}
                      />
                    </div>
                    <p className="hint">
                      {p ? <>gTrade traders: long {whole(p.longUsd)}, short {whole(p.shortUsd)} USDC.</> : 'No gTrade pair with this name.'}
                    </p>
                  </div>
                );
              })}
            </div>
            <div className="two xterms">
              <div className="field">
                <label htmlFor="q-ret">Vault keeps first, USDG</label>
                <input id="q-ret" inputMode="decimal" value={retention} onChange={(e) => setRetention(e.target.value)} />
              </div>
              <div className="field">
                <label htmlFor="q-lim">Heracles pays up to, USDG</label>
                <input id="q-lim" inputMode="decimal" value={limit} onChange={(e) => setLimit(e.target.value)} />
              </div>
            </div>
            <p className="src">
              {live ? 'The gUSDC vault book' : 'The gUSDC vault book, saved read'} at Arbitrum One block{' '}
              <a href={`https://arbiscan.io/block/${read.block}`} target="_blank" rel="noreferrer">#{read.block.toLocaleString('en-US')}</a>:{' '}
              <span className="file">getPairOiAfterV10Collateral(3, pair)</span> plus <span className="file">getPairOisBeforeV10Collateral(3, pair)</span> on gTrade's
              Diamond <a href={`https://arbiscan.io/address/${GAINS_DIAMOND}`} target="_blank" rel="noreferrer">{short(GAINS_DIAMOND)}</a>, collateral 3 being USDC,
              position size at open in USDC.
              {status && <> {status}.</>}
              {book.isError && <> Showing the saved read.</>}
            </p>
          </section>

          <section aria-labelledby="grid-h">
            <div className="exhibit-head">
              <h2 id="grid-h" className="chart-title">Premium across retention and limit</h2>
              <div className="markets" role="tablist" aria-label="Grid figure">
                <button role="tab" type="button" aria-selected={gridMode === 'premium'} onClick={() => setGridMode('premium')}>Premium</button>
                <button role="tab" type="button" aria-selected={gridMode === 'pct'} onClick={() => setGridMode('pct')}>Premium as % of limit</button>
              </div>
            </div>
            <p className="caveat">Each cell is one call to the Stylus pricer for that retention (down the side) and limit (across the top), on the exposure above. Your own terms sit in the outlined cell. Under each premium, the expected payout a weekend.</p>
            {grid ? (
              <div className="pgrid" role="table" aria-label="Premium by retention and limit">
                <div className="pg-row pg-head" role="row">
                  <span role="columnheader">Keeps first, pays up to</span>
                  {grid.cells[0].map((c) => <span role="columnheader" key={c.limit.toString()}>{fmtUsdg(c.limit)}</span>)}
                </div>
                {grid.cells.map((row, r) => (
                  <div className="pg-row" role="row" key={row[0].retention.toString() + r}>
                    <span role="rowheader" className="pg-ret">{fmtUsdg(row[0].retention)}</span>
                    {row.map((c, l) => (
                      <span role="cell" key={l} className={c.current ? 'pg-cell current' : 'pg-cell'} aria-current={c.current ? 'true' : undefined}>
                        <b>{gridMode === 'premium' ? fmtUsdg2(c.premium) : `${(Number(c.rateBps) / 100).toFixed(2)}%`}</b>
                        <small>{fmtUsdg2(c.el)} expected</small>
                      </span>
                    ))}
                  </div>
                ))}
              </div>
            ) : gridError ? (
              <p className="err" role="alert"><b>Grid</b> {gridError}</p>
            ) : (
              <p className="note">The pricer is filling the grid.</p>
            )}
            {grid && (
              <p className="src">
                USDG. Priced by <a href={explorer.address(QUOTE_PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(QUOTE_PRICER_ADDRESS)}</a> at
                block <a href={explorer.block(grid.block)} target="_blank" rel="noreferrer">#{grid.block.toLocaleString('en-US')}</a>; premiums below the treaty minimum rate are shown raised to it.
              </p>
            )}
          </section>

          <section aria-labelledby="oi-h">
            <h2 id="oi-h" className="section">The gUSDC vault's book</h2>
            <div className="ledger" role="table" aria-label="gTrade open interest and the gUSDC vault's side, by market">
              <div className="ledger-head oi-grid" role="row">
                <span role="columnheader">Market</span>
                <span role="columnheader">Traders long</span>
                <span role="columnheader">Traders short</span>
                <span role="columnheader">Vault position</span>
              </div>
              {read.pairs.map((p) => {
                const v = vaultExposureUsd(p.longUsd, p.shortUsd);
                return (
                  <div className="ledger-row" role="row" key={p.ticker}>
                    <div className="ledger-grid oi-grid">
                      <span role="cell" data-k="Market">{p.ticker} <span className="xname">gTrade pair {p.pairIndex}</span></span>
                      <span role="cell" data-k="Traders long">{whole(p.longUsd)}</span>
                      <span role="cell" data-k="Traders short">{whole(p.shortUsd)}</span>
                      <span role="cell" data-k="Vault position">{Math.round(v) === 0 ? 'flat' : `${v > 0 ? 'long' : 'short'} ${whole(Math.abs(v))}`}</span>
                    </div>
                  </div>
                );
              })}
            </div>
            <p className="src">
              USDC, same read as above. The vault behind that book, <a href={`https://arbiscan.io/address/${GUSDC}`} target="_blank" rel="noreferrer">gUSDC {short(GUSDC)}</a>,
              holds {whole(read.vaultAssetsUsd)} USDC (<span className="file">totalAssets()</span>, same block). The pricer holds six scenario tables, four equity names
              plus EUR/USD and XAU/USD, each from 504 real weekends.
            </p>
          </section>
          <WeekendsLedger />
        </div>

        <aside className="ticket" aria-labelledby="qt-h">
          <h2 id="qt-h" className="label"><i className="sw layer" />The quote, USDG</h2>
          {parsed.error ? (
            <p className="err" role="alert"><b>Check</b> {parsed.error}</p>
          ) : quoting ? (
            <p className="terms pending">The on-chain pricer is quoting this layer.</p>
          ) : quoteError ? (
            <p className="err" role="alert"><b>Quote</b> {quoteError}</p>
          ) : quote && premium !== undefined && premiumJunior !== undefined && parsed.lim !== undefined ? (
            <>
              <p className="terms">This layer costs <b><Money v={usd(premium)} /> USDG</b> for one weekend, {((usd(premium) / usd(parsed.lim)) * 100).toFixed(2)}% of the limit.</p>
              <div className="rows figs">
                <div className="row"><span className="k" title="Expected loss">Expected payout a weekend</span><span className="v"><Money v={usd(quote.el)} /></span></div>
                <div className="row"><span className="k" title="TVaR95: the mean payout over the worst 25 of 504 weekends">Average in the worst 5% of weekends</span><span className="v"><Money v={usd(quote.tvar)} /></span></div>
                {read.vaultAssetsUsd > 0 && (
                  <div className="row">
                    <span className="k" title="Premium over the gUSDC vault's totalAssets, read at the same block as the book">Cost against the gUSDC vault<small>{(usd(premium) / read.vaultAssetsUsd * 52 * 100).toFixed(2)}% over 52 weekends of {whole(read.vaultAssetsUsd)} USDC</small></span>
                    <span className="v">{(usd(premium) / read.vaultAssetsUsd * 10_000).toFixed(2)} bps a weekend</span>
                  </div>
                )}
              </div>
              <h3 className="label sub">By asset class</h3>
              <div className="rows figs">
                {quote.classes.map((c) => (
                  <div className="row" key={c.key}>
                    <span className="k">{c.name}<small>{fmtUsdg(c.exposure)} gross exposure, expected payout {usd(c.el).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</small></span>
                    <span className="v"><Money v={usd(c.premium)} /></span>
                  </div>
                ))}
              </div>
              <p className="src">Each class priced alone on the same retention and limit.</p>
              <h3 className="label sub">Tranche split</h3>
              <div className="rows figs">
                <div className="row"><span className="k">First-loss tranche<small>takes the first {fmtUsdg(quote.jun)} of any payout</small></span><span className="v"><Money v={usd(premiumJunior)} /></span></div>
                <div className="row"><span className="k">Senior tranche<small>takes the {fmtUsdg(parsed.lim - quote.jun)} above it</small></span><span className="v"><Money v={usd(premium - premiumJunior)} /></span></div>
              </div>
              <p className="src">
                {quote.premium < quote.floor ? `Raised to the minimum price, ${Number(terms.data?.minRateBps ?? 50n) / 100}% of the limit; the pricer quoted ${fmtUsdg(quote.premium)}. ` : ''}
                Premium per tranche is the pricer's quote for that tranche's own slice of the limit; the senior tranche also takes any lift from the minimum price.
              </p>
              <div className="acts">
                <a className="btn" href={mail?.href}>Send this quote</a>
              </div>
              <p className="note">Opens your mail program with the quote as plain text. Nothing is sent from this page.</p>
              <p className="src">
                Priced by the Stylus pricer <a href={explorer.address(QUOTE_PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(QUOTE_PRICER_ADDRESS)}</a> at
                Arbitrum Sepolia block <a href={explorer.block(quote.block)} target="_blank" rel="noreferrer">#{quote.block.toLocaleString('en-US')}</a>.
                The call sets the pricer's table ids for the markets above (NVDA 0, AAPL 1, SPY 2, TSLA 3, EUR/USD 4, XAU/USD 5) and reads volatility from the
                SPY/USD feed <a href={explorer.address(FEED_ADDRESSES[0])} target="_blank" rel="noreferrer">{short(FEED_ADDRESSES[0])}</a>.
              </p>
            </>
          ) : (
            <p className="note">Enter an exposure, a retention and a limit to quote.</p>
          )}
        </aside>
      </div>
    </>
  );
}

const u6 = (v: number) => v / 1e6;
const day = (ts: number) => fmtDay(new Date(ts * 1000).toISOString().slice(0, 10));
const signedUsd = (v: number) => `${v < 0 ? '−' : v > 0 ? '+' : ''}${whole(Math.abs(u6(v)))}`;

/** The gUSDC vault's real gap PnL on its stock, index, FX and gold book over recent weekends (scripts/gusdc_weekends.py). */
function WeekendsLedger() {
  const rows = weekends.weekends;
  const prem = rows.reduce((a, r) => a + r.premium, 0);
  const paid = rows.reduce((a, r) => a + r.payout, 0);
  const losing = rows.filter((r) => r.netGapPnl < 0).length;
  const worst = rows.reduce((w, r) => (r.netGapPnl < w.netGapPnl ? r : w), rows[0]);
  return (
    <section aria-labelledby="wk-h">
      <h2 id="wk-h" className="section">The gUSDC vault, weekend by weekend</h2>
      <p className="prose">
        Over the last {rows.length} weekends the gUSDC vault's book on these six markets lost money on the gap {losing} times. The worst was the
        weekend of {day(worst.fridayClose)}: {whole(Math.abs(u6(worst.netGapPnl)))} USDC, {(Math.abs(worst.netGapPnl) / worst.gusdcAssets * 1e4).toFixed(2)} bps
        of the vault. A layer at this page's starting terms on each weekend's book would have cost {whole(u6(prem))} USDC in premium and paid {whole(u6(paid))}.
      </p>
      <div className="ledger" role="table" aria-label="The gUSDC vault's weekend gap PnL and a layer on each weekend's book">
        <div className="ledger-head rp-grid" role="row">
          <span role="columnheader">Weekend</span>
          <span role="columnheader">Vault gap PnL</span>
          <span role="columnheader">Losing legs</span>
          <span role="columnheader">Layer pays</span>
          <span role="columnheader">Premium</span>
        </div>
        {rows.map((r) => (
          <div className="ledger-row" role="row" key={r.fridayClose}>
            <div className="ledger-grid rp-grid">
              <span role="cell" data-k="Weekend">{day(r.fridayClose)} <span className="xname">book {whole(u6(r.gross))}, layer {whole(u6(r.retention))} to {whole(u6(r.retention + r.limit))}</span></span>
              <span role="cell" data-k="Vault gap PnL">{signedUsd(r.netGapPnl)}</span>
              <span role="cell" data-k="Losing legs">{whole(u6(r.losingLegs))}</span>
              <span role="cell" data-k="Layer pays">{whole(u6(r.payout))}</span>
              <span role="cell" data-k="Premium">{whole(u6(r.premium))}</span>
            </div>
          </div>
        ))}
      </div>
      <p className="src">
        USDC. Each book is the vault's side of gTrade's USDC-collateral open interest at the Arbitrum One block of that Friday's 4:00pm New York close
        (<span className="file">getPairOiAfterV10Collateral</span> plus <span className="file">getPairOisBeforeV10Collateral</span>, archive reads), and each gap
        is the Chainlink round in effect at the close against the first round at or after Monday's 9:30am open, the two rounds the Treaty settles on.
        The layer keeps 0.25% of the gross book and covers up to 2%, paying on the losing legs as the Treaty does; premiums are the six-table Stylus pricer's
        quote today at Arbitrum Sepolia block {weekends.pricerBlock.toLocaleString('en-US')}. Reproduce with <span className="file">python3 scripts/gusdc_weekends.py</span>.
      </p>
    </section>
  );
}

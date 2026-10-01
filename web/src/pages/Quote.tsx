import { useEffect, useMemo, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { FEED_ADDRESSES, PRICER_ADDRESS, TREATY_ADDRESS, pricerAbi, treatyAbi } from '../abi';
import { explorer } from '../chain';
import { Money } from '../components/Money';
import { fmtUsdg, parseExposure, parseUsdg, short } from '../lib/format';
import { explainError } from '../lib/revert';
import { readOstium, type OstiumRead } from '../lib/ostium';
import { bucketOf, groupOi, vaultExposureUsd, type Bucket, type PairOi } from '../lib/ostium-core';
import { PRICED_MARKETS, composeQuoteMail, tableIdsSlot } from '../lib/quote-core';
import snapshot from '../data/ostium-oi-by-group.json';

const CLASSES: { key: Bucket; name: string }[] = [
  { key: 'equities', name: 'Equities and indices' },
  { key: 'fx', name: 'FX' },
  { key: 'gold_metals', name: 'Gold and metals' },
  { key: 'commodities', name: 'Commodities' },
  { key: 'crypto', name: 'Crypto' },
];

type SnapRow = { pairIndex: number; from: string; to: string; subgraphGroup: string; longOI_usd: number; shortOI_usd: number };
const snapPairs: PairOi[] = (snapshot.pairs as SnapRow[]).map((p) => ({
  pairIndex: p.pairIndex, from: p.from, to: p.to, bucket: bucketOf(p.subgraphGroup, p.from), longUsd: p.longOI_usd, shortUsd: p.shortOI_usd,
}));
const SNAPSHOT: OstiumRead = { block: BigInt(snapshot.block), pairs: snapPairs, groups: groupOi(snapPairs) };

const whole = (v: number) => Math.round(v).toLocaleString('en-US');
const usd = (v: bigint) => Number(v) / 1e6;

/** Exposure inputs for the four priced names from one Ostium read: the vault's side, whole dollars. */
function prefill(read: OstiumRead): string[] {
  return PRICED_MARKETS.map((m) => {
    const p = read.pairs.find((x) => x.from === m.ostium && x.bucket === 'equities');
    return whole(p ? vaultExposureUsd(p.longUsd, p.shortUsd) : 0);
  });
}

/** Starting terms: the vault keeps about a quarter of one percent of what it carries, the layer is 2%. */
function defaultTerms(exposures: string[]) {
  const gross = exposures.reduce((s, x) => s + Math.abs(Number(x.replace(/,/g, '')) || 0), 0);
  const round = (v: number, to: number) => Math.max(to, Math.round(v / to) * to);
  return { retention: whole(round(gross * 0.0025, 100)), limit: whole(round(gross * 0.02, 1000)) };
}

type Quote = { premium: bigint; premiumJunior: bigint; el: bigint; tvar: bigint; block: bigint; floor: bigint; jun: bigint };

export function QuotePage() {
  useEffect(() => { document.title = 'Heracles: quote a weekend layer'; }, []);
  const client = usePublicClient() as PublicClient | undefined;

  const ostium = useQuery({ queryKey: ['ostium-oi'], queryFn: readOstium, staleTime: Infinity, retry: 1, refetchOnWindowFocus: false });
  const read = ostium.data ?? SNAPSHOT;
  const live = !!ostium.data;

  const [exposures, setExposures] = useState<string[]>(() => prefill(SNAPSHOT));
  const [retention, setRetention] = useState(() => defaultTerms(prefill(SNAPSHOT)).retention);
  const [limit, setLimit] = useState(() => defaultTerms(prefill(SNAPSHOT)).limit);
  const [filledFrom, setFilledFrom] = useState<bigint>(SNAPSHOT.block);

  // The live read replaces the snapshot's figures once, and again each time "Refresh" re-reads it.
  useEffect(() => {
    if (!ostium.data || ostium.data.block === filledFrom) return;
    const next = prefill(ostium.data);
    const t = defaultTerms(next);
    setExposures(next);
    setRetention(t.retention);
    setLimit(t.limit);
    setFilledFrom(ostium.data.block);
  }, [ostium.data, filledFrom]);

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
      if (exp.every((e) => e === 0n)) return { error: 'Enter a non-zero exposure for at least one name.' };
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
    const exp = used.map((x) => x.e);
    const feeds = used.map(() => FEED_ADDRESSES[0]);
    // The deployed pricer holds one table id on chain; this call sets the ids for the names quoted.
    const stateOverride = [{ address: PRICER_ADDRESS, stateDiff: [{ slot: `0x${'0'.repeat(64)}` as const, value: tableIdsSlot(used.map((x) => x.m.tableId)) }] }];
    setQuoting(true);
    const t = setTimeout(async () => {
      try {
        const block = await client.getBlockNumber();
        const q = (limitArg: bigint) => client.readContract({ address: PRICER_ADDRESS, abi: pricerAbi, functionName: 'quote', args: [exp, feeds, parsed.ret!, limitArg], blockNumber: block, stateOverride });
        const [total, junior] = await Promise.all([q(parsed.lim!), q(parsed.jun!)]);
        const floor = (parsed.lim! * (terms.data?.minRateBps ?? 50n)) / 10000n;
        setQuote({ premium: total[0], premiumJunior: junior[0], el: total[1], tvar: total[2], block, floor, jun: parsed.jun! });
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
      pricer: PRICER_ADDRESS, block: quote.block.toLocaleString('en-US'), page: `${window.location.origin}/quote`,
    });
  }, [quote, premium, premiumJunior, parsed]);

  const status = ostium.isFetching ? 'Reading Ostium' : ostium.isError ? 'Ostium read failed' : null;

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
              <button type="button" className="key" onClick={() => ostium.refetch()} disabled={ostium.isFetching}>
                {ostium.isFetching ? 'Reading Ostium…' : 'Refresh from Ostium'}
              </button>
            </div>
            <p className="caveat">
              Ostium's vault is the other side of every trader, so it holds the opposite of what traders hold net. Positive is long
              (a lower Monday open is the risk), negative is short. The figures start from Ostium's open interest and you can set your own.
            </p>
            <div className="xrows">
              {PRICED_MARKETS.map((m, i) => {
                const p = read.pairs.find((x) => x.from === m.ostium && x.bucket === 'equities');
                return (
                  <div className="xrow" key={m.ticker}>
                    <div className="field">
                      <label htmlFor={`x-${m.ticker}`}>{m.ticker} <span className="xname">{m.name}</span></label>
                      <input
                        id={`x-${m.ticker}`} inputMode="decimal" value={exposures[i]}
                        onChange={(e) => setExposures((xs) => xs.map((x, j) => (j === i ? e.target.value : x)))}
                      />
                    </div>
                    <p className="hint">
                      {p ? <>Ostium traders: long {whole(p.longUsd)}, short {whole(p.shortUsd)} USD.</> : 'No Ostium pair with this name.'}
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
              {live ? 'Ostium open interest' : 'Ostium open interest, saved read'} at Arbitrum One block{' '}
              <a href={`https://arbiscan.io/block/${read.block}`} target="_blank" rel="noreferrer">#{read.block.toLocaleString('en-US')}</a>,
              TradingStorage <a href={`https://arbiscan.io/address/0xcCd5891083A8acD2074690F65d3024E7D13d66E7`} target="_blank" rel="noreferrer">{short('0xcCd5891083A8acD2074690F65d3024E7D13d66E7')}</a>,
              each side priced at the pair's last Ostium trade price.
              {status && <> {status}.</>}
              {ostium.isError && <> Showing the saved read.</>}
            </p>
          </section>

          <section aria-labelledby="oi-h">
            <h2 id="oi-h" className="section">Ostium open interest by class</h2>
            <div className="ledger" role="table" aria-label="Ostium open interest by asset class">
              <div className="ledger-head oi-grid" role="row">
                <span role="columnheader">Class</span>
                <span role="columnheader">Traders long</span>
                <span role="columnheader">Traders short</span>
                <span role="columnheader">Gross</span>
              </div>
              {CLASSES.map((c) => {
                const g = read.groups[c.key];
                if (!g) return null;
                return (
                  <div className="ledger-row" role="row" key={c.key}>
                    <div className="ledger-grid oi-grid">
                      <span role="cell" data-k="Class">{c.name} <span className="xname">{g.pairs} pairs</span></span>
                      <span role="cell" data-k="Traders long">{whole(g.longUsd)}</span>
                      <span role="cell" data-k="Traders short">{whole(g.shortUsd)}</span>
                      <span role="cell" data-k="Gross">{whole(g.grossUsd)}</span>
                    </div>
                  </div>
                );
              })}
            </div>
            <p className="src">USD, same read as above. The pricer's scenario tables are the four equity names, each from 504 real weekends.</p>
          </section>
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
              </div>
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
                Priced by the Stylus pricer <a href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a> at
                Arbitrum Sepolia block <a href={explorer.block(quote.block)} target="_blank" rel="noreferrer">#{quote.block.toLocaleString('en-US')}</a>.
                The call sets the pricer's table ids for the names above (NVDA 0, AAPL 1, SPY 2, TSLA 3) and reads volatility from the
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

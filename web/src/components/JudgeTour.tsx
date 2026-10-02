import { Link } from 'react-router-dom';
import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import type { PublicClient } from 'viem';
import { LIVE_CYCLE, OIGUARD_ADDRESS, QUOTE_PRICER_ADDRESS, RH_SIX_TABLE_PRICER, RH_TESTNET, TREATY_ADDRESS, VAULT_COVER_ADDRESS, VAULT_COVER_REFUSED } from '../abi';
import { explorer } from '../chain';
import { fmtCountdown, fmtPx, fmtStamp, fmtUsdg, fmtUsdg2, short } from '../lib/format';
import { readTour, type GuardVerdict } from '../lib/tour';
import { readRhGuard } from '../lib/rhGuard';
import { readVaultCover } from '../lib/vaultCover';
import { readParity, PYTHON_PREMIUM } from '../lib/parity';
import { useNow } from '../hooks/useNow';
import weekends from '../data/gusdc-weekends.json';

const rx = (path: string) => `${RH_TESTNET.explorer}/${path}`;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const day = (ts: number) => { const d = new Date(ts * 1000); return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`; };
const u = (v: number) => (v / 1e6).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const whole = (v: number) => Math.round(Math.abs(v) / 1e6).toLocaleString('en-US');
const TICKERS = ['NVDA', 'AAPL', 'SPY', 'TSLA', 'EUR', 'XAU'];

const W = [...weekends.weekends].sort((a, b) => a.fridayClose - b.fridayClose);
const LOSING = W.filter((w) => w.netGapPnl < 0).length;
const WORST = W.reduce((m, w) => (w.netGapPnl < m.netGapPnl ? w : m), W[0]);

/** The gUSDC vault's losing legs each weekend, with the slice a layer would have paid drawn in the layer's colour. */
function WeekendBars() {
  const top = Math.max(...W.map((w) => w.losingLegs)) * 1.12;
  const h = 210;
  const y = (v: number) => (v / top) * h;
  const bw = 100 / W.length;
  return (
    <figure className="wb" aria-label={`The gUSDC vault's losing legs on the weekend gap for ${W.length} weekends; a layer would have paid on ${W.filter((w) => w.payout > 0).length} of them.`}>
      <div className="wb-plot">
        <div className="wb-axis" aria-hidden="true">
          {[0, 1000, 2000].filter((t) => t * 1e6 < top).map((t) => (
            <span key={t} style={{ top: `${(y(t * 1e6) / h) * 100}%` }}>{t === 0 ? '0' : `−${t.toLocaleString('en-US')}`}</span>
          ))}
        </div>
        <svg viewBox={`0 0 100 ${h}`} preserveAspectRatio="none" className="wb-svg" role="presentation">
          {[1000, 2000].filter((t) => t * 1e6 < top).map((t) => <line key={t} x1="0" x2="100" y1={y(t * 1e6)} y2={y(t * 1e6)} className="wb-grid" />)}
          {W.map((w, i) => {
            const x = i * bw + bw * 0.22;
            const width = bw * 0.56;
            const paidTop = y(w.retention);
            const paidH = y(w.payout);
            return (
              <g key={w.fridayClose} style={{ ['--i' as string]: i }}>
                <rect className="wb-loss" x={x} y={0} width={width} height={y(w.losingLegs)} />
                {w.payout > 0 && <rect className="wb-paid" x={x} y={paidTop} width={width} height={paidH} />}
              </g>
            );
          })}
          <line x1="0" x2="100" y1="0" y2="0" className="wb-zero" />
        </svg>
        <p className="wb-note" style={{ left: `${(W.indexOf(WORST) + 0.5) * bw}%`, top: `${(y(WORST.losingLegs) / h) * 100 + 4}%` }}>
          <b>{day(WORST.fridayClose)}</b> lost {u(Math.abs(WORST.netGapPnl))}; the layer pays {u(WORST.payout)}
        </p>
      </div>
      <div className="wb-x" aria-hidden="true">
        {W.map((w, i) => <span key={w.fridayClose} style={{ left: `${(i + 0.5) * bw}%` }}>{i % 2 === W.length % 2 ? day(w.fridayClose) : ''}</span>)}
      </div>
    </figure>
  );
}

function VerdictRows({ chain, v, block, blockHref, txHref, tx }: { chain: string; v?: GuardVerdict; block?: bigint; blockHref?: string; txHref: string; tx: string }) {
  return (
    <div className="rows figs">
      <div className="row">
        <span className="k">{chain}<small>{block !== undefined ? <>read at block <a href={blockHref} target="_blank" rel="noreferrer">#{block.toLocaleString('en-US')}</a></> : 'reading…'}</small></span>
        <span className="v">{v ? (v.refused ? 'refused' : 'accepted') : '…'}<small>{v ? `cover ${fmtUsdg2(v.premium)} vs budget ${fmtUsdg2(v.budget)}` : ''}</small></span>
      </div>
      <div className="row">
        <span className="k">The same refusal, sent as a transaction</span>
        <span className="v"><a href={txHref} target="_blank" rel="noreferrer">{short(tx)}</a><small>status 0x0</small></span>
      </div>
    </div>
  );
}

export function JudgeTour() {
  const client = usePublicClient() as PublicClient | undefined;
  const now = BigInt(useNow());
  const tour = useQuery({ queryKey: ['tour'], enabled: !!client, queryFn: () => readTour(client!), refetchInterval: 60_000, retry: 1 });
  const rh = useQuery({ queryKey: ['rh-guard'], queryFn: readRhGuard, refetchInterval: 60_000, retry: 1 });
  const vc = useQuery({ queryKey: ['vault-cover'], enabled: !!client, queryFn: () => readVaultCover(client!), refetchInterval: 60_000, retry: 1 });
  const parity = useQuery({ queryKey: ['parity'], enabled: !!client, queryFn: () => readParity(client!), retry: 1, staleTime: Infinity });
  const t = tour.data;
  const rv = rh.data?.refusedNow;
  const rhVerdict: GuardVerdict | undefined = rh.data && rv ? { premium: rv.premium, budget: rh.data.budget, current: 'current' in rv ? rv.current : rv.premium, refused: 'current' in rv } : undefined;
  const nextMonday = (() => { const d = new Date(Number(now) * 1000); const add = (8 - d.getUTCDay()) % 7 || 7; return BigInt(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + add) / 1000); })();
  const same = parity.data && parity.data.sepolia.every((x, i) => x === parity.data!.robinhood[i]);

  return (
    <>
      <div className="desk tour">
        <div className="main-col">
          <header className="argument">
            <h1 className="display">The Monday gap cost gTrade's LP vault money on {LOSING} of its last {W.length} weekends.</h1>
            <p className="lede">
              The worst, {day(WORST.fridayClose)}, cost {u(Math.abs(WORST.netGapPnl))} USDC. Heracles prices that gap on chain, refuses open
              interest a vault cannot afford to cover, and pays the vault from the price feed when the gap lands.
            </p>
            <p className="live-now only-narrow">
              Live now: both guards refuse 2,000,000 more NVDA short, cover {t ? fmtUsdg2(t.guard.premium) : '…'} and {rhVerdict ? fmtUsdg2(rhVerdict.premium) : '…'} against
              a 4,000.00 budget. <a href="#gv-h">See the reads</a>
            </p>
          </header>
          <section className="exhibit" aria-labelledby="wb-h">
            <div className="exhibit-head"><h2 id="wb-h" className="chart-title">gUSDC's losing legs each weekend, and the slice a layer pays</h2></div>
            <WeekendBars />
            <p className="src">
              USDC. The vault's side of gTrade's open interest in SPY, NVDA, AAPL, TSLA, EUR and gold at each Friday-close block on Arbitrum One, against the
              Chainlink rounds the Treaty settles on; the layer keeps 0.25% of the book and covers up to 2%. <Link to="/quote">All twelve weekends</Link>.
            </p>
          </section>
        </div>

        <aside className="ticket" aria-labelledby="gv-h">
          <h2 id="gv-h" className="label"><i className="sw layer" />The guard, live on two chains</h2>
          <p className="terms">
            Ask either guard now to take 2,000,000 more NVDA short and it refuses: cover for that book would cost{' '}
            <b>{t ? fmtUsdg2(t.guard.premium) : '…'}</b> on Arbitrum and <b>{rhVerdict ? fmtUsdg2(rhVerdict.premium) : '…'}</b> on Robinhood Chain, against a{' '}
            {t ? fmtUsdg2(t.guard.budget) : '4,000.00'} budget.
          </p>
          <VerdictRows chain="Arbitrum Sepolia" v={t?.guard} block={t?.block} blockHref={t ? explorer.block(t.block) : undefined} txHref={explorer.tx(VAULT_COVER_REFUSED.tx)} tx={VAULT_COVER_REFUSED.tx} />
          <VerdictRows chain="Robinhood Chain testnet" v={rhVerdict} block={rh.data?.block} blockHref={rh.data ? rx(`block/${rh.data.block}`) : undefined} txHref={rx(`tx/${RH_TESTNET.refused.tx}`)} tx={RH_TESTNET.refused.tx} />
          <p className="src">
            Guards <a href={`${explorer.address(OIGUARD_ADDRESS)}#code`} target="_blank" rel="noreferrer">{short(OIGUARD_ADDRESS)}</a> and{' '}
            <a href={rx(`address/${RH_TESTNET.guard}`)} target="_blank" rel="noreferrer">{short(RH_TESTNET.guard)}</a>, read in your browser. No wallet needed.
          </p>
          <div className="acts">
            <Link className="btn" to="/sdk">Ask the guard yourself</Link>
            <Link className="btn line" to="/bind">Price cover for your vault</Link>
          </div>
        </aside>
      </div>

      <section className="tour-life" aria-labelledby="life-h">
        <h2 id="life-h" className="section">One cover, start to finish, on chain</h2>
        <ol className="steps">
          <li>
            <h3>Writers back the cover</h3>
            <p>{t ? <>The USDG book holds {fmtUsdg2(t.usdg.firstLoss)} USDG first-loss and {fmtUsdg2(t.usdg.senior)} senior, every unit from the Paxos testnet faucet.</> : 'Reading the vaults…'}</p>
            <p className="txs">{LIVE_CYCLE.usdgDeposits.map((d) => <a key={d.tx} href={explorer.tx(d.tx)} target="_blank" rel="noreferrer">{u(d.amount)} {d.vault === 'usdgSenior' ? 'senior' : 'first-loss'}</a>)}</p>
          </li>
          <li>
            <h3>A vault's book goes on chain</h3>
            <p>
              VaultCover <a href={explorer.address(VAULT_COVER_ADDRESS)} target="_blank" rel="noreferrer">{short(VAULT_COVER_ADDRESS)}</a> carries gUSDC's book from Arbitrum One:{' '}
              {vc.data ? TICKERS.map((k, i) => (vc.data!.net[i] === 0n ? null : `${k} ${vc.data!.net[i] < 0n ? 'short' : 'long'} ${whole(Number(vc.data!.net[i]))}`)).filter(Boolean).join(', ') : 'reading…'}.
            </p>
            <p className="txs">{LIVE_CYCLE.vaultCoverOpens.map((o) => <a key={o.tx} href={explorer.tx(o.tx)} target="_blank" rel="noreferrer">open {o.market}</a>)}</p>
          </li>
          <li>
            <h3>The guard decides every new position</h3>
            <p>It prices weekend cover on the book after the trade with the Stylus pricer and accepts what stays inside the budget.</p>
            <p className="txs">
              <a href={explorer.tx(LIVE_CYCLE.vaultCoverOpens[2].tx)} target="_blank" rel="noreferrer">accepted, Arbitrum</a>
              <a href={explorer.tx(VAULT_COVER_REFUSED.tx)} target="_blank" rel="noreferrer">refused, Arbitrum</a>
              <a href={rx(`tx/${RH_TESTNET.accepted.tx}`)} target="_blank" rel="noreferrer">accepted, Robinhood</a>
              <a href={rx(`tx/${RH_TESTNET.refused.tx}`)} target="_blank" rel="noreferrer">refused, Robinhood</a>
            </p>
          </li>
          <li>
            <h3>A layer binds for the weekend</h3>
            <p>{t ? <>Layer 0 on the Treaty <a href={explorer.address(TREATY_ADDRESS)} target="_blank" rel="noreferrer">{short(TREATY_ADDRESS)}</a>: long 200 SPY, retention 2, limit 10, premium {fmtUsdg(t.layer0.premium)} USDC, now {t.layer0.state.toLowerCase()}.</> : 'Reading layer 0…'}</p>
            <p className="txs"><a href={explorer.tx(LIVE_CYCLE.bindTx)} target="_blank" rel="noreferrer">bind</a></p>
          </li>
          <li className={t && t.layer0.referenced && t.layer0.state === 'Bound' ? 'done' : undefined}>
            <h3>Friday's close becomes the reference</h3>
            <p>{t ? (t.layer0.referenced ? <>Set at SPY {fmtPx(t.layer0.fridayPrice)}, the round in effect at Friday's 4:00pm New York close.</> : 'Opens after Friday 4:00pm New York.') : 'Reading…'}</p>
            <p className="txs"><a href={explorer.tx(LIVE_CYCLE.referenceTx)} target="_blank" rel="noreferrer">setReference</a></p>
          </li>
          <li className={t && t.layer0.state === 'Bound' ? 'now' : undefined}>
            <h3>Monday's open settles it</h3>
            <p>
              {!t ? 'Reading…' : t.layer0.state === 'Settled'
                ? <>Fixed at SPY {fmtPx(t.layer0.mondayPrice)}; the layer paid {fmtUsdg2(t.layer0.payout)} USDC.</>
                : <>Fixing opens {fmtStamp(t.layer0.expiry)}, {t.layer0.expiry > now ? `in ${fmtCountdown(Number(t.layer0.expiry - now))}` : 'now'}: the first SPY round after the open decides the payout, and anyone can send it.</>}
            </p>
          </li>
          <li>
            <h3>Next week's cover renews itself</h3>
            <p>
              VaultCover's keeper binds the next layer on the book as it stands from Monday 00:00 UTC
              {nextMonday > now ? `, in ${fmtCountdown(Number(nextMonday - now))}` : ''}
              {vc.data ? (vc.data.renew.ok ? `; renewCover would bind layer ${vc.data.renew.id} right now.` : `; right now renewCover answers ${vc.data.renew.name}.`) : '.'}
            </p>
          </li>
        </ol>
      </section>

      <section className="tour-pricer" aria-labelledby="pr-h">
        <h2 id="pr-h" className="section">One Stylus pricer, wherever the money moves</h2>
        <p className="prose">
          The same Rust excess-of-loss pricer runs inside the guard, the Treaty's bind and its settlement, priced from 504 recorded weekends per
          market and scaled by each feed's own volatility. It runs on Arbitrum Sepolia and on Robinhood Chain testnet, and asked the same question
          right now, the two give the same answer:
        </p>
        <div className="rows figs">
          <div className="row"><span className="k">EUR/USD long 2,000,000, retention 2,000, limit 20,000<small>the same feed placed on both chains for the call</small></span><span className="v">{same ? 'identical' : parity.data ? 'differ' : '…'}</span></div>
          <div className="row">
            <span className="k">Arbitrum Sepolia <a href={explorer.address(QUOTE_PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(QUOTE_PRICER_ADDRESS)}</a><small>{parity.data ? `block ${parity.data.sepoliaBlock.toLocaleString('en-US')}` : 'reading…'}</small></span>
            <span className="v">{parity.data ? fmtUsdg2(parity.data.sepolia[0]) : '…'}</span>
          </div>
          <div className="row">
            <span className="k">Robinhood Chain testnet <a href={rx(`address/${RH_SIX_TABLE_PRICER}`)} target="_blank" rel="noreferrer">{short(RH_SIX_TABLE_PRICER)}</a><small>{parity.data ? `block ${parity.data.robinhoodBlock.toLocaleString('en-US')}` : 'reading…'}</small></span>
            <span className="v">{parity.data ? fmtUsdg2(parity.data.robinhood[0]) : '…'}</span>
          </div>
          <div className="row"><span className="k">From the evidence file alone<small>scripts/fx_gold_fair_premium.py</small></span><span className="v">{fmtUsdg2(PYTHON_PREMIUM)}</span></div>
          <div className="row"><span className="k">Gas against its Solidity twin<small>block 314,661,533, eight markets to one</small></span><span className="v">4.29x to 8.00x less</span></div>
        </div>
      </section>
    </>
  );
}

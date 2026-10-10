// The OIGuard refusing new open interest live: the trade is simulated as the venue calling
// VaultCover.open on Arbitrum Sepolia right now, so the verdict is the contract's own revert.
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { usePublicClient } from 'wagmi';
import { BaseError, ContractFunctionRevertedError } from 'viem';
import { OIGUARD_ADDRESS, VAULT_COVER_ADDRESS, VAULT_COVER_REFUSED, oiGuardAbi, vaultCoverAbi } from '../abi';
import { explorer } from '../chain';
import { MARKETS, type Ticker } from '../lib/book';
import { short } from '../lib/format';
import { Stamp } from './Stamp';

const usd = (v: bigint) => Number(v) / 1e6;
const fmt = (v: bigint) => usd(v).toLocaleString('en-US', { maximumFractionDigits: 0 });
const fmt2 = (v: bigint) => usd(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

type Preset = { label: string; market: Ticker; size: number };
const PRESETS: Preset[] = [
  { label: 'Whale buys 2M NVDA: vault −2M NVDA', market: 'NVDA', size: -2_000_000 },
  { label: 'Trader shorts 50k gold: vault +50k XAU', market: 'XAU', size: 50_000 },
  { label: 'Hedge: vault −50k SPY', market: 'SPY', size: -50_000 },
];

type Verdict =
  | { ok: true; premium: bigint; block: bigint; market: Ticker; size: bigint }
  | { ok: false; premium: bigint; budget: bigint; current: bigint; block: bigint; market: Ticker; size: bigint }
  | { ok: false; error: string; block: bigint; market: Ticker; size: bigint };

export function GuardDesk() {
  const client = usePublicClient();
  const [market, setMarket] = useState<Ticker>('NVDA');
  const [size, setSize] = useState('-2000000');
  const [verdict, setVerdict] = useState<Verdict | null>(null);
  const [busy, setBusy] = useState(false);

  const state = useQuery({
    queryKey: ['guard-desk'],
    enabled: !!client,
    refetchInterval: 60_000,
    queryFn: async () => {
      const block = await client!.getBlockNumber();
      const [net, owner, budget] = await Promise.all([
        client!.readContract({ address: VAULT_COVER_ADDRESS, abi: vaultCoverAbi, functionName: 'net', blockNumber: block }),
        client!.readContract({ address: VAULT_COVER_ADDRESS, abi: vaultCoverAbi, functionName: 'owner', blockNumber: block }),
        client!.readContract({ address: OIGUARD_ADDRESS, abi: oiGuardAbi, functionName: 'premiumBudget', blockNumber: block }),
      ]);
      const now = await client!.readContract({ address: OIGUARD_ADDRESS, abi: oiGuardAbi, functionName: 'check', args: [net, 0n, 0n], blockNumber: block });
      return { block, net, owner, budget, now };
    },
  });

  async function run(m: Ticker, s: string) {
    if (!client || !state.data) return;
    setMarket(m); setSize(s); setBusy(true);
    const d = BigInt(Math.round(Number(s) * 1e6));
    const idx = BigInt(MARKETS.indexOf(m));
    const block = await client.getBlockNumber();
    try {
      // The venue (the vault's owner is registered as one) asking VaultCover to record the open.
      const { result } = await client.simulateContract({
        address: VAULT_COVER_ADDRESS, abi: [...vaultCoverAbi, ...oiGuardAbi], functionName: 'open', args: [idx, d], account: state.data.owner, blockNumber: block,
      });
      setVerdict({ ok: true, premium: result, block, market: m, size: d });
    } catch (e) {
      const r = e instanceof BaseError ? e.walk((x) => x instanceof ContractFunctionRevertedError) : null;
      if (r instanceof ContractFunctionRevertedError && r.data?.errorName === 'PremiumOverBudget') {
        const [premium, budget, current] = r.data.args as readonly [bigint, bigint, bigint];
        setVerdict({ ok: false, premium, budget, current, block, market: m, size: d });
      } else {
        const name = r instanceof ContractFunctionRevertedError ? r.data?.errorName ?? r.shortMessage : e instanceof BaseError ? e.shortMessage : String(e);
        setVerdict({ ok: false, error: name, block, market: m, size: d });
      }
    } finally { setBusy(false); }
  }

  const s = state.data;
  const budget = s?.budget ?? 0n;
  const scaleTop = verdict && 'premium' in verdict ? (verdict.premium > budget ? verdict.premium : budget) : budget;
  const w = (v: bigint) => (scaleTop > 0n ? `${Math.min(100, (Number(v) / Number(scaleTop)) * 100).toFixed(2)}%` : '0%');
  const leg = (m: Ticker) => (s ? s.net[MARKETS.indexOf(m)] : 0n);

  return (
    <section className="guard-desk" aria-labelledby="gd-h">
      <div className="gd-head">
        <h2 id="gd-h" className="section">The guard, live: open interest the vault cannot cover is refused</h2>
        {s && <Stamp block={s.block} />}
      </div>
      <p className="caveat">
        Before the venue accepts a position, it calls <span className="file">VaultCover.open</span>. The OIGuard prices next weekend's cover on the book <i>after</i> the trade with the same Stylus pricer the Treaty binds on.
        Over the owner's premium budget, and worse than today's book, it reverts. Each check below is a live call on Arbitrum Sepolia as the registered venue. Nothing is signed or spent.
      </p>

      <div className="gd-grid">
        <div className="gd-book">
          <p className="label">VaultCover book now</p>
          <ul>
            {MARKETS.map((m) => <li key={m}><span>{m}</span><b>{s ? `${leg(m) < 0n ? 'short' : leg(m) > 0n ? 'long' : ''} ${fmt(leg(m) < 0n ? -leg(m) : leg(m))}` : '…'}</b></li>)}
          </ul>
          <p className="gd-meta">Cover premium today <b>{s ? fmt2(s.now) : '…'}</b> · budget <b>{s ? fmt2(s.budget) : '…'}</b></p>
          <p className="gd-meta"><a href={explorer.address(VAULT_COVER_ADDRESS)} target="_blank" rel="noreferrer">VaultCover {short(VAULT_COVER_ADDRESS)}</a> · <a href={`${explorer.address(OIGUARD_ADDRESS)}#code`} target="_blank" rel="noreferrer">OIGuard {short(OIGUARD_ADDRESS)}</a></p>
        </div>

        <div className="gd-try">
          <p className="label">Try a trade (vault side, USD)</p>
          <div className="gd-presets">
            {PRESETS.map((p) => (
              <button key={p.label} type="button" className="chip" disabled={!s || busy} onClick={() => run(p.market, String(p.size))}>{p.label}</button>
            ))}
          </div>
          <form className="gd-form" onSubmit={(e) => { e.preventDefault(); run(market, size); }}>
            <select value={market} onChange={(e) => setMarket(e.target.value as Ticker)} aria-label="Market">{MARKETS.map((m) => <option key={m}>{m}</option>)}</select>
            <input value={size} onChange={(e) => setSize(e.target.value)} inputMode="decimal" aria-label="Change to the vault's net exposure, USD" />
            <button className="btn" type="submit" disabled={!s || busy}>{busy ? 'Asking the guard…' : 'Ask the guard'}</button>
          </form>

          <div className={`gd-verdict ${verdict ? (verdict.ok ? 'ok' : 'no') : 'idle'}`} aria-live="polite">
            {!verdict && <p className="gd-idle">Pick a trade. The whale is the one to watch.</p>}
            {verdict && (
              <>
                <div className="gd-stamp">{verdict.ok ? 'Accepted' : 'Refused'}</div>
                <p className="gd-what">vault {verdict.size < 0n ? '−' : '+'}{fmt(verdict.size < 0n ? -verdict.size : verdict.size)} {verdict.market} · <Stamp block={verdict.block} label="simulated at" /></p>
                {'premium' in verdict && (
                  <div className="meter" role="img" aria-label="Premium after the trade against the budget">
                    <div className="meter-row"><span>premium after trade</span><i className={verdict.ok ? 'fit' : 'over'} style={{ width: w(verdict.premium) }} /><b>{fmt2(verdict.premium)}</b></div>
                    <div className="meter-row"><span>budget</span><i className="budget" style={{ width: w(budget) }} /><b>{fmt2(budget)}</b></div>
                  </div>
                )}
                <p className="gd-words">
                  {verdict.ok
                    ? 'Within budget, or it lowers the premium: VaultCover records the position.'
                    : 'premium' in verdict
                      ? <>VaultCover.open reverts <span className="file">PremiumOverBudget({fmt2(verdict.premium)}, {fmt2(verdict.budget)}, {fmt2(verdict.current)})</span>: the vault cannot afford to cover the book this trade creates, so the venue never fills it.</>
                      : <>Reverted: <span className="file">{verdict.error}</span></>}
                </p>
              </>
            )}
          </div>
          <p className="src">
            The same refusal, mined: <a href={explorer.tx(VAULT_COVER_REFUSED.tx)} target="_blank" rel="noreferrer">tx {short(VAULT_COVER_REFUSED.tx)}</a> at block #{VAULT_COVER_REFUSED.block.toLocaleString('en-US')}, status 0, {VAULT_COVER_REFUSED.revert}.
          </p>
        </div>
      </div>
    </section>
  );
}

import { useState } from 'react';
import type { Address } from 'viem';
import { TREATY_ADDRESS, treatyAbi } from '../abi';
import { useTx } from '../hooks/useTx';
import { type BookSnapshot, type Layer } from '../hooks/useBook';
import { useOnChain } from '../components/Wallet';
import { TxNote } from '../components/TxNote';
import { fmtCountdown, fmtPx, fmtUsdg, short } from '../lib/format';
import { fixingWords } from '../lib/treaty';

/**
 * Per-layer setReference / fix / claim / claimTo / cancel. Fixing opens after
 * expiry (Monday 13:30 UTC). These render inside the layer table's State
 * column (Overview.tsx), one live layer or one done layer at a time, not as
 * a separate settlement panel.
 */
export function SettleItem({ layer, book, now }: { layer: Layer; book: BookSnapshot; now: number }) {
  const me = useOnChain();
  const tx = useTx();
  const [roundIds, setRoundIds] = useState<string[]>(() => book.markets.map(() => ''));
  const open = now >= layer.expiry;
  const refTime = layer.fridayCutoff + 4 * 3600 + 30 * 60;
  const refOpen = now >= refTime;
  const allReferenced = layer.referencedCount >= book.markets.length;
  const graceEnd = layer.expiry + 7 * 86400;
  const cancellable = now >= graceEnd;

  const fillLatest = (m: number) => {
    setRoundIds((r) => r.map((v, i) => (i === m ? book.markets[m].latest.roundId.toString() : v)));
  };

  const setReference = async (m: number) => {
    if (!me.ready || !me.address) return;
    const rid = roundIds[m].trim();
    if (!/^\d+$/.test(rid)) return;
    await tx.run({
      address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'setReference',
      args: [layer.id, BigInt(m), BigInt(rid)], account: me.address,
    });
  };

  const fix = async (m: number) => {
    if (!me.ready || !me.address) return;
    const rid = roundIds[m].trim();
    if (!/^\d+$/.test(rid)) return;
    await tx.run({
      address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'fix',
      args: [layer.id, BigInt(m), BigInt(rid)], account: me.address,
    });
  };

  const cancel = () =>
    me.ready && me.address
      ? tx.run({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'cancel', args: [layer.id], account: me.address })
      : undefined;

  return (
    <div className="settle-item">
      <h3>
        <span className="num">Layer #{layer.id.toString()}</span>
        <span className="tag Bound">Bound</span>
      </h3>
      <p className="prose tight">
        {refOpen
          ? `Friday reference is open. ${layer.referencedCount} of ${book.markets.length} markets referenced.`
          : `Reference opens Saturday 00:00 UTC, in ${fmtCountdown(refTime - now)}.`}{' '}
        {open
          ? 'Fixing is open. Use the first round at or after expiry for each market.'
          : `Fixing opens in ${fmtCountdown(layer.expiry - now)}. ${fixingWords(BigInt(layer.expiry))}`}
      </p>
      {book.markets.map((mkt, m) => (
        <div key={mkt.address} className="rowline">
          <span className="tx" title={mkt.address}>SPY</span>
          {!layer.referenceSet[m] ? (
            <>
              <input
                aria-label={`Reference round id for market ${m + 1}`}
                placeholder="ref round id"
                inputMode="numeric"
                value={roundIds[m] ?? ''}
                onChange={(e) => setRoundIds((r) => r.map((v, i) => (i === m ? e.target.value : v)))}
              />
              <button className="key" onClick={() => fillLatest(m)}>use latest</button>
              <button className="btn ghost" disabled={!me.ready || tx.busy || !refOpen} onClick={() => setReference(m)}>
                set reference
              </button>
            </>
          ) : layer.marketFixed[m] ? (
            <span className="prose ok tight">
              ref <span className="num">{fmtPx(layer.fridayPrice[m])}</span> ·
              fixed at <span className="num">{fmtPx(layer.mondayPrice[m])}</span>
            </span>
          ) : (
            <>
              <input
                aria-label={`Fix round id for market ${m + 1}`}
                placeholder="fix round id"
                inputMode="numeric"
                value={roundIds[m] ?? ''}
                onChange={(e) => setRoundIds((r) => r.map((v, i) => (i === m ? e.target.value : v)))}
              />
              <button className="key" onClick={() => fillLatest(m)}>use latest</button>
              <button className="btn ghost" disabled={!me.ready || tx.busy || !open} onClick={() => fix(m)}>
                fix
              </button>
            </>
          )}
        </div>
      ))}
      {!allReferenced && (
        <p className="prose">Every market needs its Friday reference before any market can be fixed (ReferenceNotSet).</p>
      )}
      {!me.ready && <p className="prose">{me.reason}</p>}
      {cancellable && (
        <div className="rowline">
          <button className="btn danger" disabled={!me.ready || tx.busy} onClick={cancel}>
            cancel layer, refund the premium
          </button>
        </div>
      )}
      <TxNote status={tx.status} hash={tx.hash} error={tx.error} />
    </div>
  );
}

export function ClaimRow({ layer }: { layer: Layer }) {
  const me = useOnChain();
  const tx = useTx();
  const toTx = useTx();
  const [to, setTo] = useState('');
  const mine = me.address?.toLowerCase() === layer.buyer.toLowerCase();
  const toValid = /^0x[0-9a-fA-F]{40}$/.test(to.trim());
  if (layer.state !== 2) {
    return (
      <div className="settle-item">
        <h3><span className="num">Layer #{layer.id.toString()}</span><span className="tag Cancelled">Cancelled</span></h3>
        <p className="prose">No fresh Monday round arrived within grace. The locked limit was freed and the buyer's premium was refunded.</p>
      </div>
    );
  }
  return (
    <div className="settle-item">
      <h3><span className="num">Layer #{layer.id.toString()}</span><span className="tag Settled">Settled</span></h3>
      <p className="prose tight">
        Payout <span className="num">{fmtUsdg(layer.payout)} USDG</span>
        {mine ? (layer.buyerClaimed ? ' (claimed).' : '. Pull it below.') : ` for ${short(layer.buyer)}.`}
      </p>
      {mine && !layer.buyerClaimed && layer.payout > 0n && (
        <>
          <div className="rowline">
            <button
              className="btn"
              disabled={!me.ready || tx.busy}
              onClick={() => me.address && tx.run({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'claim', args: [layer.id], account: me.address })}
            >
              claim payout
            </button>
          </div>
          <div className="rowline">
            <input
              aria-label="Redirect payout to address"
              placeholder="0x recipient for claimTo"
              inputMode="text"
              value={to}
              onChange={(e) => setTo(e.target.value)}
            />
            <button
              className="btn ghost"
              disabled={!me.ready || toTx.busy || !toValid}
              onClick={() => me.address && toTx.run({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'claimTo', args: [layer.id, to.trim() as Address], account: me.address })}
            >
              claim to address
            </button>
          </div>
        </>
      )}
      <TxNote status={tx.status} hash={tx.hash} error={tx.error} />
      <TxNote status={toTx.status} hash={toTx.hash} error={toTx.error} />
    </div>
  );
}

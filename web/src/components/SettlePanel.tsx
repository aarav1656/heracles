import { useEffect, useState } from 'react';
import { usePublicClient } from 'wagmi';
import type { Address, PublicClient } from 'viem';
import { TREATY_ADDRESS, treatyAbi } from '../abi';
import { useTx } from '../hooks/useTx';
import { type BookSnapshot, type Layer } from '../hooks/useBook';
import { useOnChain } from '../components/Wallet';
import { TxNote } from '../components/TxNote';
import { fmtClock, fmtCountdown, fmtPx, fmtUsdg, short } from '../lib/format';
import { fixingWords, findFirstRoundAtOrAfter, type ReferenceRound, GRACE_SECONDS } from '../lib/treaty';

/** The contract's own `fridayCloseOf(fridayCutoff)`: Friday 4:00pm ET, DST-aware. */
function useFridayClose(client: PublicClient | undefined, fridayCutoff: number): number | undefined {
  const [refTime, setRefTime] = useState<number>();
  useEffect(() => {
    if (!client) return;
    let live = true;
    client.readContract({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'fridayCloseOf', args: [BigInt(fridayCutoff)] })
      .then((r) => { if (live) setRefTime(Number(r as bigint)); })
      .catch(() => { if (live) setRefTime(undefined); });
    return () => { live = false; };
  }, [client, fridayCutoff]);
  return refTime;
}

/**
 * Per-layer setReference / fix / claim / claimTo / cancel. Fixing opens after
 * expiry (Monday 13:30/14:30 UTC, DST-aware). These render inside the layer table's State
 * column (Overview.tsx), one live layer or one done layer at a time, not as
 * a separate settlement panel.
 */
export function SettleItem({ layer, book, now }: { layer: Layer; book: BookSnapshot; now: number }) {
  const me = useOnChain();
  const tx = useTx();
  const client = usePublicClient() as PublicClient | undefined;
  const [roundIds, setRoundIds] = useState<string[]>(() => book.markets.map(() => ''));
  const [refRounds, setRefRounds] = useState<Record<number, ReferenceRound | undefined>>({});
  const open = now >= layer.expiry;
  const refTime = useFridayClose(client, layer.fridayCutoff);
  const refOpen = refTime !== undefined && now >= refTime;
  const allReferenced = layer.referencedCount >= book.markets.length;
  const anyVoided = layer.referenceVoid.some(Boolean);
  const graceEnd = layer.expiry + GRACE_SECONDS;
  const cancellable = now >= graceEnd;

  useEffect(() => {
    if (!client || refTime === undefined || !refOpen) { setRefRounds({}); return; }
    let live = true;
    book.markets.forEach((mkt, m) => {
      if (layer.referenceSet[m] || layer.referenceVoid[m]) return;
      findFirstRoundAtOrAfter(client, mkt.address, refTime, mkt.latest.roundId, mkt.latest.updatedAt)
        .then((res) => { if (live) setRefRounds((r) => ({ ...r, [m]: res })); });
    });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    client, refOpen, refTime, layer.id.toString(),
    JSON.stringify(layer.referenceSet), JSON.stringify(layer.referenceVoid),
    book.markets.map((m) => m.latest.roundId.toString()).join(','),
  ]);

  const fillLatest = (m: number) => {
    setRoundIds((r) => r.map((v, i) => (i === m ? book.markets[m].latest.roundId.toString() : v)));
  };

  const setReference = async (m: number, roundId: bigint) => {
    if (!me.ready || !me.address) return;
    await tx.run({
      address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'setReference',
      args: [layer.id, BigInt(m), roundId], account: me.address,
    });
  };

  const setReferenceManual = async (m: number) => {
    const rid = roundIds[m].trim();
    if (!/^\d+$/.test(rid)) return;
    await setReference(m, BigInt(rid));
  };

  const voidReference = async (m: number, roundId: bigint) => {
    if (!me.ready || !me.address) return;
    await tx.run({
      address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'voidReference',
      args: [layer.id, BigInt(m), roundId], account: me.address,
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

  const referenceCell = (m: number) => {
    if (!refOpen) {
      return (
        <span className="prose tight">
          {refTime === undefined ? "Loading Friday's close time…" : `Reference opens after ${fmtClock(refTime)} UTC.`}
        </span>
      );
    }
    const rr = refRounds[m];
    if (!rr) return <span className="prose tight">Finding the reference round…</span>;
    if (rr.kind === 'none') {
      return <span className="prose tight">No round has printed at or after Friday's close yet.</span>;
    }
    if (rr.kind === 'found' && rr.late) {
      return (
        <>
          <span className="prose warn tight">
            This round arrived more than 36 hours after Friday's close, so it can no longer serve as the reference:
            voiding this market clears the way to cancel the layer, which refunds your premium in full.
          </span>
          <button
            className="btn danger"
            disabled={!me.ready || tx.busy}
            onClick={() => voidReference(m, rr.roundId)}
          >
            void reference
          </button>
        </>
      );
    }
    if (rr.kind === 'found') {
      return (
        <>
          <span className="tx">round {rr.roundId.toString()}</span>
          <button className="btn ghost" disabled={!me.ready || tx.busy} onClick={() => setReference(m, rr.roundId)}>
            set reference
          </button>
        </>
      );
    }
    // 'unknown': the automatic walk couldn't reach the crossing round (phase boundary or a
    // feed read failure); fall back to manual entry.
    return (
      <>
        <input
          aria-label={`Reference round id for market ${m + 1}`}
          placeholder="ref round id"
          inputMode="numeric"
          value={roundIds[m] ?? ''}
          onChange={(e) => setRoundIds((r) => r.map((v, i) => (i === m ? e.target.value : v)))}
        />
        <button className="key" onClick={() => fillLatest(m)}>use latest</button>
        <button className="btn ghost" disabled={!me.ready || tx.busy} onClick={() => setReferenceManual(m)}>
          set reference
        </button>
      </>
    );
  };

  return (
    <div className="settle-item">
      <h3>
        <span className="num">Layer #{layer.id.toString()}</span>
        <span className="tag Bound">Bound</span>
      </h3>
      <p className="prose tight">
        {refTime === undefined
          ? "Loading Friday's close time…"
          : refOpen
            ? `Friday reference is open. ${layer.referencedCount} of ${book.markets.length} markets referenced.`
            : `Reference opens after Friday's close (${fmtClock(refTime)} UTC), in ${fmtCountdown(refTime - now)}.`}{' '}
        {open
          ? 'Fixing is open. Use the first round at or after expiry for each market.'
          : `Fixing opens in ${fmtCountdown(layer.expiry - now)}. ${fixingWords(BigInt(layer.expiry))}`}
      </p>
      {book.markets.map((mkt, m) => (
        <div key={mkt.address} className="rowline">
          <span className="tx" title={mkt.address}>SPY</span>
          {layer.referenceVoid[m] ? (
            <span className="prose tight">Reference voided: its first round after close landed more than 36h late.</span>
          ) : !layer.referenceSet[m] ? (
            referenceCell(m)
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
      {anyVoided && (
        <p className="prose">A voided market can never be fixed; this layer becomes cancellable once every other market is also unfixable and the grace period has passed.</p>
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

export function ClaimRow({ layer, unit }: { layer: Layer; unit: string }) {
  const me = useOnChain();
  const tx = useTx();
  const toTx = useTx();
  const [to, setTo] = useState('');
  const mine = me.address?.toLowerCase() === layer.buyer.toLowerCase();
  const toValid = /^0x[0-9a-fA-F]{40}$/.test(to.trim());
  const cancelled = layer.state !== 2;
  const owedToBuyer = cancelled ? layer.premium : layer.payout;
  return (
    <div className="settle-item">
      <h3><span className="num">Layer #{layer.id.toString()}</span><span className={`tag ${cancelled ? 'Cancelled' : 'Settled'}`}>{cancelled ? 'Cancelled' : 'Settled'}</span></h3>
      <p className="prose tight">
        {cancelled
          ? 'This layer could not settle. The locked limit was freed and the whole premium is refundable to the buyer. '
          : ''}
        {cancelled ? 'Refund' : 'Payout'} <span className="num">{fmtUsdg(owedToBuyer)} {unit}</span>
        {mine ? (layer.buyerClaimed ? ' (claimed).' : '. Pull it below.') : ` for ${short(layer.buyer)}.`}
      </p>
      {mine && !layer.buyerClaimed && owedToBuyer > 0n && (
        <>
          <div className="rowline">
            <button
              className="btn"
              disabled={!me.ready || tx.busy}
              onClick={() => me.address && tx.run({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'claim', args: [layer.id], account: me.address })}
            >
              {cancelled ? 'claim refund' : 'claim payout'}
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

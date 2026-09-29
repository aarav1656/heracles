import { Link } from 'react-router-dom';
import { CAPACITY_ADDRESS, TREATY_ADDRESS, USDG_ADDRESS, erc20Abi, treatyAbi } from '../abi';
import type { BookSnapshot } from '../hooks/useBook';
import type { AtBlock } from '../hooks/useAtBlock';
import { termsKey, type LiveQuote, type Terms } from '../hooks/useLiveQuote';
import { useTx } from '../hooks/useTx';
import { reopensAt, type WeekWindow } from '../hooks/useWeekWindow';
import { Wallet, useOnChain } from './Wallet';
import { TxNote } from './TxNote';
import { fmtClock, fmtCountdown, fmtUsdg } from '../lib/format';

const usd0 = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 });

/** What bind charges: the pricer's quote, raised to the floor of minRateOnLineBps of the limit (Treaty.bind). */
export function charged(quoted: bigint, lim: bigint, minRateBps: bigint) {
  const floor = (lim * minRateBps) / 10_000n;
  return { premium: quoted < floor ? floor : quoted, floor, floored: quoted < floor };
}

/**
 * The one bind path in the app: approve the premium to Capacity if the allowance is short, then
 * Treaty.bind(exposure, retention, limit). Both the cover page and /bind render this, so a v3
 * book or tranche choice is one more prop here, not two forms to change.
 */
export function BuyCover({ terms, quote, book, win, now }: {
  terms: Terms | undefined;
  quote: LiveQuote | undefined;
  book: AtBlock<BookSnapshot> | undefined;
  win: WeekWindow | undefined;
  now: number;
}) {
  const me = useOnChain();
  const tx = useTx();
  const approveTx = useTx();

  const fresh = quote && terms && termsKey(quote.terms) === termsKey(terms) ? quote : undefined;
  const price = fresh && book ? charged(fresh.premium, fresh.terms.lim, book.value.minRateBps) : undefined;
  const allowance = book?.value.capacity.myAllowance ?? 0n;
  const needsApprove = price !== undefined && price.premium > 0n && allowance < price.premium;
  const free = book?.value.capacity.free;
  const short = terms && free !== undefined && terms.lim > free;
  const closed = win !== undefined && now >= win.cutoff && now < win.expiry;

  const approve = () =>
    me.address && price && approveTx.run({ address: USDG_ADDRESS, abi: erc20Abi, functionName: 'approve', args: [CAPACITY_ADDRESS, price.premium], account: me.address });
  const bind = () =>
    me.address && terms && tx.run({ address: TREATY_ADDRESS, abi: treatyAbi, functionName: 'bind', args: [terms.exp, terms.ret, terms.lim], account: me.address });

  if (closed && win) {
    return (
      <div className="buybox">
        <button className="buy" disabled>Buy cover</button>
        <p className="wn" role="status">
          Buying for this weekend closed at {fmtClock(win.cutoff)} UTC. Next week's cover opens
          Monday 00:00 UTC, in {fmtCountdown(reopensAt(win) - now)}.
        </p>
      </div>
    );
  }

  return (
    <div className="buybox">
      {short ? (
        <button className="buy" disabled>Buy cover</button>
      ) : !me.address ? (
        <Wallet label="Buy cover" className="buy" />
      ) : needsApprove ? (
        <button className="buy" disabled={!me.ready || approveTx.busy} onClick={approve}>
          Approve {fmtUsdg(price!.premium)} USDG
        </button>
      ) : (
        <button className="buy" disabled={!me.ready || tx.busy || !price} onClick={bind}>Buy cover</button>
      )}
      {short && book && terms && (
        <p className="wn" role="status">
          Buying opens once writers back it: {usd0.format(Number(free!) / 1e6)} USDG free at
          block {book.block.toLocaleString('en-US')}, and this cover needs {usd0.format(Number(terms.lim) / 1e6)}. <Link to="/write">Write cover</Link>
        </p>
      )}
      {me.address && !me.ready && <p className="wn">{me.reason}</p>}
      {needsApprove && me.ready && !short && (
        <p className="wn">Step 1 of 2: let the pool take the premium. Then buy.</p>
      )}
      <TxNote status={approveTx.status} hash={approveTx.hash} error={approveTx.error} />
      <TxNote status={tx.status} hash={tx.hash} error={tx.error} />
    </div>
  );
}

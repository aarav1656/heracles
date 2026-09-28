import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useConnection } from 'wagmi';
import { CAPACITY_ADDRESS, PRICER_ADDRESS, TREATY_ADDRESS, USDG_ADDRESS } from '../abi';
import { explorer } from '../chain';
import { useBook, type BookSnapshot, type Layer } from '../hooks/useBook';
import { useNow } from '../hooks/useNow';
import { Stamp } from '../components/Stamp';
import { SettleItem, ClaimRow } from '../components/SettlePanel';
import { LayerTower } from '../components/LayerTower';
import { fmtClock, fmtCountdown, fmtPx, fmtStamp, fmtUsdg, short } from '../lib/format';
import { LAYER_STATES } from '../lib/treaty';
import { explainError } from '../lib/revert';

export function Overview() {
  useEffect(() => { document.title = 'Heracles: book'; }, []);
  const conn = useConnection();
  const now = useNow();
  const q = useBook(conn.address);

  return (
    <>
      <h1 className="visually-hidden">Heracles: the book</h1>

      {/* The figure leads, one line of context under it, no h1 wrapping it
          (gmx-pools study.md, signature move 1). */}
      <div className="headline">
        {q.data ? (
          <>
            <span className="big">{fmtUsdg(q.data.value.capacity.balance)}<small>USDG</small></span>
            <p>Pool balance for excess-of-loss reinsurance on perp vault risk, quoted live by the Stylus pricer.</p>
            <p className="stamp" style={{ marginTop: 6 }}><Stamp block={q.data.block} label="book read at" /></p>
          </>
        ) : q.error ? (
          <p className="prose err" role="alert"><b>{explainError(q.error).name}</b> {explainError(q.error).words}</p>
        ) : (
          <p className="prose">Reading the treaty book at the latest block…</p>
        )}
      </div>

      <details className="how">
        <summary>How it works</summary>
        <p>
          A vault declares its Friday exposure across the Chainlink equity feeds, the Stylus
          pricer quotes the layer from 504 historical weekend gaps, USDG writers fund the
          limit, and the first fresh Monday round settles it. No price setter, no adjuster.
        </p>
      </details>

      {q.data && (
        <div className="sheet">
          <div>
            <section className="sec block" aria-label="Layers on the book">
              <div className="sec-head">
                <h2>Layers on the book</h2>
              </div>
              <div className="sec-body">
                <div className="ltable">
                  <div className="ltable-head" role="row">
                    <span>Market</span>
                    <span>Exposure</span>
                    <span>Retention / Limit</span>
                    <span>Premium</span>
                    <span>Fixing countdown</span>
                    <span>State</span>
                  </div>
                  {q.data.value.layers.length === 0 ? (
                    <div className="ltable-row empty">
                      <div className="ltable-grid">
                        <span className="cell market">
                          <span className="market-icon" aria-hidden="true">S</span>SPY
                        </span>
                        <span className="cell note">{bindWindowNote(now)}</span>
                      </div>
                    </div>
                  ) : (
                    q.data.value.layers.map((l) => (
                      <LayerRow key={l.id.toString()} layer={l} book={q.data!.value} now={now} />
                    ))
                  )}
                </div>
              </div>
            </section>

            <section className="sec block" aria-label="Markets">
              <div className="sec-head">
                <h2>Feed prices</h2>
              </div>
              <div className="sec-body">
                <dl className="kv">
                  {q.data.value.markets.map((m) => (
                    <div key={m.address} style={{ display: 'contents' }}>
                      <dt><a href={explorer.address(m.address)} target="_blank" rel="noreferrer">SPY feed</a></dt>
                      <dd>
                        <span className="num">{fmtPx(m.latest.answer)}</span>{' '}
                        <span className="muted">updated {fmtStamp(m.latest.updatedAt)}</span>
                      </dd>
                    </div>
                  ))}
                </dl>
                <p className="prose">
                  Sepolia carries one live equity feed, so this deploy binds a single market.
                  The four-market book (NVDA, AAPL, SPY, TSLA) is proven on a fork of Arbitrum One state.
                </p>
              </div>
            </section>
          </div>

          <div className="rail">
            <section className="sec block" aria-label="Writer capacity">
              <div className="sec-head">
                <h2>Writer capacity</h2>
              </div>
              <div className="sec-body">
                <div className="cell">
                  <CapacityStrip
                    locked={q.data.value.capacity.locked}
                    owed={q.data.value.capacity.liabilities}
                    free={q.data.value.capacity.free}
                    balance={q.data.value.capacity.balance}
                    pending={q.data.value.capacity.pendingPremium}
                  />
                  {q.data.value.capacity.balance === 0n ? (
                    <p className="prose">The pool is empty. No writer has deposited USDG yet, so no layer can bind.</p>
                  ) : (
                    <p className="prose"><Link to="/write">Write capacity</Link> to fund the layer, or withdraw what is free.</p>
                  )}
                </div>
              </div>
            </section>

            <section className="sec block" aria-label="Contracts">
              <div className="sec-head">
                <h2>Contracts</h2>
              </div>
              <div className="sec-body">
                <dl className="kv">
                  <dt>treaty</dt><dd><a className="tx" href={explorer.address(TREATY_ADDRESS)} target="_blank" rel="noreferrer">{short(TREATY_ADDRESS)}</a></dd>
                  <dt>capacity</dt><dd><a className="tx" href={explorer.address(CAPACITY_ADDRESS)} target="_blank" rel="noreferrer">{short(CAPACITY_ADDRESS)}</a></dd>
                  <dt>pricer</dt><dd><a className="tx" href={explorer.address(PRICER_ADDRESS)} target="_blank" rel="noreferrer">{short(PRICER_ADDRESS)}</a></dd>
                  <dt>USDG</dt><dd><a className="tx" href={explorer.address(USDG_ADDRESS)} target="_blank" rel="noreferrer">{short(USDG_ADDRESS)}</a></dd>
                </dl>
              </div>
            </section>
          </div>
        </div>
      )}
    </>
  );
}

/**
 * One row of the book: the GMX pools/positions table shape (column header
 * strip, rounded card rows, a market icon). Settlement lives in the State
 * column, an expand toggle onto the same actions the layer used to get a
 * separate "Settlement" card for (SettleItem for a live layer, ClaimRow once
 * it is settled or cancelled), not a second table.
 */
function LayerRow({ layer, book, now }: { layer: Layer; book: BookSnapshot; now: number }) {
  const [open, setOpen] = useState(false);
  const stateName = LAYER_STATES[layer.state];
  const exp = layer.exposure[0] ?? 0n;
  const dir = exp < 0n ? 'short' : 'long';
  const fixing = layer.state === 1 ? (now >= layer.expiry ? 'fixing open' : fmtCountdown(layer.expiry - now)) : '-';

  return (
    <div className="ltable-row">
      <div className="ltable-grid">
        <span className="cell market">
          <span className="market-icon" aria-hidden="true">S</span>SPY
        </span>
        <span className="cell exposure">
          <span className="cell-lab">Exposure</span>
          <span className="num">{fmtUsdg(exp < 0n ? -exp : exp)}</span>
          <span className="dir">{dir}</span>
        </span>
        <span className="cell">
          <span className="cell-lab">Retention / limit</span>
          <span className="num">{fmtUsdg(layer.retention)} / {fmtUsdg(layer.limit)}</span>
        </span>
        <span className="cell">
          <span className="cell-lab">Premium</span>
          <span className="num">{fmtUsdg(layer.premium)}</span>
        </span>
        <span className="cell">
          <span className="cell-lab">Fixing countdown</span>
          <span className="num">{fixing}</span>
        </span>
        <span className="cell state">
          <span className="cell-lab">State</span>
          <span className={`tag ${stateName}`}>{stateName}</span>
          <button type="button" className="details-btn" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
            {open ? 'Hide' : 'Details'}
          </button>
        </span>
      </div>
      {open && (
        <div className="ltable-expand">
          <LayerTower
            name={`Layer #${layer.id.toString()}`}
            who={<>buyer {short(layer.buyer)} · cutoff {fmtClock(layer.fridayCutoff)} · expiry {fmtClock(layer.expiry)}</>}
            exposure={exp}
            retention={layer.retention}
            limit={layer.limit}
            premium={layer.premium}
            payout={layer.payout}
            tag={stateName}
            state={layer.state === 2 ? 'settled' : layer.state === 3 ? 'cancelled' : 'bound'}
          />
          {layer.state === 1 ? <SettleItem layer={layer} book={book} now={now} /> : <ClaimRow layer={layer} />}
        </div>
      )}
    </div>
  );
}

/**
 * The pool split into what it has promised and what it has not. Both sides are
 * direct contract reads: limits locked, payouts owed but unclaimed (still
 * reserved inside locked until claim), and free.
 */
export function CapacityStrip({ locked, owed, free, balance, pending }: { locked: bigint; owed: bigint; free: bigint; balance: bigint; pending: bigint }) {
  const l = Number(locked);
  const o = Math.min(Number(owed), l);
  const f = Number(free);
  const total = l + f || 1;
  const owedPart = o > 0 ? (o / total) * 100 : 0;
  const lockedPart = l > 0 ? (l / total) * 100 - owedPart : 0;
  const freePart = f > 0 ? (f / total) * 100 : 0;
  const summary = `${fmtUsdg(owed)} USDG of the ${fmtUsdg(locked)} USDG locked is owed but unclaimed; ${fmtUsdg(free)} USDG is free.`;

  return (
    <div className="strip">
      <div className="strip-bar" role="img" aria-label={summary}>
        {owedPart > 0 && <i className="owed" style={{ width: `${owedPart.toFixed(2)}%` }} />}
        {lockedPart > 0 && <i className="locked" style={{ width: `${lockedPart.toFixed(2)}%` }} />}
        {freePart > 0 && <i className="free" style={{ width: `${freePart.toFixed(2)}%` }} />}
      </div>
      <dl className="strip-key">
        <div>
          <dt><span className="swatch free" />free</dt>
          <dd className="num">{fmtUsdg(free)} USDG</dd>
        </div>
        <div>
          <dt><span className="swatch lock" />locked</dt>
          <dd className="num">{fmtUsdg(locked)} USDG</dd>
        </div>
        <div>
          <dt><span className="swatch owed" />owed, unclaimed</dt>
          <dd className="num">{fmtUsdg(owed)} USDG</dd>
        </div>
        <div>
          <dt>pending premium</dt>
          <dd className="num">{fmtUsdg(pending)} USDG</dd>
        </div>
        <div>
          <dt>pool balance</dt>
          <dd className="num">{fmtUsdg(balance)} USDG</dd>
        </div>
      </dl>
    </div>
  );
}

/** Mirrors Treaty.weekWindow: binding is open from Monday 00:00 UTC until Friday 19:30 UTC. */
function bindWindowNote(now: number): string {
  const day = (new Date(now * 1000).getUTCDay() + 6) % 7;
  const monday = Math.floor(now / 86400 - day) * 86400;
  const cutoff = monday + 4 * 86400 + 19.5 * 3600;
  return now < cutoff
    ? 'No layers yet this week. Binding is open until Fri 19:30 UTC.'
    : 'No layers this week. Binding reopens Mon 00:00 UTC.';
}

// The replay's three acts on one rail: the book the vault held at Friday's close, the gap each
// name opened with on Monday, and what the layer paid against what it cost.
import type { CSSProperties } from 'react';
import replay from '../data/replay.json';

const { weekend, markets, result, premium, layer } = replay;
const usd = (v: number) => v / 1e6;
const n0 = (v: number) => Math.round(usd(v)).toLocaleString('en-US');
const k = (v: number) => {
  const a = Math.abs(usd(v));
  return a >= 1e6 ? `${(a / 1e6).toFixed(2)}M` : a >= 1e3 ? `${(a / 1e3).toFixed(1)}k` : a.toFixed(0);
};
const pctGap = (b: number) => `${b < 0 ? '−' : '+'}${(Math.abs(b) / 100).toFixed(2)}%`;
const dayShort = (iso: string) => {
  const [, m, d] = iso.split('-').map(Number);
  return `${d} ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1]}`;
};

export function WeekendStory() {
  const maxExp = Math.max(...markets.map((m) => Math.abs(m.vaultExposureUsd6)));
  const maxGap = Math.max(...markets.map((m) => Math.abs(m.gapBps)));
  const net = result.payoutUsd6 - premium.premiumUsd6;
  const top = Math.max(result.lossUsd6, result.payoutUsd6, premium.premiumUsd6);
  const h = (v: number) => `${((v / top) * 100).toFixed(1)}%`;

  return (
    <section className="story" aria-label="The weekend in three acts">
      <ol className="story-rail">
        <li className="act">
          <p className="act-when"><b>Friday</b> {dayShort(weekend.friday)}, market close</p>
          <h3 className="act-title">The vault holds the book</h3>
          <p className="act-line">Traders' net, reversed: what the vault carries into a weekend with no trading.</p>
          <ul className="book-bars">
            {markets.map((m) => (
              <li key={m.ticker}>
                <span className="t">{m.ticker}</span>
                <span className="track">
                  <i className={m.vaultExposureUsd6 >= 0 ? 'long' : 'short'} style={{ width: `${((Math.abs(m.vaultExposureUsd6) / maxExp) * 50).toFixed(2)}%` }} />
                </span>
                <span className="v">{m.vaultExposureUsd6 >= 0 ? 'long' : 'short'} {k(m.vaultExposureUsd6)}</span>
              </li>
            ))}
          </ul>
        </li>

        <li className="act gapact">
          <p className="act-when"><b>Monday</b> {dayShort(weekend.monday)}, first feed round</p>
          <h3 className="act-title">The market opens somewhere else</h3>
          <p className="act-line">Each name's Chainlink fix against Friday's reference. Red is the legs that moved against the vault.</p>
          <ul className="gap-bars">
            {markets.map((m) => (
              <li key={m.ticker} className={m.lossUsd6 > 0 ? 'hurt' : 'ok'}>
                <span className="t">{m.ticker}</span>
                <span className="track">
                  <i style={{ width: `${((Math.abs(m.gapBps) / maxGap) * 50).toFixed(2)}%`, [m.gapBps < 0 ? 'right' : 'left']: '50%' } as CSSProperties} />
                </span>
                <span className="v">{pctGap(m.gapBps)}{m.lossUsd6 > 0 ? <small> −{n0(m.lossUsd6)}</small> : <small> gain</small>}</span>
              </li>
            ))}
          </ul>
        </li>

        <li className="act verdict">
          <p className="act-when"><b>Monday</b> settlement, from the feed</p>
          <h3 className="act-title">The layer pays {n0(result.payoutUsd6)}</h3>
          <p className="act-line">The vault keeps the first {n0(layer.retentionUsd6)}; the layer pays the rest. Nobody files a claim.</p>
          <div className="columns" role="img" aria-label={`Loss ${n0(result.lossUsd6)}, payout ${n0(result.payoutUsd6)}, premium ${n0(premium.premiumUsd6)} USDG`}>
            <div className="col"><i className="loss" style={{ height: h(result.lossUsd6) }} /><b>{n0(result.lossUsd6)}</b><span>gap loss</span></div>
            <div className="col"><i className="pay" style={{ height: h(result.payoutUsd6) }} /><b>{n0(result.payoutUsd6)}</b><span>payout</span></div>
            <div className="col"><i className="prem" style={{ height: h(premium.premiumUsd6) }} /><b>{n0(premium.premiumUsd6)}</b><span>premium</span></div>
          </div>
          <p className="net-line">Payout less premium, this weekend: <b>{net >= 0 ? '+' : '−'}{n0(Math.abs(net))} USDG</b> to the vault. On a quiet weekend the premium is the whole cost; that is the trade.</p>
        </li>
      </ol>
    </section>
  );
}

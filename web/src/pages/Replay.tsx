import { useEffect } from 'react';
import { Link } from 'react-router-dom';
import { explorer } from '../chain';
import { Money } from '../components/Money';
import { fmtClock, fmtStamp, short } from '../lib/format';
import replay from '../data/replay.json';

const usd = (v: number) => v / 1e6;
const n2 = (v: number) => usd(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const n0 = (v: number) => Math.round(usd(v)).toLocaleString('en-US');
const px = (answer: number) => (answer / 1e8).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const roundNo = (id: string) => (BigInt(id) & ((1n << 64n) - 1n)).toString();
const phaseNo = (id: string) => (BigInt(id) >> 64n).toString();
const signedBps = (b: number) => `${b < 0 ? '−' : '+'}${(Math.abs(b) / 100).toFixed(2)}%`;
const day = (iso: string) => {
  const [y, m, d] = iso.split('-').map(Number);
  return `${d} ${['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][m - 1]} ${y}`;
};

const { weekend, snapshot, layer, markets, result, premium } = replay;
const scale = layer.retentionUsd6 + layer.limitUsd6;
const pct = (v: number) => `${((v / scale) * 100).toFixed(3)}%`;
const seniorLimit = layer.limitUsd6 - layer.juniorLimitUsd6;

export function Replay() {
  useEffect(() => { document.title = `Heracles: replay, weekend of ${day(weekend.friday)}`; }, []);
  const lossAt = result.lossUsd6 / scale;

  return (
    <>
      <header className="argument row">
        <h1 className="title">Replay: weekend of {day(weekend.friday)}</h1>
        <p className="lede">Ostium's LP vault carried this book through the weekend. Here is what the gap cost it, what a layer would have paid, and what the Stylus pricer quotes for that layer.</p>
      </header>

      <div className="desk">
        <div className="main-col">
          <section className="exhibit" aria-labelledby="ladder-h">
            <div className="exhibit-head">
              <h2 id="ladder-h" className="chart-title">Where the loss landed in the layer</h2>
            </div>
            <p className="caveat">
              The vault's loss on {markets.length} names between Friday's close and Monday's open, laid along the layer.
              The vault keeps the first {n0(layer.retentionUsd6)}; the first-loss tranche pays the next {n0(layer.juniorLimitUsd6)}; the senior tranche pays what is left above that.
            </p>
            <div className="ladder">
              <div className="ladder-mark" style={{ left: `${(lossAt * 100).toFixed(3)}%` }}>
                <b><Money v={usd(result.lossUsd6)} /></b>
                <span>weekend loss</span>
              </div>
              <div
                className="ladder-bar"
                role="img"
                aria-label={`The weekend loss of ${n2(result.lossUsd6)} USDG: the vault keeps ${n2(result.vaultKeepsUsd6)}, the first-loss tranche pays ${n2(result.payoutJuniorUsd6)} of its ${n2(layer.juniorLimitUsd6)}, the senior tranche pays ${n2(result.payoutSeniorUsd6)} of its ${n2(seniorLimit)}.`}
              >
                <i className="seg keep" style={{ width: pct(layer.retentionUsd6) }} />
                <i className="seg first" style={{ width: pct(layer.juniorLimitUsd6) }} />
                <i className="seg senior" style={{ width: pct(seniorLimit) }}>
                  <i className="fill" style={{ width: `${((result.payoutSeniorUsd6 / seniorLimit) * 100).toFixed(3)}%` }} />
                </i>
                <i className="ladder-line" style={{ left: `${(lossAt * 100).toFixed(3)}%` }} />
              </div>
              <div className="ladder-scale" aria-hidden="true">
                <span style={{ left: 0 }}>0</span>
                <span style={{ left: pct(layer.retentionUsd6) }}>{n0(layer.retentionUsd6)}</span>
                <span style={{ left: pct(layer.retentionUsd6 + layer.juniorLimitUsd6) }}>{n0(layer.retentionUsd6 + layer.juniorLimitUsd6)}</span>
                <span style={{ left: '100%' }}>{n0(scale)}</span>
              </div>
              <dl className="ladder-key">
                <div><dt><i className="swatch keep" />Vault keeps</dt><dd>{n2(result.vaultKeepsUsd6)} <small>of the first {n0(layer.retentionUsd6)}</small></dd></div>
                <div><dt><i className="swatch layer" />First-loss tranche pays</dt><dd>{n2(result.payoutJuniorUsd6)} <small>of {n0(layer.juniorLimitUsd6)}</small></dd></div>
                <div><dt><i className="swatch open layerline" />Senior tranche pays</dt><dd>{n2(result.payoutSeniorUsd6)} <small>of {n0(seniorLimit)}</small></dd></div>
              </dl>
            </div>
          </section>

          <section aria-labelledby="pos-h">
            <h2 id="pos-h" className="section">The vault's position at Friday's close</h2>
            <div className="ledger" role="table" aria-label="The vault's position and the gap, by market">
              <div className="ledger-head rp-grid" role="row">
                <span role="columnheader">Market</span>
                <span role="columnheader">Traders net</span>
                <span role="columnheader">Vault position</span>
                <span role="columnheader">Gap on the feed</span>
                <span role="columnheader">Vault loss</span>
              </div>
              {markets.map((m) => {
                const net = m.traderLongUsd6 - m.traderShortUsd6;
                return (
                  <div className="ledger-row" role="row" key={m.ticker}>
                    <div className="ledger-grid rp-grid">
                      <span role="cell" data-k="Market">{m.ticker} <span className="xname">{m.ostiumPair === m.ticker ? `Ostium ${m.ostiumPair}` : `Ostium ${m.ostiumPair}, SPY feed`}</span></span>
                      <span role="cell" data-k="Traders net">{net >= 0 ? 'long' : 'short'} {n0(Math.abs(net))}</span>
                      <span role="cell" data-k="Vault position">{m.vaultExposureUsd6 >= 0 ? 'long' : 'short'} {n0(Math.abs(m.vaultExposureUsd6))}</span>
                      <span role="cell" data-k="Gap on the feed">{signedBps(m.gapBps)}</span>
                      <span role="cell" data-k="Vault loss">{m.lossUsd6 > 0 ? n2(m.lossUsd6) : 'a gain, not counted'}</span>
                    </div>
                  </div>
                );
              })}
              <div className="ledger-row total" role="row">
                <div className="ledger-grid rp-grid">
                  <span role="cell">All four</span><span role="cell" /><span role="cell" /><span role="cell" />
                  <span role="cell" data-k="Vault loss"><b>{n2(result.lossUsd6)}</b></span>
                </div>
              </div>
            </div>
            <p className="src">
              Positions are Ostium's open interest per pair at Arbitrum One block{' '}
              <a href={`https://arbiscan.io/block/${snapshot.block}`} target="_blank" rel="noreferrer">#{snapshot.block.toLocaleString('en-US')}</a>{' '}
              ({fmtStamp(snapshot.blockTimestamp)}), read from TradingStorage{' '}
              <a href={`https://arbiscan.io/address/${snapshot.contract}`} target="_blank" rel="noreferrer">{short(snapshot.contract)}</a>, each side valued at Ostium's last trade before the close.
              The vault is the other side of every trader, so its position is the opposite of the traders' net. A name that gains on the gap adds nothing to the loss: the layer sums only the legs that moved against the vault.
            </p>
          </section>

          <section aria-labelledby="rounds-h">
            <h2 id="rounds-h" className="section">The two feed rounds that settle each name</h2>
            <div className="rows figs">
              {markets.map((m) => (
                <div className="row" key={m.ticker}>
                  <span className="k">
                    {m.feed.name}
                    <small>
                      <a href={`https://arbiscan.io/address/${m.feed.address}`} target="_blank" rel="noreferrer">{short(m.feed.address)}</a>, phase {phaseNo(m.feed.reference.roundId)},
                      round {roundNo(m.feed.reference.roundId)} to {roundNo(m.feed.fix.roundId)}
                    </small>
                  </span>
                  <span className="v">
                    {px(m.feed.reference.answer)} to {px(m.feed.fix.answer)}
                    <small>{fmtClock(m.feed.reference.updatedAt)} to {fmtClock(m.feed.fix.updatedAt)} UTC</small>
                  </span>
                </div>
              ))}
            </div>
            <p className="src">
              The reference is the round in effect at Friday's close ({fmtClock(weekend.closeTs)} UTC); the fix is the first round at or after Monday's open ({fmtClock(weekend.expiryTs)} UTC)
              whose predecessor is earlier, the two rounds the Treaty accepts. Chainlink proxies on Arbitrum One, read with <span className="file">getRoundData</span>.
              Loss per name is <span className="file">exposure × (Monday − Friday) ÷ Friday</span> on those answers, as in <span className="file">Treaty._settle</span>.
            </p>
          </section>
        </div>

        <aside className="ticket" aria-labelledby="rt-h">
          <h2 id="rt-h" className="label"><i className="sw layer" />The layer, USDG</h2>
          <p className="terms">
            The vault loses <b><Money v={usd(result.lossUsd6)} /></b> on the gap. A layer with a {n0(layer.retentionUsd6)} retention and a {n0(layer.limitUsd6)} limit pays <b><Money v={usd(result.payoutUsd6)} /></b>, for a premium of <b><Money v={usd(premium.premiumUsd6)} /></b>.
          </p>
          <div className="rows figs">
            <div className="row"><span className="k">Vault keeps<small>the retention</small></span><span className="v"><Money v={usd(result.vaultKeepsUsd6)} /></span></div>
            <div className="row"><span className="k">First-loss tranche pays<small>premium {n2(premium.premiumJuniorUsd6)}</small></span><span className="v"><Money v={usd(result.payoutJuniorUsd6)} /></span></div>
            <div className="row"><span className="k">Senior tranche pays<small>premium {n2(premium.premiumSeniorUsd6)}</small></span><span className="v"><Money v={usd(result.payoutSeniorUsd6)} /></span></div>
            <div className="row"><span className="k" title="Expected loss: the mean payout over 504 weekends">Pricer's expected payout a weekend</span><span className="v"><Money v={usd(premium.elUsd6)} /></span></div>
            <div className="row"><span className="k" title="TVaR95: the mean payout over the worst 25 of 504 weekends">Average in the worst 5% of weekends</span><span className="v"><Money v={usd(premium.tvar95Usd6)} /></span></div>
          </div>
          <p className="src">
            Premium quoted by the Stylus pricer <a href={explorer.address(premium.pricer)} target="_blank" rel="noreferrer">{short(premium.pricer)}</a> at Arbitrum Sepolia block{' '}
            <a href={explorer.block(BigInt(premium.block))} target="_blank" rel="noreferrer">#{premium.block.toLocaleString('en-US')}</a> on these four positions, with each name's own 504-weekend table
            (SPY 2, NVDA 0, TSLA 3, AAPL 1) and volatility from the SPY/USD feed. The first-loss tranche is the Treaty's fixed {layer.juniorShareBps / 100}% of the limit; each tranche's premium is the pricer's quote for its own slice.
          </p>
          <div className="acts">
            <Link className="btn" to="/quote">Quote a layer for your vault</Link>
          </div>
        </aside>
      </div>
    </>
  );
}

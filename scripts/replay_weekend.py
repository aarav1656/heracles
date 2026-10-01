#!/usr/bin/env python3
"""Replay one real weekend through the treaty's layer math and the Stylus pricer.

Weekend: Friday 2026-09-25 20:00 UTC (4pm New York close) to Monday 2026-09-28 13:30 UTC (9:30am open).
Book: Ostium's LP vault on Arbitrum One, the counterparty to every trader. Four markets carry a
Heracles scenario table: SPX (priced on the SPY table and settled on the SPY/USD feed), NVDA, TSLA, AAPL.

Reads, all Arbitrum One unless noted:
  * Ostium open interest per pair at the Friday-close block (TradingStorage.getPairOpeningInterestInfo, archive read).
  * Ostium's last trade price at or before the close (subgraph `orders`), to value each side in USD.
  * The Chainlink round in effect at the close and the first round at or after the Monday open, per feed,
    the same two rounds Treaty.setReference / Treaty.fix accept.
  * The deployed Stylus pricer on Arbitrum Sepolia, called with the per-market table ids set in the call's state.
The layer math is Treaty._settle: loss = sum over markets of the losing legs, exposure * (monday - friday) / friday
(integer, truncated toward zero), payout = min(limit, max(0, loss - retention)), first-loss tranche pays
min(payout, juniorLimit), senior the rest.

Usage: python3 scripts/replay_weekend.py [--out web/src/data/replay.json]
"""
import argparse
import json
import subprocess
import urllib.request

ARB_ARCHIVE = "https://arbitrum.gateway.tenderly.co"  # arb1.arbitrum.io prunes historical state
SEPOLIA = "https://sepolia-rollup.arbitrum.io/rpc"
SUBGRAPH = "https://api.subgraph.ormilabs.com/api/public/67a599d5-c8d2-4cc4-9c4d-2975a97bc5d8/subgraphs/ost-prod/live/gn"
TRADING_STORAGE = "0xcCd5891083A8acD2074690F65d3024E7D13d66E7"
PRICER = "0xbe99217180a5fcb83372375b0928c971dfa71f88"
TREATY = "0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807"
SEPOLIA_SPY_FEED = "0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06"
CLOSE_TS, EXPIRY_TS = 1790366400, 1790602200
RETENTION, LIMIT = 3_000 * 10**6, 20_000 * 10**6
# ticker, Ostium pair index, pair name, pricer table id, Arbitrum One Chainlink proxy settled on
MARKETS = [
    ("SPY", 10, "SPX", 2, "0x46306F3795342117721D8DEd50fbcF6DF2b3cc10", "SPY/USD"),
    ("NVDA", 18, "NVDA", 0, "0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F", "NVDA/USD"),
    ("TSLA", 22, "TSLA", 3, "0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3", "TSLA/USD"),
    ("AAPL", 23, "AAPL", 1, "0x8d0CC5f38f9E802475f2CFf4F9fc7000C2E1557c", "AAPL/USD"),
]
PRICER_CLI = "pricer/pricer_cli/target/release/pricer-cli"


def rpc(url, method, params):
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                         {"content-type": "application/json", "user-agent": "heracles-replay/1"})
            r = json.load(urllib.request.urlopen(req, timeout=60))
            if "error" in r:
                raise RuntimeError(f"{method}: {r['error']}")
            return r["result"]
        except Exception:
            if attempt == 4:
                raise


def cast(*a):
    import os
    return subprocess.run(["cast", *a], capture_output=True, text=True, check=True,
                          env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"}).stdout.strip()


def words(h):
    h = h[2:]
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]


def signed(n):
    return n - 2**256 if n >= 2**255 else n


def tdiv(a, b):  # Solidity int division truncates toward zero
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def block_at(ts, head):
    lo, hi = 400_000_000, head
    while lo < hi:
        mid = (lo + hi) // 2
        if int(rpc(ARB_ARCHIVE, "eth_getBlockByNumber", [hex(mid), False])["timestamp"], 16) < ts:
            lo = mid + 1
        else:
            hi = mid
    return lo


def graph(q):
    req = urllib.request.Request(SUBGRAPH, json.dumps({"query": q}).encode(), {"content-type": "application/json", "user-agent": "curl/8.7.1"})
    return json.load(urllib.request.urlopen(req, timeout=60))["data"]


def round_of(feed, rid):
    w = words(rpc(ARB_ARCHIVE, "eth_call", [{"to": feed, "data": "0x9a6fc8f5" + format(rid, "064x")}, "latest"]))
    return {"roundId": str(w[0]), "answer": signed(w[1]), "updatedAt": w[3]}


def chainlink_rounds(feed):
    latest = words(rpc(ARB_ARCHIVE, "eth_call", [{"to": feed, "data": "0xfeaf968c"}, "latest"]))[0]
    phase, hi = latest >> 64, latest & (2**64 - 1)

    def last_before(ts):  # largest round whose updatedAt < ts
        lo, h = 1, hi
        while lo < h:
            mid = (lo + h + 1) // 2
            if round_of(feed, (phase << 64) | mid)["updatedAt"] < ts:
                lo = mid
            else:
                h = mid - 1
        return lo

    ref = last_before(CLOSE_TS + 1)  # in effect at the close: updatedAt <= CLOSE_TS
    fix = last_before(EXPIRY_TS) + 1  # first round at or after the open, predecessor strictly before it
    return round_of(feed, (phase << 64) | ref), round_of(feed, (phase << 64) | fix)


def pricer_quote(exposure, feeds, retention, limit, table_ids, block):
    data = cast("calldata", "quote(int256[],address[],uint256,uint256)", "[" + ",".join(map(str, exposure)) + "]",
                "[" + ",".join(feeds) + "]", str(retention), str(limit))
    slot0 = "0x" + (bytes(table_ids).hex() + "00" * 31)[:62] + format(2 * len(table_ids), "02x")
    out = rpc(SEPOLIA, "eth_call", [{"to": PRICER, "data": data}, hex(block), {PRICER: {"stateDiff": {"0x" + "0" * 64: slot0}}}])
    return tuple(words(out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="web/src/data/replay.json")
    a = ap.parse_args()

    head = int(rpc(ARB_ARCHIVE, "eth_blockNumber", []), 16)
    fri_block = block_at(CLOSE_TS, head)
    mon_block = block_at(EXPIRY_TS, head)
    fri_ts = int(rpc(ARB_ARCHIVE, "eth_getBlockByNumber", [hex(fri_block), False])["timestamp"], 16)

    sel = cast("sig", "getPairOpeningInterestInfo(uint16)")
    markets, total_loss = [], 0
    for ticker, pair, name, table_id, feed, feed_name in MARKETS:
        oi = words(rpc(ARB_ARCHIVE, "eth_call", [{"to": TRADING_STORAGE, "data": sel + format(pair, "064x")}, hex(fri_block)]))
        order = graph('{orders(first:1,where:{pair:"%d",executedAt_lte:"%d"},orderBy:executedAt,orderDirection:desc){id price executedAt executedBlock}}' % (pair, CLOSE_TS))["orders"][0]
        price_raw = int(order["price"])
        long_units, short_units = oi[0], oi[1]  # 1e18 units
        # vault side: positive when traders are net short (the vault is long), in 6dp USD
        exposure = tdiv((short_units - long_units) * price_raw, 10**30)
        ref, fix = chainlink_rounds(feed)
        pnl = tdiv(exposure * (fix["answer"] - ref["answer"]), ref["answer"])
        loss = -pnl if pnl < 0 else 0
        total_loss += loss
        markets.append({
            "ticker": ticker, "ostiumPair": name, "pairIndex": pair, "tableId": table_id,
            "oi": {"longUnits": str(long_units), "shortUnits": str(short_units)},
            "ostiumPrice": {"value": str(price_raw), "orderId": order["id"], "executedAt": int(order["executedAt"]), "executedBlock": int(order["executedBlock"])},
            "traderLongUsd6": tdiv(long_units * price_raw, 10**30), "traderShortUsd6": tdiv(short_units * price_raw, 10**30),
            "vaultExposureUsd6": exposure,
            "feed": {"name": feed_name, "address": feed, "reference": ref, "fix": fix},
            "gapBps": round((fix["answer"] - ref["answer"]) * 10000 / ref["answer"], 2),
            "lossUsd6": loss,
        })

    junior_limit = LIMIT * 3000 // 10000
    payout = min(LIMIT, max(0, total_loss - RETENTION))
    payout_junior = min(payout, junior_limit)
    payout_senior = payout - payout_junior

    sep_block = int(rpc(SEPOLIA, "eth_blockNumber", []), 16)
    exposures = [m["vaultExposureUsd6"] for m in markets]
    table_ids = [m["tableId"] for m in markets]
    feeds = [SEPOLIA_SPY_FEED] * len(markets)
    total_q = pricer_quote(exposures, feeds, RETENTION, LIMIT, table_ids, sep_block)
    junior_q = pricer_quote(exposures, feeds, RETENTION, junior_limit, table_ids, sep_block)
    # Independent cross-check: the native build of the same pricer_core at the neutral 1.0x volatility scale.
    cli = subprocess.run([PRICER_CLI, str(RETENTION), str(LIMIT), ",".join(map(str, exposures)), ",".join(["1000000"] * len(markets)),
                          ",".join(map(str, table_ids))], capture_output=True, text=True, check=True).stdout.strip()
    assert tuple(words(cli)) == total_q, f"on-chain pricer {total_q} differs from native pricer_core {words(cli)}"
    min_rate = int(cast("call", TREATY, "minRateOnLineBps()(uint256)", "--rpc-url", SEPOLIA).split()[0])
    floor = LIMIT * min_rate // 10000
    premium = max(total_q[0], floor)
    premium_junior = min(junior_q[0], premium)

    doc = {
        "weekend": {"friday": "2026-09-25", "monday": "2026-09-28", "closeTs": CLOSE_TS, "expiryTs": EXPIRY_TS},
        "snapshot": {"chain": "Arbitrum One", "block": fri_block, "blockTimestamp": fri_ts, "mondayBlock": mon_block,
                     "contract": TRADING_STORAGE, "call": "getPairOpeningInterestInfo(uint16)", "rpc": ARB_ARCHIVE, "headBlock": head},
        "layer": {"retentionUsd6": RETENTION, "limitUsd6": LIMIT, "juniorShareBps": 3000, "juniorLimitUsd6": junior_limit},
        "markets": markets,
        "result": {"lossUsd6": total_loss, "payoutUsd6": payout, "payoutJuniorUsd6": payout_junior, "payoutSeniorUsd6": payout_senior,
                   "vaultKeepsUsd6": min(total_loss, RETENTION), "uncoveredUsd6": max(0, total_loss - RETENTION - LIMIT)},
        "premium": {"chain": "Arbitrum Sepolia", "block": sep_block, "pricer": PRICER, "tableIds": table_ids, "volFeed": SEPOLIA_SPY_FEED,
                    "premiumUsd6": premium, "quotedUsd6": total_q[0], "elUsd6": total_q[1], "tvar95Usd6": total_q[2],
                    "premiumJuniorUsd6": premium_junior, "premiumSeniorUsd6": premium - premium_junior,
                    "minRateBps": min_rate, "floorUsd6": floor, "nativeCrossCheck": cli},
    }
    json.dump(doc, open(a.out, "w"), indent=2)
    print(json.dumps({k: doc[k] for k in ("snapshot", "result", "premium")}, indent=1))
    for m in markets:
        print(m["ticker"], "vault", m["vaultExposureUsd6"] / 1e6, "gap bps", m["gapBps"], "loss", m["lossUsd6"] / 1e6,
              "ref", m["feed"]["reference"]["roundId"], "fix", m["feed"]["fix"]["roundId"])


if __name__ == "__main__":
    main()

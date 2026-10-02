#!/usr/bin/env python3
"""The gTrade gUSDC vault's real weekend gaps over recent weekends, and what a Heracles layer on
each weekend's book would have cost and paid.

For each Friday 16:00 ET close (20:00 UTC in EDT) back from the latest one:
  * the Arbitrum One block at the close (binary search on block timestamps, archive RPC);
  * the vault's book at that block: getPairOiAfterV10Collateral(3, pair) plus
    getPairOisBeforeV10Collateral(3, pair) on the gTrade Diamond for SPY, NVDA, AAPL, TSLA, EUR and
    XAU, USDC collateral (index 3), the vault holding traders' short minus long;
  * gUSDC totalAssets() at the same block;
  * per market, the Chainlink round in effect at the close and the first round at or after Monday
    13:30 UTC whose predecessor is earlier, the two rounds Treaty.setReference and Treaty.fix take;
  * the gap PnL of the book (exposure * (monday - friday) / friday, truncated toward zero), net and on
    the losing legs only, as Treaty._settle sums them;
  * a layer with the /quote page's starting terms for that book (vault keeps 0.25% of the gross
    book, cover up to 2%), its payout, and its premium from the deployed six-table Stylus pricer on
    Arbitrum Sepolia today (SPY/USD volatility, the 50 bps floor applied).

Usage: python3 scripts/gusdc_weekends.py [--weekends 12] [--out web/src/data/gusdc-weekends.json]
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from replay_weekend import ARB_ARCHIVE, SEPOLIA, block_at, cast, rpc, round_of, tdiv, words  # noqa: E402

DIAMOND = "0xFF162c694eAA571f685030649814282eA457f169"
GUSDC = "0xd3443ee1e91aF28e5FB858Fbd0D72A63bA8046E0"
QUOTE_PRICER = "0x1674ecf8d236a91c484c11fd11a21601837f7e37"
SEPOLIA_SPY_FEED = "0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06"
# ticker, gTrade pair index, Arbitrum One Chainlink proxy; order = the six-table pricer's tables
MARKETS = [
    ("NVDA", 65, "0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F"),
    ("AAPL", 58, "0x8d0CC5f38f9E802475f2CFf4F9fc7000C2E1557c"),
    ("SPY", 86, "0x46306F3795342117721D8DEd50fbcF6DF2b3cc10"),
    ("TSLA", 63, "0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3"),
    ("EUR", 21, "0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84"),
    ("XAU", 90, "0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c"),
]
WEEK = 7 * 86400
LATEST_CLOSE = 1790366400  # Fri 2026-09-25 20:00 UTC; earlier closes step back a week (all EDT)


def sel(sig):
    return cast("sig", sig)


def call(to, data, block):
    return words(rpc(ARB_ARCHIVE, "eth_call", [{"to": to, "data": data}, hex(block)]))


def book_at(block, s_after, s_before):
    book = []
    for t, pair, _ in MARKETS:
        args = format(3, "064x") + format(pair, "064x")
        after = call(DIAMOND, s_after + args, block)
        before = call(DIAMOND, s_before + args, block)
        long_, short = after[0] + before[0], after[1] + before[1]
        book.append({"ticker": t, "pair": pair, "traderLong": long_, "traderShort": short, "vault": short - long_})
    return book


class Feed:
    """Chainlink round lookups with a cache, so successive weekends reuse earlier reads."""

    def __init__(self, addr):
        self.addr = addr
        latest = words(rpc(ARB_ARCHIVE, "eth_call", [{"to": addr, "data": "0xfeaf968c"}, "latest"]))[0]
        self.phase, self.hi = latest >> 64, latest & (2**64 - 1)
        self.cache = {}

    def at(self, agg):
        if agg not in self.cache:
            self.cache[agg] = round_of(self.addr, (self.phase << 64) | agg)
        return self.cache[agg]

    def last_before(self, ts):  # largest aggregator round with updatedAt < ts
        lo, h = 1, self.hi
        while lo < h:
            mid = (lo + h + 1) // 2
            if self.at(mid)["updatedAt"] < ts:
                lo = mid
            else:
                h = mid - 1
        return lo

    def weekend(self, close_ts, open_ts):
        ref = self.last_before(close_ts + 1)
        fix = self.last_before(open_ts) + 1
        return self.at(ref), self.at(fix)


def premium(exposure, retention, limit, block):
    data = cast("calldata", "quote(int256[],address[],uint256,uint256)", "[" + ",".join(map(str, exposure)) + "]",
                "[" + ",".join([SEPOLIA_SPY_FEED] * len(exposure)) + "]", str(retention), str(limit))
    p, el, tv = words(rpc(SEPOLIA, "eth_call", [{"to": QUOTE_PRICER, "data": data}, hex(block)]))
    return max(p, limit * 50 // 10_000), el, tv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weekends", type=int, default=12)
    ap.add_argument("--out", default="web/src/data/gusdc-weekends.json")
    a = ap.parse_args()
    s_after = sel("getPairOiAfterV10Collateral(uint8,uint16)")
    s_before = sel("getPairOisBeforeV10Collateral(uint8,uint16)")
    s_assets = sel("totalAssets()")
    head = int(rpc(ARB_ARCHIVE, "eth_blockNumber", []), 16)
    sep_block = int(rpc(SEPOLIA, "eth_blockNumber", []), 16)
    feeds = [Feed(f) for _, _, f in MARKETS]
    rows = []
    for k in range(a.weekends):
        close_ts = LATEST_CLOSE - k * WEEK
        open_ts = close_ts + 2 * 86400 + 17 * 3600 + 30 * 60  # Monday 13:30 UTC
        block = block_at(close_ts, head)
        book = book_at(block, s_after, s_before)
        assets = call(GUSDC, s_assets, block)[0]
        legs = []
        for m, f in zip(book, feeds):
            ref, fix = f.weekend(close_ts, open_ts)
            pnl = tdiv(m["vault"] * (fix["answer"] - ref["answer"]), ref["answer"])
            legs.append({**m, "ref": ref, "fix": fix, "pnl": pnl})
        gross = sum(abs(m["vault"]) for m in book)
        losing = sum(-l["pnl"] for l in legs if l["pnl"] < 0)
        net = sum(l["pnl"] for l in legs)
        retention = max(100, round(gross / 1e6 * 0.0025 / 100) * 100) * 10**6
        limit = max(1000, round(gross / 1e6 * 0.02 / 1000) * 1000) * 10**6
        payout = min(limit, max(0, losing - retention))
        p, el, tv = premium([m["vault"] for m in book], retention, limit, sep_block)
        row = {"fridayClose": close_ts, "mondayOpen": open_ts, "block": block, "gusdcAssets": assets, "gross": gross,
               "netGapPnl": net, "losingLegs": losing, "retention": retention, "limit": limit, "payout": payout,
               "premium": p, "el": el, "tvar95": tv,
               "legs": [{"ticker": l["ticker"], "vault": l["vault"], "traderLong": l["traderLong"], "traderShort": l["traderShort"], "pnl": l["pnl"],
                         "ref": {"roundId": l["ref"]["roundId"], "answer": l["ref"]["answer"], "updatedAt": l["ref"]["updatedAt"]},
                         "fix": {"roundId": l["fix"]["roundId"], "answer": l["fix"]["answer"], "updatedAt": l["fix"]["updatedAt"]}} for l in legs]}
        rows.append(row)
        print(f"Fri {close_ts}: block {block}, gross {gross/1e6:,.0f}, net gap PnL {net/1e6:,.2f}, losing legs {losing/1e6:,.2f}, "
              f"layer {retention/1e6:,.0f}/{limit/1e6:,.0f} pays {payout/1e6:,.2f}, premium {p/1e6:,.2f}, gUSDC {assets/1e6:,.0f}", flush=True)
    out = {"chain": "Arbitrum One (42161)", "diamond": DIAMOND, "gToken": GUSDC, "collateralIndex": 3,
           "pricer": QUOTE_PRICER, "pricerChain": "Arbitrum Sepolia (421614)", "pricerBlock": sep_block,
           "terms": "retention 0.25% and limit 2% of each weekend's gross book, as /quote starts", "weekends": rows}
    Path(a.out).write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()

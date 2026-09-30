#!/usr/bin/env python3
"""Read Ostium's live open interest per pair from TradingStorage.getPairOpeningInterestInfo
on Arbitrum One at one pinned block, price each leg with the pair's lastTradePrice from
Ostium's own subgraph (a separate, timestamped read since Ostium prices are pushed by its
own oracle network, not a per-pair Chainlink AggregatorV3), and sum long/short OI into five
groups: equities (stocks + indices), fx, gold/metals, commodities (non-metal), crypto.

Usage:
    python3 scripts/ostium_oi_by_group.py --block 510265853 \
        --pairs-json evidence/gap-tables/.ostium-pairs-live.json
"""
import argparse
import json
import subprocess

TRADING_STORAGE = "0xcCd5891083A8acD2074690F65d3024E7D13d66E7"
RPC = "https://arb1.arbitrum.io/rpc"

# Ostium's subgraph groups are crypto/indices/forex/stocks/commodities/etf. The task wants
# five buckets: equities, fx, gold/metals, commodities, crypto. Metals (XAU/XAG/XPT/XPD) are
# split out of "commodities"; etf is folded into equities (it is equity-like and closes for
# the weekend the same way stocks do).
METALS = {"XAU", "XAG", "XPT", "XPD"}


def bucket(group_name: str, base: str) -> str:
    if group_name == "crypto":
        return "crypto"
    if group_name in ("stocks", "indices", "etf"):
        return "equities"
    if group_name == "forex":
        return "fx"
    if group_name == "commodities":
        return "gold_metals" if base in METALS else "commodities"
    return "other"


def cast_oi(pair_index: int, block: int) -> tuple[int, int, int]:
    out = subprocess.run(
        [
            "cast", "call", TRADING_STORAGE,
            "getPairOpeningInterestInfo(uint16)(uint256,uint256,uint256)",
            str(pair_index), "--rpc-url", RPC, "--block", str(block),
        ],
        capture_output=True, text=True, check=True,
    ).stdout
    nums = [line.split()[0].replace(",", "") for line in out.splitlines() if line.strip() and line.strip()[0].isdigit()]
    long_raw, short_raw, max_raw = (int(n) for n in nums[:3])
    return long_raw, short_raw, max_raw


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--block", type=int, required=True)
    ap.add_argument("--pairs-json", required=True, help="subgraph pairs snapshot (id, from, to, group, lastTradePrice)")
    ap.add_argument("--out", default="evidence/gap-tables/ostium-oi-by-group.json")
    args = ap.parse_args()

    meta = json.load(open(args.pairs_json))["data"]["pairs"]
    meta_by_id = {int(p["id"]): p for p in meta}

    rows = []
    for pid in sorted(meta_by_id):
        p = meta_by_id[pid]
        long_raw, short_raw, max_raw = cast_oi(pid, args.block)
        price_raw = int(p["lastTradePrice"])  # 1e18 fixed point
        long_units = long_raw / 1e18
        short_units = short_raw / 1e18
        price = price_raw / 1e18
        long_usd = long_units * price
        short_usd = short_units * price
        grp = p["group"]["name"]
        b = bucket(grp, p["from"])
        rows.append({
            "pairIndex": pid, "from": p["from"], "to": p["to"], "subgraphGroup": grp,
            "bucket": b, "longOI_units": long_units, "shortOI_units": short_units,
            "price": price, "longOI_usd": long_usd, "shortOI_usd": short_usd,
            "netOI_usd": long_usd - short_usd,
        })
        print(f"{pid:3d} {p['from']:>6}/{p['to']:<5} {b:12} long={long_usd:14,.2f} short={short_usd:14,.2f} net={long_usd - short_usd:14,.2f}")

    groups: dict[str, dict[str, float]] = {}
    for r in rows:
        g = groups.setdefault(r["bucket"], {"long_usd": 0.0, "short_usd": 0.0, "net_usd": 0.0, "gross_usd": 0.0, "pairs": 0})
        g["long_usd"] += r["longOI_usd"]
        g["short_usd"] += r["shortOI_usd"]
        g["net_usd"] += r["netOI_usd"]
        g["gross_usd"] += r["longOI_usd"] + r["shortOI_usd"]
        g["pairs"] += 1

    doc = {
        "block": args.block,
        "tradingStorage": TRADING_STORAGE,
        "rpc": RPC,
        "priceSource": "Ostium subgraph lastTradePrice (api.subgraph.ormilabs.com ost-prod), separate fetch, see pairs-json fetch time",
        "pairsJson": args.pairs_json,
        "groups": groups,
        "pairs": rows,
    }
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=2)
    print("\n=== groups (USD) ===")
    for g, v in sorted(groups.items(), key=lambda kv: -kv[1]["gross_usd"]):
        print(f"{g:12} long={v['long_usd']:14,.2f} short={v['short_usd']:14,.2f} net={v['net_usd']:14,.2f} gross={v['gross_usd']:14,.2f} pairs={v['pairs']}")
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

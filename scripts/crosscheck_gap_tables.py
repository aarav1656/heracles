#!/usr/bin/env python3
"""Cross-check random weekends from a Dukascopy-sourced gap table (XAU.json /
EUR.json) against Yahoo Finance's independent feed. Yahoo only serves 60m
candles this far back (no free 1-minute history over multi-year ranges), so
the Yahoo price at the exact Friday-16:00-ET / Monday-9:30-ET instant is
linearly interpolated between the two bracketing hourly bars -- that
resolution gap, not a real vendor disagreement, is the dominant source of any
difference reported here. Yahoo's spot gold ticker does not exist; GC=F
(COMEX front-month futures) is used for gold and carries its own small
future-vs-spot basis, noted separately from the FX check.

Usage:
    python3 scripts/crosscheck_gap_tables.py evidence/gap-tables/EUR.json EURUSD=X --n 20
    python3 scripts/crosscheck_gap_tables.py evidence/gap-tables/XAU.json GC=F --n 20
"""
import json
import random
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def yahoo_bars(symbol: str, start_ts: int, end_ts: int):
    url = (
        "https://query1.finance.yahoo.com/v8/finance/chart/"
        f"{urllib.parse.quote(symbol)}?period1={start_ts}&period2={end_ts}&interval=60m"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            d = json.load(resp)
    except urllib.error.HTTPError:
        return None  # out of Yahoo's retention window for this symbol/range
    res = d.get("chart", {}).get("result")
    if not res:
        return None
    r = res[0]
    ts = r.get("timestamp")
    if not ts:
        return None  # no bars in this window (e.g. futures maintenance break / holiday)
    opens = r["indicators"]["quote"][0]["open"]
    return [(t, o) for t, o in zip(ts, opens) if o is not None]


def interp_price(bars, target_ts: int):
    before = [b for b in bars if b[0] <= target_ts]
    after = [b for b in bars if b[0] >= target_ts]
    if not before or not after:
        return None
    b, a = before[-1], after[0]
    if b[0] == a[0]:
        return b[1]
    frac = (target_ts - b[0]) / (a[0] - b[0])
    return b[1] + frac * (a[1] - b[1])


def main() -> int:
    table_path, yahoo_symbol = sys.argv[1], sys.argv[2]
    n = int(sys.argv[sys.argv.index("--n") + 1]) if "--n" in sys.argv else 20
    doc = json.load(open(table_path))
    random.seed(20260930)
    # Yahoo's 60m history only goes back to about 2023-12-14 for these symbols;
    # restrict candidates to weekends inside that window so random sampling
    # doesn't burn requests on weekends Yahoo can never answer.
    candidates = [g for g in doc["gaps"] if g["friday"] >= "2023-12-15"]
    random.shuffle(candidates)

    checked = []
    for g in candidates:
        if len(checked) >= n:
            break
        ft = int(datetime.fromisoformat(g["friday_ref_utc"]).timestamp())
        mt = int(datetime.fromisoformat(g["monday_fix_utc"]).timestamp())
        fbars = yahoo_bars(yahoo_symbol, ft - 4 * 3600, ft + 4 * 3600)
        time.sleep(0.3)
        mbars = yahoo_bars(yahoo_symbol, mt - 4 * 3600, mt + 4 * 3600)
        time.sleep(0.3)
        if not fbars or not mbars:
            continue  # out of Yahoo's retention window for this symbol; skip, don't fabricate
        fp = interp_price(fbars, ft)
        mp = interp_price(mbars, mt)
        if fp is None or mp is None:
            continue
        yahoo_gap_bps = round((mp - fp) / fp * 10000, 2)
        diff = round(abs(yahoo_gap_bps - g["gap_bps"]), 2)
        checked.append({
            "friday": g["friday"], "dukascopy_gap_bps": g["gap_bps"],
            "yahoo_gap_bps": yahoo_gap_bps, "abs_diff_bps": diff,
        })
        print(f"{g['friday']}: dukascopy={g['gap_bps']} yahoo={yahoo_gap_bps} diff={diff}")

    if not checked:
        print("NO WEEKENDS CROSS-CHECKED (all outside Yahoo's retention window)")
        return 1

    max_diff = max(c["abs_diff_bps"] for c in checked)
    out = {
        "table": table_path, "yahoo_symbol": yahoo_symbol, "n_checked": len(checked),
        "n_requested": n, "max_abs_diff_bps": max_diff, "checks": checked,
    }
    out_path = table_path.rsplit(".", 1)[0] + ".crosscheck.json"
    with open(out_path, "w") as f:
        json.dump(out, f, indent=2)
    print(f"\nchecked {len(checked)}/{n}, max abs diff = {max_diff} bps, wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

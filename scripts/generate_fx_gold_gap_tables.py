#!/usr/bin/env python3
"""Generate gap tables of exactly N real weekends (default 504) for XAU/USD
and EUR/USD, matching how
Treaty.sol settles: reference = price at Friday 16:00 ET (4pm ET, DST-aware
via `_isUsDst`/`fridayCloseOf`), fix = price at Monday 9:30 ET (DST-aware via
`weekWindow`). Same JSON shape as evidence/gap-tables/SPY.json.

Source: Dukascopy's live-chart JSON feed (freeserv.dukascopy.com/2.0/index.php,
path=chart/json3), reached through the `dukascopy-python` package, 1-minute
BID candles. Free, no auth. This is the same underlying Dukascopy tick archive
the standalone .bi5 downloader tools use, exposed as an already-decoded JSON
API instead of raw LZMA-compressed tick files.

FX/gold weekends are calendar weekends (Friday to Monday), not trading-day
adjusted like the equities table: forex and gold trade close to 24/5 and
Treaty's `weekWindow` is pure calendar math, so there is no holiday-Monday
shift to apply.

Usage:
    python3 scripts/generate_fx_gold_gap_tables.py --symbol XAU/USD --ticker XAU \
        --out evidence/gap-tables/XAU.json --weekends 504
"""
import argparse
import json
import sys
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import dukascopy_python as dp

ET = ZoneInfo("America/New_York")
UTC = timezone.utc


def weekend_at(friday: "datetime.date"):
    """Friday 16:00 ET / Monday 9:30 ET instants for the weekend starting at
    `friday`, via IANA America/New_York, which implements the same 2nd-Sunday-
    March/1st-Sunday-November US DST rule (Energy Policy Act of 2005) that
    Treaty._isUsDst hand-rolls on chain -- each instant's DST state is decided
    by its own calendar date, exactly like fridayCloseOf/weekWindow do."""
    monday = friday + timedelta(days=3)
    friday_close_et = datetime(friday.year, friday.month, friday.day, 16, 0, tzinfo=ET)
    monday_expiry_et = datetime(monday.year, monday.month, monday.day, 9, 30, tzinfo=ET)
    return {
        "friday": friday.isoformat(),
        "monday": monday.isoformat(),
        "friday_close_utc": friday_close_et.astimezone(UTC),
        "monday_expiry_utc": monday_expiry_et.astimezone(UTC),
    }


def fetch_minute_bars(instrument: str, start_ms: int, limit: int, max_retries: int = 5):
    for attempt in range(max_retries):
        try:
            rows = dp._fetch(
                instrument=instrument, interval=dp.INTERVAL_MIN_1,
                offer_side=dp.OFFER_SIDE_BID, last_update=start_ms, limit=limit,
            )
            if isinstance(rows, list) and rows and all(r for r in rows):
                return rows
        except Exception:
            pass
        time.sleep(1.0 + attempt)
    return []


def nearest_bar(rows, target_ms: int):
    """Bar whose open timestamp is closest to target_ms; use its open price
    (open of a 1-minute bar = the traded price at that bar's start instant).
    Returns (bar_ts_ms, open_price, delta_minutes) or None if rows is empty."""
    if not rows:
        return None
    best = min(rows, key=lambda r: abs(r[0] - target_ms))
    return best[0], best[1], (best[0] - target_ms) / 60000.0


def build_table(symbol: str, ticker: str, n: int, last_friday_str: str):
    """Walk weekends backward from last_friday, skipping (not backfilling) any
    weekend with no real price at both fixing minutes, until exactly n real
    weekends are collected. Holiday weekends push the start date further back
    instead of being interpolated."""
    friday = datetime.strptime(last_friday_str, "%Y-%m-%d").date()
    gaps = []  # newest first while walking; reversed to oldest-first at the end
    missing = []
    attempted = 0
    while len(gaps) < n:
        attempted += 1
        w = weekend_at(friday)
        friday_target_ms = int(w["friday_close_utc"].timestamp() * 1000)
        monday_target_ms = int(w["monday_expiry_utc"].timestamp() * 1000)
        start_ms = friday_target_ms - 5 * 60000
        rows = fetch_minute_bars(symbol, start_ms, limit=2500)
        fri = nearest_bar(rows, friday_target_ms)
        mon = nearest_bar(rows, monday_target_ms)
        if fri is None or mon is None or abs(fri[2]) > 180 or abs(mon[2]) > 180:
            missing.append(w["friday"])
            print(f"[{len(gaps)}/{n}, attempt {attempted}] {ticker} {w['friday']} MISSING (fri={fri} mon={mon})", file=sys.stderr)
            friday -= timedelta(weeks=1)
            time.sleep(0.2)
            continue
        friday_close = fri[1]
        monday_open = mon[1]
        gap_bps = round((monday_open - friday_close) / friday_close * 10000, 2)
        gaps.append({
            "friday": w["friday"], "monday": w["monday"],
            "friday_close": friday_close, "monday_open": monday_open,
            "gap_bps": gap_bps,
            "friday_ref_utc": w["friday_close_utc"].isoformat(),
            "monday_fix_utc": w["monday_expiry_utc"].isoformat(),
            "friday_bar_delta_min": round(fri[2], 2),
            "monday_bar_delta_min": round(mon[2], 2),
        })
        if len(gaps) % 25 == 0:
            print(f"[{len(gaps)}/{n}, attempt {attempted}] {ticker} through {w['friday']}", file=sys.stderr)
        friday -= timedelta(weeks=1)
        time.sleep(0.15)

    gaps.reverse()  # oldest first, matching SPY.json's convention
    assert all(-32768 <= g["gap_bps"] <= 32767 for g in gaps), "gap_bps out of int16 range"

    doc = {
        "ticker": ticker,
        "fetch_date": datetime.now(tz=UTC).strftime("%Y-%m-%d"),
        "fetch_time_utc": datetime.now(tz=UTC).isoformat(),
        "source": "https://freeserv.dukascopy.com/2.0/index.php?path=chart/json3 (Dukascopy live-chart 1-minute BID candles, via dukascopy-python)",
        "method": (
            "gap_bps = round((monday_price - friday_price) / friday_price * 10000, 2); "
            "friday_price = open of the 1-minute Dukascopy bar starting at Friday 16:00 ET "
            "(DST via IANA America/New_York, matching Treaty._isUsDst/fridayCloseOf); "
            "monday_price = open of the 1-minute bar starting at Monday 9:30 ET "
            "(matching Treaty.weekWindow's expiry, DST decided by Monday's own date)"
        ),
        "count": len(gaps),
        "missing_weekends": missing,
        "gaps": gaps,
    }
    return doc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", required=True, help="Dukascopy instrument, e.g. 'EUR/USD' or 'XAU/USD'")
    ap.add_argument("--ticker", required=True, help="short ticker for output, e.g. EUR, XAU")
    ap.add_argument("--out", required=True)
    ap.add_argument("--weekends", type=int, default=504)
    ap.add_argument("--last-friday", default="2026-09-25")
    args = ap.parse_args()

    doc = build_table(args.symbol, args.ticker, args.weekends, args.last_friday)
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=2)
    gaps_txt = args.out.rsplit(".", 1)[0] + ".gaps.txt"
    with open(gaps_txt, "w") as f:
        f.write("\n".join(str(g["gap_bps"]) for g in doc["gaps"]) + "\n")
    print(f"wrote {args.out} ({doc['count']} rows, {len(doc['missing_weekends'])} missing) and {gaps_txt}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

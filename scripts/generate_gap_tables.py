#!/usr/bin/env python3
"""Regenerate the per-market weekend-gap scenario tables used by Pricer.sol / pricer/src/lib.rs.

Source: api.nasdaq.com daily historical bars (same endpoint and method already used for
spikes/stylus-pricer/nvda_gaps.json). Free, no key, documented and re-runnable.

Method (identical to nvda_gaps.json's own "method" field): for every Friday close, find the
next trading day's open (Monday, or later if Monday is a holiday) and compute
gap_bps = round((next_open - friday_close) / friday_close * 10000).

Usage:
    python3 scripts/generate_gap_tables.py                 # AAPL, SPY, TSLA, NVDA, default 10y window
    python3 scripts/generate_gap_tables.py --tickers AAPL SPY
    python3 scripts/generate_gap_tables.py --fromdate 2016-09-26 --todate 2026-09-26

Writes evidence/gap-tables/<TICKER>.json (full detail, same schema as nvda_gaps.json) and
evidence/gap-tables/<TICKER>.gaps.txt (bare comma-separated bps list, for pasting into
Pricer.sol / lib.rs).
"""
import argparse
import json
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
ASSETCLASS = {"SPY": "etf"}  # SPY is an ETF on this endpoint; everything else is "stocks"


def fetch(ticker: str, fromdate: str, todate: str) -> list[dict]:
    assetclass = ASSETCLASS.get(ticker, "stocks")
    url = (
        f"https://api.nasdaq.com/api/quote/{ticker}/historical"
        f"?assetclass={assetclass}&fromdate={fromdate}&todate={todate}&limit=9999"
    )
    req = urllib.request.Request(url, headers={"accept": "application/json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.load(resp)
    rows = payload["data"]["tradesTable"]["rows"]
    out = []
    for r in rows:
        out.append(
            {
                "date": datetime.strptime(r["date"], "%m/%d/%Y").date(),
                "close": float(r["close"].replace("$", "").replace(",", "")),
                "open": float(r["open"].replace("$", "").replace(",", "")),
            }
        )
    out.sort(key=lambda x: x["date"])
    return out


def weekend_gaps(rows: list[dict]) -> list[dict]:
    """For each Friday close, pair with the next trading day's open (skips holiday Mondays
    automatically since it walks the actual trading-day sequence, not the calendar)."""
    gaps = []
    for i in range(len(rows) - 1):
        d = rows[i]["date"]
        if d.weekday() != 4:  # 4 == Friday
            continue
        nxt = rows[i + 1]
        # Only treat this as a weekend gap if the next session is Sat/Sun-adjacent (i.e. not
        # another trading day inside the same week, which would mean this "Friday" row was
        # actually a short week's last session before a midweek gap we don't want to count).
        if nxt["date"] <= d + timedelta(days=0):
            continue
        if nxt["date"].weekday() not in (0, 1, 2):  # Mon/Tue/Wed (Tue/Wed after a long weekend)
            continue
        fc, mo = rows[i]["close"], nxt["open"]
        if fc <= 0:
            continue
        gap_bps = round((mo - fc) / fc * 10000)
        gaps.append(
            {
                "friday": d.isoformat(),
                "monday": nxt["date"].isoformat(),
                "friday_close": fc,
                "monday_open": mo,
                "gap_bps": gap_bps,
            }
        )
    return gaps


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tickers", nargs="+", default=["NVDA", "AAPL", "SPY", "TSLA"])
    ap.add_argument("--fromdate", default="2016-09-26")
    ap.add_argument("--todate", default="2026-09-26")
    ap.add_argument("--out", default="evidence/gap-tables")
    args = ap.parse_args()

    for ticker in args.tickers:
        assetclass = ASSETCLASS.get(ticker, "stocks")
        rows = fetch(ticker, args.fromdate, args.todate)
        gaps = weekend_gaps(rows)
        source = (
            f"https://api.nasdaq.com/api/quote/{ticker}/historical?assetclass={assetclass}"
            f"&fromdate={args.fromdate}&todate={args.todate}&limit=9999"
        )
        doc = {
            "ticker": ticker,
            "fetch_date": datetime.now(timezone.utc).date().isoformat(),
            "source": source,
            "method": (
                "gap_bps = round((next_open - friday_close) / friday_close * 10000); Friday "
                "last close to next trading day open (Monday, or later on a holiday Monday)"
            ),
            "count": len(gaps),
            "gaps": gaps,
        }
        import os

        os.makedirs(args.out, exist_ok=True)
        with open(f"{args.out}/{ticker}.json", "w") as f:
            json.dump(doc, f, indent=2)
        with open(f"{args.out}/{ticker}.gaps.txt", "w") as f:
            f.write(",".join(str(g["gap_bps"]) for g in gaps))
        print(f"{ticker}: {len(gaps)} weekend gaps written to {args.out}/{ticker}.json", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

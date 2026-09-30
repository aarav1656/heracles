#!/usr/bin/env python3
"""Step-4 summary for a gap table: worst weekend, count past 1% and 4%, and
what a layer sized to a given net USD exposure would have paid across all
weekends at a few retention/limit choices.

Payoff (same shape as Heracles' first-loss/senior tranches):
    loss_usd(weekend)  = exposure_usd * max(0, -gap_bps) / 10000
        (net exposure here is long, so only a DOWN gap produces a loss;
         flip the sign if the book being covered is net short)
    payout(weekend)    = min(limit, max(0, loss_usd - retention))

Usage:
    python3 scripts/summarize_gap_tables.py evidence/gap-tables/XAU.json 1888745.54
    python3 scripts/summarize_gap_tables.py evidence/gap-tables/EUR.json 2107976.02
"""
import json
import sys


def main() -> int:
    path, exposure = sys.argv[1], float(sys.argv[2])
    doc = json.load(open(path))
    gaps = doc["gaps"]
    n = len(gaps)

    worst = min(gaps, key=lambda g: g["gap_bps"])
    over_1pct = sum(1 for g in gaps if abs(g["gap_bps"]) > 100)
    over_4pct = sum(1 for g in gaps if abs(g["gap_bps"]) > 400)

    print(f"{doc['ticker']}: {n} weekends")
    print(f"worst: {worst['friday']} -> {worst['monday']}, {worst['gap_bps']} bps "
          f"({worst['friday_close']} -> {worst['monday_open']})")
    print(f"weekends past 1% abs gap: {over_1pct} ({over_1pct/n*100:.1f}%)")
    print(f"weekends past 4% abs gap: {over_4pct} ({over_4pct/n*100:.1f}%)")
    print(f"exposure modeled: ${exposure:,.2f} (net long)")

    choices = [
        (0.0, exposure * 0.05),
        (exposure * 0.01, exposure * 0.10),
        (exposure * 0.02, exposure * 0.20),
    ]
    print("\nretention / limit -> total payout across all weekends, weekends that pay, worst single payout")
    for retention, limit in choices:
        total = 0.0
        paying = 0
        worst_payout = 0.0
        for g in gaps:
            loss = exposure * max(0.0, -g["gap_bps"]) / 10000.0
            payout = min(limit, max(0.0, loss - retention))
            if payout > 0:
                paying += 1
                total += payout
                worst_payout = max(worst_payout, payout)
        print(f"retention ${retention:,.2f} / limit ${limit:,.2f} -> "
              f"total ${total:,.2f} over {n} weekends, {paying} paying, worst single ${worst_payout:,.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

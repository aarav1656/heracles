#!/usr/bin/env python3
"""Fair premium of a weekend layer on the EUR/USD and XAU/USD tables, computed from
evidence/gap-tables/{EUR,XAU}.gaps.txt alone, with no code shared with the Rust or Solidity pricer.

Two computations per layer, both at the 1.0x volatility scale (the pricer's floor; `integer` takes any scale):
  exact   Decimal arithmetic with no rounding until the last step.
  integer the pricer's own semantics: every division truncates toward zero, bps in hundredths.
The two must agree to a few micro-USDG; the integer figures are what the Rust tests assert and what
the on-chain pricer returns at a 1.0x scale.

  python3 scripts/fx_gold_fair_premium.py            print the table
  python3 scripts/fx_gold_fair_premium.py --check    also assert the exact and integer figures agree
"""
import sys
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec = 60
GAPS = Path(__file__).resolve().parent.parent / "evidence" / "gap-tables"
TAIL, RISK_LOAD, CAPITAL, LOCK_DAYS, DAYS_YEAR = 25, Decimal("0.03"), Decimal("0.04"), 7, 365

# exposure and money in USDG micro-units (6dp); positive exposure is long (loses on a down gap).
LAYERS = [
    ("EUR/USD long 2,000,000", "EUR", 2_000_000 * 10**6, 2_000 * 10**6, 20_000 * 10**6),
    ("EUR/USD short 2,000,000", "EUR", -2_000_000 * 10**6, 2_000 * 10**6, 20_000 * 10**6),
    ("XAU/USD long 1,000,000", "XAU", 1_000_000 * 10**6, 5_000 * 10**6, 30_000 * 10**6),
    ("XAU/USD short 1,000,000", "XAU", -1_000_000 * 10**6, 5_000 * 10**6, 30_000 * 10**6),
]


def centibps(name):
    out = []
    for tok in (GAPS / f"{name}.gaps.txt").read_text().split():
        d = Decimal(tok) * 100
        assert d == d.to_integral_value(), f"{name}: {tok} has more than two decimals"
        out.append(int(d))
    assert len(out) == 504, f"{name}: {len(out)} rows"
    return out


def trunc_div(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def exact(table, exposure, retention, limit):
    payouts = []
    for g in table:
        loss = max(Decimal(0), -(Decimal(exposure) * Decimal(g) / Decimal(10**6)))
        payouts.append(min(Decimal(limit), max(Decimal(0), loss - retention)))
    el = sum(payouts) / 504
    tvar = sum(sorted(payouts, reverse=True)[:TAIL]) / TAIL
    prem = el + RISK_LOAD * (tvar - el) + CAPITAL * limit * LOCK_DAYS / DAYS_YEAR
    return prem, el, tvar


def integer(table, exposure, retention, limit, scale=10**6):
    payouts = []
    for g in table:
        pnl = trunc_div(exposure * trunc_div(g * scale, 10**6), 10_000 * 100)
        loss = -pnl if pnl < 0 else 0
        payouts.append(min(limit, max(0, loss - retention)))
    el = sum(payouts) // 504
    tvar = sum(sorted(payouts, reverse=True)[:TAIL]) // TAIL
    prem = el + trunc_div((tvar - el) * 30_000, 10**6) + trunc_div(limit * 40_000 * LOCK_DAYS, DAYS_YEAR * 10**6)
    return prem, el, tvar


if __name__ == "__main__":
    tables = {n: centibps(n) for n in ("EUR", "XAU")}
    for label, name, e, r, l in LAYERS:
        ex, it = exact(tables[name], e, r, l), integer(tables[name], e, r, l)
        print(f"{label}, retention {r/10**6:,.0f}, limit {l/10**6:,.0f}")
        print(f"  integer premium={it[0]} el={it[1]} tvar95={it[2]}   (USDG {it[0]/1e6:,.6f} / {it[1]/1e6:,.6f} / {it[2]/1e6:,.6f})")
        print(f"  exact   premium={ex[0]:.3f} el={ex[1]:.3f} tvar95={ex[2]:.3f}")
        if "--check" in sys.argv:
            assert all(abs(Decimal(a) - b) < 4 for a, b in zip(it, ex)), "integer and exact figures diverge"

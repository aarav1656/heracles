#!/usr/bin/env python3
"""Mutation pass over the six-table pricer change (commit 3d732df): Pricer.sol and pricer/core.

Each mutant replaces one exact string, runs the suites that guard it, and is KILLED when any of
them fails. A mutant whose string is missing aborts the run, so a stale mutant cannot pass as
killed. The file is restored after every mutant and the clean suites run first and last.

  python3 scripts/mutate_six_tables.py            # every mutant
  python3 scripts/mutate_six_tables.py R6 S3      # a subset by id
Writes evidence/mutation/six-tables.json.
"""
import json, os, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOL = ROOT / "contracts/src/Pricer.sol"
CORE = ROOT / "pricer/core/src/lib.rs"
ENV = {**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1", "FOUNDRY_SPARSE_MODE": "true", "FOUNDRY_FUZZ_RUNS": "64"}

FORGE = ["nice", "forge", "test", "--match-path", "test/Pricer*.t.sol", "-j", "2"]
CARGO_CORE = ["nice", "cargo", "test", "--manifest-path", "pricer/core/Cargo.toml", "-j", "2", "-q"]
CARGO_STYLUS = ["nice", "cargo", "test", "--manifest-path", "pricer/Cargo.toml", "-j", "2", "-q"]
SUITES = {
    "forge": (FORGE, ROOT / "contracts"),
    "core": (CARGO_CORE, ROOT),
    "stylus": (CARGO_STYLUS, ROOT),
}

# id, file, original, mutant, what it breaks, suites that must catch it
MUTANTS = [
    ("S1", SOL, "if (tableIds[i] > 5) revert BadTableId();", "if (tableIds[i] > 4) revert BadTableId();", "gold table id rejected at deploy", ["forge"]),
    ("S2", SOL, "if (tableIds[i] > 5) revert BadTableId();", "if (tableIds[i] > 6) revert BadTableId();", "table id 6 accepted, priced on a fallback table", ["forge"]),
    ("S3", SOL, "if (id == 4) return gapsEUR;", "if (id == 4) return gapsXAU;", "EUR/USD priced on the gold table", ["forge"]),
    ("S4", SOL, "if (id == 5) return gapsXAU;", "if (id == 5) return gapsEUR;", "gold priced on the EUR/USD table", ["forge"]),
    ("S5", SOL, "return tableIdAt(i) >= 4 ? FX_UNIT : int256(1);", "return tableIdAt(i) >= 5 ? FX_UNIT : int256(1);", "EUR/USD gaps read as whole bps, 100x too large", ["forge"]),
    ("S6", SOL, "return tableIdAt(i) >= 4 ? FX_UNIT : int256(1);", "return tableIdAt(i) == 4 ? FX_UNIT : int256(1);", "gold gaps read as whole bps, 100x too large", ["forge"]),
    ("S7", SOL, "return tableIdAt(i) >= 4 ? FX_UNIT : int256(1);", "return tableIdAt(i) >= 3 ? FX_UNIT : int256(1);", "TSLA gaps divided by 100", ["forge"]),
    ("S8", SOL, "int256 internal constant FX_UNIT = 100;", "int256 internal constant FX_UNIT = 10;", "FX unit off by 10x", ["forge"]),
    ("S9", SOL, "int256 pnl = (exposure[i] * gap) / (BPS * _unitFor(i));", "int256 pnl = (exposure[i] * gap) / BPS;", "unit dropped from the loss division", ["forge"]),
    ("R1", CORE, "4 => (EUR_GAPS[s] as i128, FX_UNIT),", "4 => (XAU_GAPS[s] as i128, FX_UNIT),", "EUR/USD priced on the gold table", ["core"]),
    ("R2", CORE, "5 => (XAU_GAPS[s] as i128, FX_UNIT),", "5 => (EUR_GAPS[s] as i128, FX_UNIT),", "gold priced on the EUR/USD table", ["core"]),
    ("R3", CORE, "4 => (EUR_GAPS[s] as i128, FX_UNIT),", "4 => (EUR_GAPS[s] as i128, 1),", "EUR/USD gaps read as whole bps", ["core"]),
    ("R4", CORE, "5 => (XAU_GAPS[s] as i128, FX_UNIT),", "5 => (XAU_GAPS[s] as i128, 1),", "gold gaps read as whole bps", ["core"]),
    ("R5", CORE, "3 => (TSLA_GAPS[s] as i128, 1),", "3 => (TSLA_GAPS[s] as i128, FX_UNIT),", "TSLA gaps divided by 100", ["core"]),
    ("R6", CORE, "pub const FX_UNIT: i128 = 100;", "pub const FX_UNIT: i128 = 10;", "FX unit off by 10x", ["core"]),
    ("R7", CORE, "pub const MAX_TABLE_ID: u8 = 5;", "pub const MAX_TABLE_ID: u8 = 6;", "table id 6 accepted, priced on NVDA", ["core", "stylus"]),
    ("R8", CORE, "pub const MAX_TABLE_ID: u8 = 5;", "pub const MAX_TABLE_ID: u8 = 4;", "gold table id rejected", ["core", "stylus"]),
    ("R9", CORE, ".checked_div(bps.checked_mul(c(unit)).ok_or_else(overflow)?)", ".checked_div(bps)", "unit dropped from the loss division", ["core"]),
]


def run(suite):
    cmd, cwd = SUITES[suite]
    t = time.time()
    p = subprocess.run(cmd, cwd=cwd, env=ENV, capture_output=True, text=True)
    out = p.stdout + p.stderr
    failed = [l.strip() for l in out.splitlines() if "[FAIL" in l or l.strip().startswith("test ") and "FAILED" in l or "panicked" in l]
    return p.returncode == 0, round(time.time() - t, 1), failed[:4]


def main():
    want = set(sys.argv[1:])
    chosen = [m for m in MUTANTS if not want or m[0] in want]
    suites = sorted({s for m in chosen for s in m[5]})
    for s in suites:
        ok, secs, _ = run(s)
        print(f"clean {s}: {'PASS' if ok else 'FAIL'} ({secs}s)", flush=True)
        if not ok:
            sys.exit(f"clean {s} suite fails before any mutant; fix that first")
    rows = []
    for mid, path, orig, mut, what, guard in chosen:
        src = path.read_text()
        if src.count(orig) != 1:
            sys.exit(f"{mid}: expected exactly one '{orig}' in {path.name}, found {src.count(orig)}")
        try:
            path.write_text(src.replace(orig, mut))
            results = {s: run(s) for s in guard}
        finally:
            path.write_text(src)
        killed = [s for s, (ok, _, _) in results.items() if not ok]
        row = {"id": mid, "file": str(path.relative_to(ROOT)), "mutant": mut, "breaks": what,
               "verdict": "KILLED" if killed else "SURVIVED", "killedBy": killed,
               "failing": {s: r[2] for s, r in results.items() if not r[0]}, "seconds": {s: r[1] for s, r in results.items()}}
        rows.append(row)
        print(f"{mid} {row['verdict']:8} {what} :: {killed} {row['failing']}", flush=True)
    for s in suites:
        ok, secs, _ = run(s)
        print(f"restored {s}: {'PASS' if ok else 'FAIL'} ({secs}s)", flush=True)
    out = ROOT / "evidence/mutation/six-tables.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"commit": "3d732df", "mutants": rows}, indent=2) + "\n")
    survivors = [r["id"] for r in rows if r["verdict"] == "SURVIVED"]
    print(f"{len(rows) - len(survivors)}/{len(rows)} killed; survivors: {survivors or 'none'}")
    sys.exit(1 if survivors else 0)


if __name__ == "__main__":
    main()

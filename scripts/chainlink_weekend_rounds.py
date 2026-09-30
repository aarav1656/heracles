#!/usr/bin/env python3
"""Binary-search a Chainlink AggregatorV3 feed's round history to find, for a
set of target UTC timestamps, the last round at or before / first round at or
after that instant. Used to measure real weekend round behaviour (last round
before Friday 16:00 ET close, first round after Monday 9:30 ET reopen) ahead
of building the Heracles gap tables.

Chainlink round ids on Arbitrum are phase-aware: roundId = (phase << 64) | aggRound.
Timestamps are monotonic non-decreasing in aggRound within a phase, so plain
binary search works.
"""
import json
import subprocess
import sys

RPC = "https://arb1.arbitrum.io/rpc"
PHASE_SHIFT = 1 << 64


def get_round(addr: str, round_id: int, block: int) -> dict:
    out = subprocess.run(
        [
            "cast", "call", addr,
            "getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)",
            str(round_id), "--rpc-url", RPC, "--block", str(block),
        ],
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    vals = [l.split()[0].replace(",", "") for l in out if l.strip()]
    rid, answer, started_at, updated_at, answered_in_round = (int(v) for v in vals[:5])
    return {"roundId": rid, "answer": answer, "startedAt": started_at, "updatedAt": updated_at, "answeredInRound": answered_in_round}


def last_before_and_first_after(addr: str, phase: int, lo: int, hi: int, target_ts: int, block: int):
    """lo, hi are aggRound bounds (inclusive) known to exist. Returns
    (last_round_before_or_at, first_round_after)."""
    best_before = None
    best_after = None
    a, b = lo, hi
    while a <= b:
        mid = (a + b) // 2
        r = get_round(addr, PHASE_SHIFT * phase + mid, block)
        if r["updatedAt"] <= target_ts:
            best_before = r
            a = mid + 1
        else:
            best_after = r
            b = mid - 1
    return best_before, best_after


def main() -> int:
    cfg = json.load(open(sys.argv[1]))
    block = cfg["block"]
    results = {}
    for feed in cfg["feeds"]:
        name = feed["name"]
        addr = feed["address"]
        phase = feed["phase"]
        lo = feed["lo"]
        hi = feed["hi"]
        results[name] = {"address": addr, "phase": phase, "targets": {}}
        for label, ts in cfg["targets"]:
            before, after = last_before_and_first_after(addr, phase, lo, hi, ts, block)
            results[name]["targets"][label] = {
                "target_ts": ts,
                "last_before_or_at": before,
                "first_after": after,
            }
            print(f"{name} {label} target={ts}")
            print(f"  last_before_or_at: {before}")
            print(f"  first_after:       {after}")
    with open(cfg["out"], "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nwrote {cfg['out']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

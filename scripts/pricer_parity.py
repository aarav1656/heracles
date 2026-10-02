#!/usr/bin/env python3
"""Output parity of the six-table Stylus pricer deployed on two chains: Arbitrum Sepolia
(0x1674...7e37) and Robinhood Chain testnet (0x0114...a49b), same bytecode build, table ids 0-5.

The pricer reads one Chainlink-shaped feed per market for its volatility scale, and the two chains
carry different feeds, so every call puts the same feed on both: an eth_call state override places
the MockFeed runtime (contracts/test/mocks/MockFeed.sol) at one address with the same nine rounds.
Two feeds: a flat one (scale floors at 1.0x, so the result is the table alone and must equal the
figures scripts/fx_gold_fair_premium.py computes from the evidence files) and one that moves 1.5%
a round (scale above 1.0x, exercising the volatility path). Each case asserts identical
(premium, el, tvar95) on both chains.

Usage: python3 scripts/pricer_parity.py [--out evidence/parity/rh-testnet.json]
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from replay_weekend import cast, rpc, words  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CHAINS = {
    "Arbitrum Sepolia (421614)": ("https://sepolia-rollup.arbitrum.io/rpc", "0x1674ecf8d236a91c484c11fd11a21601837f7e37"),
    "Robinhood Chain testnet (46630)": ("https://robinhood-sepolia-rpc.publicnode.com", "0x01143a467990d06b6481c3d7bef95ad25c36a49b"),
}
FEED = "0x00000000000000000000000000000000000fEed1"
FEED_CODE = json.loads((ROOT / "contracts/out/MockFeed.sol/MockFeed.json").read_text())["deployedBytecode"]["object"]
U = 10**6
# label, exposure in table order (NVDA, AAPL, SPY, TSLA, EUR, XAU), retention, limit, python figures at 1.0x
CASES = [
    ("EUR/USD long 2,000,000", [0, 0, 0, 0, 2_000_000 * U, 0], 2_000 * U, 20_000 * U, (1_977_298_772, 1_648_960_317, 12_082_160_000)),
    ("XAU/USD long 1,000,000", [0, 0, 0, 0, 0, 1_000_000 * U], 5_000 * U, 30_000 * U, (1_635_305_987, 1_173_676_587, 15_794_200_000)),
    ("TSLA long 500,000", [0, 0, 0, 500_000 * U, 0, 0], 5_000 * U, 30_000 * U, (2_398_667_943, 1_847_519_841, 19_452_000_000)),
    ("gUSDC book, 2026-09-25 close", [-24_151 * U, 1_569 * U, 152_232 * U, 0, -2_282 * U, 36_071 * U], 500 * U, 4_000 * U, None),
    ("NVDA short 1,000,000, SPY long 1,000,000", [-1_000_000 * U, 0, 1_000_000 * U, 0, 0, 0], 20_000 * U, 200_000 * U, None),
]


def slot(key, base):
    return cast("index", "uint80", str(key), str(base))


def feed_state(prices, now):
    diff = {"0x" + format(1, "064x"): "0x" + format(len(prices), "064x")}  # latestId
    for i, p in enumerate(prices, start=1):
        s = int(slot(i, 0), 16)
        diff["0x" + format(s, "064x")] = "0x" + format(p, "064x")
        diff["0x" + format(s + 1, "064x")] = "0x" + format(now - (len(prices) - i) * 3600, "064x")
    return {FEED: {"code": FEED_CODE, "stateDiff": diff}}


def quote(url, pricer, exposure, retention, limit, override):
    data = cast("calldata", "quote(int256[],address[],uint256,uint256)", "[" + ",".join(map(str, exposure)) + "]",
                "[" + ",".join([FEED] * 6) + "]", str(retention), str(limit))
    return tuple(words(rpc(url, "eth_call", [{"to": pricer, "data": data}, "latest", override])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="evidence/parity/rh-testnet.json")
    a = ap.parse_args()
    now = int(rpc(CHAINS["Arbitrum Sepolia (421614)"][0], "eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
    feeds = {"flat": [500_00000000] * 9, "moving 1.5% a round": [int(500e8 * (1.015 if i % 2 else 0.985)) for i in range(9)]}
    rows, ok = [], True
    for fname, prices in feeds.items():
        ov = feed_state(prices, now)
        for label, exp, ret, lim, py in CASES:
            out = {c: quote(url, p, exp, ret, lim, ov) for c, (url, p) in CHAINS.items()}
            vals = list(out.values())
            same = vals[0] == vals[1]
            matches_py = py is None or fname != "flat" or vals[0] == py
            ok &= same and matches_py
            rows.append({"feed": fname, "case": label, "results": {c: list(v) for c, v in out.items()}, "identical": same,
                         "python": list(py) if py and fname == "flat" else None, "matchesPython": matches_py if py and fname == "flat" else None})
            print(f"{'OK ' if same and matches_py else 'BAD'} {fname:20} {label:40} premium {vals[0][0]/U:>12,.6f} el {vals[0][1]/U:>12,.6f} "
                  f"tvar95 {vals[0][2]/U:>14,.6f}  {'identical' if same else 'DIFFER ' + str(vals)}" + (" = python" if py and fname == 'flat' and vals[0] == py else ""))
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps({"chains": {c: {"rpc": u, "pricer": p} for c, (u, p) in CHAINS.items()}, "feed": FEED,
                                       "feedCode": "contracts/test/mocks/MockFeed.sol runtime", "cases": rows, "allIdentical": ok}, indent=2) + "\n")
    print(f"{'ALL IDENTICAL' if ok else 'MISMATCH'}; wrote {a.out}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

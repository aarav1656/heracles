#!/usr/bin/env python3
"""Stylus pricer vs its Solidity twin, gas of one quote() call at 1, 4 and 8 markets.

Both contracts are the live Arbitrum Sepolia deployments (README "Deployed"). Each holds one
configured market on chain, so the per-market table ids are set inside the call with an
eth_estimateGas / eth_call state override of the contract's own table-id storage (Stylus: slot 0,
a Solidity-layout `bytes`; twin: slot 252, a `uint8[]`). Same bytecode, same formula, same feeds.

Gas = eth_estimateGas at one pinned block. The L1 component is NodeInterface
gasEstimateL1Component for the same calldata (it prices the data posted to L1 and executes no
target code, so it ignores overrides); L2 execution gas = total - L1 component, the same split
docs/pricing.md uses for the single-market figure.

Usage: python3 scripts/measure_pricer_gas.py [--rpc URL] [--out evidence/gas/pricer-multimarket.json]
"""
import argparse
import json
import subprocess
import urllib.request

STYLUS = "0xbe99217180a5fcb83372375b0928c971dfa71f88"
TWIN = "0x6aAf1b58939d55d1142a34aE02903bB788E9e771"
NODE_INTERFACE = "0x00000000000000000000000000000000000000C8"
TWIN_IDS_SLOT = 252  # forge inspect src/Pricer.sol:Pricer storageLayout: marketTableIds
FEEDS = [  # Arbitrum Sepolia Chainlink proxies, distinct so every market pays a cold feed read
    ("SPY/USD", "0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06"),
    ("LINK/USD", "0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298"),
    ("DAI/USD", "0xb113F5A928BCfF189C998ab20d753a47F9dE5A61"),
    ("ARB/USD", "0xD1092a65338d049DB68D7Be6bD89d17a0929945e"),
    ("UNI/USD", "0x850A128C3f67C3D13B58a88AC2f4742D90705c0a"),
    ("AVAX/USD", "0xe27498c9Cc8541033F265E63c8C29A97CfF9aC6D"),
    ("LTC/USD", "0x474c723Cd790F02BaAffA10A50fb506F8B29856b"),
    ("BNB/USD", "0x53ab995fBb01C617aa1256698aD55b417168bfF9"),
]
TABLE_IDS = [2, 0, 1, 3, 2, 0, 1, 3]  # SPY, NVDA, AAPL, TSLA, repeated
EXPOSURE = [2_000_000, -1_000_000, 500_000, -250_000, 1_500_000, -750_000, 400_000, -300_000]  # USDG
RETENTION, LIMIT = 20_000 * 10**6, 60_000 * 10**6
SIG = "quote(int256[],address[],uint256,uint256)"


def cast(*a):
    return subprocess.run(["cast", *a], capture_output=True, text=True, check=True,
                          env={"FOUNDRY_DISABLE_NIGHTLY_WARNING": "1", "PATH": "/usr/bin:/bin:" + subprocess.os.environ["PATH"]}).stdout.strip()


def rpc(url, method, params):
    req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 {"content-type": "application/json", "user-agent": "heracles-gas/1"})
    r = json.load(urllib.request.urlopen(req, timeout=60))
    if "error" in r:
        raise RuntimeError(f"{method}: {r['error']}")
    return r["result"]


def word(n):
    return "0x" + format(n, "064x")


def pack_ids(ids):
    return "0x" + format(sum(i << (8 * k) for k, i in enumerate(ids)), "064x")


def overrides(n):
    stylus_slot0 = "0x" + (bytes(TABLE_IDS[:n]).hex() + "00" * 31)[:62] + format(2 * n, "02x")
    twin_data = cast("keccak", word(TWIN_IDS_SLOT))
    return {
        STYLUS: {"stateDiff": {word(0): stylus_slot0}},
        TWIN: {"stateDiff": {word(TWIN_IDS_SLOT): word(n), twin_data: pack_ids(TABLE_IDS[:n])}},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default="https://sepolia-rollup.arbitrum.io/rpc")
    ap.add_argument("--out", default="evidence/gas/pricer-multimarket.json")
    a = ap.parse_args()
    block = int(rpc(a.rpc, "eth_blockNumber", []), 16)
    tag = hex(block)
    for name, f in FEEDS:  # every feed must be live with history, or the vol-scale path short-circuits
        rid, ans, *_ = (int(x.split()[0]) for x in cast("call", f, "latestRoundData()(uint80,int256,uint256,uint256,uint80)", "--rpc-url", a.rpc, "--block", str(block)).splitlines())
        assert ans > 0 and rid > 8, (name, rid, ans)

    rows = []
    for n in (1, 4, 8):
        data = cast("calldata", SIG, "[" + ",".join(str(e * 10**6) for e in EXPOSURE[:n]) + "]",
                    "[" + ",".join(f for _, f in FEEDS[:n]) + "]", str(RETENTION), str(LIMIT))
        ov = overrides(n)
        res = {}
        for label, addr in (("stylus", STYLUS), ("solidity", TWIN)):
            if n > 1:  # the override is what makes the call possible: on chain each contract holds one market
                try:
                    rpc(a.rpc, "eth_call", [{"to": addr, "data": data}, tag])
                    raise SystemExit(f"{label} priced {n} markets without the override; the method measures the wrong thing")
                except RuntimeError as e:
                    assert "execution reverted" in str(e), e
            out = rpc(a.rpc, "eth_call", [{"to": addr, "data": data}, tag, {addr: ov[addr]}])
            total = int(rpc(a.rpc, "eth_estimateGas", [{"to": addr, "data": data}, tag, {addr: ov[addr]}]), 16)
            l1 = int(cast("call", NODE_INTERFACE, "gasEstimateL1Component(address,bool,bytes)(uint64,uint256,uint256)", addr, "false", data,
                          "--rpc-url", a.rpc, "--block", str(block)).splitlines()[0].split()[0])
            res[label] = {"output": out, "total": total, "l1": l1, "l2": total - l1}
        assert res["stylus"]["output"] == res["solidity"]["output"], f"outputs differ at n={n}"
        assert len(res["stylus"]["output"]) == 2 + 3 * 64
        prem, el, tvar = (int(res["stylus"]["output"][2 + 64 * i: 2 + 64 * (i + 1)], 16) for i in range(3))
        rows.append({"markets": n, "premium": prem, "el": el, "tvar95": tvar, **res,
                     "ratioL2": res["solidity"]["l2"] / res["stylus"]["l2"], "ratioTotal": res["solidity"]["total"] / res["stylus"]["total"]})

    doc = {"chainId": 421614, "rpc": a.rpc, "block": block, "stylus": STYLUS, "solidityTwin": TWIN,
           "retention": RETENTION, "limit": LIMIT, "tableIds": TABLE_IDS, "exposureUsdg": EXPOSURE,
           "feeds": [{"name": n, "address": f} for n, f in FEEDS], "rows": rows}
    json.dump(doc, open(a.out, "w"), indent=2)
    print(f"block {block}")
    print("| markets | Stylus L2 gas | Solidity L2 gas | ratio | Stylus total | Solidity total | ratio |")
    for r in rows:
        s, t = r["stylus"], r["solidity"]
        print(f"| {r['markets']} | {s['l2']:,} | {t['l2']:,} | {r['ratioL2']:.2f}x | {s['total']:,} | {t['total']:,} | {r['ratioTotal']:.2f}x |")


if __name__ == "__main__":
    main()

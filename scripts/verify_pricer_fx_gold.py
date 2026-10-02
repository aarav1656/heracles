#!/usr/bin/env python3
"""Reads the deployed six-table Stylus pricer on Arbitrum Sepolia and checks its EUR/USD and XAU/USD
quotes against scripts/fx_gold_fair_premium.py, which prices from the .gaps.txt files alone.

The pricer scales every scenario by a volatility factor read from the feed it is handed (Sepolia
carries one live feed, SPY/USD). This script reads the same feed rounds at the same block, derives
the factor with its own implementation, and prices the layer in Python at that factor. Equality is
exact: premium, expected loss and TVaR95 as integers in USDG micro-units.

  python3 scripts/verify_pricer_fx_gold.py [pricer_address]
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fx_gold_fair_premium import centibps, integer  # noqa: E402

RPC = "https://sepolia-rollup.arbitrum.io/rpc"
FEED = "0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06"
ROOT = Path(__file__).resolve().parent.parent
DEFAULT = json.loads((ROOT / "contracts/deployments/421614.json").read_text())["contracts"]["PricerSixTables"]["address"]


def cast(*args):
    return subprocess.run(["cast", *args, "--rpc-url", RPC], check=True, capture_output=True, text=True,
                          env={"FOUNDRY_DISABLE_NIGHTLY_WARNING": "1", "PATH": "/Users/kamal/.foundry/bin:/usr/bin:/bin"}).stdout.splitlines()


def feed_round(block, rid=None):
    out = cast("call", FEED, "latestRoundData()(uint80,int256,uint256,uint256,uint80)" if rid is None
               else "getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)", *([] if rid is None else [str(rid)]), "--block", str(block))
    return int(out[0].split()[0]), int(out[1].split()[0])


def vol_scale(block):
    latest, answer = feed_round(block)
    prev, total, n = answer, 0, 0
    for k in range(1, 9):
        _, a = feed_round(block, latest - k)
        total += abs(prev - a) * 10_000 // prev
        prev, n = a, n + 1
    return min(3_000_000, max(1_000_000, (total // n) * 1_000_000 // 50))


def quote(pricer, block, slot, exposure, retention, limit):
    exp = ",".join(str(exposure if i == slot else 0) for i in range(slot + 1))
    feeds = ",".join([FEED] * (slot + 1))
    out = cast("call", pricer, "quote(int256[],address[],uint256,uint256)(uint256,uint256,uint256)",
               f"[{exp}]", f"[{feeds}]", str(retention), str(limit), "--block", str(block))
    return tuple(int(x.split()[0]) for x in out)


if __name__ == "__main__":
    pricer = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    block = int(cast("block-number")[0])
    scale = vol_scale(block)
    print(f"pricer {pricer} block {block} volatility scale {scale} ppm")
    ids = [int(cast("call", pricer, "tableIdAt(uint256)(uint8)", str(i), "--block", str(block))[0]) for i in range(6)]
    assert ids == [0, 1, 2, 3, 4, 5], ids
    cases = [("EUR/USD long 2,000,000", "EUR", 4, 2_000_000, 2_000, 20_000), ("EUR/USD short 2,000,000", "EUR", 4, -2_000_000, 2_000, 20_000),
             ("XAU/USD long 1,000,000", "XAU", 5, 1_000_000, 5_000, 30_000), ("XAU/USD short 1,000,000", "XAU", 5, -1_000_000, 5_000, 30_000)]
    tables = {"EUR": centibps("EUR"), "XAU": centibps("XAU")}
    for label, name, slot, e, r, l in cases:
        e, r, l = e * 10**6, r * 10**6, l * 10**6
        chain = quote(pricer, block, slot, e, r, l)
        py = integer(tables[name], e, r, l, scale)
        print(f"{label}: chain premium {chain[0]/1e6:,.6f} el {chain[1]/1e6:,.6f} tvar95 {chain[2]/1e6:,.6f} | python {'MATCH' if chain == py else 'DIFF ' + str(py)}")
        assert chain == py, (label, chain, py)
    print("on-chain FX and gold quotes equal the independent Python prices")

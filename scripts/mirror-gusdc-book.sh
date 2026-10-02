#!/usr/bin/env bash
# Puts the gTrade gUSDC vault's book, as read from Arbitrum One (web/src/data/gains-gusdc-book.json),
# onto a VaultCover on Arbitrum Sepolia one market at a time. Each leg is an `open` the OIGuard
# prices on the live Stylus pricer before VaultCover records it. After every transaction the
# script asserts receipt status 0x1 and that `net()` moved by exactly that leg. Legs already at
# their target are skipped, so a rerun only opens what is missing.
#   PRIVATE_KEY=... scripts/mirror-gusdc-book.sh <vaultCover>
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
C=$1
R=${RPC:-https://sepolia-rollup.arbitrum.io/rpc}
BOOK=$(dirname "$0")/../web/src/data/gains-gusdc-book.json
MARKETS=(NVDA AAPL SPY TSLA EUR XAU) # OIGuard / six-table pricer order
net_at() { cast call "$C" 'net()(int256[])' --rpc-url "$R" --block "$1" --json | jq -r ".[0][$2]"; }

echo "gUSDC book read at Arbitrum One block $(jq .block "$BOOK"); VaultCover $C"
for i in "${!MARKETS[@]}"; do
  t=${MARKETS[$i]}
  # the vault holds the opposite of the traders' net: short minus long, USDC 6dp, whole dollars
  target=$(jq -r --arg t "$t" '.pairs[] | select(.ticker==$t) | ((.shortUsd - .longUsd) | round) * 1000000' "$BOOK")
  before=$(net_at latest "$i")
  delta=$((target - before))
  [ "$delta" = 0 ] && { echo "$t at $target already, skipped"; continue; }
  quote=$(cast call "$C" 'open(uint256,int256)(uint256)' --from "$(cast wallet address --private-key "$PRIVATE_KEY")" --rpc-url "$R" -- "$i" "$delta" | cut -d' ' -f1)
  tx=$(cast send "$C" 'open(uint256,int256)' --private-key "$PRIVATE_KEY" --rpc-url "$R" --json -- "$i" "$delta" | jq -r .transactionHash)
  st=$(cast receipt "$tx" --rpc-url "$R" --json | jq -r .status)
  blk=$(cast receipt "$tx" blockNumber --rpc-url "$R")
  after=$(net_at "$blk" "$i")
  echo "$t open $delta: tx $tx block $blk status $st, guard premium $quote, net $before -> $after"
  [ "$st" = 0x1 ] && [ $((after - before)) -eq "$delta" ] || { echo "FAIL on $t"; exit 1; }
done
echo "book now: $(cast call "$C" 'net()(int256[])' --rpc-url "$R")"
echo "cover exposure (Treaty order): $(cast call "$C" 'coverExposure()(int256[])' --rpc-url "$R")"

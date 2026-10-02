#!/usr/bin/env bash
# Walks one Treaty layer through settlement on Arbitrum Sepolia, each step only once it is due:
#   after Friday's close  setReference with the round in effect at the close (the last round at or
#                         before it), per market
#   after Monday's expiry fix with the first round at or after expiry whose predecessor is
#                         earlier, per market; the last fix settles the layer
#   once settled          claim, when this wallet bought the layer and it paid out
# Every transaction is checked by receipt status 0x1 and a post-condition read, and appended to
# docs/e2e/heracles-settle.log. Rounds are found by walking back from the feed's latest round.
#   PRIVATE_KEY=... scripts/settle-layer.sh <layerId>     (without PRIVATE_KEY it only reports)
set -uo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
ID=$1
R=${RPC:-https://sepolia-rollup.arbitrum.io/rpc}
T=${TREATY:-0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807}
LOG=docs/e2e/heracles-settle.log
first() { awk '{print $1}'; }
say() { echo "$(date -u +%FT%TZ) layer $ID: $*" | tee -a "$LOG"; }
round_at() { cast call "$1" 'getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)' "$2" --rpc-url "$R" 2>/dev/null | sed -n 4p | first; }
send() {
  local tx st
  tx=$(cast send "$T" "$@" --private-key "$PRIVATE_KEY" --rpc-url "$R" --json | jq -r .transactionHash)
  st=$(cast receipt "$tx" --rpc-url "$R" --json | jq -r .status)
  echo "$tx $st"
}

L=$(cast call $T 'layers(uint256)(address,uint40,uint40,uint16,uint8,uint8,uint8,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)' "$ID" --rpc-url "$R")
BUYER=$(echo "$L" | sed -n 1p); CUTOFF=$(echo "$L" | sed -n 2p | first); EXPIRY=$(echo "$L" | sed -n 3p | first); STATE=$(echo "$L" | sed -n 7p | first)
CLOSE=$(cast call $T 'fridayCloseOf(uint256)(uint256)' "$CUTOFF" --rpc-url "$R" | first)
N=$(cast call $T 'marketsLength()(uint256)' --rpc-url "$R" | first)
NOW=$(cast block latest -f timestamp --rpc-url "$R")
say "state $STATE (1 Bound, 2 Settled, 3 Cancelled), close $(date -u -r "$CLOSE" +%FT%TZ), expiry $(date -u -r "$EXPIRY" +%FT%TZ), chain time $(date -u -r "$NOW" +%FT%TZ)"
ME=${PRIVATE_KEY:+$(cast wallet address --private-key "$PRIVATE_KEY")}

for ((m = 0; m < N; m++)); do
  FEED=$(cast call $T 'markets(uint256)(address)' "$m" --rpc-url "$R")
  LATEST=$(cast call "$FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$R" | sed -n 1p | first)
  if [ "$STATE" = 1 ] && [ "$(cast call $T 'referenceSet(uint256,uint256)(bool)' "$ID" "$m" --rpc-url "$R")" = false ]; then
    if [ "$NOW" -le "$CLOSE" ]; then say "market $m: reference opens after the close"; continue; fi
    r=$LATEST; u=$(round_at "$FEED" "$r")
    while [ -n "$u" ] && [ "$u" -gt "$CLOSE" ]; do r=$((r - 1)); u=$(round_at "$FEED" "$r"); done
    say "market $m: round in effect at close $r (updatedAt $(date -u -r "$u" +%FT%TZ))"
    [ -n "$ME" ] || continue
    read -r tx st < <(send 'setReference(uint256,uint256,uint80)' "$ID" "$m" "$r")
    say "market $m: setReference tx $tx status $st, referenceSet $(cast call $T 'referenceSet(uint256,uint256)(bool)' "$ID" "$m" --rpc-url "$R"), fridayPrice $(cast call $T 'fridayPrice(uint256,uint256)(uint64)' "$ID" "$m" --rpc-url "$R" | first)"
    [ "$st" = 0x1 ] || exit 1
  fi
  if [ "$STATE" = 1 ] && [ "$(cast call $T 'marketFixed(uint256,uint256)(bool)' "$ID" "$m" --rpc-url "$R")" = false ]; then
    if [ "$NOW" -lt "$EXPIRY" ]; then say "market $m: fix opens at expiry"; continue; fi
    r=$LATEST; u=$(round_at "$FEED" "$r")
    [ "$u" -ge "$EXPIRY" ] || { say "market $m: no round at or after expiry yet"; continue; }
    p=$(round_at "$FEED" $((r - 1)))
    while [ -n "$p" ] && [ "$p" -ge "$EXPIRY" ]; do r=$((r - 1)); p=$(round_at "$FEED" $((r - 1))); done
    say "market $m: first round at or after expiry $r"
    [ -n "$ME" ] || continue
    read -r tx st < <(send 'fix(uint256,uint256,uint80)' "$ID" "$m" "$r")
    say "market $m: fix tx $tx status $st, mondayPrice $(cast call $T 'mondayPrice(uint256,uint256)(uint64)' "$ID" "$m" --rpc-url "$R" | first)"
    [ "$st" = 0x1 ] || exit 1
  fi
done

L=$(cast call $T 'layers(uint256)(address,uint40,uint40,uint16,uint8,uint8,uint8,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)' "$ID" --rpc-url "$R")
STATE=$(echo "$L" | sed -n 7p | first); CLAIMED=$(echo "$L" | sed -n 8p); PAYOUT=$(echo "$L" | sed -n 15p | first)
say "now state $STATE, payout $PAYOUT, claimed $CLAIMED"
if [ "$STATE" = 2 ] && [ "$CLAIMED" = false ] && [ "$PAYOUT" != 0 ] && [ "${ME:-}" = "$BUYER" ]; then
  read -r tx st < <(send 'claim(uint256)' "$ID")
  say "claim tx $tx status $st"
fi

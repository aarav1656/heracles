#!/usr/bin/env bash
# Keeper run for a VaultCover: binds this week's Treaty layer on the vault's book once it can.
# Checks the Treaty's feed-age rule first (every market needs a round under 26 hours old), then
# simulates renewCover and, if it would pass, sends it and asserts: receipt status 0x1, one more
# layer recorded, lastCutoff and coveredUntil at this week's window, each covered leg's bound equal
# to the book, and the premium paid equal to the layer's premium and within maxPremium. Appends to
# docs/e2e/heracles-renew.log.
#   PRIVATE_KEY=... scripts/renew-cover.sh [vaultCover]     (without PRIVATE_KEY it only reports)
set -uo pipefail
cd "$(dirname "$0")/.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
C=${1:-$(jq -r .contracts.VaultCover.address contracts/deployments/421614.json)}
R=${RPC:-https://sepolia-rollup.arbitrum.io/rpc}
T=$(cast call "$C" 'treaty()(address)' --rpc-url "$R")
LOG=docs/e2e/heracles-renew.log
first() { awk '{print $1}'; }
say() { echo "$(date -u +%FT%TZ) VaultCover $C: $*" | tee -a "$LOG"; }

NOW=$(cast block latest -f timestamp --rpc-url "$R")
N=$(cast call "$T" 'marketsLength()(uint256)' --rpc-url "$R" | first)
for ((m = 0; m < N; m++)); do
  F=$(cast call "$T" 'markets(uint256)(address)' "$m" --rpc-url "$R")
  U=$(cast call "$F" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$R" | sed -n 4p | first)
  AGE=$((NOW - U))
  say "market $m feed round $((AGE / 3600))h $(((AGE % 3600) / 60))m old"
  [ "$AGE" -le $((26 * 3600)) ] || { say "a feed round is older than 26h; the Treaty would revert BadRound, waiting"; exit 0; }
done

FROM=$(cast call "$C" 'owner()(address)' --rpc-url "$R")
if ! SIM=$(cast call "$C" 'renewCover()(uint256)' --from "$FROM" --rpc-url "$R" 2>&1); then
  sel=$(echo "$SIM" | grep -oE 'data: "0x[0-9a-f]{8}' | cut -d'"' -f2)
  for e in 'BadTiming()' 'BadRound()' 'PremiumTooHigh()' 'CapacityExceeded()' 'AlreadyCovered(uint256)' 'BadParams()' 'ERC20InsufficientBalance(address,uint256,uint256)'; do
    [ "$sel" = "$(cast sig "$e")" ] && { say "renewCover would revert $e; nothing sent"; exit 0; }
  done
  say "renewCover would revert ($sel); nothing sent"; exit 0
fi
say "renewCover simulates layer $(echo "$SIM" | first)"
[ -n "${PRIVATE_KEY:-}" ] || exit 0

ASSET=$(cast call "$C" 'asset()(address)' --rpc-url "$R")
BAL0=$(cast call "$ASSET" 'balanceOf(address)(uint256)' "$C" --rpc-url "$R" | first)
L0=$(cast call "$C" 'layers()(uint256[])' --rpc-url "$R" --json | jq '.[0] | length')
TX=$(cast send "$C" 'renewCover()' --private-key "$PRIVATE_KEY" --rpc-url "$R" --json | jq -r .transactionHash)
ST=$(cast receipt "$TX" --rpc-url "$R" --json | jq -r .status)
B=$(cast receipt "$TX" blockNumber --rpc-url "$R")
LAYERS=$(cast call "$C" 'layers()(uint256[])' --rpc-url "$R" --block "$B" --json | jq -c '.[0]')
ID=$(echo "$LAYERS" | jq -r '.[-1]')
BAL1=$(cast call "$ASSET" 'balanceOf(address)(uint256)' "$C" --rpc-url "$R" --block "$B" | first)
PREM=$(cast call "$T" 'layers(uint256)(address,uint40,uint40,uint16,uint8,uint8,uint8,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)' "$ID" --rpc-url "$R" --block "$B" | sed -n 12p | first)
read -r CUT EXP < <(cast call "$T" 'weekWindow(uint256)(uint256,uint256)' "$(cast block "$B" -f timestamp --rpc-url "$R")" --rpc-url "$R" | first | tr '\n' ' ')
LC=$(cast call "$C" 'lastCutoff()(uint256)' --rpc-url "$R" --block "$B" | first)
CU=$(cast call "$C" 'coveredUntil()(uint256)' --rpc-url "$R" --block "$B" | first)
MAXP=$(cast call "$C" 'maxPremium()(uint256)' --rpc-url "$R" | first)
NET=$(cast call "$C" 'net()(int256[])' --rpc-url "$R" --block "$B" --json | jq -c '.[0]')
BOUND=$(cast call "$C" 'bound()(int256[])' --rpc-url "$R" --block "$B" --json | jq -c '.[0]')
IDX=$(cast call "$C" 'coverIndex()(uint256[])' --rpc-url "$R" --json | jq -c '.[0]')
say "renewCover tx $TX block $B status $ST, layer $ID, premium $PREM (paid $((BAL0 - BAL1)), ceiling $MAXP), lastCutoff $LC, coveredUntil $CU"
ok=1
[ "$ST" = 0x1 ] || ok=0
[ "$(echo "$LAYERS" | jq length)" -eq $((L0 + 1)) ] || ok=0
[ "$LC" = "$CUT" ] && [ "$CU" = "$EXP" ] || ok=0
[ $((BAL0 - BAL1)) -eq "$PREM" ] && [ "$PREM" -le "$MAXP" ] || ok=0
for i in $(echo "$IDX" | jq -r '.[]'); do
  [ "$(echo "$BOUND" | jq -r ".[$i]")" = "$(echo "$NET" | jq -r ".[$i]")" ] || ok=0
done
[ "$ok" = 1 ] && say "post-conditions hold" || { say "FAIL: a post-condition does not hold"; exit 1; }

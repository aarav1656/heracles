#!/usr/bin/env bash
# Deposit into a Capacity vault with one transaction: sign an EIP-2612 permit for the book asset
# offline, then call depositWithPermit. Prints the receipt status and the vault's totalAssets and
# the depositor's shares before and after. PRIVATE_KEY comes from the environment; never printed.
#   PRIVATE_KEY=... scripts/permit-deposit.sh <vault> <amount in base units>
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
VAULT=$1
AMOUNT=$2
R=${RPC:-https://sepolia-rollup.arbitrum.io/rpc}
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
ASSET=$(cast call "$VAULT" 'asset()(address)' --rpc-url "$R")
NAME=$(cast call "$ASSET" 'name()(string)' --rpc-url "$R" | tr -d '"')
VERSION=$(cast call "$ASSET" 'version()(string)' --rpc-url "$R" 2>/dev/null | tr -d '"' || echo 1)
NONCE=$(cast call "$ASSET" 'nonces(address)(uint256)' "$ME" --rpc-url "$R" | cut -d' ' -f1)
CHAIN=$(cast chain-id --rpc-url "$R")
DEADLINE=$(( $(date +%s) + 3600 ))

TYPED=$(mktemp)
trap 'rm -f "$TYPED"' EXIT
cat > "$TYPED" <<JSON
{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
"Permit":[{"name":"owner","type":"address"},{"name":"spender","type":"address"},{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}]},
"primaryType":"Permit",
"domain":{"name":"$NAME","version":"$VERSION","chainId":$CHAIN,"verifyingContract":"$ASSET"},
"message":{"owner":"$ME","spender":"$VAULT","value":"$AMOUNT","nonce":"$NONCE","deadline":"$DEADLINE"}}
JSON
SIG=$(cast wallet sign --data --from-file "$TYPED" --private-key "$PRIVATE_KEY")
RS=${SIG#0x}
SIG_R=0x${RS:0:64}
SIG_S=0x${RS:64:64}
SIG_V=$((16#${RS:128:2}))

before_assets=$(cast call "$VAULT" 'totalAssets()(uint256)' --rpc-url "$R" | cut -d' ' -f1)
before_shares=$(cast call "$VAULT" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$R" | cut -d' ' -f1)
echo "depositor $ME, asset $ASSET ($NAME v$VERSION), vault $VAULT, amount $AMOUNT"
echo "before: totalAssets $before_assets, shares $before_shares"

OUT=$(cast send "$VAULT" 'depositWithPermit(uint256,address,uint256,uint8,bytes32,bytes32)' \
  "$AMOUNT" "$ME" "$DEADLINE" "$SIG_V" "$SIG_R" "$SIG_S" --private-key "$PRIVATE_KEY" --rpc-url "$R" --json)
TX=$(echo "$OUT" | jq -r .transactionHash)
STATUS=$(cast receipt "$TX" --rpc-url "$R" --json | jq -r .status)
BLOCK=$(cast receipt "$TX" blockNumber --rpc-url "$R")
echo "tx $TX block $BLOCK status $STATUS"

after_assets=$(cast call "$VAULT" 'totalAssets()(uint256)' --rpc-url "$R" --block "$BLOCK" | cut -d' ' -f1)
after_shares=$(cast call "$VAULT" 'balanceOf(address)(uint256)' "$ME" --rpc-url "$R" --block "$BLOCK" | cut -d' ' -f1)
echo "after (block $BLOCK): totalAssets $after_assets, shares $after_shares"
[ "$STATUS" = 0x1 ] || { echo "FAIL: receipt status $STATUS"; exit 1; }
[ $((after_assets - before_assets)) -eq "$AMOUNT" ] || { echo "FAIL: totalAssets moved by $((after_assets - before_assets)), expected $AMOUNT"; exit 1; }
[ $((after_shares - before_shares)) -gt 0 ] || { echo "FAIL: no shares minted"; exit 1; }
echo "OK: totalAssets +$AMOUNT, shares +$((after_shares - before_shares))"

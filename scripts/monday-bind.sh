#!/usr/bin/env bash
# One-shot live bind on Heracles v3 (Arbitrum Sepolia 421614) for the current week's window
# (binding closes Thursday 19:30 UTC, reopens Monday 00:00 UTC). Layer on the USDC book (book 1):
# long 200 USDC of SPY, retention 2, limit 10 (3 first-loss, 7 senior). The premium is re-quoted
# from the live Pricer and used as the `maxPremium` ceiling; the bind is skipped if the wallet
# cannot pay it or either vault lacks free capacity for its slice. The key is read from the
# repo-root .env inside this process only and is never printed. Every step is appended to
# docs/e2e/heracles-bind.log.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
LOG=docs/e2e/heracles-bind.log
R=https://sepolia-rollup.arbitrum.io/rpc
TREATY=0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807
BOOK=1
FIRST_LOSS=0xb293E54AffE056708FCc54D0D1d16A7B7aD1FebB
SENIOR=0x510e4266C55a58879d3a77eC02e77CCF1602cA39
PRICER=0xbe99217180a5fcb83372375b0928c971dfa71f88
USDC=0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
SPY_FEED=0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06
EXPOSURE='[200000000]'; RETENTION=2000000; LIMIT=10000000
set -a; . ./.env; set +a
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
num() { awk '{print $1}'; }
log "== start, block $(cast block-number --rpc-url $R), buyer $ME"

now=$(date -u +%s)
cutoff=$(cast call $TREATY 'weekWindow(uint256)(uint256,uint256)' "$now" --rpc-url $R | head -1 | num)
deadline=$(( cutoff - 86400 ))
if [ "$now" -ge "$deadline" ]; then log "bind window closed (now $now >= deadline $deadline), not binding"; exit 1; fi

JUNIOR=$(( LIMIT * $(cast call $TREATY 'juniorShareBps()(uint256)' --rpc-url $R | num) / 10000 ))
quoted=$(cast call $PRICER 'quote(int256[],address[],uint256,uint256)(uint256,uint256,uint256)' "$EXPOSURE" "[$SPY_FEED]" $RETENTION $LIMIT --rpc-url $R | head -1 | num)
floor=$(( LIMIT * $(cast call $TREATY 'minRateOnLineBps()(uint256)' --rpc-url $R | num) / 10000 ))
premium=$(( quoted > floor ? quoted : floor ))
bal=$(cast call $USDC 'balanceOf(address)(uint256)' "$ME" --rpc-url $R | num)
free_fl=$(( $(cast call $FIRST_LOSS 'totalAssets()(uint256)' --rpc-url $R | num) - $(cast call $FIRST_LOSS 'locked()(uint256)' --rpc-url $R | num) ))
free_sr=$(( $(cast call $SENIOR 'totalAssets()(uint256)' --rpc-url $R | num) - $(cast call $SENIOR 'locked()(uint256)' --rpc-url $R | num) ))
log "quoted $quoted floor $floor premium $premium balance $bal free first-loss $free_fl senior $free_sr"
if [ "$bal" -lt "$premium" ]; then log "balance below premium, not binding"; exit 1; fi
if [ "$free_fl" -lt "$JUNIOR" ] || [ "$free_sr" -lt $(( LIMIT - JUNIOR )) ]; then log "free capacity below a slice, not binding"; exit 1; fi

allow=$(cast call $USDC 'allowance(address,address)(uint256)' "$ME" $TREATY --rpc-url $R | num)
if [ "$allow" -lt "$premium" ]; then
  tx=$(cast send $USDC 'approve(address,uint256)' $TREATY "$premium" --private-key "$PRIVATE_KEY" --rpc-url $R --json | jq -r .transactionHash)
  log "approve $premium tx $tx status $(cast receipt "$tx" status --rpc-url $R)"
fi

tx=$(cast send $TREATY 'bind(uint256,int256[],uint256,uint256,uint256)' $BOOK "$EXPOSURE" $RETENTION $LIMIT "$premium" --private-key "$PRIVATE_KEY" --rpc-url $R --json | jq -r .transactionHash)
status=$(cast receipt "$tx" status --rpc-url $R)
log "bind tx $tx status $status"
log "layerCount $(cast call $TREATY 'layerCount()(uint256)' --rpc-url $R | num), locked first-loss $(cast call $FIRST_LOSS 'locked()(uint256)' --rpc-url $R | num) senior $(cast call $SENIOR 'locked()(uint256)' --rpc-url $R | num)"
[ "$status" = "1" ] || [ "$status" = "true" ] || [ "$status" = "1 (success)" ]

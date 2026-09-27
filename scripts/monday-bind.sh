#!/usr/bin/env bash
# One-shot live bind on Heracles (Arbitrum Sepolia 421614) once the next weekly
# window opens (Monday 00:00 UTC). Layer: short 10 USDG SPY exposure, 0.30 USDG retention,
# 0.40 USDG limit; the premium is re-quoted from the live Pricer and the bind is skipped if the
# deployer cannot pay it. The key is read from contracts/.env inside this process only and is
# never printed. Every step is appended to docs/e2e/heracles-bind.log.
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
LOG=docs/e2e/heracles-bind.log
R=https://sepolia-rollup.arbitrum.io/rpc
TREATY=0x889F1fA08DE3d280511432893A1D7e5DB66d3252
CAPACITY=0xe645d83EA67ca1ECC7689f48Eb65eB2dE2e8933D
PRICER=0x0202D849Dc7CC7b643ff62Cf3E81130EA30D95da
USDG=0xFFC95faa3d63Cde504a05B567C600B78C0b41892
EXPOSURE='[-10000000]'; RETENTION=300000; LIMIT=400000
set -a; . contracts/.env; set +a
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
log "== start, block $(cast block-number --rpc-url $R), buyer $ME"

now=$(date -u +%s)
read -r cutoff _ < <(cast call $TREATY 'weekWindow(uint256)(uint256,uint256)' "$now" --rpc-url $R | tr '\n' ' ' | awk '{print $1, $3}')
if [ "$now" -ge "$cutoff" ]; then log "window closed (now $now >= cutoff $cutoff), not binding"; exit 1; fi

quoted=$(cast call $PRICER 'quote(int256[],uint256,uint256)(uint256,uint256,uint256)' "$EXPOSURE" $RETENTION $LIMIT --rpc-url $R | head -1 | awk '{print $1}')
floor=$(( LIMIT * $(cast call $TREATY 'minRateOnLineBps()(uint256)' --rpc-url $R | awk '{print $1}') / 10000 ))
premium=$(( quoted > floor ? quoted : floor ))
bal=$(cast call $USDG 'balanceOf(address)(uint256)' "$ME" --rpc-url $R | awk '{print $1}')
free=$(( $(cast call $CAPACITY 'totalAssets()(uint256)' --rpc-url $R | awk '{print $1}') - $(cast call $CAPACITY 'locked()(uint256)' --rpc-url $R | awk '{print $1}') ))
log "quoted $quoted floor $floor premium $premium balance $bal free capacity $free"
if [ "$bal" -lt "$premium" ]; then log "balance below premium, not binding"; exit 1; fi
if [ "$free" -lt "$LIMIT" ]; then log "free capacity below limit, not binding"; exit 1; fi

allow=$(cast call $USDG 'allowance(address,address)(uint256)' "$ME" $CAPACITY --rpc-url $R | awk '{print $1}')
if [ "$allow" -lt "$premium" ]; then
  tx=$(cast send $USDG 'approve(address,uint256)' $CAPACITY "$premium" --private-key "$PRIVATE_KEY" --rpc-url $R --json | jq -r .transactionHash)
  log "approve $premium tx $tx status $(cast receipt "$tx" status --rpc-url $R)"
fi

tx=$(cast send $TREATY 'bind(int256[],uint256,uint256)' "$EXPOSURE" $RETENTION $LIMIT --private-key "$PRIVATE_KEY" --rpc-url $R --json | jq -r .transactionHash)
status=$(cast receipt "$tx" status --rpc-url $R)
log "bind tx $tx status $status"
count=$(cast call $TREATY 'layerCount()(uint256)' --rpc-url $R | awk '{print $1}')
log "layerCount $count, capacity locked $(cast call $CAPACITY 'locked()(uint256)' --rpc-url $R | awk '{print $1}')"
[ "$status" = "1" ] || [ "$status" = "true" ] || [ "$status" = "1 (success)" ]

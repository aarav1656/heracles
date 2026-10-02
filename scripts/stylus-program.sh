#!/usr/bin/env bash
# Health and reactivation of a Stylus program through the ArbWasm precompile (0x...71).
# Prints the chain's Stylus version, the program's activated version, the days it has left before
# it expires, and what activateProgram would do right now (simulated). With --activate it sends
# activateProgram with the data fee the simulation quoted, then asserts the program reads back
# active at the current version. Anyone can call it; the Treaty's pricer address never changes.
#   scripts/stylus-program.sh <program> [--activate]
#   RPC=https://... (default Arbitrum Sepolia); --activate needs PRIVATE_KEY in the environment.
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
P=$1
R=${RPC:-https://sepolia-rollup.arbitrum.io/rpc}
W=0x0000000000000000000000000000000000000071
ERRS='ProgramNotWasm() ProgramNotActivated() ProgramNeedsUpgrade(uint16,uint16) ProgramExpired(uint64) ProgramUpToDate() ProgramKeepaliveTooSoon(uint64) ProgramInsufficientValue(uint256,uint256)'

BLOCK=$(cast block-number --rpc-url "$R")
CHAIN=$(cast chain-id --rpc-url "$R")
first() { cut -d' ' -f1; }
STYLUS=$(cast call $W 'stylusVersion()(uint16)' --rpc-url "$R" -b "$BLOCK")
EXPIRY=$(cast call $W 'expiryDays()(uint16)' --rpc-url "$R" -b "$BLOCK")
KEEPALIVE=$(cast call $W 'keepaliveDays()(uint16)' --rpc-url "$R" -b "$BLOCK")
CODEHASH=$(cast keccak "$(cast code "$P" --rpc-url "$R" --block "$BLOCK")")
echo "chain $CHAIN block $BLOCK program $P codehash $CODEHASH"
echo "chain Stylus version $STYLUS, programs expire after $EXPIRY days, keepalive after $KEEPALIVE days"

decode() {
  local data=$1
  for e in $ERRS; do
    if [ "${data:0:10}" = "$(cast sig "$e")" ]; then echo "$e $(cast decode-error --sig "$e" "$data" 2>/dev/null | tr '\n' ' ')"; return; fi
  done
  echo "$data"
}
revert_data() { grep -oE 'data: "0x[0-9a-fA-F]*"' | head -1 | cut -d'"' -f2; }

if VERSION=$(cast call $W 'programVersion(address)(uint16)' "$P" --rpc-url "$R" -b "$BLOCK" 2>/tmp/stylus-err); then
  LEFT=$(cast call $W 'programTimeLeft(address)(uint64)' "$P" --rpc-url "$R" -b "$BLOCK" | first)
  echo "program version $VERSION, $((LEFT / 86400)) days $(((LEFT % 86400) / 3600)) h left (programTimeLeft $LEFT s)"
else
  echo "programVersion reverts: $(decode "$(revert_data </tmp/stylus-err)")"
fi

FROM=${PRIVATE_KEY:+$(cast wallet address --private-key "$PRIVATE_KEY")}
FROM=${FROM:-0x000000000000000000000000000000000000dEaD}
if SIM=$(cast call $W 'activateProgram(address)(uint16,uint256)' "$P" --value 1ether --from "$FROM" --rpc-url "$R" -b "$BLOCK" 2>/tmp/stylus-err); then
  NEWV=$(echo "$SIM" | sed -n 1p | first); FEE=$(echo "$SIM" | sed -n 2p | first)
  echo "activateProgram would activate version $NEWV for a data fee of $FEE wei"
else
  echo "activateProgram simulation reverts: $(decode "$(revert_data </tmp/stylus-err)")"
  FEE=
fi

[ "${2:-}" = "--activate" ] || exit 0
[ -n "$FEE" ] || { echo "nothing to activate"; exit 0; }
TX=$(cast send $W 'activateProgram(address)' "$P" --value "$FEE" --private-key "$PRIVATE_KEY" --rpc-url "$R" --json | jq -r .transactionHash)
STATUS=$(cast receipt "$TX" --rpc-url "$R" --json | jq -r .status)
AFTER=$(cast call $W 'programVersion(address)(uint16)' "$P" --rpc-url "$R")
LEFT=$(cast call $W 'programTimeLeft(address)(uint64)' "$P" --rpc-url "$R" | first)
echo "activation tx $TX status $STATUS, program version $AFTER, $((LEFT / 86400)) days left"
[ "$STATUS" = 0x1 ] && [ "$AFTER" = "$STYLUS" ] || { echo "FAIL: program not active at version $STYLUS"; exit 1; }

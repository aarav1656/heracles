#!/usr/bin/env bash
# Checks, against the deployed Stylus pricer on Arbitrum Sepolia, that a layer (R, L) priced whole
# equals its first-loss slice (R, J) plus its senior slice (R + J, L - J), with J = 30% of L.
# premium, el and tvar95 must each add up within the tolerances the Solidity fuzz test uses:
# el and tvar95 within 1 base unit, premium within 3. Exits 1 on any miss. Read-only, no key.
set -uo pipefail
export PATH="$HOME/.foundry/bin:/opt/homebrew/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
R=${RPC_URL:-https://sepolia-rollup.arbitrum.io/rpc}
PRICER=${PRICER:-0xbe99217180a5fcb83372375b0928c971dfa71f88}
SPY_FEED=0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06
SHARE_BPS=${SHARE_BPS:-3000}
BLOCK=$(cast block-number --rpc-url "$R")

# exposure retention limit, 6-decimal units; the pricer is deployed with the SPY table only
LAYERS=(
  "[2000000000000] 20000000000 60000000000"
  "[1000000000000] 30000000000 50000000000"
  "[-1000000000000] 20000000000 40000000000"
  "[500000000000] 5000000000 10000000000"
  "[-10000000] 300000 400000"
)

quote() {
  cast call "$PRICER" 'quote(int256[],address[],uint256,uint256)(uint256,uint256,uint256)' \
    "$1" "[$SPY_FEED]" "$2" "$3" --block "$BLOCK" --rpc-url "$R" | awk '{print $1}' | tr '\n' ' '
}
off() { local d=$(( $1 - $2 )); echo $(( d < 0 ? -d : d )); }

fail=0
echo "pricer $PRICER, Arbitrum Sepolia block $BLOCK, first-loss share $SHARE_BPS bps"
for layer in "${LAYERS[@]}"; do
  read -r exp ret lim <<< "$layer"
  j=$(( lim * SHARE_BPS / 10000 ))
  read -r p el tv <<< "$(quote "$exp" "$ret" "$lim")"
  read -r pj elj tvj <<< "$(quote "$exp" "$ret" "$j")"
  read -r ps els tvs <<< "$(quote "$exp" $(( ret + j )) $(( lim - j )))"
  dp=$(off $(( pj + ps )) "$p"); de=$(off $(( elj + els )) "$el"); dt=$(off $(( tvj + tvs )) "$tv")
  ok=PASS
  if [ "$dp" -gt 3 ] || [ "$de" -gt 1 ] || [ "$dt" -gt 1 ] || [ "$pj" -gt "$p" ]; then ok=FAIL; fail=1; fi
  echo "$ok exposure $exp R $ret L $lim J $j | premium $p = $pj + $ps (off $dp) | el $el = $elj + $els (off $de) | tvar95 $tv = $tvj + $tvs (off $dt)"
done
exit $fail

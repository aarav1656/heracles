#!/usr/bin/env bash
# Wire a perp venue's LP vault to Heracles on Arbitrum Sepolia, from a clone of the repo.
# Run from contracts/ with your key in PRIVATE_KEY:  bash ../web/scripts/integrate-vault.sh
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
R=${RPC:-https://sepolia-rollup.arbitrum.io/rpc}
ME=$(cast wallet address --private-key "$PRIVATE_KEY")
PRICER=0x1674ecf8d236a91c484c11fd11a21601837f7e37 # six-table Stylus pricer: NVDA AAPL SPY TSLA EUR XAU
TREATY=0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807 # Treaty v3; book 0 settles in USDG
FEED=0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06   # SPY/USD, the volatility feed for every market here

# 1. A guard over the live pricer: weekend layer 20,000 to 220,000, premium budget 4,000 a week.
GUARD=$(forge create src/OIGuard.sol:OIGuard --rpc-url "$R" --private-key "$PRIVATE_KEY" --broadcast --json \
  --constructor-args $PRICER "[$FEED,$FEED,$FEED,$FEED,$FEED,$FEED]" "$ME" 20000000000 200000000000 4000000000 | jq -r .deployedTo)
echo "OIGuard     $GUARD"

# 2. The vault's book on chain. The Treaty's one market (SPY) covers book market 2.
COVER=$(forge create src/VaultCover.sol:VaultCover --rpc-url "$R" --private-key "$PRIVATE_KEY" --broadcast --json \
  --constructor-args $TREATY "$GUARD" 0 "[2]" "$ME" | jq -r .deployedTo)
echo "VaultCover  $COVER"

# 3. Who may move the book, who renews the cover, and the weekly layer: keep 3,000, cover 80, pay at most 10.
cast send "$COVER" 'setVenue(address,bool)' "$ME" true --rpc-url "$R" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$COVER" 'setKeeper(address,bool)' "$ME" true --rpc-url "$R" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$COVER" 'setTerms(uint256,uint256,uint256)' 3000000000 80000000 10000000 --rpc-url "$R" --private-key "$PRIVATE_KEY" >/dev/null

# 4. The venue reports each new position as the vault's side of it: a trader short 100,000 SPY leaves the vault long.
cast send "$COVER" 'open(uint256,int256)' 2 100000000000 --rpc-url "$R" --private-key "$PRIVATE_KEY" >/dev/null
echo "book        $(cast call "$COVER" 'net()(int256[])' --rpc-url "$R")"

# 5. A position the vault cannot afford to cover is refused before it is booked.
why() { grep -oE 'data: "0x[0-9a-f]+' | cut -d'"' -f2; }
REV=$({ cast call "$COVER" 'open(uint256,int256)(uint256)' --from "$ME" --rpc-url "$R" -- 0 -2000000000000 2>&1 || true; } | why)
echo "refused     PremiumOverBudget(premium, budget, today) = $(cast decode-error --sig 'PremiumOverBudget(uint256,uint256,uint256)' "$REV" | awk '{print $1}' | paste -sd, -)"

# 6. Each week a keeper binds the layer on the book as it stands (Monday 00:00 to Thursday 19:30 UTC).
#    The premium comes from VaultCover's own balance: send it at least maxPremium of the book's USDG first.
if ID=$(cast call "$COVER" 'renewCover()(uint256)' --from "$ME" --rpc-url "$R" 2>/dev/null); then echo "renewCover  would bind layer $ID"
else
  SEL=$({ cast call "$COVER" 'renewCover()(uint256)' --from "$ME" --rpc-url "$R" 2>&1 || true; } | why | cut -c1-10)
  case $SEL in
    $(cast sig 'BadTiming()')) echo "renewCover  outside the bind window (BadTiming): Monday 00:00 to Thursday 19:30 UTC" ;;
    $(cast sig 'BadRound()')) echo "renewCover  waits for a feed round under 26 hours old (BadRound)" ;;
    *) echo "renewCover  reverts $SEL: check the premium budget held by $COVER and the book's free capacity" ;;
  esac
fi

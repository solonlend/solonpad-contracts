#!/usr/bin/env bash
# LOCAL ANVIL ONLY (chainId 31337). Pool A end to end on a DeployV3 local deployment (script/v3/run-local.sh with
# r9 default pool-A seed $1k+$1k+$1k reserve): restock keeper seeds/ranges pool A, a user buys an NVDA.sol-quoted meme with native USDC in
# one transaction through V3MultiHopRouter, the keeper restocks (restockMint) and re-anchors (pushPrice).
# Two steps cannot happen on one local chain (no Robinhood Chain, no LayerZero) and are simulated, marked [SIM]:
#   the NVDA.sol of a restock fill is minted to the vault by impersonating the hub (on mainnet: a real RH purchase,
#   BuyFilled over LayerZero); the seeding fill also moves the vault's USDC like the real order would.
# Usage: RPC_URL=http://127.0.0.1:18645 script/v3/e2e-pool-a-local.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
CAST="${CAST:-$HOME/.foundry/bin/cast}"
RPC="${RPC_URL:-http://127.0.0.1:8545}"
M=script/v3/out/v3-31337.json
[ "$($CAST chain-id --rpc-url "$RPC")" = 31337 ] || { echo "not anvil"; exit 1; }
j() { python3 -c "import json,sys;d=json.load(open('$M'));print(d$1)"; }
VAULT=$(j "['contracts']['StockPoolVault']"); ROUTER=$(j "['contracts']['V3MultiHopRouter']")
HUB=$(j "['contracts']['SolonStockHub']"); FACTORY=$(j "['contracts']['V3LaunchFactory']")
HOOK=$(j "['contracts']['V3QuoteFeeHook']"); DESK=$(j "['contracts']['DeskNFT']"); OPS=$(j "['contracts']['OpsVault']")
SOLON=$(j "['config']['solon']"); NVDA=$(j "['config']['rewardAsset']"); ASSET_ID=$(j "['config']['rewardAssetId']")
UNDER=$(j "['contracts']['standin_RHStock']"); ORACLE=$(j "['contracts']['SolonStockOracle']")
USER_PK=0x1111111111111111111111111111111111111111111111111111111111111111
USER=$($CAST wallet address "$USER_PK")
KEEPER_DIR=$(mktemp -d)
printf '0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a' >"$KEEPER_DIR/key" # anvil #4 = local STOCK_KEEPER
chmod 600 "$KEEPER_DIR/key"
cat >"$KEEPER_DIR/arc.json" <<EOF
{ "chains": { "arc": { "chainId": 31337, "rpcUrl": "$RPC" } }, "keys": { "restock-keeper": "KEEPER_KEY_PATH" },
  "statusDir": "$KEEPER_DIR/state", "restock": { "params": { "cooldownSec": 0 } } }
EOF
keeper() { (cd keepers/v3 && KEEPER_KEY_PATH="$KEEPER_DIR/key" node bin/restock-keeper.mjs --config="$KEEPER_DIR/arc.json" \
  --manifest="../../$M" "$@" 2>&1 | grep -E '"action"|"reason"|"status"|"tx"|WARN|ERROR' | sed 's/^/    keeper: /'); }
send() { $CAST send --rpc-url "$RPC" "$@" --json | python3 -c "import json,sys;r=json.load(sys.stdin);print(r['transactionHash'], 'status', int(r['status'],16));"; }
state() {
  local tick usdc stock liq
  tick=$($CAST call --rpc-url "$RPC" "$VAULT" "currentTick()(int24)" | awk '{print $1}')
  liq=$($CAST call --rpc-url "$RPC" "$VAULT" "liquidity()(uint128)" | awk '{print $1}')
  usdc=$($CAST balance --rpc-url "$RPC" "$VAULT"); stock=$($CAST call --rpc-url "$RPC" "$NVDA" "balanceOf(address)(uint256)" "$VAULT" | awk '{print $1}')
  local ref; ref=$($CAST call --rpc-url "$RPC" "$(j "['contracts']['OracleRefTickSigner']")" "refTickOf(address)(int24)" "$NVDA" | awk '{print $1}')
  python3 -c "t=$tick;r=$ref;print(f'    pool A: tick {t} oracle tick {r} -> pool vs oracle {(1.0001**(r-t)-1)*1e4:+.0f} bps; liquidity $liq; idle USDC {$usdc/1e18:.2f}; idle NVDA.sol {$stock/1e18:.4f}')"
}
impersonate_mint() { # [SIM] NVDA.sol arriving at the vault from a hub fill
  $CAST rpc --rpc-url "$RPC" anvil_impersonateAccount "$HUB" >/dev/null
  $CAST rpc --rpc-url "$RPC" anvil_setBalance "$HUB" 0x56BC75E2D63100000 >/dev/null
  $CAST send --rpc-url "$RPC" --unlocked --from "$HUB" "$NVDA" "mint(address,uint256)" "$VAULT" "$1" >/dev/null
  $CAST rpc --rpc-url "$RPC" anvil_stopImpersonatingAccount "$HUB" >/dev/null
}
PRICE=$($CAST call --rpc-url "$RPC" "$ORACLE" "execPrice(address)(uint256,uint256)" "$NVDA" | head -1 | awk '{print $1}')
echo "== oracle NVDA execPrice $PRICE (Live)"; state

echo "== 1. keeper dry-run on the funded, empty pool (expects the seeding restockMint, simulated on chain)"
keeper
echo "== 1b. [SIM] seeding fill: \$1,000 of NVDA.sol at the oracle price less the 0.25% hub fee; the vault's USDC drops by \$1,000"
SEED=$(python3 -c "print(int(1000*10**18*9975//10000*10**18//$PRICE))")
impersonate_mint "$SEED"
$CAST rpc --rpc-url "$RPC" anvil_setBalance "$VAULT" "$(python3 -c "print(hex(2000*10**18))")" >/dev/null
state
echo "== 2. keeper --execute: first range around the oracle price (keeps the USDC buffer idle)"
keeper --execute; state

echo "== 3. creator launches an NVDA.sol-quoted meme (desk + ops readiness first)"
$CAST rpc --rpc-url "$RPC" anvil_setBalance "$USER" 0x21E19E0C9BAB2400000 >/dev/null # 10,000 native USDC
send --private-key "$USER_PK" "$SOLON" "mint(address,uint256)" "$USER" 100000000000000000000000 >/dev/null
send --private-key "$USER_PK" "$SOLON" "approve(address,uint256)" "$DESK" 100000000000000000000000 >/dev/null
SUR=$($CAST call --rpc-url "$RPC" "$DESK" "surchargeUSDC18()(uint256)" | awk '{print $1}')
[ "$($CAST call --rpc-url "$RPC" "$OPS" "paidDeskCount()(uint256)")" != 0 ] || send --private-key "$USER_PK" "$DESK" "mint(uint256,address)" 1 "$USER" --value "$SUR" >/dev/null
send --private-key "$USER_PK" "$OPS" "fundBudget(uint256)" 1 --value 1ether >/dev/null
SALT=0x$(python3 -c "import os;print(os.urandom(32).hex())")
R=$($CAST send --rpc-url "$RPC" --private-key "$USER_PK" "$FACTORY" \
  "launch(string,string,bytes32,bytes32,address,(uint8,address,bytes32,address),uint256)" \
  "NVDA Pair Meme" "NPM" 0x0000000000000000000000000000000000000000000000000000000000000001 "$SALT" "$USER" \
  "(1,$NVDA,$ASSET_ID,$UNDER)" 0 --json)
MEME=$(echo "$R" | python3 -c "
import json,sys;r=json.load(sys.stdin)
for l in r['logs']:
  if l['topics'][0].lower()=='$($CAST keccak 'LaunchState(bytes32,address,uint8)')'.lower(): print('0x'+l['topics'][2][-40:]); break")
echo "    launch tx $(echo "$R" | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])") meme $MEME"
if python3 -c "exit(0 if int('$NVDA',16) < int('$MEME',16) else 1)"; then KEY="($NVDA,$MEME,0,100,$HOOK)"; else KEY="($MEME,$NVDA,0,100,$HOOK)"; fi

echo "== 4. user: 800 native USDC -> pool A -> NVDA.sol -> meme in ONE transaction (V3MultiHopRouter)"
DL=$(( $(date +%s) + 3600 ))
Q=$($CAST call --rpc-url "$RPC" --from "$USER" --value 800ether "$ROUTER" \
  "quote(((address,address,uint24,int24,address),bool,uint256,uint256,address,uint256),address)(uint256,uint256,uint256)" \
  "($KEY,true,800000000000000000000,0,$USER,$DL)" "$USER")
OUT=$(echo "$Q" | head -1 | awk '{print $1}'); echo "    quote: meme out $OUT, pool-A fee $(echo "$Q" | sed -n 2p | awk '{print $1}'), hook fee $(echo "$Q" | sed -n 3p | awk '{print $1}')"
MIN=$(python3 -c "print($OUT*99//100)")
BEFORE=$($CAST call --rpc-url "$RPC" "$MEME" "balanceOf(address)(uint256)" "$USER" | awk '{print $1}')
echo "    swap tx $(send --private-key "$USER_PK" "$ROUTER" "swapExactIn(((address,address,uint24,int24,address),bool,uint256,uint256,address,uint256))" "($KEY,true,800000000000000000000,$MIN,$USER,$DL)" --value 800ether)"
AFTER=$($CAST call --rpc-url "$RPC" "$MEME" "balanceOf(address)(uint256)" "$USER" | awk '{print $1}')
echo "    user meme balance $BEFORE -> $AFTER"; state

echo "== 5. keeper --execute: pool A above the oracle by > 1.3% -> restock (restockMint, a real hub buy order)"
B5=$($CAST balance --rpc-url "$RPC" "$VAULT"); keeper --execute; A5=$($CAST balance --rpc-url "$RPC" "$VAULT"); state
echo "== 5b. [SIM] the restock fill lands: NVDA.sol for the order's USDC at the oracle price less 0.25% (fee reserve refunded)"
$CAST rpc --rpc-url "$RPC" anvil_setBalance "$VAULT" "$(python3 -c "print(hex($A5+2*10**18))")" >/dev/null
FILL=$(python3 -c "print(($B5-$A5-2*10**18)*9975//10000*10**18//$PRICE)")
impersonate_mint "$FILL"; state
echo "== 6. keeper --execute: sell the restocked NVDA.sol into pool A back to the oracle price (pushPrice)"
keeper --execute; state
echo "== 7. keeper again (expects hold: inside the band)"
keeper
rm -rf "$KEEPER_DIR"

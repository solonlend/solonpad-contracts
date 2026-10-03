#!/usr/bin/env bash
# Local end-to-end: DeployV3 against a running anvil, save the manifest, then VerifyV3.
# Usage: RPC_URL=http://127.0.0.1:8545 script/v3/run-local.sh
# Uses anvil account #0 and LOCAL_STANDINS=true (chainId 31337 only). Never use on a live chain.
set -euo pipefail
cd "$(dirname "$0")/../.."
FORGE="${FORGE:-$HOME/.foundry/bin/forge}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
OUT_DIR=script/v3/out
mkdir -p "$OUT_DIR"
export FOUNDRY_DYNAMIC_TEST_LINKING=false LOCAL_STANDINS=true
# r9: pool A defaults to $1k USDC + $1k NVDA.sol side (bought by the keeper) + $1k idle USDC reserve = $3,000 sent.
export DEPLOYER_PRIVATE_KEY="${DEPLOYER_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
LOG="$OUT_DIR/deploy-local.log"
"$FORGE" script script/v3/DeployV3.s.sol:DeployV3 --rpc-url "$RPC_URL" --broadcast --slow --non-interactive >"$LOG" 2>&1 || {
  tail -40 "$LOG"; exit 1; }
MANIFEST="$OUT_DIR/v3-31337.json"
grep -o 'V3_MANIFEST_JSON=.*' "$LOG" | tail -1 | sed 's/^V3_MANIFEST_JSON=//' >"$MANIFEST"
test -s "$MANIFEST"
MANIFEST_JSON="$(cat "$MANIFEST")" "$FORGE" script script/v3/VerifyV3.s.sol:VerifyV3 --rpc-url "$RPC_URL" >"$OUT_DIR/verify-local.log" 2>&1 || {
  tail -40 "$OUT_DIR/verify-local.log"; exit 1; }
grep -hE 'VerifyV3 checks passed|^ +V3Governance 0x|^ +V3LaunchFactory 0x' "$LOG" "$OUT_DIR/verify-local.log" || true

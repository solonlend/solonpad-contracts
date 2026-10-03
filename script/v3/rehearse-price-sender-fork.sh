#!/usr/bin/env bash
# r9: rehearse the RH side of the oracle on an anvil FORK of Robinhood Chain mainnet (never the real chain):
#   1. DeployV3PriceSender exactly as on mainnet (ChainlinkStockSource + StockPriceSender, real feeds/pools, real
#      LayerZero EndpointV2 / SendUln302 / DVNs from V3LzConfig), broadcast to the local fork only;
#   2. VerifyV3PriceSender (DVN set != Dead DVN, confirmations, delegate/owner, peer);
#   3. quote + one poke -> LayerZero send; prints PricesSent / PacketSent / DVNFeePaid / ExecutorFeePaid and fees.
# The Arc peer is a stand-in address (the Arc RelayedStockSource is not deployed); delivery on Arc is not simulated.
# Usage: RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com/rpc [FORK_BLOCK=n] [PORT=18747] script/v3/rehearse-price-sender-fork.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
FORGE="${FORGE:-$HOME/.foundry/bin/forge}"; CAST="${CAST:-$HOME/.foundry/bin/cast}"; ANVIL="${ANVIL:-$HOME/.foundry/bin/anvil}"
RH="${RH_RPC_URL:-https://rpc.mainnet.chain.robinhood.com/rpc}"
PORT="${PORT:-18747}"; RPC="http://127.0.0.1:$PORT"
OUT=script/v3/out; mkdir -p "$OUT"; LOG="$OUT/rehearse-price-sender-fork.log"; : >"$LOG"
FORK_BLOCK="${FORK_BLOCK:-$($CAST block-number -r "$RH")}"
"$ANVIL" --fork-url "$RH" --fork-block-number "$FORK_BLOCK" --port "$PORT" --silent >"$OUT/anvil-rh-fork.log" 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do $CAST chain-id -r "$RPC" >/dev/null 2>&1 && break; sleep 1; done
[ "$($CAST chain-id -r "$RPC")" = 4663 ] || { echo "fork not up"; exit 1; }
echo "== RH mainnet fork at block $FORK_BLOCK (chainId 4663) on $RPC" | tee -a "$LOG"

# anvil test accounts only (local fork): #0 deployer/poker, #1 stands in for the RH timelock
export DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export RH_OWNER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export RH_LZ_ENDPOINT=0x6F475642a6e85809B1c36Fa62763669b1b48DD5B ARC_EID=30417 RH_CONFIRMATIONS=20
export RH_USDG_FEED=0x61B7e5650328764B076A108EFF5fa7282a1B9aD2
export ORACLE_STOCKS=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9,0x322F0929c4625eD5bAd873c95208D54E1c003b2d
export ORACLE_FEEDS=0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15,0x6B22A786bAa607d76728168703a39Ea9C99f2cD0,0x4A1166a659A55625345e9515b32adECea5547C38
export ORACLE_POOLS=0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3,0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D,0xf4ACdAEEB7022862A763C9B1B885e11191c889E3
export ARC_PRICE_SOURCE=0x00000000000000000000000000000000A5C50A2C # stand-in Arc RelayedStockSource
"$FORGE" script script/v3/DeployV3Reserve.s.sol:DeployV3PriceSender --rpc-url "$RPC" --broadcast --slow --non-interactive >>"$LOG" 2>&1
SRC=$(grep -o 'ChainlinkStockSource 0x[0-9a-fA-F]*' "$LOG" | tail -1 | awk '{print $2}')
SENDER=$(grep -o 'StockPriceSender 0x[0-9a-fA-F]*' "$LOG" | tail -1 | awk '{print $2}')
echo "== deployed ChainlinkStockSource $SRC StockPriceSender $SENDER" | tee -a "$LOG"
BC=$(ls -t broadcast/DeployV3Reserve.s.sol/4663/run-latest.json)
python3 - "$BC" <<'EOF' | tee -a "$LOG"
import json,sys
d=json.load(open(sys.argv[1])); tot=0
for t,r in zip(d["transactions"],d["receipts"]):
    g=int(r["gasUsed"],16); p=int(r["effectiveGasPrice"],16); tot+=g*p
    print(f"   deploy tx {r['transactionHash']} {t.get('function') or t['transactionType']+' '+(t.get('contractName') or '')} gas {g}")
print(f"   deploy txs {len(d['receipts'])}, fork gas cost {tot/1e18:.9f} ETH (anvil gas price, not RH's)")
EOF

PRICE_SENDER=$SENDER "$FORGE" script script/v3/DeployV3Reserve.s.sol:VerifyV3PriceSender --rpc-url "$RPC" >>"$LOG" 2>&1
grep -h 'VerifyV3PriceSender checks passed' "$LOG" | tail -1

STOCKS="[${ORACLE_STOCKS}]"
QUOTE=$($CAST call -r "$RPC" "$SENDER" "quote(address[])(uint256)" "$STOCKS" | awk '{print $1}')
echo "== quote(3 stocks) = $QUOTE wei" | tee -a "$LOG"
RCPT=$($CAST send -r "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" "$SENDER" "poke(address[])" "$STOCKS" --value "$QUOTE" --json)
echo "$RCPT" >"$OUT/rehearse-poke-receipt.json"
python3 - "$OUT/rehearse-poke-receipt.json" "$QUOTE" <<'EOF' | tee -a "$LOG"
import json,sys
r=json.load(open(sys.argv[1])); q=int(sys.argv[2])
from subprocess import check_output
def k(s): return check_output([__import__('os').path.expanduser('~/.foundry/bin/cast'),'keccak',s]).decode().strip()
T={k('PricesSent(bytes32,uint64,uint256,uint256)'):'PricesSent',k('PacketSent(bytes,bytes,address)'):'PacketSent',
   k('DVNFeePaid(address[],address[],uint256[])'):'DVNFeePaid',k('ExecutorFeePaid(address,uint256)'):'ExecutorFeePaid'}
print(f"   poke tx {r['transactionHash']} status {int(r['status'],16)} gasUsed {int(r['gasUsed'],16)} value {q} wei")
for l in r['logs']:
    n=T.get(l['topics'][0]);
    if not n: continue
    data=bytes.fromhex(l['data'][2:])
    if n=='PricesSent':
        guid=l['topics'][1]; rh=int.from_bytes(data[0:32],'big'); cnt=int.from_bytes(data[32:64],'big'); fee=int.from_bytes(data[64:96],'big')
        print(f"   PricesSent guid {guid} rhBlock {rh} count {cnt} fee {fee} wei ({l['address']})")
    elif n=='ExecutorFeePaid':
        print(f"   ExecutorFeePaid executor 0x{data[12:32].hex()} fee {int.from_bytes(data[32:64],'big')} wei ({l['address']})")
    elif n=='DVNFeePaid':
        w=[int.from_bytes(data[i:i+32],'big') for i in range(0,len(data),32)]
        o1,o2,o3=w[0]//32,w[1]//32,w[2]//32
        req=[hex(x) for x in w[o1+1:o1+1+w[o1]]]; opt=[hex(x) for x in w[o2+1:o2+1+w[o2]]]; fees=w[o3+1:o3+1+w[o3]]
        print(f"   DVNFeePaid required {req} optional {opt} fees {fees} ({l['address']})")
    else:
        print(f"   PacketSent by endpoint {l['address']} (sendLibrary in data), {len(data)} bytes")
EOF
echo "== done (fork only; nothing was sent to Robinhood Chain)"

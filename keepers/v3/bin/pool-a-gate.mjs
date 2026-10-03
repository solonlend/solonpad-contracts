#!/usr/bin/env node
// Design §12.8 gate for NVDA stock-quote launches (read-only): prints {open, checks} and exits 0 only when open.
//   node bin/pool-a-gate.mjs --config=config/arc.json --manifest=<DeployV3 manifest> \
//     --verify-log=<VerifyV3 output> [--events=<state>/restock-keeper.dry.events.jsonl]
import { Contract, JsonRpcProvider, keccak256, AbiCoder, solidityPackedKeccak256 } from 'ethers';
import { readFileSync, existsSync } from 'node:fs';
import { parseArgs } from '../lib/cli.mjs';
import { loadConfig } from '../lib/config.mjs';
import { VaultAbi } from '../restock/keeper.mjs';
import { evaluateGate } from '../restock/gate.mjs';

const args = parseArgs();
const cfg = loadConfig(args.config);
const arc = cfg.chains.arc;
const provider = new JsonRpcProvider(arc.rpcUrl, arc.chainId, { staticNetwork: true });
const m = JSON.parse(readFileSync(args.extra.manifest, 'utf8'));
const vault = new Contract(m.contracts.StockPoolVault, VaultAbi, provider);
const router = new Contract(m.contracts.V3MultiHopRouter, ['function poolA() view returns (tuple(address,address,uint24,int24,address))'], provider);
const factory = new Contract(m.contracts.V3LaunchFactory, ['function approvedQuote(address) view returns (bytes32)'], provider);
const pm = new Contract(m.config.poolManager, ['function extsload(bytes32) view returns (bytes32)'], provider);
const key = await vault.poolKey();
const enc = k => AbiCoder.defaultAbiCoder().encode(['address', 'address', 'uint24', 'int24', 'address'], [...k]);
const poolId = keccak256(enc(key));
const [slot0, liquidity, idleUsdc, routerKey, approved] = await Promise.all([
  pm.extsload(solidityPackedKeccak256(['bytes32', 'uint256'], [poolId, 6n])), vault.liquidity(), provider.getBalance(vault.target),
  router.poolA(), factory.approvedQuote(m.config.rewardAsset),
]);
const eventsPath = args.extra.events ?? `${cfg.statusDir}/restock-keeper.dry.events.jsonl`;
const events = existsSync(eventsPath) ? readFileSync(eventsPath, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) : [];
const verifyLog = args.extra['verify-log'];
const facts = {
  approvedQuote: approved !== '0x' + '0'.repeat(64),
  initialized: (BigInt(slot0) & ((1n << 160n) - 1n)) !== 0n,
  liquidity, idleUsdc,
  routerBound: keccak256(enc(routerKey)) === poolId,
  verifyPassed: Boolean(verifyLog && existsSync(verifyLog) && /VerifyV3 checks passed/.test(readFileSync(verifyLog, 'utf8'))),
  events,
};
// The reserve the gate checks is the deployed one (manifest) unless the restock config overrides it, and the alert
// share is the keeper's own, so gate and keeper agree on "reserve low".
const rp = cfg.restock?.params ?? {};
const gateParams = {
  ...(m.config.poolAReserveUsd !== undefined && Number(m.config.poolAStockUsd) > 0 ? { reserveUsd: Number(m.config.poolAReserveUsd) } : {}),
  ...(rp.reserveUsd !== undefined ? { reserveUsd: rp.reserveUsd } : {}),
  ...(rp.reserveAlertBps !== undefined ? { reserveAlertBps: rp.reserveAlertBps } : {}),
  ...(cfg.restock?.gate ?? {}),
};
const out = evaluateGate(facts, Date.now(), gateParams);
console.log(JSON.stringify({ asset: 'NVDA', vault: vault.target, router: router.target, ...out }, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
process.exit(out.open ? 0 : 2);

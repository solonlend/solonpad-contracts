#!/usr/bin/env node
// Pool-A restock/range keeper (Arc, NVDA only). Dry-run by default.
//   node bin/restock-keeper.mjs --config=config/arc.json [--manifest=../../script/v3/out/v3-5042.json]   one evaluation
//   ... --loop        daemon: event subscription (WS if configured, else HTTP polling) + periodic tick
//   ... --execute     actually send (KEEPER_KEY_PATH, the vault's fixed keeper)
// Addresses come from the DeployV3 manifest (StockPoolVault, SolonStockOracle, OracleRefTickSigner, SolonStockHub,
// rewardAsset, StockPriceSource) unless config.restock overrides them. Oracle push requests go to
// `${restock.demandDir ?? statusDir}/oracle-push-demand.json`, read by the RH oracle keeper.
import { Contract, keccak256, AbiCoder, solidityPackedKeccak256 } from 'ethers';
import WebSocket from 'ws';
import { readFileSync } from 'node:fs';
import { buildContext } from '../lib/runner.mjs';
import { withLock, lockPathFor } from '../lib/lock.mjs';
import { writeHeartbeat } from '../lib/heartbeat.mjs';
import { RestockKeeper, chainReader, VaultAbi, OracleAbi, SignerAbi, HubAbi } from '../restock/keeper.mjs';
import { restockSubscription } from '../restock/events.mjs';
import { LogWatcher } from '../oracle/watch.mjs';
import { makeDebouncer } from '../oracle/decide.mjs';

const NAME = 'restock-keeper';
const replacer = (_, v) => (typeof v === 'bigint' ? v.toString() : v);
const ctx = await buildContext(NAME);
const { cfg, provider, logger, journal, alert, tx, args } = ctx;
const rc = cfg.restock ?? {};
const manifestPath = args.extra.manifest ?? rc.manifest ?? null;
const m = manifestPath ? JSON.parse(readFileSync(manifestPath, 'utf8')) : { contracts: {}, config: {} };
const pick = (k, mk, src = 'contracts') => rc[k] ?? m[src]?.[mk] ?? null;
const addr = {
  vault: pick('vault', 'StockPoolVault'), oracle: pick('oracle', 'SolonStockOracle'), signer: pick('signer', 'OracleRefTickSigner'),
  hub: pick('hub', 'SolonStockHub'), token: pick('token', 'rewardAsset', 'config'), poolManager: pick('poolManager', 'poolManager', 'config'),
  relayedSource: rc.relayedSource ?? (m.config?.localStandIns ? null : m.contracts?.StockPriceSource ?? null),
};
for (const [k, v] of Object.entries(addr)) if (!v && k !== 'relayedSource') throw new Error(`restock: ${k} address missing (config.restock.${k} or --manifest)`);

const vault = new Contract(addr.vault, VaultAbi, ctx.wallet ?? provider);
const oracle = new Contract(addr.oracle, OracleAbi, provider);
const signer = new Contract(addr.signer, SignerAbi, provider);
const hub = new Contract(addr.hub, HubAbi, provider);
const token = new Contract(addr.token, ['function balanceOf(address) view returns (uint256)'], provider);
const underlying = await vault.underlying();
const key = await vault.poolKey();
const poolId = keccak256(AbiCoder.defaultAbiCoder().encode(['address', 'address', 'uint24', 'int24', 'address'], [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]));
// v4 pool state lives at keccak256(poolId, POOLS_SLOT = 6) in the PoolManager; slot0's low 160 bits = sqrtPriceX96.
const pm = new Contract(addr.poolManager, ['function extsload(bytes32) view returns (bytes32)'], provider);
const stateSlot = solidityPackedKeccak256(['bytes32', 'uint256'], [poolId, 6n]);
const manager = { sqrtPriceX96: async () => BigInt(await pm.extsload(stateSlot)) & ((1n << 160n) - 1n) };

// r9: the deployed starting structure (manifest poolAStockUsd / poolAReserveUsd) is the default target; config wins.
function manifestTargets(c = {}) {
  const t = {};
  if (Number(c.poolAStockUsd) > 0) t.poolStockUsd = Number(c.poolAStockUsd);
  if (c.poolAReserveUsd !== undefined && Number(c.poolAStockUsd) > 0) t.reserveUsd = Number(c.poolAReserveUsd);
  return t;
}

const keeper = new RestockKeeper({
  reader: chainReader({ provider, vault, oracle, signer, hub, token, manager }), vault, tx, journal, logger, alert,
  execute: args.execute, params: { ...manifestTargets(m.config), ...(rc.params ?? {}) }, statusDir: rc.demandDir ?? cfg.statusDir, underlying,
});
logger.info(`pool A vault ${addr.vault} pool ${poolId} underlying ${underlying}`);

const lockPath = ctx.wallet ? lockPathFor(ctx.wallet.address) : null;
let failures = 0; // consecutive failed evaluations (heartbeat / health check)
const evaluate = async why => {
  // r13: quote deadlines and the cooldown follow chain time (on a real chain ~ wall clock; on forks the clock is warped).
  const chainNow = (await provider.getBlock('latest')).timestamp;
  keeper.now = () => chainNow;
  const out = args.execute && lockPath ? await withLock(lockPath, NAME, () => keeper.tick()) : { value: await keeper.tick() };
  if (out.skipped) logger.warn(`signer lock held by ${out.holder}; retry on the next trigger`);
  else console.log(JSON.stringify({ trigger: why, ...out.value }, replacer, 2));
  failures = 0;
  writeHeartbeat(cfg.statusDir, NAME, { ok: true, execute: args.execute });
  return out.value;
};

await tx.reconcileAll();
if (!args.loop) {
  await evaluate(['once']);
  process.exit(process.exitCode ?? 0);
}
const trigger = makeDebouncer(why => evaluate(why).catch(e => {
  logger.error(`evaluate failed: ${e?.shortMessage ?? e?.message}`);
  writeHeartbeat(cfg.statusDir, NAME, { ok: false, execute: args.execute, failures: ++failures, note: e?.shortMessage ?? e?.message });
}), rc.debounceMs ?? 2000);
const sub = restockSubscription({ ...addr, underlying, poolId });
const wsUrl = (rc.wsEnv && process.env[rc.wsEnv]) || rc.wsUrl || null;
const watcher = new LogWatcher({
  http: provider, wsUrl, WebSocketImpl: WebSocket, logger, addresses: sub.addresses, topics: sub.topics,
  onLogs: logs => { const hits = logs.filter(sub.relevant); if (hits.length) trigger(`events:${hits.length}`); },
  catchUpMs: wsUrl ? (rc.catchUpMs ?? 300_000) : (rc.pollMs ?? 10_000), initialLookback: rc.initialLookbackBlocks ?? 200,
});
logger.info(wsUrl ? 'WebSocket subscription + HTTP catch-up' : `no WebSocket configured: HTTP log polling every ${(rc.pollMs ?? 10_000) / 1000}s`);
await watcher.start();
setInterval(() => trigger('tick'), args.interval * 1000); // fallback: native USDC arrivals have no event
trigger('start');
for (const s of ['SIGINT', 'SIGTERM']) process.on(s, () => { watcher.stop(); process.exit(0); });

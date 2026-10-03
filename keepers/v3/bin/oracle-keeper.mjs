#!/usr/bin/env node
// RH oracle push keeper (r8): event-driven StockPriceSender.poke. Dry-run by default.
//   node bin/oracle-keeper.mjs --config=config/oracle.json            one catch-up + one decision, exit
//   node bin/oracle-keeper.mjs --config=config/oracle.json --loop     daemon: WS (if configured) + HTTP catch-up
//   ... --execute                                                     actually send (key file via env, see config)
import { JsonRpcProvider, Contract } from 'ethers';
import WebSocket from 'ws';
import { parseArgs } from '../lib/cli.mjs';
import { loadConfig } from '../lib/config.mjs';
import { loadSigner } from '../lib/signer.mjs';
import { Journal } from '../lib/journal.mjs';
import { makeLogger } from '../lib/log.mjs';
import { makeAlerter } from '../lib/alert.mjs';
import { TxSender } from '../lib/tx.mjs';
import { withLock, lockPathFor } from '../lib/lock.mjs';
import { writeHeartbeat } from '../lib/heartbeat.mjs';
import { STOCKS } from '../oracle/stocks.mjs';
import { OracleKeeper, SenderAbi, SUBSCRIBED_TOPICS } from '../oracle/keeper.mjs';
import { LogWatcher } from '../oracle/watch.mjs';

const NAME = 'oracle-keeper';
const replacer = (_, v) => (typeof v === 'bigint' ? v.toString() : v);
const args = parseArgs();
const cfg = loadConfig(args.config);
const rh = cfg.chains?.rh;
if (!rh?.rpcUrl) throw new Error('config chains.rh.rpcUrl (or its rpcEnv) is required');
const oc = cfg.oracle ?? {};
if (!oc.stockPriceSender) throw new Error('config oracle.stockPriceSender is required');
const provider = new JsonRpcProvider(rh.rpcUrl, rh.chainId, { staticNetwork: true, cacheTimeout: -1 });
const logger = makeLogger({ file: `${cfg.statusDir}/${NAME}.log`, name: NAME });
const keyEnv = cfg.keys?.[NAME] ?? 'ORACLE_KEEPER_KEY_PATH';
const wallet = args.execute ? loadSigner(keyEnv, provider, { allowSolonConfigDir: cfg.keys?.allowSolonConfigDir === true }) : null;
const journal = new Journal(`${cfg.statusDir}/${NAME}${args.execute ? '' : '.dry'}.json`);
const alert = makeAlerter({ logger, name: NAME, enabled: args.execute });
const tx = new TxSender({ provider, wallet, journal, logger, chainId: rh.chainId, execute: args.execute, maxFeePerGasCap: rh.maxFeePerGasCap ? BigInt(rh.maxFeePerGasCap) : null });
const sender = new Contract(oc.stockPriceSender, SenderAbi, provider);
const stocks = (oc.stocks?.length ? oc.stocks : STOCKS).map(s => ({ ...s }));
// The feed proxy may be repointed by Chainlink: subscribe to its current aggregator. (Between restarts the 60s
// tick still reads latestRoundData through the proxy, so a missed aggregator change delays a push by <= 1 tick.)
for (const s of stocks) {
  // A feed without aggregator() (testnet mock feeds emit AnswerUpdated themselves) is subscribed to directly.
  const agg = await new Contract(s.feed, ['function aggregator() view returns (address)'], provider).aggregator().catch(() => s.feed);
  if (s.aggregator && s.aggregator.toLowerCase() !== agg.toLowerCase()) logger.warn(`${s.symbol}: aggregator changed ${s.aggregator} -> ${agg}`);
  s.aggregator = agg;
}
const k = await new OracleKeeper({
  params: oc.params ?? {}, stocks, provider, sender, tx, journal, logger, alert, statusDir: cfg.statusDir, chainId: rh.chainId,
  execute: args.execute, feeBufferBps: BigInt(oc.feeBufferBps ?? 1000), maxFeeWei: BigInt(oc.maxFeeWei ?? '1000000000000000'),
  debounceMs: oc.debounceMs ?? 3000, simulateFrom: oc.simulateFrom ?? null,
}).init();
logger.info(`start ${args.execute ? 'EXECUTE' : 'dry-run'} chain ${rh.chainId} sender ${sender.target}${wallet ? ` signer ${wallet.address}` : ''}`);

// Every send takes the signer's lock (same rule as the other keepers sharing a hot wallet).
const lockPath = wallet ? lockPathFor(wallet.address) : null;
let failures = 0; // consecutive failed evaluations (heartbeat / health check)
const evaluate = async why => {
  const out = lockPath ? await withLock(lockPath, NAME, () => k.evaluate(why)) : { value: await k.evaluate(why) };
  if (out.skipped) logger.warn(`signer lock held by ${out.holder}; will retry on the next tick`);
  else if (out.value?.decision?.push || !args.loop) console.log(JSON.stringify(out.value, replacer, 2));
  failures = 0;
  writeHeartbeat(cfg.statusDir, NAME, { ok: true, execute: args.execute });
  return out.value;
};
k.trigger = (await import('../oracle/decide.mjs')).makeDebouncer(why => evaluate(why).catch(e => {
  logger.error(`evaluate failed: ${e?.shortMessage ?? e?.message}`);
  writeHeartbeat(cfg.statusDir, NAME, { ok: false, execute: args.execute, failures: ++failures, note: e?.shortMessage ?? e?.message });
}), oc.debounceMs ?? 3000);

await tx.reconcileAll();
await k.recover(oc.recoverLookbackBlocks ?? 120_000).catch(e => logger.warn(`recover failed: ${e?.message}`));
const wsUrl = (oc.wsEnv && process.env[oc.wsEnv]) || oc.wsUrl || null;
const watcher = new LogWatcher({
  http: provider, wsUrl, WebSocketImpl: WebSocket, logger,
  addresses: [...new Set([...stocks.map(s => s.aggregator).filter(Boolean), ...stocks.map(s => s.pool).filter(Boolean), sender.target])],
  topics: SUBSCRIBED_TOPICS, onLogs: logs => k.onLogs(logs),
  // Polling-only (no WS URL) catches up every pollMs; with WS, catch-up is the safety net every catchUpMs.
  catchUpMs: wsUrl ? (oc.catchUpMs ?? 300_000) : (oc.pollMs ?? 15_000), maxRange: oc.maxLogRange ?? 50_000,
  initialLookback: oc.initialLookbackBlocks ?? 2_000,
});

if (!args.loop) {
  await watcher.catchUp();
  await evaluate(['once']);
  process.exit(process.exitCode ?? 0);
}
logger.info(wsUrl ? 'WebSocket subscription + HTTP catch-up' : `no WebSocket configured: HTTP polling every ${(oc.pollMs ?? 15_000) / 1000}s`);
await watcher.start();
k.watchDemand();
// Heartbeat/demand clock: decisions also run on a fixed tick, not only on events.
setInterval(() => k.trigger('tick'), (args.interval ?? 60) * 1000);
k.trigger('start');
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { watcher.stop(); k.stop(); process.exit(0); });

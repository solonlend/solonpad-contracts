#!/usr/bin/env node
// Native-balance watch (fork F8): RH ReserveVault ETH (it pays every result message's LZ fee) and each keeper
// wallet's gas. Read-only: no key, no tx. One check and exit (launchd StartInterval), or --loop[=300].
//   node bin/balance-watch.mjs --config=config/balances.json [--loop=300]
// Alerts go through lib/alert.mjs (~/.config/solon/v3_alert.env); with no alert config they are only logged.
import { JsonRpcProvider } from 'ethers';
import { parseArgs } from '../lib/cli.mjs';
import { loadConfig } from '../lib/config.mjs';
import { makeLogger } from '../lib/log.mjs';
import { makeAlerter } from '../lib/alert.mjs';
import { BalanceWatcher, parseTargets } from '../lib/balances.mjs';
import { writeHeartbeat } from '../lib/heartbeat.mjs';

const NAME = 'balance-watch';
const replacer = (_, v) => (typeof v === 'bigint' ? v.toString() : v);
const args = parseArgs();
const cfg = loadConfig(args.config);
const targets = parseTargets(cfg.balances?.targets ?? []);
if (!targets.length) throw new Error('config balances.targets is empty');
const logger = makeLogger({ file: `${cfg.statusDir}/${NAME}.log`, name: NAME });
const readers = {};
for (const [name, chain] of Object.entries(cfg.chains ?? {})) {
  if (!chain.rpcUrl) continue;
  const provider = new JsonRpcProvider(chain.rpcUrl, chain.chainId, { staticNetwork: true, cacheTimeout: -1 });
  readers[name] = address => provider.getBalance(address);
}
const watcher = new BalanceWatcher({ targets, readers, logger, alert: makeAlerter({ logger, name: NAME, repeatMs: Number(cfg.balances?.repeatMs ?? 6 * 3600_000) }) });
for (;;) {
  console.log(JSON.stringify(await watcher.tick(), replacer, 2));
  writeHeartbeat(cfg.statusDir, NAME, { ok: true });
  if (!args.loop) break;
  await new Promise(resolve => setTimeout(resolve, args.interval * 1000));
}

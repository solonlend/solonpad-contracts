#!/usr/bin/env node
// Fleet health check (ops batch 10-02): every keeper's heartbeat, every role wallet's gas, both floats. Read-only, no key.
//   node bin/health-check.mjs --config=config/mainnet-health.json [--alert] [--json]
// Prints one OK/WARN/FAIL line per check and a summary; exit code 0 = all OK, 1 = worst is WARN, 2 = worst is FAIL
// (3 = the check itself could not run). --alert (or --execute) also sends non-OK checks through lib/alert.mjs
// (~/.config/solon/v3_alert.env), de-duplicated across runs in <statusDir>/health-alerts.json (new / level changed /
// repeatMs, default 1 h; one RECOVERED note). launchd: script/v3/mainnet/launchd/xyz.solonlend.v3-health.plist (300 s).
import { JsonRpcProvider, Contract } from 'ethers';
import { parseArgs } from '../lib/cli.mjs';
import { loadConfig } from '../lib/config.mjs';
import { makeLogger } from '../lib/log.mjs';
import { makeAlerter } from '../lib/alert.mjs';
import { writeHeartbeat } from '../lib/heartbeat.mjs';
import { StockHubAbi, ReserveVaultAbi } from '../lib/abis.mjs';
import { readHeartbeat, evaluateHeartbeat, parseGasTargets, evaluateGas, evaluateFloat, FLOAT_HEALTH_DEFAULTS,
  summarize, formatLine, dueAlerts, forgetDelivery, loadState, saveState } from '../lib/health.mjs';

const NAME = 'health-check';
const RPC_TIMEOUT_MS = 20_000;
const withTimeout = (p, what) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`${what}: timeout ${RPC_TIMEOUT_MS / 1000}s`)), RPC_TIMEOUT_MS))]);
// RPC URLs carry the dRPC key: never let one reach stdout / the log through an error message.
const noUrl = text => String(text).replace(/\b(?:https?|wss?):\/\/\S+/g, '<rpc-url>');
const settle = (p, what) => withTimeout(p, what).catch(e => new Error(noUrl(e?.shortMessage ?? e?.message ?? e).slice(0, 120)));

async function main() {
  const args = parseArgs();
  const cfg = loadConfig(args.config);
  const h = cfg.health ?? {};
  const sendAlerts = args.execute || args.extra.alert === 'true';
  const logger = makeLogger({ file: `${cfg.statusDir}/${NAME}.log`, name: NAME, echo: false });
  const providers = {};
  for (const [name, c] of Object.entries(cfg.chains ?? {})) if (c.rpcUrl) providers[name] = new JsonRpcProvider(c.rpcUrl, c.chainId, { staticNetwork: true, cacheTimeout: -1 });
  const nowMs = Date.now();
  const results = [];

  for (const spec of h.heartbeats ?? []) results.push(evaluateHeartbeat(spec, readHeartbeat(cfg.statusDir, spec), nowMs));

  const gas = parseGasTargets(h.gas ?? []);
  const balances = await Promise.all(gas.map(t => {
    const p = providers[t.chain];
    if (!p) return new Error(`no RPC for chain ${t.chain}`);
    const read = t.token ? new Contract(t.token, ['function balanceOf(address) view returns (uint256)'], p).balanceOf(t.address) : p.getBalance(t.address);
    return settle(read.then(BigInt), `${t.chain} balance`);
  }));
  gas.forEach((t, i) => results.push(evaluateGas(t, balances[i])));

  if (h.float !== false && h.float !== null && (cfg.contracts?.stockHub || cfg.contracts?.reserveVault)) {
    const hub = providers.arc && cfg.contracts?.stockHub ? new Contract(cfg.contracts.stockHub, StockHubAbi, providers.arc) : null;
    const vault = providers.rh && cfg.contracts?.reserveVault ? new Contract(cfg.contracts.reserveVault, ReserveVaultAbi, providers.rh) : null;
    const none = what => new Error(`${what} not configured (contracts + chains.${what === 'hub' ? 'arc' : 'rh'})`);
    const [arcAvail18, hubFloatOn, rhFree6, rhFloatOn] = await Promise.all([
      hub ? settle(hub.available(), 'hub.available') : none('hub'), hub ? settle(hub.floatEnabled(), 'hub.floatEnabled') : none('hub'),
      vault ? settle(vault.freeSettlement(), 'vault.freeSettlement') : none('vault'), vault ? settle(vault.floatEnabled(), 'vault.floatEnabled') : none('vault')]);
    results.push(...evaluateFloat({ arcAvail18, hubFloatOn, rhFree6, rhFloatOn }, { ...FLOAT_HEALTH_DEFAULTS, ...(h.float ?? {}) }));
  }

  for (const p of Object.values(providers)) p.destroy();
  if (!results.length) throw new Error('config health has no heartbeats, gas or float checks');
  const sum = summarize(results);
  if (args.extra.json === 'true') console.log(JSON.stringify({ at: new Date(nowMs).toISOString(), ...sum, results }, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
  else {
    for (const r of results) console.log(formatLine(r));
    console.log(`${sum.status}: ${sum.counts.OK} ok, ${sum.counts.WARN} warn, ${sum.counts.FAIL} fail`);
  }
  logger.info(`${sum.status} ${JSON.stringify(sum.counts)}${sum.level ? ': ' + results.filter(r => r.level).map(r => r.check).join(', ') : ''}`);

  if (sendAlerts) {
    const stateFile = `${cfg.statusDir}/health-alerts.json`;
    const prev = loadState(stateFile);
    const { send, state } = dueAlerts(results, prev, nowMs, Number(h.repeatMs ?? 3600_000));
    const alert = makeAlerter({ logger, name: NAME, repeatMs: 0 });
    for (const a of send) {
      const res = await withTimeout(alert(a.key, a.text), 'alert').catch(e => { logger.warn(`alert failed: ${e.message}`); return { sent: false, reason: 'delivery' }; });
      if (res?.reason === 'delivery') forgetDelivery(state, prev, a.check); // Telegram down: retry next run, not after repeatMs
    }
    saveState(stateFile, state);
  }
  writeHeartbeat(cfg.statusDir, NAME, { ok: true, execute: true, note: sum.status });
  return sum.exitCode;
}

main().then(code => process.exit(code), error => {
  console.error(`health-check could not run: ${noUrl(error?.message ?? error).slice(0, 300)}`);
  process.exit(3);
});

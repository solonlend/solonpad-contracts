// Ops batch 10-02: heartbeat files, the fleet health check (heartbeat age / gas low-water / float) and its exit code,
// alert de-duplication across runs. Pure parts in-process; the CLI end to end against a local JSON-RPC stub.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, utimesSync, existsSync } from 'node:fs';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { Interface } from 'ethers';
import { writeHeartbeat, heartbeatPath } from '../lib/heartbeat.mjs';
import { readHeartbeat, evaluateHeartbeat, parseGasTargets, evaluateGas, evaluateFloat, summarize, dueAlerts, forgetDelivery, LEVEL } from '../lib/health.mjs';
import { runLoop } from '../lib/runner.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const E18 = 10n ** 18n, E6 = 10n ** 6n;
const W1 = '0x1111111111111111111111111111111111111111', W2 = '0x2222222222222222222222222222222222222222';

test('heartbeat: atomic JSON per process, .dry for dry-run; never throws without a statusDir', () => {
  const dir = tmp();
  assert.equal(writeHeartbeat(dir, 'launcher', { ok: true, execute: true, now: () => 1234 }), true);
  const hb = JSON.parse(readFileSync(heartbeatPath(dir, 'launcher'), 'utf8'));
  assert.deepEqual({ name: hb.name, at: hb.at, ok: hb.ok, failures: hb.failures }, { name: 'launcher', at: 1234, ok: true, failures: 0 });
  writeHeartbeat(dir, 'restock-keeper', { ok: false, execute: false, failures: 2, note: 'x'.repeat(500) });
  const dry = JSON.parse(readFileSync(join(dir, 'heartbeat', 'restock-keeper.dry.json'), 'utf8'));
  assert.equal(dry.ok, false); assert.equal(dry.note.length, 200);
  assert.equal(writeHeartbeat(null, 'x', { ok: true }), false);
});

test('runLoop writes a heartbeat on every tick: ok after success, failures count after an error', async () => {
  const dir = tmp();
  const ctx = { args: { execute: false, loop: false }, logger: quietLogger, alert: async () => {}, wallet: null, cfg: { statusDir: dir } };
  const log = console.log; console.log = () => {};
  try {
    await runLoop(ctx, { tick: async () => ({}) }, { name: 'push-keeper' });
    assert.equal(JSON.parse(readFileSync(heartbeatPath(dir, 'push-keeper', { dry: true }), 'utf8')).ok, true);
    await runLoop(ctx, { tick: async () => { throw new Error('rpc down'); } }, { name: 'push-keeper' });
  } finally { console.log = log; process.exitCode = 0; }
  const hb = JSON.parse(readFileSync(heartbeatPath(dir, 'push-keeper', { dry: true }), 'utf8'));
  assert.deepEqual([hb.ok, hb.failures, hb.note], [false, 1, 'rpc down']);
});

test('evaluateHeartbeat: age thresholds, failed ticks, missing file, log-mtime fallback', () => {
  const spec = { name: 'launcher', warnSec: 120, failSec: 600 };
  const now = 1_000_000_000;
  assert.equal(evaluateHeartbeat(spec, { at: now - 30_000, ok: true }, now).level, LEVEL.OK);
  assert.equal(evaluateHeartbeat(spec, { at: now - 300_000, ok: true }, now).level, LEVEL.WARN);
  assert.equal(evaluateHeartbeat(spec, { at: now - 700_000, ok: true }, now).level, LEVEL.FAIL);
  const failing = evaluateHeartbeat(spec, { at: now - 10_000, ok: false, failures: 2, note: 'nonce too low' }, now);
  assert.equal(failing.level, LEVEL.WARN); assert.match(failing.text, /FAILED \(2 in a row\): nonce too low/);
  assert.equal(evaluateHeartbeat(spec, { at: now - 10_000, ok: false, failures: 5 }, now).level, LEVEL.FAIL);
  assert.equal(evaluateHeartbeat(spec, null, now).level, LEVEL.FAIL);
  assert.equal(evaluateHeartbeat({ ...spec, optional: true }, null, now).level, LEVEL.WARN);
  // Fallback: a process without heartbeat support is judged by its log file's mtime.
  const dir = tmp();
  writeFileSync(join(dir, 'oracle-keeper.log'), 'x\n');
  const old = (Date.now() - 900_000) / 1000;
  utimesSync(join(dir, 'oracle-keeper.log'), old, old);
  const hb = readHeartbeat(dir, { name: 'oracle-keeper' });
  assert.equal(hb.source, 'log-mtime');
  const r = evaluateHeartbeat({ name: 'oracle-keeper', warnSec: 300, failSec: 1800 }, hb, Date.now());
  assert.equal(r.level, LEVEL.WARN); assert.match(r.text, /log mtime/);
  // The heartbeat file wins over the log.
  writeHeartbeat(dir, 'oracle-keeper', { ok: true });
  assert.equal(readHeartbeat(dir, { name: 'oracle-keeper' }).source, 'heartbeat');
});

// Review 10-02: oracle / restock wrote failed heartbeats without a count (failures 0) -> must still be at least WARN;
// error text quoting an RPC URL (dRPC key) never reaches the heartbeat file or the check line.
test('failed heartbeat without a count is WARN; URLs in notes are stripped on write and on read', () => {
  const spec = { name: 'oracle-keeper', warnSec: 300, failSec: 1800 };
  const now = 1_000_000_000;
  const r = evaluateHeartbeat(spec, { at: now - 5_000, ok: false, failures: 0 }, now);
  assert.equal(r.level, LEVEL.WARN); assert.match(r.text, /FAILED \(1 in a row\)/);
  const dir = tmp();
  writeHeartbeat(dir, 'oracle-keeper', { ok: false, failures: 3, note: 'request to https://lb.drpc.live/robinhood/SECRETKEY failed' });
  const raw = readFileSync(heartbeatPath(dir, 'oracle-keeper'), 'utf8');
  assert.doesNotMatch(raw, /SECRETKEY|drpc/); assert.match(raw, /request to <url> failed/);
  const old = evaluateHeartbeat(spec, { at: now, ok: false, failures: 1, note: 'wss://x.example/KEY2 closed' }, now);
  assert.doesNotMatch(old.text, /KEY2/);
});

test('forgetDelivery: a failed Telegram send is retried next run, not after repeatMs', () => {
  const r = (check, level) => ({ check, level, text: 't' });
  const prev = {};
  const { send, state } = dueAlerts([r('a', 2)], prev, 1000, 3600_000);
  assert.equal(send[0].check, 'a');
  forgetDelivery(state, prev, 'a');
  assert.equal(dueAlerts([r('a', 2)], state, 2000, 3600_000).send.length, 1, 'retried on the next run');
  // A failed RECOVERED note keeps the old entry so the recovery is announced next run.
  const prev2 = { a: { level: 2, at: 1000 } };
  const d = dueAlerts([r('a', 0)], prev2, 5000, 3600_000);
  assert.match(d.send[0].text, /^RECOVERED/);
  forgetDelivery(d.state, prev2, 'a');
  assert.match(dueAlerts([r('a', 0)], d.state, 6000, 3600_000).send[0].text, /^RECOVERED/);
});

test('gas: warn / fail low-water marks, ERC-20 decimals, maxLevel cap, unreadable = FAIL', () => {
  const [eth, usdc, bridger] = parseGasTargets([
    { label: 'RH keeper', chain: 'rh', address: W1, warn: '0.02', fail: '0.005', unit: 'ETH' },
    { label: 'Arc hub keeper', chain: 'arc', address: W2, warn: '5', fail: '1', unit: 'USDC' },
    { label: 'bridger USDC', chain: 'eth', address: W2, token: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6, warn: '2', fail: '1', unit: 'USDC', maxLevel: 'WARN', note: 'top up before day 6' },
  ]);
  assert.equal(evaluateGas(eth, 3n * 10n ** 16n).level, LEVEL.OK);
  assert.equal(evaluateGas(eth, 10n ** 16n).level, LEVEL.WARN);
  assert.equal(evaluateGas(eth, 10n ** 15n).level, LEVEL.FAIL);
  assert.equal(evaluateGas(usdc, 4n * E18).level, LEVEL.WARN);
  assert.equal(evaluateGas(usdc, E18 / 2n).level, LEVEL.FAIL);
  const b = evaluateGas(bridger, 0n);
  assert.equal(b.level, LEVEL.WARN, 'capped at WARN'); assert.match(b.text, /0\.00 USDC .*top up before day 6/);
  assert.equal(evaluateGas(bridger, 3n * E6).level, LEVEL.OK);
  assert.equal(evaluateGas(eth, new Error('timeout')).level, LEVEL.FAIL);
  assert.throws(() => parseGasTargets([{ label: 'x', chain: 'rh', address: W1, warn: '1', fail: '2' }]), /fail .* above warn/);
  assert.throws(() => parseGasTargets([{ label: 'x', chain: 'rh', address: '0x12', warn: '1' }]), /bad address/);
});

test('float: both sides vs L_run warn / fail, floatEnabled off = FAIL; summary exit code = worst level', () => {
  const ok = evaluateFloat({ arcAvail18: 2_000n * E18, hubFloatOn: true, rhFree6: 3_000n * E6, rhFloatOn: true });
  assert.deepEqual(ok.map(r => r.level), [0, 0, 0, 0]);
  assert.equal(summarize(ok).exitCode, 0);
  const low = evaluateFloat({ arcAvail18: 802n * E18, hubFloatOn: true, rhFree6: 50n * E6, rhFloatOn: true });
  assert.deepEqual(low.map(r => r.level), [LEVEL.WARN, LEVEL.FAIL, 0, 0]);
  assert.match(low[0].text, /802\.00 USDC/); assert.match(low[1].text, /50\.00 USDG/);
  const off = evaluateFloat({ arcAvail18: 2_000n * E18, hubFloatOn: false, rhFree6: new Error('timeout'), rhFloatOn: true }, { arcWarnUsd: 500, arcFailUsd: 50, rhWarnUsd: 500, rhFailUsd: 50 });
  assert.deepEqual(off.map(r => r.level), [0, LEVEL.FAIL, LEVEL.FAIL, 0]);
  const s = summarize([...ok, low[0]]);
  assert.deepEqual([s.status, s.exitCode, s.counts], ['WARN', 1, { OK: 4, WARN: 1, FAIL: 0 }]);
  assert.equal(summarize(off).exitCode, 2);
});

test('dueAlerts: new / level change / repeat interval, one RECOVERED note, quiet otherwise', () => {
  const r = (check, level) => ({ check, level, text: 't' });
  let { send, state } = dueAlerts([r('a', 1), r('b', 0)], {}, 1000, 3600_000);
  assert.deepEqual(send.map(x => x.text.split(' ')[0]), ['WARN']);
  ({ send, state } = dueAlerts([r('a', 1)], state, 2000, 3600_000));
  assert.equal(send.length, 0, 'same level within repeat window');
  ({ send, state } = dueAlerts([r('a', 2)], state, 3000, 3600_000));
  assert.match(send[0].text, /^FAIL a/);
  ({ send, state } = dueAlerts([r('a', 2)], state, 3000 + 3600_000, 3600_000));
  assert.equal(send.length, 1, 'repeat after the interval');
  ({ send, state } = dueAlerts([r('a', 0)], state, 5000 + 3600_000, 3600_000));
  assert.match(send[0].text, /^RECOVERED a/);
  ({ send } = dueAlerts([r('a', 0)], state, 6000 + 3600_000, 3600_000));
  assert.equal(send.length, 0, 'recovered once');
});

// End to end: the real CLI against a tiny JSON-RPC stub (eth_getBalance / eth_call), real heartbeat files.
test('bin/health-check.mjs: OK/WARN/FAIL lines, exit codes 0 / 1 / 2, --json, no RPC URL in output', async () => {
  const hub = '0x1111111111111111111111111111111111111111', vault = '0x2222222222222222222222222222222222222222';
  const iface = new Interface(['function available() view returns (uint256)', 'function floatEnabled() view returns (bool)', 'function freeSettlement() view returns (uint256)']);
  const state = { bal: { [W1.toLowerCase()]: 5n * 10n ** 16n, [W2.toLowerCase()]: 20n * E18 }, arc: 2_000n * E18, rh: 3_000n * E6 };
  const server = createServer((req, res) => {
    let body = ''; req.on('data', c => { body += c; }); req.on('end', () => {
      const one = q => {
        let result;
        if (q.method === 'eth_chainId') result = '0x' + (req.url.includes('rh') ? 4663 : 5042).toString(16);
        else if (q.method === 'eth_getBalance') result = '0x' + (state.bal[q.params[0].toLowerCase()] ?? 0n).toString(16);
        else if (q.method === 'eth_call') {
          const sel = q.params[0].data.slice(0, 10);
          const fn = iface.getFunction(sel).name;
          const v = fn === 'available' ? state.arc : fn === 'freeSettlement' ? state.rh : true;
          result = iface.encodeFunctionResult(fn, [v]);
        } else result = null;
        return { jsonrpc: '2.0', id: q.id, result };
      };
      const q = JSON.parse(body);
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify(Array.isArray(q) ? q.map(one) : one(q)));
    });
  });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const dir = tmp();
  const cfgFile = join(dir, 'health.json');
  writeFileSync(cfgFile, JSON.stringify({
    chains: { arc: { chainId: 5042, rpcUrl: `http://127.0.0.1:${port}/arc?key=SECRETKEY` }, rh: { chainId: 4663, rpcUrl: `http://127.0.0.1:${port}/rh` } },
    statusDir: dir, contracts: { stockHub: hub, reserveVault: vault },
    health: { heartbeats: [{ name: 'launcher', warnSec: 120, failSec: 600 }], gas: [
      { label: 'RH keeper', chain: 'rh', address: W1, warn: '0.02', fail: '0.005', unit: 'ETH' },
      { label: 'Arc hub keeper', chain: 'arc', address: W2, warn: '5', fail: '1', unit: 'USDC' }] },
  }));
  const run = (...extra) => new Promise((resolve, reject) => {
    const p = spawn(process.execPath, ['bin/health-check.mjs', `--config=${cfgFile}`, ...extra], { cwd: new URL('..', import.meta.url).pathname, env: { PATH: process.env.PATH, HOME: dir } });
    let out = ''; p.stdout.on('data', d => { out += d; }); p.stderr.on('data', d => { out += d; });
    const t = setTimeout(() => { p.kill(); reject(new Error('health-check timed out')); }, 30_000);
    p.on('close', code => { clearTimeout(t); resolve({ code, out }); });
  });
  try {
    writeHeartbeat(dir, 'launcher', { ok: true });
    let r = await run();
    assert.equal(r.code, 0, r.out);
    assert.match(r.out, /^OK {4}heartbeat launcher/m);
    assert.match(r.out, /OK: 7 ok, 0 warn, 0 fail/);
    state.arc = 900n * E18; // Arc float under L_run
    r = await run();
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /^WARN  float Arc hub \(USDC available\): 900\.00 USDC/m);
    state.bal[W1.toLowerCase()] = 10n ** 15n; // RH keeper out of gas
    writeHeartbeat(dir, 'launcher', { ok: true, now: () => Date.now() - 3600_000 });
    r = await run('--json');
    assert.equal(r.code, 2, r.out);
    const j = JSON.parse(r.out);
    assert.equal(j.status, 'FAIL');
    assert.deepEqual(j.results.filter(x => x.level === 2).map(x => x.check).sort(), ['gas RH keeper (rh 0x1111…1111)', 'heartbeat launcher']);
    assert.doesNotMatch(r.out, /SECRETKEY/);
    // --alert without alert config: alerts are only logged; state file written for de-duplication.
    r = await run('--alert');
    assert.equal(r.code, 2);
    assert.ok(existsSync(join(dir, 'health-alerts.json')));
    assert.match(readFileSync(join(dir, 'health-check.log'), 'utf8'), /alert \(not sent: no TELEGRAM_BOT_TOKEN\/TELEGRAM_CHAT_ID\): \[health-check\] FAIL heartbeat launcher/);
    // A dead RPC (unreachable chain) is a FAIL line, not a crash; the URL never shows.
    const cfg = JSON.parse(readFileSync(cfgFile, 'utf8'));
    cfg.chains.rh.rpcUrl = 'http://127.0.0.1:9/rh?key=SECRETKEY';
    writeFileSync(cfgFile, JSON.stringify(cfg));
    r = await run();
    assert.equal(r.code, 2, r.out);
    assert.match(r.out, /FAIL  gas RH keeper .*balance unreadable/);
    assert.doesNotMatch(r.out, /SECRETKEY/);
  } finally {
    server.close();
  }
});

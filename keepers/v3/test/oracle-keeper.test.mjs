import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { Interface, zeroPadValue, toBeHex } from 'ethers';
import { OracleKeeper, SenderAbi, TOPICS, PRICES_SENT, DEMAND_FILE, LAST_FILE } from '../oracle/keeper.mjs';
import { LogWatcher } from '../oracle/watch.mjs';
import { makeDebouncer, E18 } from '../oracle/decide.mjs';
import { Journal } from '../lib/journal.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const N = '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC';
const A = '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9';
const T = '0x322F0929c4625eD5bAd873c95208D54E1c003b2d';
const SENDER = '0x00000000000000000000000000000000000005e4';
const STOCKS = [{ underlying: N }, { underlying: A }, { underlying: T }];
const WED_1500_ET = Date.UTC(2026, 9, 7, 19, 0) / 1000;
const iface = new Interface(SenderAbi);
const usd = x => BigInt(Math.round(x * 1e6)) * 10n ** 12n;

// Manual timers so debounce/backoff are deterministic.
function fakeTimers() {
  let seq = 0;
  const q = new Map();
  return {
    q,
    setTimeout: (fn, ms) => { q.set(++seq, { fn, ms, interval: false }); return seq; },
    clearTimeout: id => q.delete(id),
    setInterval: (fn, ms) => { q.set(++seq, { fn, ms, interval: true }); return seq; },
    clearInterval: id => q.delete(id),
    async runTimeouts() { for (const [id, t] of [...q]) if (!t.interval) { q.delete(id); await t.fn(); } },
    timeouts() { return [...q.values()].filter(t => !t.interval).map(t => t.ms); },
  };
}

function world({ now = WED_1500_ET } = {}) {
  const w = {
    now, l1: 26_000_000, prices: { [N]: 100, [A]: 200, [T]: 300 }, twap: {}, sent: [], quotes: 0, failObserve: new Set(),
    pushTx: new Map(),
  };
  w.source = {
    observe: async (u, opts) => {
      if (w.failObserve.has(u)) throw new Error('StalePrice');
      const px = w.prices[u];
      return { price18: usd(px), twapPrice18: usd(w.twap[u] ?? px), quoteUsd18: E18, sourceUpdatedAt: BigInt(w.updated?.[u] ?? w.now - 60), roundId: 1n, _tag: opts?.blockTag };
    },
  };
  w.sender = {
    target: SENDER, interface: iface,
    quote: async us => { w.quotes++; return 97_000_000_000_000n + BigInt(us.length); },
  };
  w.provider = {
    call: async () => toBeHex(w.l1, 32),
    getBlock: async n => ({ number: n, timestamp: w.now }),
    getBlockNumber: async () => 77_000_000,
    getTransaction: async h => w.pushTx.get(h),
    getLogs: async () => [],
  };
  w.tx = {
    from: '0x00000000000000000000000000000000000000aa',
    mode: 'confirmed',
    send: async req => {
      w.sent.push(req);
      if (w.tx.mode !== 'confirmed') return { status: w.tx.mode };
      const log = { address: SENDER, ...iface.encodeEventLog('PricesSent', [zeroPadValue('0x01', 32), w.l1, 3, req.value]) };
      return { status: 'confirmed', receipt: { hash: `0xtx${w.sent.length}`, blockNumber: 77_000_000 + w.sent.length, logs: [log] } };
    },
  };
  return w;
}

function keeper(w, o = {}) {
  const dir = tmp();
  const journal = new Journal(join(dir, 'oracle-keeper.json'));
  const timers = fakeTimers();
  // r8 behaviour tests: pinned to the pre-2026-10-02 parameters (0.5% + 2h heartbeat) unless a test passes params.
  const k = new OracleKeeper({ params: { deviationBps: 50, heartbeatSec: 7_200 }, stocks: STOCKS, provider: w.provider, sender: w.sender, source: w.source, tx: w.tx, journal, logger: quietLogger, statusDir: dir, execute: true, now: () => w.now, timers, ...o });
  return { k, dir, journal, timers };
}

test('first evaluate pushes all three (initial), writes oracle-push-last.json; then nothing is due', async () => {
  const w = world();
  const { k, dir } = keeper(w);
  const r = await k.evaluate(['start']);
  assert.equal(r.result.status, 'confirmed');
  assert.equal(w.sent.length, 1);
  assert.deepEqual([...iface.decodeFunctionData('poke', w.sent[0].data)[0]], [N, A, T]);
  assert.equal(w.sent[0].value, ((97_000_000_000_000n + 3n) * 11_000n) / 10_000n, 'quote + 10% buffer (refunded)');
  const last = JSON.parse(readFileSync(join(dir, LAST_FILE), 'utf8'));
  assert.equal(last.txHash, '0xtx1');
  assert.equal(last.guid, zeroPadValue('0x01', 32));
  assert.equal(last.rhBlock, 26_000_000);
  assert.equal(last.reason, 'initial');
  assert.equal(last.prices[N], usd(100).toString());
  w.now += 60; w.l1 += 5;
  assert.equal((await k.evaluate()).decision.push, false);
  assert.equal(w.sent.length, 1);
});

test('deviation after a feed move; the same L1 block blocks a second push', async () => {
  const w = world();
  const { k } = keeper(w);
  await k.evaluate();
  w.now += 120; w.prices[A] = 201.2; // +0.6%
  const r = await k.evaluate();
  assert.equal(r.decision.push, false, 'block.number (L1) unchanged since the last push');
  assert.match(r.decision.reason, /L1 block/);
  w.l1 += 1;
  const r2 = await k.evaluate();
  assert.equal(r2.result.status, 'confirmed');
  assert.deepEqual(r2.decision.reasons, { [A]: ['deviation'] });
  assert.equal(w.sent.length, 2);
});

test('demand file triggers a push for stocks not pushed since requestedAt; satisfied demand is idle', async () => {
  const w = world();
  const { k, dir } = keeper(w);
  await k.evaluate();
  w.now += 600; w.l1 += 10;
  writeFileSync(join(dir, DEMAND_FILE), JSON.stringify({ underlyings: [T], reason: 'restock pool A', requestedAt: w.now - 2 }));
  const r = await k.evaluate(['demand-file']);
  assert.equal(r.decision.reason, 'demand');
  assert.equal(r.result.status, 'confirmed');
  assert.equal(JSON.parse(readFileSync(join(dir, LAST_FILE), 'utf8')).reason, 'demand');
  w.now += 90; w.l1 += 10;
  assert.equal((await k.evaluate()).decision.push, false, 'pushed after requestedAt: done');
  writeFileSync(join(dir, DEMAND_FILE), '{broken');
  assert.equal((await k.evaluate()).decision.push, false, 'malformed demand ignored');
});

test('failed send keeps the due episode (same task key) and does not advance last', async () => {
  const w = world();
  const { k, dir, journal } = keeper(w);
  w.tx.mode = 'simulation-failed';
  const r = await k.evaluate();
  assert.equal(r.result.status, 'simulation-failed');
  assert.equal(existsSync(join(dir, LAST_FILE)), false);
  assert.equal(journal.record('oracle', 'last'), null);
  w.now += 30;
  await k.evaluate();
  assert.equal(w.sent[0].key, w.sent[1].key, 'retry reuses the task key (journal backoff applies)');
  w.tx.mode = 'confirmed';
  await k.evaluate();
  assert.equal(journal.record('oracle', 'pending').since, null);
});

test('dry-run writes oracle-push-last.dry.json, never the live file', async () => {
  const w = world();
  w.tx.mode = 'dry-run';
  const { k, dir } = keeper(w, { execute: false });
  const r = await k.evaluate();
  assert.equal(r.result.status, 'dry-run');
  assert.equal(existsSync(join(dir, LAST_FILE)), false);
  assert.equal(JSON.parse(readFileSync(join(dir, 'oracle-push-last.dry.json'), 'utf8')).by, 'dry-run');
});

test('onLogs: feed rounds wake the keeper, swaps only while a pushed observation is TWAP-divergent, PricesSent is adopted', async () => {
  const w = world();
  const { k, timers, journal } = keeper(w);
  await k.evaluate();
  await k.onLogs([{ address: '0xpool', topics: [TOPICS.Swap] }]);
  assert.deepEqual(timers.timeouts(), [], 'swap ignored: nothing divergent');
  await k.onLogs([{ address: '0xagg', topics: [TOPICS.AnswerUpdated] }, { address: '0xagg', topics: [TOPICS.AnswerUpdated] }]);
  assert.deepEqual(timers.timeouts(), [3_000], 'one debounced evaluation');
  // A third party pokes NVDA only; we adopt it as "last" for NVDA.
  w.now += 500; w.l1 += 40; w.prices[N] = 103;
  const data = iface.encodeFunctionData('poke', [[N]]);
  w.pushTx.set('0xother', { from: '0x00000000000000000000000000000000000000bb', data });
  const ev = iface.encodeEventLog('PricesSent', [zeroPadValue('0x02', 32), w.l1, 1, 1n]);
  await k.onLogs([{ address: SENDER, topics: ev.topics, data: ev.data, transactionHash: '0xother', blockNumber: 77_000_500 }]);
  const rec = journal.record('oracle', 'last');
  assert.equal(rec.txHash, '0xother');
  assert.equal(rec.stocks[N].price18, usd(103));
  assert.equal(rec.stocks[A].pushedAt, WED_1500_ET, 'other stocks keep their own push time');
  assert.equal(PRICES_SENT, ev.topics[0]);
});

test('debouncer: a burst collapses into one call; a trigger during a run schedules exactly one follow-up', async () => {
  const timers = fakeTimers();
  const calls = [];
  let release;
  const fn = async why => { calls.push(why); if (calls.length === 1) await new Promise(r => { release = r; }); };
  const trig = makeDebouncer(fn, 3_000, timers);
  trig('a'); trig('b'); trig('c');
  assert.equal(timers.timeouts().length, 1);
  const run = timers.runTimeouts();
  await new Promise(r => setImmediate(r));
  trig('d'); trig('e');
  release();
  await run;
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].sort(), ['a', 'b', 'c']);
  assert.equal(timers.timeouts().length, 1, 'one follow-up queued');
  await timers.runTimeouts();
  assert.equal(calls.length, 2);
});

test('LogWatcher catch-up: chunked ranges, cursor advances only after a successful read', async () => {
  const ranges = [];
  let head = 1_000;
  let fail = false;
  const http = {
    getBlockNumber: async () => head,
    getLogs: async f => { if (fail) throw new Error('rpc down'); ranges.push([f.fromBlock, f.toBlock]); return f.fromBlock === 900 ? [{ topics: [TOPICS.AnswerUpdated] }] : []; },
  };
  const got = [];
  const wtc = new LogWatcher({ http, addresses: ['0x1'], topics: [TOPICS.AnswerUpdated], onLogs: logs => got.push(...logs), maxRange: 100, initialLookback: 200, timers: fakeTimers() });
  assert.equal(await wtc.catchUp(), 1);
  assert.deepEqual(ranges, [[800, 899], [900, 999], [1000, 1000]]);
  assert.equal(wtc.lastBlock, 1_000);
  head = 1_150; fail = true;
  await assert.rejects(wtc.catchUp());
  assert.equal(wtc.lastBlock, 1_000, 'failed read does not skip blocks');
  fail = false; ranges.length = 0;
  await wtc.catchUp();
  assert.deepEqual(ranges, [[1001, 1100], [1101, 1150]]);
});

class FakeWs extends EventEmitter {
  static all = [];
  constructor(url) { super(); this.url = url; this.out = []; FakeWs.all.push(this); }
  send(m) { this.out.push(JSON.parse(m)); }
  ping() { this.pinged = (this.pinged ?? 0) + 1; }
  terminate() { this.terminated = true; this.emit('close'); }
  close() { this.emit('close'); }
}

test('LogWatcher WS: subscribes on open, catches up after every (re)connect, reconnects with backoff, kills a silent socket', async () => {
  FakeWs.all = [];
  const timers = fakeTimers();
  let catchUps = 0;
  const http = { getBlockNumber: async () => { catchUps++; return 10; }, getLogs: async () => [] };
  const seen = [];
  const wtc = new LogWatcher({ http, wsUrl: 'wss://x', WebSocketImpl: FakeWs, addresses: ['0x1'], topics: [TOPICS.AnswerUpdated, TOPICS.Swap], onLogs: (l, origin) => seen.push(origin), timers, stableMs: 1e12 });
  await wtc.start();
  assert.equal(catchUps, 1, 'initial HTTP catch-up');
  const ws = FakeWs.all[0];
  ws.emit('open');
  assert.deepEqual(ws.out[0].params, ['logs', { address: ['0x1'], topics: [[TOPICS.AnswerUpdated, TOPICS.Swap]] }]);
  await new Promise(r => setImmediate(r));
  assert.equal(catchUps, 2, 'catch-up after connect');
  ws.emit('message', JSON.stringify({ method: 'eth_subscription', params: { result: { topics: [TOPICS.AnswerUpdated] } } }));
  await new Promise(r => setImmediate(r));
  assert.deepEqual(seen, ['ws']);
  ws.close();
  assert.deepEqual(timers.timeouts(), [1_000]);
  await timers.runTimeouts();
  const ws2 = FakeWs.all[1];
  ws2.close();
  assert.deepEqual(timers.timeouts(), [2_000], 'exponential backoff');
  await timers.runTimeouts();
  const ws3 = FakeWs.all[2];
  ws3.emit('open');
  await new Promise(r => setImmediate(r));
  assert.equal(catchUps, 3);
  // Ping watchdog: two ping intervals without pong/message => terminate => reconnect scheduled.
  const ping = [...timers.q.values()].find(t => t.interval && t.ms === 30_000);
  ping.fn();
  assert.equal(ws3.pinged, 1);
  ping.fn();
  assert.equal(ws3.terminated, true);
  assert.deepEqual(timers.timeouts(), [4_000]);
  wtc.stop();
  assert.equal(wtc.stats.reconnects, 3);
});

test('M1: a frozen feed in an open session is never pushed and alerts; a Saturday evaluation sends nothing', async () => {
  const w = world();
  const alerts = [];
  const { k } = keeper(w, { alert: async (key, t) => alerts.push({ key, t }) });
  w.updated = { [N]: w.now - 25 * 3600 };
  const out = await k.evaluate(['test']);
  assert.equal(out.decision.push, true);
  assert.equal(w.sent.length, 1);
  assert.deepEqual(iface.decodeFunctionData('poke', w.sent[0].data)[0].map(String).sort(), [A, T].sort(), 'NVDA left out');
  assert.equal(alerts.length, 1);
  assert.match(alerts[0].t, /older than heartbeat/);
  const sat = world({ now: Date.UTC(2026, 9, 10, 16, 0) / 1000 });
  const s = keeper(sat, { alert: async (key, t) => alerts.push({ key, t }) });
  const o2 = await s.k.evaluate(['test']);
  assert.equal(o2.decision.push, false);
  assert.equal(sat.sent.length, 0);
  assert.equal(alerts.length, 1, 'a routine close is not alerted');
});

// On-demand oracle push (2026-10-02): the shared demand file (lib/price-demand.mjs), its reading by the oracle keeper
// (oracle/decide.mjs parseDemand), the Arc freshness check and the push keeper's wait-for-price.
import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { readFileSync, writeFileSync } from 'node:fs';
import { mergeRequest, dropRequest, requestPush, clearRequest, checkArcPrice, DEMAND_FILE } from '../lib/price-demand.mjs';
import { parseDemand, decidePush, mergeParams, E18 } from '../oracle/decide.mjs';
import { PushKeeper } from '../push/keeper.mjs';
import { Journal } from '../lib/journal.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const N = '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC';
const A = '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9';
const WED_1500_ET = Date.UTC(2026, 9, 7, 19, 0) / 1000;
const read = dir => JSON.parse(readFileSync(join(dir, DEMAND_FILE), 'utf8'));

test('merge: one entry per requester, not re-stamped while pending, re-stamped after refreshSec or for a new stock', () => {
  let r = mergeRequest({}, { requester: 'round', underlyings: [N], reason: 'start', nowSec: 1000 });
  assert.equal(r.status, 'demand-written');
  r = mergeRequest(r.body, { requester: 'restock', underlyings: [N, A], reason: 'pool A', nowSec: 1030 });
  assert.deepEqual(Object.keys(r.body.requests), ['round', 'restock']);
  assert.deepEqual(r.body.underlyings, [N, A]);
  assert.equal(r.body.requestedAt, 1030, 'v1 readers see the latest request');
  const same = mergeRequest(r.body, { requester: 'round', underlyings: [N], nowSec: 1500 });
  assert.equal(same.status, 'demand-pending');
  assert.equal(same.body.requests.round.requestedAt, 1000);
  assert.equal(mergeRequest(r.body, { requester: 'round', underlyings: [N], nowSec: 1600 }).status, 'demand-written', '600 s later');
  const more = mergeRequest(r.body, { requester: 'round', underlyings: [A], nowSec: 1100 });
  assert.equal(more.status, 'demand-written');
  assert.deepEqual(more.body.requests.round.underlyings, [N, A]);
  assert.deepEqual(more.body.requests.round.at, { [N]: 1000, [A]: 1100 }, 'NVDA not re-stamped');
  // Expired entries are dropped; a v1 file becomes one legacy request.
  assert.deepEqual(Object.keys(mergeRequest(r.body, { requester: 'push', underlyings: [A], nowSec: 1000 + 1801 }).body.requests), ['restock', 'push']);
  assert.deepEqual(Object.keys(mergeRequest({ underlyings: [A], requestedAt: 990 }, { requester: 'round', underlyings: [N], nowSec: 1000 }).body.requests), ['legacy', 'round']);
});

test('per-stock stamps: adding a stock never re-stamps one in flight; a landed stock is cleared alone', () => {
  let r = mergeRequest({}, { requester: 'push', underlyings: [N], nowSec: 1000 });
  r = mergeRequest(r.body, { requester: 'push', underlyings: [A], nowSec: 1200 });
  assert.equal(r.status, 'demand-written');
  assert.deepEqual(r.body.requests.push.at, { [N]: 1000, [A]: 1200 }, 'NVDA keeps its 1000 stamp');
  const dm = parseDemand(r.body, { listed: [N, A], nowSec: 1300 });
  assert.deepEqual(dm.demand.at, { [N]: 1000, [A]: 1200 });
  const d = dropRequest(r.body, 'push', [N.toLowerCase()]);
  assert.deepEqual(d.requests.push.underlyings, [A], 'only the landed stock is cleared');
  assert.equal(dropRequest(d, 'push', [N]), null, 'nothing left to drop');
});

test('file: concurrent requesters merge under the lock; the oracle keeper pushes once for all of them', async () => {
  const dir = tmp();
  const now = WED_1500_ET;
  const out = await Promise.all([
    requestPush({ statusDir: dir, requester: 'round', underlyings: [N], reason: 'start', nowSec: now - 20 }),
    requestPush({ statusDir: dir, requester: 'restock', underlyings: [N], reason: 'pool A', nowSec: now - 15 }),
    requestPush({ statusDir: dir, requester: 'push', underlyings: [A], reason: 'payout', nowSec: now - 10 }),
  ]);
  assert.deepEqual(out, ['demand-written', 'demand-written', 'demand-written']);
  const body = read(dir);
  assert.deepEqual(Object.keys(body.requests).sort(), ['push', 'restock', 'round'], 'no request lost');
  const dm = parseDemand(body, { listed: [N, A], nowSec: now });
  const p = mergeParams({ deviationBps: 100, heartbeatSec: 0 });
  const obs = usd => ({ ok: true, price18: BigInt(usd) * E18, twapPrice18: BigInt(usd) * E18, quoteUsd18: E18, sourceUpdatedAt: now - 30 });
  const cur = { [N]: obs(180), [A]: obs(250) };
  const old = { [N]: { ...obs(180), pushedAt: now - 3600 }, [A]: { ...obs(250), pushedAt: now - 3600 } };
  const d = decidePush({ nowSec: now, l1Block: 10, lastL1Block: 9, current: cur, last: old, lastPushAt: now - 3600, demand: dm.demand, params: p });
  assert.equal(d.push, true);
  assert.deepEqual(d.underlyings, [N, A], 'one poke carries every requested stock');
  // Right after that push (in flight), every request is answered: no second push.
  const after = { [N]: { ...obs(180), pushedAt: now + 2 }, [A]: { ...obs(250), pushedAt: now + 2 } };
  assert.equal(decidePush({ nowSec: now + 120, l1Block: 20, lastL1Block: 10, current: cur, last: after, lastPushAt: now + 2, demand: dm.demand, params: p }).reason, 'nothing due');
  // A requester whose price landed clears only its own entry.
  assert.equal(await clearRequest({ statusDir: dir, requester: 'round' }), true);
  assert.deepEqual(Object.keys(read(dir).requests).sort(), ['push', 'restock']);
  assert.equal(await clearRequest({ statusDir: dir, requester: 'round' }), false);
});

const fakeOracle = ({ observedAt, status = 1, maxAge = 900, price = 180n * E18, sourceUpdatedAt = observedAt, underlying = N }) => ({
  latest: async () => [{ price18: price || 180n * E18, observedAt: BigInt(observedAt), sourceUpdatedAt: BigInt(sourceUpdatedAt) }, BigInt(status)],
  assetOf: async () => ({ params: { maxAge: BigInt(maxAge) } }),
  priceUSD18: async () => [price, BigInt(observedAt)],
  underlyingOf: async () => underlying,
});

test('checkArcPrice: execPrice window = on-chain maxAge with margin; priceUSD18 consumers pass their own window', async () => {
  const now = 10_000;
  assert.equal((await checkArcPrice({ oracle: fakeOracle({ observedAt: now - 700 }), asset: A, nowSec: now })).fresh, true);
  const old = await checkArcPrice({ oracle: fakeOracle({ observedAt: now - 800, status: 1 }), asset: A, nowSec: now });
  assert.equal(old.fresh, false, '800 + 120 > 900');
  assert.equal(old.demandable, true);
  assert.equal(old.underlying, N, 'demand is keyed by the RH underlying');
  const stale = await checkArcPrice({ oracle: fakeOracle({ observedAt: now - 1000, status: 2 }), asset: A, nowSec: now, windowSec: 7200, marginSec: 900 });
  assert.equal(stale.fresh, true, 'Stale on the 15-min rule but inside the 2h payout window');
  // No heartbeat: the relayed Chainlink time on Arc is > 26h old because nothing was pushed -> priceUSD18 0, Stale.
  // Still demandable: whether the RH feed is frozen is the RH oracle keeper's call (B1 of the 10-02 review).
  const relayOld = await checkArcPrice({ oracle: fakeOracle({ observedAt: now - 30 * 3600, sourceUpdatedAt: now - 30 * 3600, status: 2, price: 0n }), asset: A, nowSec: now });
  assert.deepEqual([relayOld.fresh, relayOld.demandable], [false, true]);
  const frozen = await checkArcPrice({ oracle: fakeOracle({ observedAt: now - 60, sourceUpdatedAt: now - 30 * 3600, status: 2, price: 0n }), asset: A, nowSec: now });
  assert.deepEqual([frozen.fresh, frozen.demandable], [false, false], 'Stale on a recent observation = frozen feed: a push cannot help');
  for (const st of [3, 4, 5]) {
    const r = await checkArcPrice({ oracle: fakeOracle({ observedAt: now - 1000, status: st, price: 0n }), asset: A, nowSec: now });
    assert.deepEqual([r.fresh, r.demandable], [false, false], `status ${st}: divergent / suspect / paused -> no demand`);
  }
});

test('push keeper: an old price during market hours defers the batch with a demand; a fresh one clears it', async () => {
  const dir = tmp();
  const now = WED_1500_ET;
  const w = { observedAt: now - 3 * 3600 };
  const oracle = { latest: async () => [{ price18: 180n * E18, observedAt: BigInt(w.observedAt), sourceUpdatedAt: BigInt(now - 60) }, 2n], assetOf: async () => ({ params: { maxAge: 900n } }), priceUSD18: async () => [180n * E18, BigInt(w.observedAt)], underlyingOf: async () => N };
  const k = new PushKeeper({ cfg: { contracts: { distributor: '0x' + '1'.repeat(40), payoutVault: '0x' + '2'.repeat(40) }, statusDir: dir, push: {} }, provider: null, tx: { execute: true }, journal: new Journal(join(dir, 'j.json')), logger: quietLogger, chainId: 5042, now: () => now, contractAt: () => oracle });
  k.distributor = { oracle: async () => '0x' + '3'.repeat(40), oracleMaxAge: async () => 7200n };
  const r = await k.priceReady({ id: 0, asset: A }, now);
  assert.equal(r.ok, false);
  assert.equal(r.demand, 'demand-written');
  assert.deepEqual(read(dir).requests.push.underlyings, [N]);
  w.observedAt = now - 60;
  assert.equal((await k.priceReady({ id: 0, asset: A }, now)).ok, true);
  assert.equal(read(dir).requests.push, undefined, 'cleared once landed');
  // Saturday: the oracle keeper would not push -> no demand, the day plan decides (skips) as before.
  const SAT = Date.UTC(2026, 9, 10, 16, 0) / 1000;
  w.observedAt = SAT - 3 * 3600;
  oracle.latest = async () => [{ price18: 180n * E18, observedAt: BigInt(w.observedAt), sourceUpdatedAt: BigInt(SAT - 20 * 3600) }, 2n];
  writeFileSync(join(dir, DEMAND_FILE), JSON.stringify({ version: 2, requests: {} }));
  assert.equal((await k.priceReady({ id: 0, asset: A }, SAT)).ok, true);
  assert.deepEqual(read(dir).requests, {});
});

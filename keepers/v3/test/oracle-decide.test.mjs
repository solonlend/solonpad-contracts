import test from 'node:test';
import assert from 'node:assert/strict';
import { decidePush, sessionOpen, parseDemand, mergeParams, movedBps, twapDivergent, recordPush, backoffMs, E18 } from '../oracle/decide.mjs';

const utc = (...a) => Date.UTC(...a) / 1000;
// October 2026 is EDT (UTC-4). 2026-10-04 is a Sunday.
const SUN_1800_ET = utc(2026, 9, 4, 22, 0);
const WED_1500_ET = utc(2026, 9, 7, 19, 0);
const FRI_1700_ET = utc(2026, 9, 9, 21, 0);
const SAT_NOON_ET = utc(2026, 9, 10, 16, 0);
const N = '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC';
const A = '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9';
const T = '0x322F0929c4625eD5bAd873c95208D54E1c003b2d';
// The r8–r12 tests below pin the pre-2026-10-02 parameters (0.5% + 2h heartbeat); on-demand mode has its own test.
const P = mergeParams({ deviationBps: 50, heartbeatSec: 7_200 });
const obs = (usd, { twap = usd, updated = WED_1500_ET - 60, ok = true } = {}) => ({ ok, price18: BigInt(Math.round(usd * 1e6)) * 10n ** 12n, twapPrice18: BigInt(Math.round(twap * 1e6)) * 10n ** 12n, quoteUsd18: E18, sourceUpdatedAt: updated });
const pushed = (usd, at, extra = {}) => ({ ...obs(usd, extra), pushedAt: at });
const base = (o = {}) => ({ nowSec: WED_1500_ET, l1Block: 1000, lastL1Block: 999, lastPushAt: WED_1500_ET - 600, params: P, ...o });

test('24/5 session: Sun 18:00 ET to Fri 17:00 ET, holidays closed', () => {
  assert.equal(sessionOpen(SUN_1800_ET - 60), false, 'Sun 17:59 ET');
  assert.equal(sessionOpen(SUN_1800_ET), true, 'Sun 18:00 ET');
  assert.equal(sessionOpen(WED_1500_ET), true);
  assert.equal(sessionOpen(utc(2026, 9, 7, 7, 0)), true, 'Wed 03:00 ET overnight session');
  assert.equal(sessionOpen(FRI_1700_ET - 60), true, 'Fri 16:59 ET');
  assert.equal(sessionOpen(FRI_1700_ET), false, 'Fri 17:00 ET');
  assert.equal(sessionOpen(SAT_NOON_ET), false);
  assert.equal(sessionOpen(WED_1500_ET, { ...P.session, holidays: ['2026-10-07'] }), false, 'holiday');
  // Winter (EST, UTC-5): 2026-12-06 is a Sunday; 18:00 EST = 23:00 UTC.
  assert.equal(sessionOpen(utc(2026, 11, 6, 22, 59)), false);
  assert.equal(sessionOpen(utc(2026, 11, 6, 23, 0)), true);
});

test('deviation is measured against the last price WE pushed (0.5% default), not the last feed round', () => {
  const last = { [N]: pushed(100, WED_1500_ET - 600) };
  assert.equal(decidePush(base({ current: { [N]: obs(100.49) }, last })).push, false);
  const d = decidePush(base({ current: { [N]: obs(100.51) }, last }));
  assert.equal(d.push, true);
  assert.deepEqual(d.reasons[N], ['deviation']);
  assert.equal(movedBps(10_050n, 10_000n, 50), false, 'exactly 50 bps is not "more than"');
  assert.equal(movedBps(9_949n, 10_000n, 50), true);
});

test('heartbeat at 2h - margin, only in session and while the feed is younger than 26h', () => {
  const at = t => ({ [N]: pushed(100, t) });
  const cur = { [N]: obs(100) };
  assert.equal(decidePush(base({ current: cur, last: at(WED_1500_ET - 6_599), lastPushAt: WED_1500_ET - 6_599 })).push, false);
  const d = decidePush(base({ current: cur, last: at(WED_1500_ET - 6_600), lastPushAt: WED_1500_ET - 6_600 }));
  assert.deepEqual(d.reasons[N], ['heartbeat']);
  const sat = decidePush(base({ nowSec: SAT_NOON_ET, current: { [N]: obs(100, { updated: SAT_NOON_ET - 3600 }) }, last: at(SAT_NOON_ET - 20_000), lastPushAt: SAT_NOON_ET - 20_000 }));
  assert.equal(sat.push, false, 'closed market: no heartbeat');
  assert.equal(sat.sessionOpen, false);
  const frozen = decidePush(base({ current: { [N]: obs(100, { updated: WED_1500_ET - 27 * 3600 }) }, last: at(WED_1500_ET - 7_000), lastPushAt: WED_1500_ET - 7_000 }));
  assert.equal(frozen.push, false, 'feed beyond maxSourceAge: Arc marks Stale anyway');
});

test('M1: no push of any kind while the market is closed (Fri after close, Saturday, holiday) or the feed is frozen', () => {
  const at = t => ({ [N]: pushed(100, t) });
  // Friday 17:30 ET: the feed moved 2% at 16:55, still "fresh" — but the session is over: not pushed.
  const fri = FRI_1700_ET + 1800;
  const friMove = decidePush(base({ nowSec: fri, current: { [N]: obs(102, { updated: FRI_1700_ET - 300 }) }, last: at(fri - 20_000), lastPushAt: fri - 20_000 }));
  assert.equal(friMove.push, false);
  assert.match(friMove.blocked[0].reason, /market closed: weekend/);
  const satMove = decidePush(base({ nowSec: SAT_NOON_ET, current: { [N]: obs(102) }, last: at(SAT_NOON_ET - 20_000), lastPushAt: SAT_NOON_ET - 20_000 }));
  assert.equal(satMove.push, false, 'r8 pushed a Saturday move; M1 does not');
  const demand = { underlyings: [N], requestedAt: SAT_NOON_ET - 10 };
  assert.equal(decidePush(base({ nowSec: SAT_NOON_ET, current: { [N]: obs(100) }, last: {}, demand })).push, false, 'neither initial nor demand');
  // Good Friday 2026-04-03 (EDT): closed all day.
  const gf = utc(2026, 3, 3, 15, 0);
  const hol = decidePush(base({ nowSec: gf, current: { [N]: obs(103, { updated: gf - 3600 }) }, last: at(gf - 20_000), lastPushAt: gf - 20_000 }));
  assert.equal(hol.push, false);
  assert.match(hol.blocked[0].reason, /holiday 2026-04-03/);
  // Open Wednesday, but NVDA's feed is 25h old: NVDA blocked (alert), AAPL still pushed alone.
  const mixed = decidePush(base({ current: { [N]: obs(103, { updated: WED_1500_ET - 25 * 3600 }), [A]: obs(200) }, last: { [N]: pushed(100, WED_1500_ET - 600), [A]: pushed(190, WED_1500_ET - 600) } }));
  assert.equal(mixed.push, true);
  assert.deepEqual(mixed.underlyings, [A], 'batchAll never carries a blocked stock');
  assert.equal(mixed.blocked[0].underlying, N);
  assert.equal(mixed.blocked[0].alert, true);
});

test('TWAP trigger only clears a Divergent observation, never creates one', () => {
  const lastDiv = { [N]: pushed(100, WED_1500_ET - 600, { twap: 98 }) };
  assert.equal(twapDivergent(lastDiv[N], 150), true);
  const clear = decidePush(base({ current: { [N]: obs(100, { twap: 99.5 }) }, last: lastDiv }));
  assert.deepEqual(clear.reasons[N], ['twap']);
  const still = decidePush(base({ current: { [N]: obs(100, { twap: 98.2 }) }, last: lastDiv }));
  assert.equal(still.push, false);
  const lastOk = { [N]: pushed(100, WED_1500_ET - 600, { twap: 100 }) };
  assert.equal(decidePush(base({ current: { [N]: obs(100, { twap: 97 }) }, last: lastOk })).push, false);
  assert.equal(decidePush(base({ current: { [N]: obs(100, { twap: 99.5 }) }, last: lastDiv, params: mergeParams({ twapTrigger: false }) })).push, false);
});

test('batchAll: one due stock sends every readable stock; unreadable ones are skipped', () => {
  const last = { [N]: pushed(100, WED_1500_ET - 600), [A]: pushed(200, WED_1500_ET - 600), [T]: pushed(300, WED_1500_ET - 600) };
  const current = { [N]: obs(101), [A]: obs(200), [T]: { ok: false, error: 'StalePrice' } };
  const d = decidePush(base({ current, last }));
  assert.equal(d.push, true);
  assert.deepEqual(d.underlyings, [N, A]);
  assert.equal(d.skipped[0].underlying, T);
  assert.deepEqual(decidePush(base({ current, last, params: mergeParams({ deviationBps: 50, heartbeatSec: 7_200, batchAll: false }) })).underlyings, [N]);
  assert.deepEqual(decidePush(base({ current: { [N]: obs(100) }, last: {} })).reasons[N], ['initial']);
});

test('guards: min interval, and never twice in the same EVM block.number (L1 block on RH)', () => {
  const last = { [N]: pushed(100, WED_1500_ET - 10) };
  const mi = decidePush(base({ current: { [N]: obs(102) }, last, lastPushAt: WED_1500_ET - 10 }));
  assert.equal(mi.push, false);
  assert.equal(mi.reason, 'min interval');
  const same = decidePush(base({ current: { [N]: obs(102) }, last: { [N]: pushed(100, WED_1500_ET - 600) }, l1Block: 999, lastL1Block: 999 }));
  assert.equal(same.push, false);
  assert.match(same.reason, /L1 block/);
});

test('demand file: pushes stocks not pushed since requestedAt, rate-limited to one per 60s', () => {
  const listed = [N, A, T];
  const ok = parseDemand(JSON.stringify({ underlyings: [N.toLowerCase()], reason: 'restock', requestedAt: WED_1500_ET - 5 }), { listed, nowSec: WED_1500_ET });
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.demand.underlyings, [N]);
  const last = { [N]: pushed(100, WED_1500_ET - 400), [A]: pushed(200, WED_1500_ET - 400) };
  const cur = { [N]: obs(100), [A]: obs(200) };
  const d = decidePush(base({ current: cur, last, lastPushAt: WED_1500_ET - 400, demand: ok.demand }));
  assert.equal(d.push, true);
  assert.equal(d.reason, 'demand');
  assert.deepEqual(d.underlyings, [N, A], 'batchAll');
  const recent = decidePush(base({ current: cur, last: { [N]: pushed(100, WED_1500_ET - 30), [A]: pushed(200, WED_1500_ET - 30) }, lastPushAt: WED_1500_ET - 30, demand: { ...ok.demand, requestedAt: WED_1500_ET - 20 }, params: mergeParams({ demandCoalesceSec: 0 }) }));
  assert.equal(recent.reason, 'min interval', 'demand waits 60s after the last push');
  const satisfied = decidePush(base({ current: cur, last: { [N]: pushed(100, WED_1500_ET - 3), [A]: pushed(200, WED_1500_ET - 3) }, lastPushAt: WED_1500_ET - 3, demand: ok.demand }));
  assert.equal(satisfied.push, false, 'already pushed after requestedAt');
  assert.equal(parseDemand('{nope', { listed, nowSec: WED_1500_ET }).ok, false);
  assert.match(parseDemand({ underlyings: ['0x0000000000000000000000000000000000000001'], requestedAt: WED_1500_ET }, { listed, nowSec: WED_1500_ET }).reason, /unlisted/);
  assert.match(parseDemand({ underlyings: [N], requestedAt: WED_1500_ET - 7200 }, { listed, nowSec: WED_1500_ET }).reason, /expired/);
  assert.equal(parseDemand({ underlyings: [N], requestedAt: WED_1500_ET + 999 }, { listed, nowSec: WED_1500_ET }).demand.requestedAt, WED_1500_ET, 'future clamped');
  assert.equal(parseDemand({ underlyings: [], requestedAt: 1 }, { listed, nowSec: WED_1500_ET }).ok, false);
});

test('on-demand mode: heartbeat 0 = off, 1% deviation; concurrent requests coalesce into one push', () => {
  const p = mergeParams({ deviationBps: 100, heartbeatSec: 0 });
  const last = { [N]: pushed(100, WED_1500_ET - 30 * 86_400) };
  assert.equal(decidePush(base({ current: { [N]: obs(100.9) }, last, params: p })).push, false, 'no heartbeat, 0.9% < 1%');
  assert.deepEqual(decidePush(base({ current: { [N]: obs(101.1) }, last, params: p })).reasons[N], ['deviation']);
  assert.throws(() => mergeParams({ heartbeatSec: 600, heartbeatMarginSec: 600 }), /heartbeatMarginSec/);
  const listed = [N, A, T];
  // round asked at -60 (NVDA), restock asked at -10 (NVDA + AAPL); our push went out at -50 and is still in flight.
  const body = { version: 2, requests: { round: { underlyings: [N], requestedAt: WED_1500_ET - 60, reason: 'start' }, restock: { underlyings: [N, A], requestedAt: WED_1500_ET - 10, reason: 'pool A' } } };
  const dm = parseDemand(body, { listed, nowSec: WED_1500_ET });
  assert.equal(dm.ok, true);
  assert.deepEqual(dm.demand.at, { [N]: WED_1500_ET - 10, [A]: WED_1500_ET - 10 }, 'latest request per stock');
  const inflight = { [N]: pushed(100, WED_1500_ET - 50), [A]: pushed(200, WED_1500_ET - 50) };
  const cur = { [N]: obs(100), [A]: obs(200) };
  const coalesced = decidePush(base({ current: cur, last: inflight, lastPushAt: WED_1500_ET - 50, demand: dm.demand, params: p }));
  assert.equal(coalesced.push, false);
  assert.equal(coalesced.reason, 'nothing due', 'answered by the push in flight (not merely rate-limited)');
  // The same requests 5 min after a push that never landed (requester re-stamped after refreshSec): push again.
  const old = { [N]: pushed(100, WED_1500_ET - 300), [A]: pushed(200, WED_1500_ET - 300) };
  const again = decidePush(base({ current: cur, last: old, lastPushAt: WED_1500_ET - 300, demand: dm.demand, params: p }));
  assert.equal(again.push, true);
  assert.equal(again.reason, 'demand');
  // A stock whose current observation is TWAP-divergent: the demand is refused (it would land Divergent on Arc).
  const div = decidePush(base({ current: { [N]: obs(100, { twap: 95 }), [A]: obs(200) }, last: old, lastPushAt: WED_1500_ET - 300, demand: { ...dm.demand, underlyings: [N], at: { [N]: WED_1500_ET - 10 } }, params: p }));
  assert.equal(div.push, false);
  assert.deepEqual(div.demandRefused, [N]);
  assert.match(div.reason, /demand refused/);
  // One expired / one unlisted entry does not void the others.
  const mixed = parseDemand({ requests: { a: { underlyings: [N], requestedAt: WED_1500_ET - 7200 }, b: { underlyings: ['0x0000000000000000000000000000000000000001'], requestedAt: WED_1500_ET }, c: { underlyings: [T], requestedAt: WED_1500_ET - 5 } } }, { listed, nowSec: WED_1500_ET });
  assert.deepEqual(mixed.demand.underlyings, [T]);
  assert.match(parseDemand({ requests: {} }, { listed, nowSec: WED_1500_ET }).reason, /no request/);
});

test('desk freshness mode (off by default) pushes every freshnessSec in session', () => {
  const last = { [N]: pushed(100, WED_1500_ET - 840) };
  assert.equal(decidePush(base({ current: { [N]: obs(100) }, last })).push, false);
  assert.deepEqual(decidePush(base({ current: { [N]: obs(100) }, last, params: mergeParams({ freshnessSec: 840 }) })).reasons[N], ['freshness']);
});

test('recordPush keeps untouched stocks and params validate', () => {
  const next = recordPush({ [A]: pushed(1, 5) }, { underlyings: [N, T], observations: { [N]: obs(100), [T]: { ok: false } }, pushedAt: 9, l1Block: 7 });
  assert.equal(next[A].pushedAt, 5);
  assert.equal(next[N].pushedAt, 9);
  assert.equal(next[T], undefined);
  assert.throws(() => mergeParams({ heartbeatSec: 7_200, heartbeatMarginSec: 8000 }));
  assert.doesNotThrow(() => mergeParams({ heartbeatSec: 0, heartbeatMarginSec: 8000 }), 'margin unused while the heartbeat is off');
  assert.throws(() => mergeParams({ deviationBps: -1 }));
  assert.deepEqual([0, 1, 2, 6, 7, 20].map(i => backoffMs(i)), [1000, 2000, 4000, 60_000, 60_000, 60_000]);
});

test('on-demand defaults (2026-10-02): 1%, heartbeat off; keeper DEFAULTS and the RH config template agree', async () => {
  const { ORACLE_DEFAULTS: DEFAULTS } = await import("../oracle/decide.mjs");
  const { readFileSync } = await import('node:fs');
  const cfg = JSON.parse(readFileSync(new URL('../config/oracle.example.json', import.meta.url)));
  for (const [k, v] of Object.entries({ deviationBps: 100, heartbeatSec: 0, demandCoalesceSec: 240 })) {
    assert.equal(DEFAULTS[k], v, k);
    assert.equal(cfg.oracle.params[k], v, `template ${k}`);
  }
});

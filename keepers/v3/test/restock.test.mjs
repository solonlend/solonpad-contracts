import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { readFileSync, existsSync } from 'node:fs';
import {
  decideRestock, devBps, tickOfPrice18, alignRange, minSharesFor, minUsdcFor, sharesBound, usdcBound, OracleStatus,
} from '../restock/decide.mjs';
import { RestockKeeper } from '../restock/keeper.mjs';
import { Journal } from '../lib/journal.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const E18 = 10n ** 18n;
// Pre-M1 cases use synthetic clocks (t=1000): the US-market gate is covered separately below.
const LEGACY = { market: false };
const decide = (s, p = {}) => decideRestock(s, { ...LEGACY, ...p });
const P = 180n * E18; // $180 per NVDA.sol (18 dp)
const REF = tickOfPrice18(P); // pool-A tick: STOCK.sol per native USDC
const live = { status: OracleStatus.Live, refTick: REF, price18: P, sourceUpdatedAt: 1000, observedAt: 1000 };
// A pool in range around the reference, with a USDC buffer and no stock buffer.
const base = {
  now: 1000, initialized: true, poolTick: REF, liquidity: 10n ** 20n, tickLower: REF - 400, tickUpper: REF + 400,
  tickSpacing: 200, idleUsdc: 1000n * E18, idleStock: 0n, oracle: live, pending: null, lastActionAt: 0,
};

test('pool-A ticks: price18 <-> tick, deviation sign (positive = NVDA.sol dearer in the pool than the oracle)', () => {
  assert.ok(Math.abs(Math.pow(1.0001, REF) - 1 / 180) / (1 / 180) < 2e-4);
  assert.ok(devBps(REF - 140, REF) > 130); // fewer NVDA.sol per USDC in the pool = dearer
  assert.ok(devBps(REF + 140, REF) < -130);
  assert.ok(Math.abs(devBps(REF, REF)) < 1e-9);
});

test('stop on every non-Live state except a merely old observation; old observation -> ask for a push', () => {
  for (const s of [OracleStatus.Divergent, OracleStatus.Suspect, OracleStatus.Paused, OracleStatus.None]) {
    const d = decide({ ...base, poolTick: REF - 300, oracle: { ...live, status: s, refTick: null } });
    assert.equal(d.action, 'stop', `status ${s}`);
  }
  // Closed market: the Chainlink update is older than 26h -> stop, no push demand.
  const closed = decide({ ...base, now: 200_000, poolTick: REF - 300, oracle: { ...live, status: OracleStatus.Stale, refTick: null, sourceUpdatedAt: 1000 } });
  assert.equal(closed.action, 'stop');
  assert.match(closed.reason, /market closed/);
  // Open market, the relayed observation is just older than 15 min, and the pool is off by > 1.3%: demand a push.
  const old = { ...live, status: OracleStatus.Stale, refTick: null, sourceUpdatedAt: 1000, observedAt: 1000 };
  const d = decide({ ...base, now: 2000, poolTick: REF - 300, oracle: old });
  assert.equal(d.action, 'demandPush');
  // ... but not when nothing would be done anyway.
  assert.equal(decide({ ...base, now: 2000, oracle: old }).action, 'hold');
});

test('inside the 1.3% band: hold; cooldown and a pending restock order are respected', () => {
  assert.equal(decide({ ...base, poolTick: REF - 100 }).action, 'hold'); // ~1.0%
  assert.equal(decide({ ...base, poolTick: REF - 300, lastActionAt: 990 }).reason, 'cooldown');
  const pending = { id: 7, mint: true, at: 900 };
  const d = decide({ ...base, poolTick: REF - 300, pending });
  assert.equal(d.action, 'hold');
  assert.match(d.reason, /restock order 7 pending/);
});

test('pool dear (> +1.3%): sell idle NVDA.sol toward the oracle; without it, restockMint with idle USDC (capped)', () => {
  const withStock = decide({ ...base, poolTick: REF - 300, idleStock: 2n * E18 });
  assert.equal(withStock.action, 'pushPrice');
  assert.equal(withStock.side, 'stock');
  assert.equal(withStock.maxIn, 2n * E18);
  const mint = decide({ ...base, poolTick: REF - 300, idleUsdc: 5000n * E18 });
  assert.equal(mint.action, 'restockMint');
  assert.equal(mint.usdcIn, 1000n * E18); // maxTradeUsd
  const none = decide({ ...base, poolTick: REF - 300, idleUsdc: 10n * E18 });
  assert.equal(none.action, 'hold');
  assert.ok(none.alert);
});

test('pool cheap (< -1.3%): buy back with idle USDC (push); idle NVDA.sol above the keep level is redeemed later', () => {
  const d = decide({ ...base, poolTick: REF + 300 });
  assert.equal(d.action, 'pushPrice');
  assert.equal(d.side, 'usdc');
  assert.equal(d.maxIn, 1000n * E18);
  const redeem = decide({ ...base, idleStock: 5n * E18 }); // $900 idle stock, keep $250
  assert.equal(redeem.action, 'restockRedeem');
  assert.ok(redeem.shares > 3n * E18 && redeem.shares < 4n * E18);
});

test('re-centre near the range edge only while the pool sits at the oracle (vault RANGE_DEVIATION = 50 ticks)', () => {
  const s = { ...base, tickLower: REF - 200, tickUpper: REF + 30 };
  const d = decide(s);
  assert.equal(d.action, 'rebalanceRange');
  assert.ok(d.lower < REF && d.upper > REF && d.lower % 200 === 0 && d.upper % 200 === 0 && d.upper - d.lower <= 4000);
  // the pool is 60 ticks away (inside the 1.3% band, but outside the vault's 50): push first
  const far = decide({ ...s, poolTick: REF + 60 });
  assert.equal(far.action, 'pushPrice');
});

test('seeding: an empty position mints the NVDA.sol part, then sets the first range keeping the USDC buffer', () => {
  const empty = { ...base, liquidity: 0n, tickLower: 0, tickUpper: 0, idleUsdc: 3000n * E18 };
  const mint = decide(empty);
  assert.equal(mint.action, 'restockMint');
  assert.equal(mint.usdcIn, 1000n * E18); // r9: $1,000 NVDA.sol side; $1,000 USDC side + $1,000 reserve stay idle
  const seeded = { ...empty, idleUsdc: 2000n * E18, idleStock: (1000n * E18 * E18) / P };
  const r = decide(seeded);
  assert.equal(r.action, 'rebalanceRange');
  const notInit = decide({ ...empty, initialized: false });
  assert.equal(notInit.action, 'hold');
  assert.match(notInit.reason, /not initialized/);
  // the empty pool is far from the oracle: move it (no liquidity, nothing is spent beyond dust)
  const away = decide({ ...seeded, poolTick: REF + 900 });
  assert.equal(away.action, 'pushPrice');
});

test('restock minimums sit just above the vault floor (bound at refTick -/+ maxDeviation, less the 25 bps hub fee)', () => {
  const usdcIn = 1000n * E18;
  const min = minSharesFor(usdcIn, REF, 60);
  assert.ok(min >= sharesBound(usdcIn, REF, 60));
  assert.ok(min < sharesBound(usdcIn, REF, 50));
  const shares = 5n * E18;
  const minU = minUsdcFor(shares, REF, 60);
  assert.ok(minU >= usdcBound(shares, REF, 60));
  assert.ok(minU < usdcBound(shares, REF, 50));
  const { tickLower, tickUpper } = alignRange({ refTick: REF, halfWidthBps: 200, tickSpacing: 200 });
  assert.ok(tickLower < REF && tickUpper > REF);
});

// ---------------------------------------------------------------- keeper (fake chain)

function fakeChain(over = {}) {
  const sent = [];
  const st = { tick: REF - 300, liquidity: 10n ** 20n, lower: REF - 400, upper: REF + 400, usdc: 5000n * E18, stock: 0n, status: 1, signerTick: REF, ...over };
  const vault = {
    target: '0x000000000000000000000000000000000000Va17'.replace('Va17', 'aa17'),
    currentTick: async () => st.tick, liquidity: async () => st.liquidity, tickLower: async () => st.lower, tickUpper: async () => st.upper,
    poolKey: async () => [0, 0, 10000, 200, 0], interface: { encodeFunctionData: (m, a) => JSON.stringify([m, a], (_, v) => (typeof v === 'bigint' ? v.toString() : v)) },
  };
  const manager = { getSlot0: async () => [1n, st.tick, 0, 0] };
  const tx = { execute: true, call: async (key, c, method, args, opts) => { sent.push({ key, method, args, opts, dry: !tx.execute }); return tx.execute ? { status: 'confirmed', receipt: { logs: [] } } : { status: 'dry-run' }; } };
  return {
    st, sent, tx,
    reader: {
      vault: async () => ({ initialized: true, poolTick: st.tick, liquidity: st.liquidity, tickLower: st.lower, tickUpper: st.upper, tickSpacing: 200, idleUsdc: st.usdc, idleStock: st.stock }),
      oracle: async () => ({ status: st.status, refTick: st.status === 1 ? st.signerTick : null, price18: P, sourceUpdatedAt: 1000, observedAt: 1000 }),
      signerTick: async () => st.signerTick,
      order: async () => ({ status: 2 }),
    },
    vault, manager,
  };
}

test('keeper: dry-run decides but sends nothing; execute sends restockMint with a quote bound to the signer tick', async () => {
  const dir = tmp();
  const c = fakeChain();
  c.tx.execute = false;
  const dry = new RestockKeeper({ params: LEGACY, reader: c.reader, vault: c.vault, tx: c.tx, journal: new Journal(join(dir, 'd.json')), logger: quietLogger, execute: false, now: () => 1000, statusDir: dir });
  const out = await dry.tick();
  assert.equal(out.decision.action, 'restockMint');
  assert.equal(out.status, 'dry-run');
  assert.equal(c.sent.length, 1); // simulated only
  assert.ok(c.sent[0].dry);
  c.sent.length = 0;
  c.tx.execute = true;

  const k = new RestockKeeper({ params: LEGACY, reader: c.reader, vault: c.vault, tx: c.tx, journal: new Journal(join(dir, 'e.json')), logger: quietLogger, execute: true, now: () => 1000, statusDir: dir });
  const r = await k.tick();
  assert.equal(r.status, 'done');
  assert.equal(c.sent.length, 1);
  const { method, args, opts } = c.sent[0];
  assert.equal(method, 'restockMint');
  const [usdcIn, minShares, feeReserve, quote, sig] = args;
  assert.equal(usdcIn, 1000n * E18);
  assert.equal(quote.refTick, REF);
  assert.equal(quote.maxDeviation, 60);
  assert.ok(minShares >= sharesBound(usdcIn, REF, 60));
  assert.equal(opts.value, undefined); // the vault pays from its own idle USDC
  assert.equal(feeReserve, 2n * E18);
  assert.match(sig, /^0x/);
});

test('review: a dry-run restock never writes the oracle push demand file (a --execute oracle keeper would push for it)', async () => {
  const dir = tmp();
  const c = fakeChain({ status: 2 });
  c.tx.execute = false;
  const k = new RestockKeeper({ params: LEGACY, reader: { ...c.reader, oracle: async () => ({ status: 2, refTick: null, price18: P, sourceUpdatedAt: 1500, observedAt: 1000 }) }, vault: c.vault, tx: c.tx, journal: new Journal(join(dir, 'j.json')), logger: quietLogger, execute: false, now: () => 2000, statusDir: dir, underlying: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC' });
  const r = await k.tick();
  assert.equal(r.decision.action, 'demandPush');
  assert.equal(r.status, 'dry-run');
  assert.equal(existsSync(join(dir, 'oracle-push-demand.json')), false);
  assert.equal(c.sent.length, 0);
});

test('keeper: an old observation writes the oracle push demand file (not re-stamped while pending), never a tx', async () => {
  const dir = tmp();
  const c = fakeChain({ status: 2 });
  const k = new RestockKeeper({ params: LEGACY, reader: { ...c.reader, oracle: async () => ({ status: 2, refTick: null, price18: P, sourceUpdatedAt: 1500, observedAt: 1000 }) }, vault: c.vault, tx: c.tx, journal: new Journal(join(dir, 'j.json')), logger: quietLogger, execute: true, now: () => 2000, statusDir: dir, underlying: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC' });
  const r = await k.tick();
  assert.equal(r.decision.action, 'demandPush');
  const file = join(dir, 'oracle-push-demand.json');
  assert.ok(existsSync(file));
  const d = JSON.parse(readFileSync(file, 'utf8'));
  assert.deepEqual(d.underlyings, ['0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC']);
  assert.equal(d.requestedAt, 2000);
  assert.equal(c.sent.length, 0);
  assert.equal(d.requests.restock.requestedAt, 2000);
  const again = await k.tick();
  assert.equal(again.status, 'demand-pending');
  assert.equal(JSON.parse(readFileSync(file, 'utf8')).requestedAt, 2000, 'not re-stamped while the push may be in flight');
});

test('keeper: Divergent stops and alerts; a pending hub order blocks new restocks until it is final', async () => {
  const dir = tmp();
  const alerts = [];
  const c = fakeChain({ status: 3 });
  const k = new RestockKeeper({ params: LEGACY, reader: c.reader, vault: c.vault, tx: c.tx, journal: new Journal(join(dir, 'j.json')), logger: quietLogger, alert: async (key, t) => alerts.push(t), execute: true, now: () => 1000, statusDir: dir });
  const r = await k.tick();
  assert.equal(r.decision.action, 'stop');
  assert.equal(alerts.length, 1);
  assert.equal(c.sent.length, 0);

  const c2 = fakeChain();
  const j = new Journal(join(dir, 'p.json'));
  j.setRecord('restock', 'pending', { id: 9, mint: true, at: 900 });
  let orderStatus = 1; // Dispatched
  const k2 = new RestockKeeper({ params: LEGACY, reader: { ...c2.reader, order: async () => ({ status: orderStatus }) }, vault: c2.vault, tx: c2.tx, journal: j, logger: quietLogger, execute: true, now: () => 1000, statusDir: dir });
  assert.match((await k2.tick()).decision.reason, /pending/);
  orderStatus = 2; // Filled
  const r2 = await k2.tick();
  assert.equal(r2.decision.action, 'restockMint');
  assert.notEqual(j.record('restock', 'pending')?.id, 9); // order 9 cleared; the new mint is the pending one
});

test('events: only pool-A swaps, our underlying\'s oracle prices and NVDA.sol arriving at the vault trigger', async () => {
  const { restockSubscription, TOPICS } = await import('../restock/events.mjs');
  const { zeroPadValue } = await import('ethers');
  const a = n => `0x${String(n).padStart(40, '0')}`;
  const poolId = `0x${'ab'.repeat(32)}`;
  const s = restockSubscription({ poolManager: a(1), oracle: a(2), relayedSource: a(3), token: a(4), vault: a(5), underlying: a(6), poolId });
  assert.equal(s.addresses.length, 4);
  const pad = x => zeroPadValue(x, 32);
  assert.ok(s.relevant({ topics: [TOPICS.Swap, poolId, pad(a(9))] }));
  assert.ok(!s.relevant({ topics: [TOPICS.Swap, `0x${'cd'.repeat(32)}`, pad(a(9))] })); // a meme pool
  assert.ok(s.relevant({ topics: [TOPICS.PriceAccepted, pad(a(6))] }));
  assert.ok(s.relevant({ topics: [TOPICS.Relayed, pad(a(6))] }));
  assert.ok(!s.relevant({ topics: [TOPICS.Relayed, pad(a(7))] })); // AAPL/TSLA
  assert.ok(s.relevant({ topics: [TOPICS.Transfer, pad(a(0)), pad(a(5))] })); // mint to the vault
  assert.ok(!s.relevant({ topics: [TOPICS.Transfer, pad(a(5)), pad(a(8))] }));
});

test('gate (design 12.8): opens only with initialized + ranged + buffer + router + verify + 24h clean dry-run', async () => {
  const { evaluateGate } = await import('../restock/gate.mjs');
  const now = Date.parse('2026-10-03T00:00:00Z');
  const ev = (minAgo, extra = {}) => ({ at: new Date(now - minAgo * 60_000).toISOString(), type: 'restock-decision', action: 'hold', ...extra });
  const events = Array.from({ length: 24 * 4 + 2 }, (_, i) => ev((24 * 4 + 1 - i) * 15));
  const facts = { approvedQuote: true, initialized: true, liquidity: 1n, idleUsdc: 500n * E18, routerBound: true, verifyPassed: true, events };
  assert.equal(evaluateGate(facts, now).open, true);
  assert.equal(evaluateGate({ ...facts, liquidity: 0n }, now).open, false);
  assert.equal(evaluateGate({ ...facts, events: events.slice(10) }, now).open, false); // dry-run younger than 24h
  const gap = events.filter((_, i) => i < 40 || i > 50); // a 2.5h hole
  assert.equal(evaluateGate({ ...facts, events: gap }, now).open, false);
  const bad = [...events, ev(5, { action: 'stop', alert: true })];
  const g = evaluateGate({ ...facts, events: bad }, now);
  assert.equal(g.open, false);
  assert.equal(g.anomalies.length, 1);
  const simFail = [...events, { at: new Date(now - 60_000).toISOString(), type: 'restock-result', status: 'simulation-failed' }];
  assert.equal(evaluateGate({ ...facts, events: simFail }, now).open, false);
});

test('r10 gate buffer = reserve x keeper alert share ($1,000 x 50% = $500), not a flat $100', async () => {
  const { evaluateGate, minBufferUsdOf, GATE_DEFAULTS } = await import('../restock/gate.mjs');
  const { DEFAULTS } = await import('../restock/decide.mjs');
  assert.equal(minBufferUsdOf(GATE_DEFAULTS), 500);
  assert.equal(GATE_DEFAULTS.reserveUsd, DEFAULTS.reserveUsd); // same r9 structure as the keeper
  assert.equal(GATE_DEFAULTS.reserveAlertBps, DEFAULTS.reserveAlertBps);
  const now = Date.parse('2026-10-03T00:00:00Z');
  const events = Array.from({ length: 24 * 4 + 2 }, (_, i) => ({ at: new Date(now - (24 * 4 + 1 - i) * 15 * 60_000).toISOString(), type: 'restock-decision', action: 'hold' }));
  const facts = { approvedQuote: true, initialized: true, liquidity: 1n, routerBound: true, verifyPassed: true, events };
  const at = (usd, params) => evaluateGate({ ...facts, idleUsdc: BigInt(usd) * E18 }, now, params).open;
  assert.equal(at(757), true); // testnet/local first range left $757 idle
  assert.equal(at(499), false); // the keeper would alert "reserve low" here
  assert.equal(at(100), false); // the old flat $100 no longer opens it
  assert.equal(at(24, { reserveUsd: 25 }), true); // testnet scale: $25 reserve -> $12.5
  assert.equal(at(12, { reserveUsd: 25 }), false);
  assert.equal(at(100, { minBufferUsd: 100 }), true); // explicit override still honoured
});

test('r9 starting structure: $1,000 NVDA.sol + $1,000 USDC in range, $1,000 USDC reserve; larger vaults keep the range at target', () => {
  const empty = { ...base, liquidity: 0n, tickLower: 0, tickUpper: 0 };
  // a bigger top-up does not grow the range: the stock side stays at poolStockUsd, the rest is reserve
  const big = decide({ ...empty, idleUsdc: 10_000n * E18 });
  assert.equal(big.action, 'restockMint');
  assert.equal(big.usdcIn, 1000n * E18);
  // less than pool + pool + reserve: the reserve is kept first, the range shrinks
  const small = decide({ ...empty, idleUsdc: 2000n * E18 });
  assert.equal(small.action, 'restockMint');
  assert.equal(small.usdcIn, 500n * E18);
  // reserve alone: nothing to seed
  const only = decide({ ...empty, idleUsdc: 1000n * E18 });
  assert.notEqual(only.action, 'restockMint');
});

test('r9 reserve: anchoring spends the idle USDC reserve; a low reserve alerts for a top-up', () => {
  const cheap = decide({ ...base, poolTick: REF + 300, idleUsdc: 1000n * E18, idleStock: 0n });
  assert.equal(cheap.action, 'pushPrice');
  assert.equal(cheap.side, 'usdc');
  const dear = decide({ ...base, poolTick: REF - 300, idleUsdc: 1000n * E18, idleStock: 0n });
  assert.equal(dear.action, 'restockMint');
  const low = decide({ ...base, idleUsdc: 400n * E18, idleStock: 0n });
  assert.equal(low.action, 'hold');
  assert.equal(low.alert, true);
  assert.match(low.reason, /reserve low/);
  const ok = decide({ ...base, idleUsdc: 900n * E18, idleStock: 0n });
  assert.equal(ok.action, 'hold');
  assert.ok(!ok.alert);
});

// ---- review M1: US market closed / frozen feed -> no anchoring, no restock, no range change (observe + alert)
const at = iso => Math.floor(Date.parse(iso) / 1000);
const FRI_CLOSE = at('2026-10-02T20:00:00Z'); // Fri 16:00 ET, last Chainlink round of the week
const m1 = (now, o = {}) => ({ ...base, now, poolTick: REF - 300, idleStock: 2n * E18, oracle: { ...live, sourceUpdatedAt: FRI_CLOSE, observedAt: now - 60, ...o } });

test('M1: Friday after 17:00 ET the oracle is still Live on a 1h-old price, but the pool is not anchored', () => {
  const now = at('2026-10-02T21:30:00Z'); // Fri 17:30 ET
  assert.equal(decideRestock({ ...m1(now), oracle: { ...m1(now).oracle, sourceUpdatedAt: now - 3600 } }).action, 'stop');
  const d = decideRestock(m1(now));
  assert.equal(d.action, 'stop');
  assert.equal(d.marketClosed, true);
  assert.match(d.reason, /market closed: weekend/);
  assert.match(d.reason, /deviation/, 'the deviation is still observed');
  // Same state on Thursday afternoon (open, fresh feed): it would push idle NVDA.sol.
  const thu = at('2026-10-01T18:00:00Z');
  assert.equal(decideRestock({ ...m1(thu), oracle: { ...live, sourceUpdatedAt: thu - 600, observedAt: thu - 60 } }).action, 'pushPrice');
});

test('M1: Saturday and a NYSE holiday (Good Friday) stop every action, including the push demand and seeding', () => {
  const sat = at('2026-10-03T16:00:00Z');
  for (const st of [m1(sat), { ...m1(sat), liquidity: 0n, idleStock: 0n }, { ...m1(sat), oracle: { ...m1(sat).oracle, status: OracleStatus.Stale } }]) {
    const d = decideRestock(st);
    assert.equal(d.action, 'stop');
    assert.equal(d.marketClosed, true);
  }
  const gf = at('2026-04-03T15:00:00Z');
  const d = decideRestock({ ...m1(gf), oracle: { ...live, sourceUpdatedAt: gf - 20 * 3600, observedAt: gf - 60 } });
  assert.equal(d.action, 'stop');
  assert.match(d.reason, /holiday 2026-04-03/);
});

test('M1: an open session with a feed older than heartbeat + margin stops and alerts', () => {
  const now = at('2026-10-01T18:00:00Z');
  const d = decideRestock({ ...m1(now), oracle: { ...live, sourceUpdatedAt: now - 25 * 3600, observedAt: now - 60 } });
  assert.equal(d.action, 'stop');
  assert.equal(d.alert, true);
  assert.match(d.reason, /older than heartbeat/);
});

test('review B1 (no heartbeat): open Monday, the Arc copy of the Chainlink time is 30h old on an old observation -> push demand, not "feed frozen"', () => {
  const now = at('2026-10-05T14:00:00Z');
  const old = { ...live, status: OracleStatus.Stale, refTick: null, sourceUpdatedAt: now - 30 * 3600, observedAt: now - 30 * 3600, maxAge: 900 };
  const d = decideRestock({ ...m1(now), poolTick: REF - 300, oracle: old });
  assert.equal(d.action, 'demandPush', d.reason);
  // A RECENT observation that is Stale on the relayed time = the feed really is frozen: stop + alert, no demand.
  const frozen = decideRestock({ ...m1(now), poolTick: REF - 300, oracle: { ...old, observedAt: now - 60 } });
  assert.equal(frozen.action, 'stop');
  assert.equal(frozen.alert, true);
});

test('M1 keeper: a closed market alerts once per closed episode and sends nothing', async () => {
  const dir = tmp();
  const alerts = [];
  const c = fakeChain();
  let now = at('2026-10-03T16:00:00Z');
  const reader = { ...c.reader, oracle: async () => ({ status: 1, refTick: REF, price18: P, sourceUpdatedAt: FRI_CLOSE, observedAt: now - 60 }) };
  const k = new RestockKeeper({ reader, vault: c.vault, tx: c.tx, journal: new Journal(join(dir, 'j.json')), logger: quietLogger, alert: async (key, t) => alerts.push(t), execute: true, now: () => now, statusDir: dir });
  assert.equal((await k.tick()).decision.action, 'stop');
  now += 600;
  await k.tick();
  assert.equal(alerts.length, 1, 'one alert for the episode');
  assert.match(alerts[0], /paused/);
  assert.equal(c.sent.length, 0);
});

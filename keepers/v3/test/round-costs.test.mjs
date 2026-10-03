// RoundKeeper batch start against fake contracts: fork findings F2 (6-dp budget), F3 (oracle floor + alert on a failing
// simulation), F4 (hub fee + Relay + LZ in fees18, external cost signed), M1 (market gate).
import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { Interface, Wallet, AbiCoder } from 'ethers';
import { Journal } from '../lib/journal.mjs';
import { RoundKeeper } from '../round/keeper.mjs';
import { RoundManagerAbi } from '../lib/abis.mjs';
import { stockQuoteDigest, digestSignerFor } from './round-fakes.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const E18 = 10n ** 18n;
const A = n => '0x' + n.toString(16).padStart(40, '0');
const at = iso => Math.floor(Date.parse(iso) / 1000);
const THU = at('2026-10-01T18:00:00Z');
const PRICE = 231_604_391_200_000_000_000n;
const mgrIface = new Interface(RoundManagerAbi);
const errs = new Interface(['error InvalidQuote()', 'error InsufficientValue(uint256,uint256)']);

function world({ queue = [350_175_316_592_261_904_761n], now = THU, sourceUpdatedAt = THU - 600, buyFeeBps = 25n, lzFee = 300_000_000_000_000_000n, relayFeeBps = 15n, sim = null, hubFeesView = true, observedAge = 60, maxAge = 900, statusDir = tmp() } = {}) {
  const signer = Wallet.createRandom();
  const w = { now, sent: [], alerts: [], previews: [], observedAt: now - observedAge, statusDir };
  const C = { manager: A(1), batcher: A(2), registry: A(3), adapter: A(4), hub: A(5), oracle: A(6), asset: A(7), underlying: A(8), vault: A(9), ops: A(10), rewardOracle: A(11) };
  const config = { coordinator: C.manager, vault: C.vault, asset: C.asset, underlying: C.underlying, hub: C.hub, signer: signer.address, path: '0x' + '11'.repeat(32), destinationChain: 4663n, opsVault: C.ops, oracle: C.oracle };
  const avail = new Map(queue.map((b, i) => [i + 1, b]));
  const entry = id => ({ source: A(100), pool: '0x' + '00'.repeat(32), epoch: 1n, cohort: 0n, budget18: avail.get(id), creditTotal: 1n, allocationId: BigInt(id), assetId: '0x' + '22'.repeat(32), adapterVersion: 1n, pricePolicy: '0x' + '00'.repeat(32), eligibilityMode: 0n });
  const preview = (group, max) => {
    w.previews.push(max);
    if (max === 0n) throw new Error('require(maxBudget > 0)');
    const ids = []; const budgets = []; let total = 0n;
    for (const [id, a] of avail) { if (total >= max) break; const take = a < max - total ? a : max - total; ids.push(BigInt(id)); budgets.push(take); total += take; }
    return { ids, budgets, total };
  };
  const fees = { adapter: 0n };
  const fakes = {
    [C.adapter]: {
      target: C.adapter, config: async () => config, feeBalance: async () => fees.adapter, nonceUsed: async () => false,
      quoteDigest: async q => stockQuoteDigest({ chainId: 5042, adapter: C.adapter, config, q }), interface: { encodeFunctionData: () => '0x' },
    },
    [C.hub]: { fees: async () => { if (!hubFeesView) throw new Error('no fees()'); return [buyFeeBps, 25n, 0n]; }, quoteOrder: async () => lzFee },
    [C.oracle]: {
      rawFor: async (asset, usd) => (usd * E18) / PRICE,
      // SolonStockOracle: Stale once the observation is older than the on-chain maxAge; priceUSD18 ignores the age.
      latest: async () => [{ price18: PRICE, sourceUpdatedAt: BigInt(sourceUpdatedAt), observedAt: BigInt(w.observedAt) }, w.now - w.observedAt > maxAge ? 2n : 1n],
      assetOf: async () => ({ token: C.asset, params: { maxAge: BigInt(maxAge) } }),
      priceUSD18: async () => [PRICE, BigInt(w.observedAt)],
      underlyingOf: async () => C.underlying,
    },
    [C.rewardOracle]: { priceUSD18: async () => [PRICE, BigInt(w.observedAt)] },
    [C.asset]: { decimals: async () => 18n },
  };
  const k = new RoundKeeper({
    cfg: { contracts: { roundManager: C.manager, batcher: C.batcher, stockRegistry: C.registry, rewardPriceOracle: C.rewardOracle }, round: {}, statusDir },
    provider: null, journal: new Journal(join(tmp(), 'r.json')), logger: quietLogger, chainId: 5042, now: () => w.now,
    alert: async (key, text) => w.alerts.push({ key, text }),
    lane: { name: 'fake', quoteMinOut6: async amt => (amt * (10_000n - relayFeeBps)) / 10_000n / 10n ** 12n },
    quoteSigner: digestSignerFor(signer),
    contractAt: addr => fakes[addr],
    tx: {
      execute: true,
      call: async (key, contract, method, args, opts = {}) => {
        w.sent.push({ key, method, args, opts });
        if (method === 'depositFees') { fees.adapter += opts.value; return { status: 'confirmed' }; }
        if (method === 'executeAndStart') {
          const err = sim?.(args, w);
          if (err) return { status: 'simulation-failed', error: err };
          const log = { address: C.manager, ...mgrIface.encodeEventLog('RoundState', [7n, 2]) };
          return { status: 'confirmed', receipt: { logs: [log] } };
        }
        return { status: 'confirmed' };
      },
    },
  });
  k.manager = {
    target: C.manager, interface: mgrIface, nextEntryId: async () => BigInt(queue.length), groupKey: async () => '0x' + '33'.repeat(32),
    available: async id => avail.get(Number(id)), pending: async () => 0n, minimumBudget: async () => 100n * E18, runLimit: async () => 10_000n * E18,
    entry: async id => entry(Number(id)), executionNonce: async () => 0n,
  };
  k.batcher = { target: C.batcher, nextToEnqueue: async () => BigInt(queue.length + 1), cursor: async () => 0n, previewBatch: async (g, m) => preview(g, m) };
  k.registry = { resolve: async () => ({ asset: C.asset, underlying: C.underlying, hub: C.hub, adapter: C.adapter, fixedCost18: 0n }) };
  k.summary = { actions: [], deferred: [], seams: [] };
  return { k, w, C, config };
}
const decodeQuote = data => AbiCoder.defaultAbiCoder().decode(['tuple(bytes32 orderId,uint256 budget18,uint256 minRawOut,uint256 deadline,uint256 nonce,uint256 fees18,uint256 fixedCost18)', 'bytes'], data)[0];

test('F2: executeAndStart gets a 1e12-aligned maxBudget; the batch is previewed with it and the dust stays queued', async () => {
  const { k, w } = world();
  await k.batchPhase(0);
  const start = w.sent.find(s => s.method === 'executeAndStart');
  assert.ok(start, JSON.stringify(k.summary.deferred));
  const [ids, maxBudget, minRaw] = start.args;
  assert.equal(maxBudget, 350_175_316n * 10n ** 12n);
  assert.equal(maxBudget % 10n ** 12n, 0n);
  assert.deepEqual(ids, [1]);
  assert.equal(w.previews.at(-1), maxBudget, 'last preview used the aligned budget (what the batcher recomputes)');
  const q = decodeQuote(start.args[4]);
  assert.equal(q.budget18, maxBudget, 'signed budget = aligned total');
  assert.ok(minRaw * 10_000n >= ((maxBudget * E18) / PRICE) * 9_900n, 'F3: minRaw over the adapter floor');
});

test('F2: only sub-micro dust left -> deferred, previewBatch never called with 0', async () => {
  const { k, w } = world({ queue: [999_999_999_999n] });
  await k.batchPhase(0);
  assert.equal(w.sent.length, 0);
  assert.ok(!w.previews.includes(0n));
  assert.match(k.summary.deferred[0].reason, /Dust|BelowMinimum|Empty/);
});

test('F4: fees18 = hub 25 bps + Relay + LZ x1.2 deposited on the adapter; signed fixedCost18 = Relay + LZ only', async () => {
  const { k, w } = world({ queue: [230_580_000n * 10n ** 12n] });
  await k.batchPhase(0);
  const dep = w.sent.find(s => s.method === 'depositFees');
  const start = w.sent.find(s => s.method === 'executeAndStart');
  assert.ok(start, JSON.stringify(k.summary.deferred));
  const q = decodeQuote(start.args[4]);
  const budget = 230_580_000n * 10n ** 12n;
  const hubFee = (budget * 25n) / 10_000n;
  const lz = 360_000_000_000_000_000n;
  assert.equal(q.fees18, dep.opts.value);
  assert.ok(q.fees18 - hubFee - lz > 0n, 'Relay fee included');
  assert.equal(q.fixedCost18, q.fees18 - hubFee, 'external cost only');
  assert.ok(q.fixedCost18 <= budget / 200n, 'the $230 round starts (fork case D was CostLimit)');
});

test('F4 compat: an older hub without fees() falls back to the configured 25 bps', async () => {
  const { k, w } = world({ hubFeesView: false });
  await k.batchPhase(0);
  const q = decodeQuote(w.sent.find(s => s.method === 'executeAndStart').args[4]);
  assert.ok(q.fees18 > (350_175_316n * 10n ** 12n * 25n) / 10_000n);
});

test('F3: a failing executeAndStart simulation alerts with the decoded reason instead of a silent backoff', async () => {
  const { k, w } = world({ sim: () => ({ data: errs.encodeErrorResult('InvalidQuote', []) }) });
  await k.batchPhase(0);
  assert.equal(w.alerts.length, 1);
  assert.match(w.alerts[0].text, /InvalidQuote/);
  assert.equal(k.summary.deferred.at(-1).reason, 'SimulationFailed');
});

test('F4 compat: InsufficientValue(got, need) from the hub raises the planned fees by the shortfall for the retry', async () => {
  let n = 0;
  const { k, w } = world({ sim: args => (n++ === 0 ? { data: errs.encodeErrorResult('InsufficientValue', [100n, 150n]) } : null) });
  await k.batchPhase(0);
  assert.match(w.alerts[0].text, /InsufficientValue/);
  const first = decodeQuote(w.sent.find(s => s.method === 'executeAndStart').args[4]);
  w.sent.length = 0;
  await k.batchPhase(0);
  const second = decodeQuote(w.sent.find(s => s.method === 'executeAndStart').args[4]);
  assert.equal(second.orderId, first.orderId, 'same order, fees topped up');
  assert.ok(second.fees18 >= first.fees18 + 50n);
  assert.equal(w.sent.find(s => s.method === 'depositFees').opts.value, second.fees18 - first.fees18);
});

test('M1: no round starts while the US market is closed (Saturday) or the feed is frozen; frozen alerts', async () => {
  const sat = at('2026-10-03T16:00:00Z');
  const a = world({ now: sat, sourceUpdatedAt: at('2026-10-02T20:00:00Z') });
  await a.k.batchPhase(0);
  assert.equal(a.w.sent.length, 0);
  assert.equal(a.k.summary.deferred[0].reason, 'MarketClosed');
  assert.equal(a.w.alerts.length, 0);
  const b = world({ sourceUpdatedAt: THU - 26 * 3600 });
  await b.k.batchPhase(0);
  assert.equal(b.w.sent.length, 0);
  assert.equal(b.w.alerts.length, 1);
});

test('decimals M2: repeated Relay funding-quote failures alert after failAlertAfter ticks, and a success resets', async () => {
  const { k, w } = world();
  k.lane = { name: 'fake', quoteMinOut6: async () => { throw new Error('relay quote HTTP 400 ORIGIN_CURRENCY_MISMATCH'); } };
  await k.batchPhase(0);
  await k.batchPhase(0);
  assert.equal(w.alerts.length, 0, 'transient failures stay quiet');
  assert.equal(k.summary.deferred.at(-1).reason, 'FundingQuote');
  await k.batchPhase(0);
  assert.equal(w.alerts.length, 1, 'third failure in a row alerts');
  assert.match(w.alerts[0].text, /ORIGIN_CURRENCY_MISMATCH/);
  k.lane = { name: 'fake', quoteMinOut6: async amt => (amt * 9_985n) / 10_000n / 10n ** 12n };
  await k.batchPhase(0);
  assert.ok(w.sent.find(s => s.method === 'executeAndStart'), 'round starts once Relay quotes again');
  k.lane = { name: 'fake', quoteMinOut6: async () => { throw new Error('again'); } };
  const before = w.alerts.length;
  await k.batchPhase(0);
  assert.equal(w.alerts.length, before, 'counter was reset by the success');
});

// ------------------------------------------------------------ on-demand oracle push (2026-10-02)
const demandOf = dir => { try { return JSON.parse(readFileSync(join(dir, 'oracle-push-demand.json'), 'utf8')); } catch { return null; } };

test('freshness: the on-chain maxAge (not 1h) gates the start; an old price writes a push demand and defers', async () => {
  // 13m20s old: inside the old 1h check, but 800 + 120 s margin > the oracle's 900 s maxAge -> the start would revert.
  const { k, w, C } = world({ observedAge: 800 });
  await k.batchPhase(0);
  assert.equal(k.summary.deferred[0].reason, 'AwaitingPrice');
  assert.equal(k.summary.deferred[0].demand, 'demand-written');
  assert.ok(!w.sent.some(x => x.method === 'executeAndStart' || x.method === 'depositFees'), 'nothing sent');
  const d = demandOf(w.statusDir);
  assert.deepEqual(d.requests.round.underlyings, [C.underlying], 'demand names the RH underlying (oracle.underlyingOf)');
  // Next tick, push still in flight: the request is not re-stamped (no second push).
  k.summary = { actions: [], deferred: [], seams: [] };
  await k.batchPhase(0);
  assert.equal(k.summary.deferred[0].demand, 'demand-pending');
  // The push lands on Arc: next tick starts and clears its request.
  w.observedAt = w.now - 5;
  k.summary = { actions: [], deferred: [], seams: [] };
  await k.batchPhase(0);
  assert.ok(w.sent.some(x => x.method === 'executeAndStart'), 'started after the price landed');
  assert.equal(demandOf(w.statusDir).requests.round, undefined, 'request cleared');
});

test('freshness: the window is read from the chain (maxAge 3600 -> a 13-min-old price starts at once)', async () => {
  const { k, w } = world({ observedAge: 800, maxAge: 3600 });
  await k.batchPhase(0);
  assert.ok(w.sent.some(x => x.method === 'executeAndStart'));
  assert.equal(demandOf(w.statusDir), null, 'no demand');
});

test('freshness: dry-run never writes the demand file; a divergent price is NoPrice, not a demand', async () => {
  const dry = world({ observedAge: 800 });
  dry.k.tx.execute = false;
  await dry.k.batchPhase(0);
  assert.equal(dry.k.summary.deferred[0].demand, 'dry-run');
  assert.equal(demandOf(dry.w.statusDir), null);
  const bad = world({ observedAge: 800 });
  const orig = bad.k.at;
  const divergent = async () => [{ price18: PRICE, sourceUpdatedAt: BigInt(THU - 600), observedAt: BigInt(bad.w.observedAt) }, 3n];
  bad.k.at = (addr, abi) => (addr === bad.C.oracle ? { ...orig(addr, abi), latest: divergent, priceUSD18: async () => [0n, 0n] } : orig(addr, abi));
  await bad.k.batchPhase(0);
  assert.equal(bad.k.summary.deferred[0].reason, 'NoPrice');
  assert.equal(demandOf(bad.w.statusDir), null);
});

test('freshness (review B1): no heartbeat -> the Arc copy of the Chainlink time is 30h old on an open Monday; the round asks for a push instead of holding as "feed frozen"', async () => {
  const MON = at('2026-10-05T14:00:00Z'); // Monday 10:00 ET, open
  const { k, w } = world({ now: MON, sourceUpdatedAt: MON - 30 * 3600, observedAge: 30 * 3600 });
  await k.batchPhase(0);
  assert.equal(k.summary.deferred[0].reason, 'AwaitingPrice', JSON.stringify(k.summary.deferred));
  assert.equal(w.alerts.length, 0, 'no frozen-feed alert while a push is requested');
  assert.ok(demandOf(w.statusDir).requests.round);
  // A Saturday stays MarketClosed (calendar), no demand.
  const SAT = at('2026-10-10T16:00:00Z');
  const s2 = world({ now: SAT, sourceUpdatedAt: SAT - 20 * 3600, observedAge: 20 * 3600 });
  await s2.k.batchPhase(0);
  assert.equal(s2.k.summary.deferred[0].reason, 'MarketClosed');
  assert.equal(demandOf(s2.w.statusDir), null);
});

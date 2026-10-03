import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { readFileSync, existsSync } from 'node:fs';
import { ZeroAddress } from 'ethers';
import { Journal } from '../lib/journal.mjs';
import { DeskKeeper } from '../desk/keeper.mjs';
import { perCardRaw, planGroups, deskGasPlan, kind0Stage, passUpdate } from '../desk/decide.mjs';
import { DeskSim, ADDR, B32, DAY, P27, E18 } from './desk-fakes.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const E = 20_400; // fee day (UTC epoch number); the market gate is off in these tests (params.market = false)
const MIN = 2n * E18;
const POOL = B32(0xa1), POOL2 = B32(0xa2), POOL3 = B32(0xa3);

function setup({ cards = 40, now = E * DAY + 12 * 3600, execute = true, path = join(tmp(), 'desk.json'), params = {} } = {}) {
  const sim = new DeskSim({ now, cards });
  return { sim, ...build(sim, { execute, path, params }) };
}

function build(sim, { execute = true, path, params = {} }) {
  const journal = new Journal(path);
  const alerts = [];
  const statusDir = join(tmp(), 'state');
  const cfg = { statusDir, contracts: { deskRewards: ADDR.rewards, deskNft: ADDR.nft, roundManager: ADDR.manager },
    desk: { discover: { fromBlock: 1, params: { confirmations: 2 } }, params: { market: false, ...params } } };
  const keeper = new DeskKeeper({ cfg, provider: sim.provider(), tx: sim.txSender(journal, { execute }), journal, logger: quietLogger,
    alert: async (k, m) => alerts.push({ k, m }), chainId: 5042, now: () => sim.now, contractAt: sim.contractAt() });
  return { keeper, journal, alerts, statusDir, path };
}

const kinds = s => s.actions.map(a => a.kind);
async function settle(keeper, n = 6) { const out = []; for (let i = 0; i < n; i++) out.push(await keeper.tick()); return out; }

// ------------------------------------------------------------------------------------------------ pure decisions

test('perCardRaw: stock stream = counter / 1e27; USDC stream = counter x purchased / totalCredit27', () => {
  assert.equal(perCardRaw({ kind: 1, counter: 5n * E18 * P27 / 100n, totalCredit27: 0n, purchasedRaw: 0n }), 5n * E18 / 100n);
  assert.equal(perCardRaw({ kind: 0, counter: 10n * P27, totalCredit27: 400n * P27, purchasedRaw: 4n * E18 }), E18 / 10n);
  assert.equal(perCardRaw({ kind: 0, counter: 10n * P27, totalCredit27: 0n, purchasedRaw: 4n * E18 }), 0n);
});

test('planGroups: same-asset keys are combined until a card is worth the push minimum; full below-minimum group drops its oldest as dust', () => {
  const price = new Map([[ADDR.nvda, 100n * E18]]);
  const k = (i, raw, at = i) => ({ key: B32(i), asset: ADDR.nvda, perCard: raw, readyAt: at });
  // 0.012 + 0.012 NVDA x $100 = $2.4 >= $2 x 1.1
  let p = planGroups({ ready: [k(1, 12n * E18 / 1000n), k(2, 12n * E18 / 1000n)], prices: price, minimumUSD18: MIN, maxKeys: 8, marginBps: 1000 });
  assert.deepEqual(p.open.map(g => g.keys), [[B32(1), B32(2)]]);
  // one alone ($1.2) waits
  p = planGroups({ ready: [k(1, 12n * E18 / 1000n)], prices: price, minimumUSD18: MIN, maxKeys: 8, marginBps: 1000 });
  assert.equal(p.open.length, 0);
  assert.deepEqual(p.hold, [B32(1)]);
  // 3 keys, maxKeys 2: [1,2] opens, 3 held; large keys are split into several queues
  p = planGroups({ ready: [k(1, E18), k(2, E18), k(3, E18 / 1000n)], prices: price, minimumUSD18: MIN, maxKeys: 2, marginBps: 1000 });
  assert.deepEqual(p.open.map(g => g.keys), [[B32(1), B32(2)]]);
  assert.deepEqual(p.hold, [B32(3)]);
  // maxKeys dust keys still below minimum -> the oldest is given up (manual claim) so newer ones can group
  p = planGroups({ ready: [k(1, 1n, 5), k(2, 1n, 1)], prices: price, minimumUSD18: MIN, maxKeys: 2, marginBps: 1000 });
  assert.deepEqual(p.dust.map(d => d.key), [B32(2)]);
  // unknown / zero price: nothing opens, nothing is dust
  p = planGroups({ ready: [k(1, E18)], prices: new Map(), minimumUSD18: MIN, maxKeys: 8, marginBps: 1000 });
  assert.deepEqual([p.open.length, p.dust.length, p.hold.length], [0, 0, 1]);
});

test('deskGasPlan: reserve grows with streams per queue; cards per tx fit maxTxGas; never more than 32', () => {
  const one = deskGasPlan({ keys: 1, maxTxGas: 15_000_000 });
  assert.equal(one.cards, 32);
  assert.ok(one.gasLimit <= 15_000_000 && one.gasLimit >= 600_000 + 32 * 100_000);
  const eight = deskGasPlan({ keys: 8, maxTxGas: 15_000_000 });
  assert.ok(eight.cards >= 1 && eight.cards < 32);
  assert.ok(eight.gasLimit <= 15_000_000 && eight.gasLimit > 500_000 * 8 + 100_000);
  assert.equal(deskGasPlan({ keys: 20, maxTxGas: 9_000_000 }).cards, 1, 'at least one card when the reserve alone nearly fills the cap');
});

test('kind0Stage: epoch end -> entry source -> seal -> round -> sync -> ready (dust < 1e12 left in available is ready)', () => {
  const base = { now: (E + 1) * DAY, epoch: E, budget: 5n * E18, sealed: false, entrySource: null, entryId: null, delivered: 0n, purchasedRaw: 0n, available: 0n, pending: 0n };
  assert.equal(kind0Stage({ ...base, now: (E + 1) * DAY - 1 }).stage, 'wait-epoch');
  assert.equal(kind0Stage({ ...base, budget: 0n }).stage, 'empty');
  assert.equal(kind0Stage(base).stage, 'create-entry');
  assert.equal(kind0Stage({ ...base, entrySource: ADDR.protocol }).stage, 'seal');
  assert.equal(kind0Stage({ ...base, sealed: true, entrySource: ADDR.protocol }).stage, 'find-entry');
  const sealed = { ...base, sealed: true, entrySource: ADDR.protocol, entryId: 3, available: 5n * E18 };
  assert.equal(kind0Stage(sealed).stage, 'await-round');
  assert.equal(kind0Stage({ ...sealed, available: 2n * E18, delivered: 7n }).stage, 'sync', 'partial delivery is synced as it lands');
  assert.equal(kind0Stage({ ...sealed, available: 2n * E18, delivered: 7n, purchasedRaw: 7n }).stage, 'await-round');
  assert.equal(kind0Stage({ ...sealed, available: 10n ** 12n - 1n, delivered: 9n, purchasedRaw: 9n }).stage, 'ready');
  assert.equal(kind0Stage({ ...sealed, available: 0n, pending: 0n, delivered: 0n }).stage, 'await-round');
});

test('passUpdate: a complete pass with no blocked card is done; blocked cards get another day up to maxPasses', () => {
  let r = passUpdate({}, { start: 0, after: 32, upperBound: 40, paid: 30, failed: 0, maxPasses: 3 });
  assert.deepEqual([r.moved, r.complete, r.patch.done ?? false], [true, false, false]);
  r = passUpdate(r.patch, { start: 32, after: 40, upperBound: 40, paid: 8, failed: 1, maxPasses: 3 });
  assert.deepEqual([r.complete, r.patch.done ?? false, r.patch.passes], [true, false, 1]);
  r = passUpdate(r.patch, { start: 0, after: 40, upperBound: 40, paid: 0, failed: 0, maxPasses: 3 });
  assert.equal(r.patch.done, true);
  r = passUpdate({ passes: 2 }, { start: 0, after: 40, upperBound: 40, paid: 0, failed: 1, maxPasses: 3 });
  assert.equal(r.patch.done, true);
  assert.equal(r.alert, true);
  assert.equal(passUpdate({}, { start: 8, after: 8, upperBound: 40, paid: 0, failed: 0, maxPasses: 3 }).moved, false);
});

// ------------------------------------------------------------------------------------------------ keeper on the model

test('USDC-quoted pool: DeskFeeCredit -> next day entrySource + seal -> round settles -> syncPurchased -> openDeskQueue -> 00:10 push to every card', async () => {
  const { sim, keeper, journal } = setup();
  const key = sim.credit({ source: POOL, epoch: E, asset: ZeroAddress, kind: 0, perCard27: E18 * P27 / 2n }); // 0.5 USDC of fees per card
  let s = await keeper.tick();
  assert.deepEqual(kinds(s), [], 'fee day still open: nothing to seal');
  assert.equal(s.streams.waiting, 1);

  sim.now = (E + 1) * DAY + 30;
  s = await keeper.tick();
  assert.deepEqual(kinds(s), ['entrySource', 'seal']);
  assert.equal(sim.entries.length - 1, 1);
  s = await keeper.tick();
  assert.deepEqual(kinds(s), [], 'sealed, round not settled yet');
  assert.equal(journal.record('deskStream', key).entryId, 1);

  sim.deliver(1, 2n * E18); // round Settled: 2 NVDA.sol for this entry -> 0.05 per card ($5)
  s = await keeper.tick();
  assert.deepEqual(kinds(s), ['syncPurchased', 'openDeskQueue']);
  assert.equal(sim.queues.length, 1);
  assert.ok(s.deferred.some(d => d.reason === 'scan-window'), '00:00:30 UTC: before the 00:10 scan window');

  sim.now = (E + 1) * DAY + 700;
  s = await keeper.tick();
  assert.deepEqual(kinds(s), ['batchDistributeDesk']);
  assert.equal(s.actions[0].from, 0);
  assert.ok(s.actions[0].to > 0 && s.actions[0].to < 40);
  sim.now += 900;
  await settle(keeper, 3);
  for (let c = 1; c <= 40; c++) assert.equal(sim.received.get(c), 5n * E18 / 100n, `card ${c} paid`);
  assert.equal(journal.record('deskQueue', '0').done, true);
  sim.now += DAY;
  s = await keeper.tick();
  assert.deepEqual(kinds(s), [], 'done queue is not scanned again');
});

test('stock-quoted pool: no entry source / seal / sync — the stream queues directly after its day and pays the stock', async () => {
  const { sim, keeper } = setup();
  sim.credit({ source: POOL, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: 3n * E18 * P27 / 100n }); // 0.03 NVDA.sol per card = $3
  assert.deepEqual(kinds(await keeper.tick()), []);
  sim.now = (E + 1) * DAY + 700;
  const s = await keeper.tick();
  assert.deepEqual(kinds(s), ['openDeskQueue', 'batchDistributeDesk']);
  assert.equal(sim.count('entrySource') + sim.count('seal') + sim.count('syncPurchased'), 0);
  sim.now += 900;
  await settle(keeper, 3);
  assert.equal(sim.received.get(40), 3n * E18 / 100n);
});

test('discovery: out-of-order, repeated DeskFeeCredit logs of one stream -> one stream; cursor persisted', async () => {
  const { sim, keeper, journal } = setup();
  for (let i = 0; i < 5; i++) sim.credit({ source: POOL, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: E18 * P27 / 100n });
  sim.credit({ source: POOL2, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: E18 * P27 / 100n });
  const s = await keeper.tick();
  assert.equal(s.streams.known, 2);
  assert.equal(Object.values(journal.state.records.discoverCursor)[0].next, sim.block + 1);
});

test('restart mid-chain (same journal file) and lost journal: nothing is sent twice, the chain decides', async () => {
  const path = join(tmp(), 'desk.json');
  const sim = new DeskSim({ now: E * DAY + 3600, cards: 40 });
  const k0 = sim.credit({ source: POOL, epoch: E, asset: ZeroAddress, kind: 0, perCard27: E18 * P27 });
  sim.credit({ source: POOL2, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: 5n * E18 * P27 / 100n });
  let { keeper } = build(sim, { path });
  sim.now = (E + 1) * DAY + 700;
  await keeper.tick(); // seal the USDC stream, queue + first page of the stock stream
  assert.equal(sim.count('seal'), 1);
  ({ keeper } = build(sim, { path })); // restart: new process, same journal file
  await keeper.tick();
  assert.equal(sim.count('seal'), 1);
  assert.equal(sim.count('entrySource'), 1);
  sim.deliver(1, 4n * E18);
  await keeper.tick();
  const lost = build(sim, { path: join(tmp(), 'fresh.json') }); // journal lost: cursors and records gone
  sim.now += 900;
  await settle(lost.keeper, 4);
  assert.equal(sim.count('seal'), 1);
  assert.equal(sim.count('syncPurchased'), 1);
  assert.equal(sim.count('openDeskQueue'), 2, 'one queue per asset; the rebuilt keeper adopts the chain queues instead of opening new ones');
  for (let c = 1; c <= 40; c++) assert.equal(sim.claimable(c, k0), 0n);
  assert.equal(sim.received.get(7), 5n * E18 / 100n + 4n * E18 / 40n);
});

test('partial delivery (round split): synced as it lands, queued only when the entry is fully bought', async () => {
  const { sim, keeper } = setup();
  sim.credit({ source: POOL, epoch: E, asset: ZeroAddress, kind: 0, perCard27: E18 * P27 });
  sim.now = (E + 1) * DAY + 700;
  await keeper.tick();
  sim.deliver(1, 1n * E18, { remaining: 20n * E18 });
  let s = await keeper.tick();
  assert.deepEqual(kinds(s), ['syncPurchased']);
  sim.deliver(1, 3n * E18, { remaining: 0n });
  s = await keeper.tick();
  assert.deepEqual(kinds(s), ['syncPurchased', 'openDeskQueue', 'batchDistributeDesk']);
  assert.deepEqual(sim.queues[0].revisions, [4n * E18]);
});

test('small streams of one asset are held and combined into one queue once a card is worth the minimum', async () => {
  const { sim, keeper } = setup();
  const per = 12n * E18 * P27 / 1000n; // 0.012 NVDA.sol per card = $1.2
  sim.credit({ source: POOL, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: per });
  sim.now = (E + 1) * DAY + 700;
  let s = await keeper.tick();
  assert.deepEqual(kinds(s), []);
  assert.equal(s.streams.held, 1);
  sim.credit({ source: POOL2, epoch: E + 1, asset: ADDR.nvda, kind: 1, perCard27: per });
  sim.credit({ source: POOL3, epoch: E + 1, asset: ADDR.aapl, kind: 1, perCard27: per }); // other asset: never mixed
  sim.now = (E + 2) * DAY + 700;
  sim.setPrice(ADDR.nvda, 100n * E18, sim.now);
  s = await keeper.tick();
  assert.deepEqual(kinds(s), ['openDeskQueue', 'batchDistributeDesk']);
  assert.equal(sim.queues[0].keys.length, 2);
  assert.equal(sim.queues[0].asset, ADDR.nvda);
});

test('old price: no batch (it would burn a pass paying nobody); a push demand is written, the batch runs once the price lands', async () => {
  const { sim, keeper, statusDir } = setup();
  sim.credit({ source: POOL, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: 5n * E18 * P27 / 100n });
  sim.now = (E + 1) * DAY + 700;
  sim.setPrice(ADDR.nvda, 100n * E18, sim.now - 3 * 3600);
  let s = await keeper.tick();
  assert.deepEqual(kinds(s), ['openDeskQueue']);
  assert.ok(s.deferred.some(d => /awaiting oracle push/.test(d.reason)));
  const demand = JSON.parse(readFileSync(join(statusDir, 'oracle-push-demand.json'), 'utf8'));
  assert.deepEqual(Object.keys(demand.requests), ['desk']);
  sim.setPrice(ADDR.nvda, 100n * E18, sim.now);
  s = await keeper.tick();
  assert.deepEqual(kinds(s), ['batchDistributeDesk']);
  assert.ok(!existsSync(join(statusDir, 'oracle-push-demand.json')) || !JSON.parse(readFileSync(join(statusDir, 'oracle-push-demand.json'), 'utf8')).requests?.desk);
});

test('protocol Desk share: fundProtocolDeskBudget (USDC stream) / forwardProtocolDesk (stock stream) once the day is over', async () => {
  const { sim, keeper } = setup();
  const a = sim.credit({ source: POOL, epoch: E, asset: ZeroAddress, kind: 0, perCard27: E18 * P27, protocol27: 3n * P27 });
  const b = sim.credit({ source: POOL2, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: 5n * E18 * P27 / 100n, protocol27: 4n * P27 });
  await keeper.tick();
  assert.equal(sim.protocolCalls.length, 0);
  sim.now = (E + 1) * DAY + 700;
  await settle(keeper, 2);
  assert.deepEqual(sim.protocolCalls.sort(), [['forward', b], ['fund', a]].sort());
});

test('seal keeps failing (missing route): quarantined after 5 attempts -> one alert; dry-run sends nothing', async () => {
  const { sim, keeper, alerts } = setup();
  sim.credit({ source: POOL, epoch: E, asset: ZeroAddress, kind: 0, perCard27: E18 * P27 });
  sim.routeMissing = true;
  sim.now = (E + 1) * DAY + 700;
  await settle(keeper, 7);
  assert.equal(sim.count('seal'), 0);
  assert.ok(alerts.some(a => /^desk-seal/.test(a.k)), JSON.stringify(alerts));

  const dry = setup({ execute: false });
  dry.sim.credit({ source: POOL, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: 5n * E18 * P27 / 100n });
  dry.sim.now = (E + 1) * DAY + 700;
  const s = await dry.keeper.tick();
  assert.deepEqual(s.actions.map(a => a.status), ['dry-run']);
  assert.equal(dry.sim.queues.length, 0);
});

test('blocked cards: the queue is scanned again on later days, then given up with an alert', async () => {
  const { sim, keeper, alerts, journal } = setup({ params: { maxPasses: 2 } });
  sim.credit({ source: POOL, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: 5n * E18 * P27 / 100n });
  sim.blocked.add(3);
  sim.now = (E + 1) * DAY + 700;
  for (let i = 0; i < 4; i++) { await keeper.tick(); sim.now += 900; }
  assert.equal(journal.record('deskQueue', '0').passes, 1);
  assert.notEqual(journal.record('deskQueue', '0').done, true);
  sim.now = (E + 2) * DAY + 700;
  for (let i = 0; i < 4; i++) { await keeper.tick(); sim.now += 900; }
  assert.equal(journal.record('deskQueue', '0').done, true);
  assert.ok(alerts.some(a => /desk-queue-0/.test(a.k)));
});

test('a confirmed batch that does not move the cursor (gas guard) is a failure with an alert, not progress', async () => {
  const { sim, keeper, alerts } = setup({ params: { fixedGas: 0, perCardGas: 0, perKeyCardGas: 0, maxTxGas: 500_000 } });
  sim.credit({ source: POOL, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: 5n * E18 * P27 / 100n });
  sim.now = (E + 1) * DAY + 700;
  const s = await keeper.tick();
  assert.equal(s.actions.at(-1).status, 'no-progress');
  assert.ok(alerts.some(a => /stall/.test(a.k)));
});

test('a stranger opened exactly our queue first: adopted and serviced, not opened again', async () => {
  const { sim, keeper } = setup();
  const k = sim.credit({ source: POOL, epoch: E, asset: ADDR.nvda, kind: 1, perCard27: 5n * E18 * P27 / 100n });
  sim.now = (E + 1) * DAY + 700;
  sim.openQueueAsStranger([k]);
  await settle(keeper, 1);
  sim.now += 900;
  await settle(keeper, 2);
  assert.equal(sim.count('openDeskQueue'), 0);
  assert.equal(sim.received.get(40), 5n * E18 / 100n);
});

test('a USDC-quoted stream below 1e12 (sub-micro-dollar) is never sealed; a sealed entry left as grid dust ends as unbuyable', async () => {
  const { sim, keeper, journal } = setup();
  const k = sim.credit({ source: POOL, epoch: E, asset: ZeroAddress, kind: 0, perCard27: 10n ** 10n * P27 / 40n });
  sim.now = (E + 1) * DAY + 700;
  await settle(keeper, 2);
  assert.equal(sim.count('entrySource') + sim.count('seal'), 0);
  assert.equal(journal.record('deskStream', k).done, true);
});

test('sealed but unbought: BelowMinimum (group still accumulating) is quiet; Ready for > 2 days alerts', async () => {
  const { sim, keeper, alerts } = setup();
  sim.credit({ source: POOL, epoch: E, asset: ZeroAddress, kind: 0, perCard27: E18 * P27 });
  sim.now = (E + 1) * DAY + 700;
  await keeper.tick();
  sim.now += 3 * DAY;
  await keeper.tick();
  assert.equal(alerts.length, 0, JSON.stringify(alerts));
  sim.entryReason.set(1, 0);
  await keeper.tick();
  assert.ok(alerts.some(a => a.k === 'desk-round-1'));
});

test('market closed (24/5 calendar) with an old price: no batch and no push demand until the session opens', async () => {
  const sat = 20_512 * DAY; // 2026-02-28, a Saturday
  const { sim, keeper, statusDir } = setup({ now: sat - DAY + 3600, params: { market: {} } });
  sim.credit({ source: POOL, epoch: sat / DAY - 1, asset: ADDR.nvda, kind: 1, perCard27: 5n * E18 * P27 / 100n });
  sim.now = sat + 3600;
  sim.setPrice(ADDR.nvda, 100n * E18, sim.now - 5 * 3600);
  const s = await keeper.tick();
  assert.deepEqual(kinds(s), ['openDeskQueue']);
  assert.ok(s.deferred.some(d => /market closed/.test(d.reason)), JSON.stringify(s.deferred));
  assert.equal(existsSync(join(statusDir, 'oracle-push-demand.json')), false);
});

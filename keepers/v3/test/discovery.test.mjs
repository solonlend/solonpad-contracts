import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { Interface, ZeroAddress } from 'ethers';
import { Journal } from '../lib/journal.mjs';
import { LogDiscovery, mergeSources } from '../lib/discovery.mjs';
import { RewardSourceDiscovery, LAUNCH_LOCKED } from '../round/sources.mjs';
import { RoundKeeper } from '../round/keeper.mjs';
import { PushKeeper } from '../push/keeper.mjs';
import { LaunchFactoryAbi, StakingV2Abi } from '../lib/abis.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const A = n => '0x' + String(n).repeat(40);
const B32 = n => '0x' + n.toString(16).padStart(64, '0');
const DAY = 86_400;
const E = 20_000; // UTC day of block 0 in the fake chain
const FACTORY = A(7);
const STAKING = A(8);
const factoryIface = new Interface(LaunchFactoryAbi);
const stakingIface = new Interface(StakingV2Abi);

let logSeq = 0;
const launchLog = (block, token, state, index = logSeq++) => ({
  address: FACTORY, blockNumber: block, index, transactionHash: B32(1000 + index), removed: false,
  ...factoryIface.encodeEventLog('LaunchState', [B32(block), token, state]),
});
const laneLog = (block, key, kind, index = logSeq++) => ({
  address: STAKING, blockNumber: block, index, transactionHash: B32(2000 + index), removed: false,
  ...stakingIface.encodeEventLog('SourceRegistered', [key, B32(9), A(5), kind]),
});

// Fake chain: getLogs returns matches in REVERSE order (out-of-order RPC) and can be told to fail on a range.
function chain({ head, logs, failFrom = null }) {
  const calls = [];
  return {
    calls,
    head,
    getBlockNumber: async function () { return this.head; },
    getBlock: async n => ({ timestamp: E * DAY + n * 600 }), // 144 blocks per day
    getLogs: async ({ address, topics, fromBlock, toBlock }) => {
      calls.push([fromBlock, toBlock]);
      if (failFrom != null && toBlock >= failFrom.block && failFrom.times-- > 0) throw new Error('rpc timeout');
      return logs.filter(l => l.address.toLowerCase() === address.toLowerCase() && l.blockNumber >= fromBlock && l.blockNumber <= toBlock && l.topics[0] === topics[0]).reverse();
    },
  };
}

const scanner = (provider, journal, extra = {}) => new LogDiscovery({
  provider, journal, name: 'launch', address: FACTORY, topics: [factoryIface.getEvent('LaunchState').topicHash], fromBlock: 10,
  params: { confirmations: 2, chunk: 100 },
  decode: async (log, ts) => {
    const e = factoryIface.parseLog(log);
    return Number(e.args.state) === LAUNCH_LOCKED ? { id: e.args.token.toLowerCase(), address: e.args.token, firstEpoch: Math.floor(ts / DAY) } : null;
  },
  ...extra,
});

test('discovery: out-of-order and duplicate logs -> one item per token, earliest sighting kept, Registered/Initialized ignored', async () => {
  const logs = [launchLog(50, A(1), 1), launchLog(50, A(1), 2), launchLog(50, A(1), 3), launchLog(150, A(2), 3), launchLog(160, A(2), 3) /* re-emission */];
  const p = chain({ head: 400, logs });
  const j = new Journal(join(tmp(), 'j.json'));
  const d = scanner(p, j);
  const r = await d.sync();
  assert.deepEqual(r.added.sort(), [A(1).toLowerCase(), A(2).toLowerCase()].sort());
  const items = d.items();
  assert.deepEqual(items.map(i => i.address), [A(1), A(2)]); // sorted by chain position, not RPC order
  assert.equal(items[1].block, 150);
  assert.equal(d.cursor(), 399); // head 400 - 2 confirmations = 398 scanned
});

test('discovery: restart resumes from the persisted cursor, never re-adds, picks up new launches', async () => {
  const path = join(tmp(), 'j.json');
  const logs = [launchLog(20, A(1), 3)];
  const p = chain({ head: 120, logs });
  const first = await scanner(p, new Journal(path)).sync();
  assert.equal(first.added.length, 1);
  assert.equal(first.next, 119);
  logs.push(launchLog(130, A(2), 3), launchLog(20, A(1), 3) /* replayed old log */);
  p.head = 300;
  p.calls.length = 0;
  const d2 = scanner(p, new Journal(path)); // fresh process, same journal file
  const second = await d2.sync();
  assert.deepEqual(second.added, [A(2).toLowerCase()]);
  assert.equal(p.calls[0][0], 119, 'resumed at the cursor, not fromBlock');
  assert.equal(d2.items().length, 2);
});

test('discovery: an RPC failure mid-scan keeps the finished chunks and the next run continues from there', async () => {
  const path = join(tmp(), 'j.json');
  const logs = [launchLog(30, A(1), 3), launchLog(250, A(2), 3)];
  const p = chain({ head: 400, logs, failFrom: { block: 210, times: 1 } });
  await assert.rejects(scanner(p, new Journal(path)).sync(), /rpc timeout/);
  const j = new Journal(path);
  assert.equal(scanner(p, j).cursor(), 210, 'chunks 10-109 and 110-209 committed');
  assert.equal(scanner(p, j).items().length, 1);
  const r = await scanner(p, j).sync();
  assert.deepEqual(r.added, [A(2).toLowerCase()]);
});

test('discovery: logs inside the confirmation window wait for the next run; removed (reorged) logs are ignored', async () => {
  const logs = [launchLog(99, A(1), 3), { ...launchLog(60, A(3), 3), removed: true }];
  const p = chain({ head: 100, logs });
  const j = new Journal(join(tmp(), 'j.json'));
  assert.equal((await scanner(p, j).sync()).added.length, 0);
  p.head = 101;
  assert.deepEqual((await scanner(p, j).sync()).added, [A(1).toLowerCase()]);
});

test('discovery: a missing fromBlock is a config error, not a scan from genesis', () => {
  assert.throws(() => scanner(chain({ head: 1, logs: [] }), new Journal(join(tmp(), 'j.json')), { fromBlock: undefined }), /fromBlock is required/);
});

test('mergeSources: configured entries win, discovered ones are added once (case-insensitive)', () => {
  const merged = mergeSources(
    [{ address: A(1), kind: 'token', firstEpoch: 5 }],
    [{ address: A(1).toLowerCase(), kind: 'token', firstEpoch: 9 }, { address: A(2), kind: 'token', firstEpoch: 9 }, { address: A(2), kind: 'token', firstEpoch: 10 }],
  );
  assert.deepEqual(merged.map(s => [s.address, s.firstEpoch]), [[A(1), 5], [A(2), 9]]);
});

// Contracts behind contractAt: token kinds, staking views.
function fakeAt({ kinds = {}, staking = {} } = {}) {
  return (address, abi) => {
    if (address.toLowerCase() === STAKING.toLowerCase()) return { target: STAKING, interface: stakingIface, ...staking };
    return {
      target: address,
      settlementKind: async () => BigInt(kinds[address.toLowerCase()] ?? 0),
      rewardPolicy: async () => ({ assetId: B32(1), version: 1n, pricePolicy: B32(2), mode: 0n }),
      epochBudget: async () => 0n, rewardSealed: async () => false, nextRoundAt: async () => 0n,
    };
  };
}

test('reward sources: USDC-quoted launches become round sources (firstEpoch = launch day); stock-quoted ones do not', async () => {
  const logs = [launchLog(144 * 2 + 5, A(1), 3), launchLog(144 * 3, A(2), 3), launchLog(144 * 3 + 1, A(3), 1)];
  const d = new RewardSourceDiscovery({ provider: chain({ head: 1000, logs }), journal: new Journal(join(tmp(), 'j.json')), logger: quietLogger,
    discover: { factory: FACTORY, fromBlock: 0 }, at: fakeAt({ kinds: { [A(2).toLowerCase()]: 1 } }) });
  await d.sync();
  assert.deepEqual(d.roundTokens(), [{ address: A(1), kind: 'token', firstEpoch: E + 2, discovered: true }]);
});

const txRecorder = (execute = false, status = execute ? 'confirmed' : 'dry-run') => {
  const calls = [];
  return { calls, execute, reconcileAll: async () => {}, call: async (key, c, method, args) => { calls.push({ key, method, args, to: c.target }); return { status }; } };
};

function roundKeeper({ logs, sources = [], tx = txRecorder(), at = fakeAt(), discover = { factory: FACTORY, fromBlock: 0 } }) {
  const provider = chain({ head: 2000, logs });
  const journal = new Journal(join(tmp(), 'j.json'));
  const cfg = { contracts: { roundManager: A(1), batcher: A(2), stockRegistry: A(3) }, round: { sources, discover, params: { lookbackEpochs: 30 } } };
  const k = new RoundKeeper({ cfg, provider, tx, journal, logger: quietLogger, alert: async () => {}, lane: null, chainId: 5042, now: () => (E + 12) * DAY + 100, contractAt: at });
  k.summary = { actions: [], deferred: [], seams: [] };
  return { k, tx, journal, provider };
}

test('round keeper: two new coins are discovered and sealed with no config change; configured sources still run (union)', async () => {
  const logs = [launchLog(144 * 5, A(4), 3), launchLog(144 * 6, A(5), 3)];
  const at = (address, abi) => {
    const base = fakeAt()(address, abi);
    return { ...base, epochBudget: async () => 10n ** 18n }; // every epoch funded
  };
  const { k, tx } = roundKeeper({ logs, sources: [{ address: A(6), kind: 'token', firstEpoch: E + 10 }], at });
  await k.discoverPhase();
  assert.deepEqual(k.sourceList().map(s => s.address), [A(6), A(4), A(5)]);
  await k.sealPhase();
  const sealed = tx.calls.filter(c => c.method === 'seal').map(c => [c.args[0], Number(c.args[1])]);
  const firstOf = a => Math.min(...sealed.filter(s => s[0] === a).map(s => s[1]));
  assert.equal(firstOf(A(4)), E + 5);
  assert.equal(firstOf(A(5)), E + 6);
  assert.equal(firstOf(A(6)), E + 10);
  assert.ok(k.summary.actions.some(a => a.kind === 'discovered'));
});

test('round keeper: discovery RPC failure keeps the configured sources sealing and alerts after repeated failures', async () => {
  const { k, journal } = roundKeeper({ logs: [], sources: [{ address: A(6), kind: 'token', firstEpoch: E + 11 }] });
  const alerts = [];
  k.alert = async (key, msg) => alerts.push(key);
  k.provider.getLogs = async () => { throw new Error('429'); };
  for (let i = 0; i < 5; i++) { k.summary = { actions: [], deferred: [], seams: [] }; await k.discoverPhase(); }
  assert.equal(journal.record('discoveryHealth', 'round').failures, 5);
  assert.deepEqual(alerts, ['round-discovery']);
  assert.deepEqual(k.sourceList().map(s => s.address), [A(6)]);
});

test('round keeper: staking kind-0 lane -> entry source created on first credit, then each credited epoch sealed', async () => {
  const key = B32(77);
  const credited = new Set([E + 9, E + 11]);
  let entry = ZeroAddress;
  const staking = {
    entrySource: async () => entry,
    carryState: async () => ({ deposited27: 0n, released27: 0n, pendingEvents: 0n }),
    ledgerLane: async () => true,
    rewardSealed: async () => false,
    creditTotal27: async (_k, e) => (credited.has(Number(e)) ? 3n * 10n ** 27n : 0n),
  };
  const tx = txRecorder(false);
  const { k } = roundKeeper({ logs: [laneLog(144 * 8, key, 0), laneLog(144 * 8 + 1, B32(78), 1)], tx, at: fakeAt({ staking }), discover: { staking: STAKING, fromBlock: 0 } });
  await k.discoverPhase();
  await k.stakingSealPhase();
  assert.deepEqual(tx.calls.map(c => c.method), ['createEntrySource'], 'dry-run: create only, kind-1 lane ignored');
  entry = A(9); // created
  tx.calls.length = 0;
  await k.stakingSealPhase();
  assert.deepEqual(tx.calls.map(c => [c.method, c.args[0], Number(c.args[1])]), [['seal', A(9), E + 9], ['seal', A(9), E + 11]]);
});

test('push keeper: staking kind-1 lane with credit becomes a direct source with no config entry (entry source created on first credit)', async () => {
  const key = B32(88);
  let entry = ZeroAddress;
  const provider = chain({ head: 2000, logs: [laneLog(144 * 4, key, 1), laneLog(144 * 4 + 1, B32(89), 0)] });
  const journal = new Journal(join(tmp(), 'j.json'));
  const tx = txRecorder(true);
  const cfg = { contracts: { distributor: A(2), payoutVault: A(3) }, push: { directSources: [{ address: A(6), firstEpoch: E + 11 }], discover: { staking: STAKING, fromBlock: 0 } } };
  const k = new PushKeeper({ cfg, provider, tx, journal, logger: quietLogger, alert: async () => {}, chainId: 5042, now: () => (E + 12) * DAY + 700 });
  k.summary = { actions: [], skipped: [] };
  k.discovery.staking = { target: STAKING, interface: stakingIface, entrySource: async () => entry, ledgerLane: async () => true, creditTotal27: async (_k, e) => (Number(e) === E + 10 ? 5n : 0n) };
  await k.discoverPhase();
  tx.call = async (key2, c, method) => { tx.calls.push({ method }); if (method === 'createEntrySource') entry = A(9); return { status: 'confirmed' }; };
  const direct = await k.discoveredDirectSources();
  assert.deepEqual(tx.calls.map(c => c.method), ['createEntrySource']);
  assert.deepEqual(direct, [{ address: A(9), firstEpoch: E + 4, minRevision: 2, lane: key }]);
  assert.deepEqual(mergeSources(cfg.push.directSources, direct).map(s => s.address), [A(6), A(9)]);
});

test('discovery: a lagging node without the chunk end block does not move the cursor (no silent gap)', async () => {
  const logs = [launchLog(150, A(1), 3)];
  const p = chain({ head: 400, logs });
  const j = new Journal(join(tmp(), 'j.json'));
  const realGetBlock = p.getBlock;
  p.getBlock = async n => (n > 205 ? null : realGetBlock(n)); // node only has blocks <= 205
  const r = await scanner(p, j).sync();
  assert.equal(r.next, 110, 'chunk 110-209 not committed: the node lacks block 209');
  assert.equal(scanner(p, j).cursor(), 110);
  p.getBlock = realGetBlock;
  const again = await scanner(p, j).sync();
  assert.equal(again.next, 399);
  assert.deepEqual(again.added, [], 'the re-read chunk re-adds nothing');
  assert.equal(scanner(p, j).items().length, 1);
});

test('round keeper: final epochs (sealed or empty) are not re-read on the next tick (RPC budget)', async () => {
  const logs = [launchLog(144 * 2, A(4), 3)];
  let reads = 0;
  const sealed = new Set([E + 2, E + 3]);
  const at = (address, abi) => ({ ...fakeAt()(address, abi),
    epochBudget: async e => { reads++; return Number(e) === E + 5 ? 10n ** 18n : 0n; },
    rewardSealed: async e => sealed.has(Number(e)) });
  const { k, journal } = roundKeeper({ logs, at });
  await k.discoverPhase();
  await k.sealPhase();
  assert.equal(reads, 10, 'epochs E+2..E+11 read once');
  assert.equal(journal.record('sealDone', A(4).toLowerCase()).through, E + 4, 'stops before the unsealed funded epoch E+5');
  reads = 0;
  await k.sealPhase();
  assert.equal(reads, 7, 'only E+5..E+11 re-read');
});

function stakingKeeper(staking, tx = txRecorder(false)) {
  const r = roundKeeper({ logs: [laneLog(144 * 8, B32(77), 0)], tx, at: fakeAt({ staking }), discover: { staking: STAKING, fromBlock: 0 } });
  return r;
}

test('round keeper: locked carry -> zero-credit epochs are probed by simulation; only the one that would seal is sent', async () => {
  const staking = {
    entrySource: async () => A(9), ledgerLane: async () => true,
    carryState: async () => ({ deposited27: 5n * 10n ** 27n, released27: 0n, pendingEvents: 3n }),
    rewardSealed: async () => false, creditTotal27: async () => 0n,
  };
  const tx = txRecorder(true, 'simulation-failed');
  const { k, journal } = stakingKeeper(staking, tx);
  const probed = [];
  k.manager = { target: A(1), seal: { staticCall: async (...args) => { probed.push(Number(args[1])); if (Number(args[1]) !== E + 10) throw new Error('EmptyBudgetError'); } } };
  await k.discoverPhase();
  await k.stakingSealPhase();
  assert.deepEqual(probed, [E + 8, E + 9, E + 10, E + 11]);
  assert.deepEqual(tx.calls.map(c => [c.method, Number(c.args[1])]), [['seal', E + 10]]);
  assert.equal(k.summary.actions.at(-1).status, 'simulation-failed', 'a refused seal is reported, the tick goes on');
  assert.equal(journal.record('sealDone', B32(77)), null, 'pending carry keeps the epochs open');
});

test('round keeper: non-ledger staking lane (protocol Desk / V2) with too little native balance is deferred, not sealed', async () => {
  const staking = {
    entrySource: async () => A(9), ledgerLane: async () => false, nativeAvailable: async () => 10n ** 18n,
    carryState: async () => ({ deposited27: 0n, released27: 0n, pendingEvents: 0n }),
    rewardSealed: async () => false, creditTotal27: async (_k, e) => (Number(e) === E + 9 ? 2n * 10n ** 45n : 0n), // budget 2 USDC (18 dp) > 1 available
  };
  const tx = txRecorder(true);
  const { k } = stakingKeeper(staking, tx);
  await k.discoverPhase();
  await k.stakingSealPhase();
  assert.deepEqual(tx.calls.map(c => c.method), []);
  assert.equal(k.summary.deferred[0].reason, 'StakingLaneUnfunded');
});

test('push keeper: stock-quoted coins are direct sources; uncredited and unfunded non-ledger staking lanes are skipped', async () => {
  const provider = chain({ head: 2000, logs: [launchLog(144 * 3, A(4), 3), launchLog(144 * 3 + 1, A(5), 3), laneLog(144 * 4, B32(90), 1), laneLog(144 * 4 + 1, B32(91), 1)] });
  const journal = new Journal(join(tmp(), 'j.json'));
  const tx = txRecorder(true);
  const cfg = { contracts: { distributor: A(2), payoutVault: A(3) }, push: { discover: { factory: FACTORY, staking: STAKING, fromBlock: 0 } } };
  const k = new PushKeeper({ cfg, provider, tx, journal, logger: quietLogger, alert: async () => {}, chainId: 5042, now: () => (E + 12) * DAY + 700 });
  k.summary = { actions: [], skipped: [] };
  k.discovery.at = fakeAt({ kinds: { [A(5).toLowerCase()]: 1 } });
  for (const s2 of k.discovery.scanners) if (s2.name === 'launch') s2.decode = (orig => async (log, ts) => {
    const e = factoryIface.parseLog(log);
    return { id: e.args.token.toLowerCase(), type: 'token', address: e.args.token, settlementKind: e.args.token === A(5) ? 1 : 0, firstEpoch: Math.floor(ts / DAY) };
  })();
  k.discovery.staking = { target: STAKING, interface: stakingIface, entrySource: async () => ZeroAddress,
    ledgerLane: async key => key === B32(90), fundedAmount: async () => 0n, totalStaged: async () => 0n, creditTotal27: async () => 0n };
  await k.discoverPhase();
  const direct = await k.discoveredDirectSources();
  assert.deepEqual(direct.map(d => [d.address, d.requireBudget ?? false]), [[A(5), true]]);
  assert.equal(tx.calls.length, 0, 'no entry source for a lane without credit');
  assert.deepEqual(k.summary.skipped.map(x => x.lane), [B32(91)]);
});

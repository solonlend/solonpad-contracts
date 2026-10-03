// Canonical lane automation (r13 follow-up): L1 outbox executor + CCTP v2 relayer.
import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { Interface, AbiCoder, getAddress, keccak256, solidityPacked, zeroPadValue, toBeHex, concat, hexlify, getBytes } from 'ethers';
import { Journal } from '../lib/journal.mjs';
import { itemHash, merkleRootFrom, ArbOutboxSource, ARBSYS, L2_TO_L1_TX } from '../canonical/arb-outbox.mjs';
import { OutboxExecutor } from '../canonical/outbox-executor.mjs';
import { IrisClient } from '../canonical/iris.mjs';
import { CctpRelayer, parseCctpV2 } from '../canonical/cctp-relayer.mjs';
import { tmp, quietLogger, clock } from './helpers.mjs';

const A = n => getAddress('0x' + String(n).repeat(40));
const VAULT = A(2), BRIDGER = A(3), GATE = A(5), OUTBOX = getAddress('0xf0ce991ea4A0d2400A4AB49b20ae333f6Dce3DE9');
const journal = () => new Journal(join(tmp(), 'j.json'));
const collect = () => { const a = []; const f = async (k, t) => { a.push({ k, t }); return { sent: false }; }; f.list = a; return f; };
const arbSysIface = new Interface([L2_TO_L1_TX]);
const coder = AbiCoder.defaultAbiCoder();

// ---------------------------------------------------------------- Arbitrum outbox Merkle (nitro-contracts MerkleLib)
// Reference tree: power-of-two, missing leaves = 0, leaf = keccak(item) (Outbox hashes the item once more).
function tree(items, depth) {
  let layer = Array.from({ length: 2 ** depth }, (_, i) => (i < items.length && items[i] ? keccak256(items[i]) : '0x' + '00'.repeat(32)));
  const layers = [layer];
  while (layer.length > 1) { const n = []; for (let i = 0; i < layer.length; i += 2) n.push(keccak256(concat([layer[i], layer[i + 1]]))); layers.push(layer = n); }
  return { root: layer[0], proof: idx => layers.slice(0, -1).map((l, d) => l[(idx >> d) ^ 1]) };
}
const send = (pos, over = {}) => ({ caller: VAULT, destination: BRIDGER, position: BigInt(pos), arbBlockNum: 1000n + BigInt(pos), ethBlockNum: 23_000_000n, timestamp: 1_700_000_000n, callvalue: 0n,
  data: new Interface(['function acceptCheckpoint((bytes32 root,uint64 fromSeq,uint64 toSeq) c)']).encodeFunctionData('acceptCheckpoint', [[keccak256('0x01'), 0, 4]]), ...over });

test('itemHash = Outbox.calculateItemHash (abi.encodePacked l2Sender,to,l2Block,l1Block,l2Timestamp,value,data)', () => {
  const s = send(7);
  assert.equal(itemHash(s), keccak256(solidityPacked(['address', 'address', 'uint256', 'uint256', 'uint256', 'uint256', 'bytes'], [s.caller, s.destination, s.arbBlockNum, s.ethBlockNum, s.timestamp, s.callvalue, s.data])));
});

test('merkleRootFrom matches MerkleLib.calculateRoot over keccak(item) for every leaf of a tree', () => {
  const items = [1, 2, 3, 4, 5].map(i => keccak256(toBeHex(i, 32)));
  const t = tree(items, 3);
  for (let i = 0; i < items.length; i++) assert.equal(merkleRootFrom(t.proof(i), BigInt(i), items[i]), t.root);
  assert.notEqual(merkleRootFrom(t.proof(1), 0n, items[0]), t.root);
});

// ---------------------------------------------------------------- confirmed send state (SendRootUpdated + L2 block)
const outboxIface = new Interface(['event SendRootUpdated(bytes32 indexed outputRoot, bytes32 indexed l2BlockHash)']);
function sendRootLog(root, blockHash, blockNumber) {
  const ev = outboxIface.getEvent('SendRootUpdated');
  return { address: OUTBOX, blockNumber, topics: [ev.topicHash, root, blockHash], data: '0x' };
}

test('ArbOutboxSource.latestConfirmed: newest SendRootUpdated -> L2 block sendCount, root cross-checked', async () => {
  const H1 = keccak256('0xb1'), H2 = keccak256('0xb2'), R1 = keccak256('0xa1'), R2 = keccak256('0xa2');
  const l1 = { getBlockNumber: async () => 100_000, getLogs: async f => [sendRootLog(R1, H1, 95_000), sendRootLog(R2, H2, 99_000)].filter(l => l.blockNumber >= f.fromBlock && l.blockNumber <= f.toBlock) };
  const blocks = { [H1]: { sendCount: '0x10', sendRoot: R1 }, [H2]: { sendCount: '0x14', sendRoot: R2 } };
  const l2 = { send: async (m, [h]) => (m === 'eth_getBlockByHash' ? blocks[h] : null) };
  const src = new ArbOutboxSource({ l1, l2, outbox: OUTBOX, chunk: 2_000 });
  const c = await src.latestConfirmed();
  assert.deepEqual([c.sendRoot, c.l2BlockHash, c.sendCount], [R2, H2, 20n]);
  blocks[H2].sendRoot = R1; // an L2 node disagreeing with L1 is never trusted
  await assert.rejects(new ArbOutboxSource({ l1, l2, outbox: OUTBOX, chunk: 2_000 }).latestConfirmed(), /sendRoot/);
});

// ---------------------------------------------------------------- outbox executor
function execFixture({ confirmedCount = 10n, spent = new Set(), status = 'confirmed', extraLogs = [], badProof = false, rootKnown = true, ethBal = 10n ** 17n } = {}) {
  const sends = [send(3), send(4, { caller: A(9) })]; // the second one is not from the vault
  const items = Array.from({ length: Number(confirmedCount) }, (_, i) => (i === 3 ? itemHash(sends[0]) : keccak256(toBeHex(i + 100, 32))));
  const t = tree(items, 4);
  const logs = [...sends, ...extraLogs].map((s, i) => {
    const ev = arbSysIface.getEvent('L2ToL1Tx');
    const enc = arbSysIface.encodeEventLog(ev, [s.caller, s.destination, itemHash(s), s.position, s.arbBlockNum, s.ethBlockNum, s.timestamp, s.callvalue, s.data]);
    return { address: ARBSYS, blockNumber: 50 + i, transactionHash: keccak256(toBeHex(i + 1, 32)), ...enc };
  });
  const calls = [];
  const source = {
    latestConfirmed: async () => ({ sendRoot: t.root, l2BlockHash: keccak256('0x01'), sendCount: confirmedCount }),
    proof: async (size, leaf) => ({ send: items[Number(leaf)], root: t.root, proof: badProof ? t.proof(Number(leaf)).reverse() : t.proof(Number(leaf)) }),
    isSpent: async p => spent.has(Number(p)),
    rootKnown: async () => rootKnown,
  };
  const ethTx = { reconcileAll: async () => [], async call(key, c, method, args, opts) { calls.push({ key, method, args, opts }); if (method === 'executeTransaction' && status === 'confirmed') spent.add(Number(args[1])); return { status, receipt: { hash: '0xabc' } }; } };
  const alert = collect();
  const rhProvider = { getBlockNumber: async () => 100, getLogs: async f => logs.filter(l => l.blockNumber >= f.fromBlock && l.blockNumber <= f.toBlock && (!f.topics?.[1] || l.topics[1] === f.topics[1])), getBlock: async n => ({ timestamp: 1_700_000_000 + n }) };
  const ethProvider = { getBalance: async () => ethBal, estimateGas: async () => 250_000n };
  const X = new OutboxExecutor({ cfg: { contracts: { reserveVault: VAULT, ethBridger: BRIDGER }, outbox: { address: OUTBOX, startBlock: 1 } },
    eth: { provider: ethProvider, tx: ethTx, chainId: 1, wallet: { address: A(7) } }, rh: { provider: rhProvider }, journal: journal(), logger: quietLogger, alert, source, now: () => 1_700_000_000 + 86_400 });
  X.bridger = { target: BRIDGER, checkpointCount: async () => 1n, forwardedThrough: async () => 1n };
  return { X, calls, alert, t, sends, spent };
}

test('OutboxExecutor: executes a confirmed vault message on the Outbox with a verified proof; second tick is a no-op', async () => {
  const { X, calls, t, sends } = execFixture();
  const s1 = await X.tick();
  const ex = calls.filter(c => c.method === 'executeTransaction');
  assert.equal(ex.length, 1, JSON.stringify(s1));
  const [proof, index, l2Sender, to, l2Block, l1Block, ts, value, data] = ex[0].args;
  assert.equal(index, 3n);
  assert.deepEqual([l2Sender, to, l2Block, l1Block, ts, value, data], [VAULT, BRIDGER, sends[0].arbBlockNum, sends[0].ethBlockNum, sends[0].timestamp, 0n, sends[0].data]);
  assert.equal(merkleRootFrom(proof, index, itemHash(sends[0])), t.root);
  assert.ok(ex[0].opts.gasLimit <= 600_000n && ex[0].opts.gasLimit >= 250_000n);
  assert.ok(!calls.some(c => c.args?.[2] === A(9)), 'a send from another L2 account is ignored');
  await X.tick();
  assert.equal(calls.filter(c => c.method === 'executeTransaction').length, 1, 'idempotent');
});

test('OutboxExecutor: waits (no tx) while the assertion is unconfirmed; alerts once the message is older than the alert age', async () => {
  const { X, calls, alert } = execFixture({ confirmedCount: 3n });
  const s = await X.tick();
  assert.equal(calls.length, 0);
  assert.equal(s.waiting[0].position, 3);
  assert.equal(alert.list.length, 0);
  X.clock = () => 1_700_000_000 + 8 * 86_400;
  await X.tick();
  assert.ok(alert.list.some(a => /not confirmed/.test(a.t)), JSON.stringify(alert.list));
});

test('OutboxExecutor: already spent (executed by anyone) -> recorded, never re-sent', async () => {
  const { X, calls } = execFixture({ spent: new Set([3]) });
  const s = await X.tick();
  assert.equal(calls.length, 0);
  assert.equal(X.journal.record('sends', '3').done, 'spent');
  assert.ok(s.actions.some(a => a.kind === 'already-executed'));
});

test('OutboxExecutor: a bad proof or an unknown root is alerted and not sent', async () => {
  for (const o of [{ badProof: true }, { rootKnown: false }]) {
    const { X, calls, alert } = execFixture(o);
    await X.tick();
    assert.equal(calls.filter(c => c.method === 'executeTransaction').length, 0);
    assert.ok(alert.list.some(a => /proof|root/.test(a.t)), JSON.stringify(alert.list));
  }
});

test('OutboxExecutor: failed execution is alerted and retried next tick; low L1 ETH is alerted', async () => {
  const { X, alert, calls } = execFixture({ status: 'reverted', ethBal: 10n ** 15n });
  await X.tick();
  assert.ok(alert.list.some(a => /executeTransaction.*reverted/.test(a.t)), JSON.stringify(alert.list));
  assert.ok(alert.list.some(a => /ETH/.test(a.k + a.t)));
  await X.tick();
  assert.equal(calls.filter(c => c.method === 'executeTransaction').length, 2);
});

test('OutboxExecutor: gas estimate above the cap -> alert, no tx', async () => {
  const { X, calls, alert } = execFixture();
  X.eth.provider.estimateGas = async () => 2_000_000n;
  await X.tick();
  assert.equal(calls.filter(c => c.method === 'executeTransaction').length, 0);
  assert.ok(alert.list.some(a => /gas/.test(a.t)));
});

test('OutboxExecutor: an accepted checkpoint the bridger could not forward is forwarded (or the USDC shortfall alerted)', async () => {
  const { X, calls, alert } = execFixture({ spent: new Set([3]) });
  X.bridger = { target: BRIDGER, checkpointCount: async () => 2n, forwardedThrough: async () => 1n };
  X.usdc = { balanceOf: async () => 0n };
  await X.tick();
  assert.equal(calls.filter(c => c.method === 'forward').length, 0);
  assert.ok(alert.list.some(a => /USDC/.test(a.t)));
  X.usdc = { balanceOf: async () => 5_000_000n };
  await X.tick();
  assert.equal(calls.filter(c => c.method === 'forward').length, 1);
});

// ---------------------------------------------------------------- Iris v2 client
const res = (status, body) => ({ status, ok: status === 200, json: async () => body });
test('IrisClient: 404 / empty / pending / complete / 429 back-off (no request while blocked)', async () => {
  const c = clock(0);
  let next = res(404, {}), n = 0;
  const fetchImpl = async url => { n++; assert.match(url, /^https:\/\/iris-api\.circle\.com\/v2\/messages\/0\?transactionHash=0xab$/); return next; };
  const iris = new IrisClient({ fetchImpl, now: c });
  assert.equal((await iris.messages(0, '0xab')).state, 'pending');
  next = res(200, { messages: [] }); assert.equal((await iris.messages(0, '0xab')).state, 'pending');
  next = res(200, { messages: [{ status: 'pending_confirmations', message: '0x', attestation: 'PENDING' }] }); assert.equal((await iris.messages(0, '0xab')).state, 'pending');
  next = res(200, { messages: [{ status: 'complete', message: '0x01', attestation: '0x02' }] });
  const ok = await iris.messages(0, '0xab');
  assert.deepEqual([ok.state, ok.messages[0].message, ok.messages[0].attestation], ['complete', '0x01', '0x02']);
  next = res(429, {}); assert.equal((await iris.messages(0, '0xab')).state, 'rate-limited');
  const before = n;
  c.advance(60_000); assert.equal((await iris.messages(0, '0xab')).state, 'rate-limited'); assert.equal(n, before, 'blocked: no request for 5 minutes');
  c.advance(5 * 60_000); next = res(200, { messages: [] }); assert.equal((await iris.messages(0, '0xab')).state, 'pending'); assert.equal(n, before + 1);
});

// ---------------------------------------------------------------- CCTP v2 relayer
const TM = getAddress('0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d');
const b32 = a => zeroPadValue(a, 32);
function cctpMessage({ src, dst, nonce, messageSender, hook = '0x1234', recipient = TM }) {
  const u32 = v => zeroPadValue(toBeHex(v), 4);
  const header = concat([u32(1), u32(src), u32(dst), nonce, b32(TM), b32(recipient), b32(dst === 26 ? GATE : BRIDGER), u32(2000), u32(2000)]);
  const body = concat([u32(1), b32(A(6)), b32(dst === 26 ? GATE : BRIDGER), zeroPadValue(toBeHex(1_000_000), 32), b32(messageSender), zeroPadValue('0x00', 32), zeroPadValue('0x00', 32), zeroPadValue('0x00', 32), hook]);
  return hexlify(concat([header, body]));
}

test('parseCctpV2 reads Circle MessageV2 + BurnMessageV2 offsets', () => {
  const m = cctpMessage({ src: 0, dst: 26, nonce: keccak256('0x07'), messageSender: BRIDGER });
  const p = parseCctpV2(m);
  assert.deepEqual([p.sourceDomain, p.destinationDomain, p.nonce, p.sender, p.messageSender, p.hookData], [0, 26, keccak256('0x07'), TM, BRIDGER, '0x1234']);
});

const gateIface = new Interface(['event DeliverSent(bytes32 indexed ref, address indexed to, uint8 mode)']);
const bridgerIface = new Interface(['event CheckpointForwarded(uint256 indexed index, bytes32 root)']);
function relayFixture({ irisState = 'complete', used = new Set(), relayStatus = 'confirmed' } = {}) {
  const ethTxHash = keccak256('0xe1'), arcTxHash = keccak256('0xa1');
  const ethLog = { address: BRIDGER, blockNumber: 10, transactionHash: ethTxHash, ...bridgerIface.encodeEventLog(bridgerIface.getEvent('CheckpointForwarded'), [0n, keccak256('0x99')]) };
  const arcLog = { address: GATE, blockNumber: 20, transactionHash: arcTxHash, ...gateIface.encodeEventLog(gateIface.getEvent('DeliverSent'), [keccak256('0x55'), A(8), 0]) };
  const msgs = {
    [`0:${ethTxHash}`]: [{ message: cctpMessage({ src: 0, dst: 26, nonce: keccak256('0x0e'), messageSender: BRIDGER }), attestation: '0xa77e', status: 'complete' }],
    [`26:${arcTxHash}`]: [{ message: cctpMessage({ src: 26, dst: 0, nonce: keccak256('0x0a'), messageSender: GATE }), attestation: '0xa77f', status: 'complete' }],
  };
  const reqs = [];
  const iris = { messages: async (d, h) => { reqs.push(`${d}:${h}`); return irisState === 'complete' ? { state: 'complete', messages: msgs[`${d}:${h}`] } : { state: irisState, messages: [] }; } };
  const calls = [];
  const mkTx = chain => ({ reconcileAll: async () => [], async call(key, c, method, args, opts) { calls.push({ chain, key, method, args, opts }); if (relayStatus === 'confirmed') used.add(parseCctpV2(args[0]).nonce); return { status: relayStatus, receipt: { hash: '0xdd' } }; } });
  const prov = logs => ({ getBlockNumber: async () => 100, getLogs: async f => logs.filter(l => l.blockNumber >= f.fromBlock && l.blockNumber <= f.toBlock && getAddress(l.address) === getAddress(f.address)), getBlock: async () => ({ timestamp: 1_000 }), getFeeData: async () => ({ gasPrice: 10_000_000n }), getBalance: async () => 10n ** 18n });
  const alert = collect();
  const R = new CctpRelayer({ cfg: { contracts: { canonicalGate: GATE, ethBridger: BRIDGER }, cctp: { startBlock: { arc: 1, eth: 1 } } },
    arc: { provider: prov([arcLog]), tx: mkTx('arc'), chainId: 5042 }, eth: { provider: prov([ethLog]), tx: mkTx('eth'), chainId: 1, wallet: { address: A(7) } }, rh: { provider: prov([]) },
    journal: journal(), logger: quietLogger, alert, iris, now: () => 1_000 });
  const usedNonce = async n => (used.has(n) ? 1n : 0n);
  R.mt = { arc: { usedNonces: usedNonce }, eth: { usedNonces: usedNonce } };
  R.submissionFee = async () => 1_000_000_000_000n;
  return { R, calls, alert, reqs, used };
}

test('CctpRelayer: checkpoint Ethereum->Arc goes to CanonicalGate.relay, delivery Arc->Ethereum to EthereumBridger.relay with ticket ETH', async () => {
  const { R, calls } = relayFixture();
  const s = await R.tick();
  const gate = calls.find(c => c.method === 'relay' && c.chain === 'arc');
  const br = calls.find(c => c.method === 'relay' && c.chain === 'eth');
  assert.ok(gate && br, JSON.stringify(s));
  assert.deepEqual(gate.args.slice(1), ['0xa77e']);
  assert.equal(parseCctpV2(gate.args[0]).destinationDomain, 26);
  const [, att, gasLimit, maxFee] = br.args;
  assert.equal(att, '0xa77f');
  assert.equal(gasLimit, 1_500_000n);
  assert.ok(maxFee >= 10_000_000n * 2n, 'L2 maxFeePerGas above the RH gas price');
  assert.equal(br.opts.value, 1_000_000_000_000n + gasLimit * maxFee, 'value = submission fee + L2 gas');
  await R.tick();
  assert.equal(calls.filter(c => c.method === 'relay').length, 2, 'idempotent once relayed');
});

test('CctpRelayer: a nonce already used on the destination (relayed by anyone) is recorded, not re-sent', async () => {
  const { R, calls } = relayFixture({ used: new Set([keccak256('0x0e'), keccak256('0x0a')]) });
  const s = await R.tick();
  assert.equal(calls.length, 0);
  assert.equal(s.actions.filter(a => a.kind === 'already-received').length, 2);
});

test('CctpRelayer: attestation pending -> no tx; alert after the pending threshold; failures alerted and retried', async () => {
  const f = relayFixture({ irisState: 'pending' });
  await f.R.tick();
  assert.equal(f.calls.length, 0);
  assert.equal(f.alert.list.length, 0);
  f.R.clock = () => 1_000 + 3 * 3600;
  await f.R.tick();
  assert.ok(f.alert.list.some(a => /attestation/.test(a.t)), JSON.stringify(f.alert.list));
  const g = relayFixture({ relayStatus: 'reverted' });
  await g.R.tick();
  assert.ok(g.alert.list.some(a => /reverted/.test(a.t)));
  await g.R.tick();
  assert.equal(g.calls.filter(c => c.method === 'relay').length, 4, 'both lanes retried');
});

test('ages follow chain time (latest block), not the wall clock, when no clock is injected', async () => {
  const { X } = execFixture({ confirmedCount: 3n });
  X.clock = null;
  X.eth.provider.getBlock = async () => ({ timestamp: 1_700_000_000 + 9 * 86_400 });
  const alert = collect(); X.alert = alert;
  await X.tick();
  assert.ok(alert.list.some(a => /not confirmed on the L1 rollup after 9\.0 d/.test(a.t)), JSON.stringify(alert.list));
  const f = relayFixture({ irisState: 'pending' });
  f.R.clock = null;
  const chainNow = async b => ({ timestamp: b === 'latest' ? 1_000 + 3 * 3600 : 1_000 });
  f.R.eth.provider.getBlock = chainNow;
  f.R.arc.provider.getBlock = chainNow;
  await f.R.tick();
  assert.equal(f.alert.list.filter(a => /attestation/.test(a.t)).length, 2, JSON.stringify(f.alert.list));
});

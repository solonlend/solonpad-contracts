// Automatic recovery after a partial tick (review, 2026-10-02):
//   - a tx confirmed only later by TxSender.reconcileAll (waitForTransaction timed out) must still hand its receipt to
//     the caller that resumes the step, or the keeper record is never written (refund withdrawFloat -> credit);
//   - the canonical reconcile cursor must not move past a checkpoint that still has unreconciled results.
import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { Interface, Wallet, keccak256, toUtf8Bytes, getAddress, zeroPadValue, toBeHex } from 'ethers';
import { Journal, TaskState } from '../lib/journal.mjs';
import { TxSender } from '../lib/tx.mjs';
import { HubStatus } from '../lib/abis.mjs';
import { RefundKeeper } from '../refund/keeper.mjs';
import { CanonicalKeeper } from '../canonical/keeper.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const E18 = 10n ** 18n;
const A = n => getAddress('0x' + String(n).repeat(40));
const HUB = A(1), ROUTE = A(4), ROUTER = getAddress('0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f');
const wallet = new Wallet(keccak256(toUtf8Bytes('recovery-test-keeper')));

// Provider whose txs are not mined within waitForTransaction (ethers v6 TIMEOUT) until mineAll() is called.
function slowProvider() {
  const p = {
    sent: [], pending: [], receipts: new Map(), slow: true, nonce: 0,
    async call() { return '0x'; },
    async getFeeData() { return { maxFeePerGas: 10n ** 9n, maxPriorityFeePerGas: 1n }; },
    async estimateGas() { return 100_000n; },
    async getTransactionCount(_, tag) { return tag === 'latest' ? p.receipts.size : p.nonce; },
    async broadcastTransaction(raw) { p.sent.push(raw); p.pending.push(keccak256(raw)); p.nonce++; },
    async waitForTransaction(hash) {
      if (p.slow) throw Object.assign(new Error('timeout'), { code: 'TIMEOUT' });
      p.mineAll();
      return p.receipts.get(hash);
    },
    async getTransactionReceipt(hash) { return p.receipts.get(hash) ?? null; },
    mineAll() { for (const h of p.pending.splice(0)) p.receipts.set(h, { status: 1, hash: h, blockNumber: 10 + p.receipts.size, logs: [] }); },
  };
  return p;
}

const order = o => ({ kind: 0, status: HubStatus.Returning, outcome: 3, amountIn: 0n, amountOut: 0n, fee: 0n, held: 0n, route: ROUTE, settledAt: 0, dispatchedAt: 0, owed: 0n, ...o });

test('TxSender: a task confirmed by reconcileAll still returns its receipt to the caller that resumes the step', async () => {
  const provider = slowProvider();
  const journal = new Journal(join(tmp(), 'j.json'));
  const tx = new TxSender({ provider, wallet, journal, logger: quietLogger, chainId: 5042, execute: true });
  const contract = { target: A(2), interface: new Interface(['function poke(uint256)']) };
  assert.equal((await tx.call('k', contract, 'poke', [1])).status, 'inflight');
  provider.mineAll();
  assert.equal((await tx.reconcileAll())[0].state, TaskState.Confirmed);
  const r = await tx.call('k', contract, 'poke', [1]);
  assert.equal(r.status, 'confirmed');
  assert.equal(r.receipt?.hash, journal.task('k').hash);
  assert.equal(provider.sent.length, 1, 'never re-sent');
  // Receipt not served (lagging RPC node): not 'confirmed' without a receipt; the caller retries next tick.
  provider.receipts.clear();
  assert.equal((await tx.call('k', contract, 'poke', [1])).status, 'inflight');
  assert.equal(provider.sent.length, 1);
});

test('refund keeper: withdrawFloat confirmed only by the next reconcileAll -> record written, credit-back resumes', async () => {
  const provider = slowProvider();
  const journal = new Journal(join(tmp(), 'j.json'));
  const tx = new TxSender({ provider, wallet, journal, logger: quietLogger, chainId: 5042, execute: true });
  const orders = new Map([[1, order({ amountIn: 100n * E18 })]]);
  // Hub float 150 < 2 x need: once the late-confirmed withdrawal has left the hub, a fresh float check would fail.
  let float = 150n * E18;
  const alerts = [];
  const K = new RefundKeeper({ cfg: { contracts: { stockHub: HUB }, relay: { relayRouter: ROUTER } }, provider: null, tx, journal, logger: quietLogger, alert: async (k, m) => { alerts.push(k); }, wallet, chainId: 5042, now: () => 86_400 * 3 });
  K.hub = {
    target: HUB, interface: K.hub.interface,
    floatRecipientA: async () => A(9), floatRecipientB: async () => wallet.address,
    openOrders: async () => [...orders.keys()].map(BigInt),
    getOrder: async id => orders.get(Number(id)),
    available: async () => float,
  };
  K.routeAt = addr => ({ target: addr, returnExecutor: async () => ROUTER });

  await K.tick(); // withdrawFloat broadcast, not mined within the wait
  assert.equal(journal.record('refunds', '1'), null);
  provider.mineAll();
  float -= 100n * E18;
  K.p.dailyCap18 = 50n * E18; // e.g. the next tick falls on a day whose cap is already near-used: must not block either
  provider.slow = false;
  await K.tick(); // reconcileAll confirms the withdrawal; credit() must pick up its receipt
  const rec = journal.record('refunds', '1');
  assert.equal(rec?.withdrawn, (100n * E18).toString());
  assert.equal(rec.withdrawTx, keccak256(provider.sent[0]));
  assert.equal(provider.sent.length, 2, 'credit-back sent once');
  assert.equal(rec.done, true);
  assert.equal(rec.creditTx, keccak256(provider.sent[1]));
  assert.deepEqual(alerts.filter(k => /^refund-(float|cap)-/.test(k)), [], 'no float-short / cap alert for a withdrawal already made');
});

function canonicalFixture({ count, failing }) {
  const state = {}, called = [];
  const ck = Object.create(CanonicalKeeper.prototype);
  const result = n => ({ ref: zeroPadValue(toBeHex(n), 32), underlying: A(5), outcome: 0, amountIn: 1n, amountOut: 1n, seq: n });
  const reconciled = new Set();
  Object.assign(ck, {
    p: { maxReconcilePerTick: 32 }, clock: () => 100_000, summary: { actions: [] }, results: new Map(),
    journal: { record: (ns, id) => state[id] ?? null, setRecord: (ns, id, p) => { state[id] = { ...state[id], ...p }; } },
    hub: { target: HUB, orderCount: async () => BigInt(count), reconciled: async ref => reconciled.has(Number(BigInt(ref))) },
    gate: { checkpointCount: async () => BigInt(count), checkpointAt: async i => ({ fromSeq: i, toSeq: i }) },
    vault: { resultAt: async n => result(n) },
    arc: { chainId: 5042, tx: { call: async (key, c, m, args) => {
      if (m === 'checkStale') return { status: 'confirmed' };
      const i = args[1];
      called.push(i);
      if (failing.has(i)) return { status: 'simulation-failed' };
      reconciled.add(i);
      return { status: 'confirmed' };
    } } },
  });
  return { ck, state, called, failing };
}

test('canonical keeper: a failed checkpoint is retried after a later one succeeds; the cursor waits for it', async () => {
  const { ck, state, called, failing } = canonicalFixture({ count: 3, failing: new Set([0]) });
  await ck.reconcilePhase();
  assert.deepEqual(called, [0, 1, 2], 'later checkpoints still reconciled in the same tick');
  assert.equal(state.gate?.fullyReconciled ?? 0, 0, 'cursor stays on the failed checkpoint');
  failing.clear();
  ck.summary = { actions: [] };
  await ck.reconcilePhase();
  assert.deepEqual(called, [0, 1, 2, 0], 'checkpoint 0 retried; 1 and 2 not re-sent (already reconciled)');
  assert.equal(state.gate.fullyReconciled, 3);
});

test('canonical keeper: cursor advances over a contiguous done prefix only', async () => {
  const { ck, state } = canonicalFixture({ count: 4, failing: new Set([2]) });
  await ck.reconcilePhase();
  assert.equal(state.gate.fullyReconciled, 2);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { Wallet, keccak256, Interface } from 'ethers';
import { Journal, TaskState } from '../lib/journal.mjs';
import { TxSender } from '../lib/tx.mjs';
import { tmp, quietLogger, clock } from './helpers.mjs';

const wallet = new Wallet('0x' + '11'.repeat(32));
const iface = new Interface(['function poke(uint256)']);
const contract = { target: '0x' + '22'.repeat(20), interface: iface };

function fakeProvider(opts = {}) {
  const p = {
    sent: [], receipts: new Map(), latestNonce: opts.latestNonce ?? 0, pendingNonce: opts.pendingNonce ?? 0,
    async call() { if (opts.revert) throw Object.assign(new Error('execution reverted'), { shortMessage: 'execution reverted: x' }); return '0x'; },
    async getFeeData() { return { maxFeePerGas: 40n * 10n ** 9n, maxPriorityFeePerGas: 1n }; },
    async estimateGas() { return 100_000n; },
    async getTransactionCount(_, tag) { return tag === 'latest' ? p.latestNonce : p.pendingNonce; },
    async broadcastTransaction(raw) { if (opts.onBroadcast) opts.onBroadcast(raw); p.sent.push(raw); if (opts.broadcastError) throw new Error(opts.broadcastError); },
    async waitForTransaction(hash) { if (opts.mine === false) return null; const r = { status: opts.status ?? 1, blockNumber: 5, hash, logs: [] }; p.receipts.set(hash, r); return r; },
    async getTransactionReceipt(hash) { return p.receipts.get(hash) ?? null; },
  };
  return p;
}

const mk = (provider, extra = {}) => {
  const journal = new Journal(join(tmp(), 'j.json'), { now: extra.now });
  return { journal, tx: new TxSender({ provider, wallet, journal, logger: quietLogger, chainId: 5042, execute: true, ...extra }) };
};

test('simulation failure sends nothing and schedules a retry', async () => {
  const provider = fakeProvider({ revert: true });
  const { tx, journal } = mk(provider);
  const r = await tx.call('k1', contract, 'poke', [1]);
  assert.equal(r.status, 'simulation-failed');
  assert.equal(provider.sent.length, 0);
  assert.equal(journal.task('k1').state, TaskState.Retryable);
});

test('dry-run simulates but never signs, sends or journals', async () => {
  const provider = fakeProvider();
  const journal = new Journal(join(tmp(), 'j.json'));
  const tx = new TxSender({ provider, wallet: null, journal, logger: quietLogger, chainId: 5042, execute: false });
  assert.equal((await tx.call('k', contract, 'poke', [1])).status, 'dry-run');
  assert.equal(provider.sent.length, 0);
  assert.equal(journal.task('k'), null);
  const bad = new TxSender({ provider: fakeProvider({ revert: true }), journal, logger: quietLogger, chainId: 5042 });
  assert.equal((await bad.call('k', contract, 'poke', [1])).status, 'simulation-failed');
  assert.equal(journal.task('k'), null, 'dry-run simulation failures are not journaled');
});

test('hash is journaled as Sent before broadcast; confirmed task is never re-sent', async () => {
  let journalAtBroadcast;
  const provider = fakeProvider({ onBroadcast: raw => { journalAtBroadcast = { ...mkRef.journal.task('k') , expect: keccak256(raw) }; } });
  const mkRef = mk(provider);
  const r = await mkRef.tx.call('k', contract, 'poke', [1]);
  assert.equal(r.status, 'confirmed');
  assert.equal(journalAtBroadcast.state, TaskState.Sent);
  assert.equal(journalAtBroadcast.hash, journalAtBroadcast.expect);
  assert.equal((await mkRef.tx.call('k', contract, 'poke', [1])).status, 'confirmed');
  assert.equal(provider.sent.length, 1, 'no second broadcast');
});

test('restart: inflight tx with a receipt is reconciled to Confirmed without re-sending', async () => {
  const provider = fakeProvider({ mine: false });
  const { tx, journal } = mk(provider);
  assert.equal((await tx.call('k', contract, 'poke', [1])).status, 'inflight');
  const hash = journal.task('k').hash;
  provider.receipts.set(hash, { status: 1, blockNumber: 8 });
  const restarted = new TxSender({ provider, wallet, journal: new Journal(journal.path), logger: quietLogger, chainId: 5042, execute: true });
  const r = await restarted.reconcileAll();
  assert.equal(r[0].state, TaskState.Confirmed);
  assert.equal(provider.sent.length, 1);
});

test('restart: nonce consumed by another tx -> Retryable, caller must re-read chain', async () => {
  const provider = fakeProvider({ mine: false, pendingNonce: 3 });
  const { tx, journal } = mk(provider);
  await tx.call('k', contract, 'poke', [1]);
  provider.latestNonce = 4;
  const r = await tx.send({ key: 'k', to: contract.target, data: '0x' });
  assert.equal(r.status, 'retry-later');
  assert.equal(journal.task('k').state, TaskState.Retryable);
});

test('restart: unmined tx within window is rebroadcast (same raw), not re-signed', async () => {
  const now = clock();
  const provider = fakeProvider({ mine: false });
  const { tx, journal } = mk(provider, { now });
  await tx.call('k', contract, 'poke', [1]);
  now.advance(60_000);
  const r = await tx.call('k', contract, 'poke', [1]);
  assert.equal(r.status, 'inflight');
  assert.equal(provider.sent.length, 2);
  assert.equal(provider.sent[0], provider.sent[1]);
  now.advance(20 * 60_000);
  assert.equal((await tx.call('k', contract, 'poke', [1])).status, 'retry-later');
  assert.equal(journal.task('k').state, TaskState.Retryable);
});

test('reverted receipt is a failure (no advance) and rejected broadcast is not left inflight', async () => {
  const p1 = fakeProvider({ status: 0 });
  const a = mk(p1);
  assert.equal((await a.tx.call('k', contract, 'poke', [1])).status, 'reverted');
  assert.equal(a.journal.task('k').state, TaskState.Retryable);
  const p2 = fakeProvider({ broadcastError: 'nonce too low' });
  const b = mk(p2);
  assert.equal((await b.tx.call('k', contract, 'poke', [1])).status, 'rejected');
  assert.equal(b.journal.task('k').state, TaskState.Retryable);
});

test('explicit gasLimit is honoured (push keeper must not rely on estimateGas)', async () => {
  let signedGas;
  const provider = fakeProvider({ onBroadcast: raw => { signedGas = raw; } });
  const { tx } = mk(provider);
  await tx.call('k', contract, 'poke', [1], { gasLimit: 7_777_777n });
  const { Transaction } = await import('ethers');
  assert.equal(Transaction.from(signedGas).gasLimit, 7_777_777n);
});

test('F10: without an explicit limit every keeper tx is signed at estimateGas x 1.3 (fork qualify-probe: 791k estimate OOG)', async () => {
  let signed;
  const provider = fakeProvider({ onBroadcast: raw => { signed = raw; } });
  const { tx } = mk(provider);
  assert.equal(tx.gasMultiplierBps, 13_000n, 'default for every keeper (runner.mjs and oracle-keeper construct TxSender without overriding it)');
  await tx.call('k', contract, 'poke', [1]);
  const { Transaction } = await import('ethers');
  assert.equal(Transaction.from(signed).gasLimit, 130_000n);
});

// ethers v6 waitForTransaction REJECTS with a TIMEOUT error (it never resolves null), and misses a tx mined before its block
// subscription started when no further block follows (seen on the Ethereum fork: canonical cctp-relayer tick "failed: timeout"
// although the relay was mined). The receipt is read directly before giving up; otherwise the task stays Sent (inflight).
test('waitForTransaction timeout: a mined receipt is still found; an unmined tx stays inflight (no throw)', async () => {
  const timeout = () => Object.assign(new Error('timeout'), { code: 'TIMEOUT' });
  const mined = fakeProvider();
  mined.waitForTransaction = async () => { throw timeout(); };
  mined.getTransactionReceipt = async hash => ({ status: 1, blockNumber: 7, hash, logs: [] });
  const a = mk(mined);
  const r = await a.tx.call('k', contract, 'poke', [1]);
  assert.equal(r.status, 'confirmed');
  assert.equal(a.journal.task('k').state, TaskState.Confirmed);
  const pending = fakeProvider();
  pending.waitForTransaction = async () => { throw timeout(); };
  const b = mk(pending);
  const s = await b.tx.call('k', contract, 'poke', [1]);
  assert.equal(s.status, 'inflight');
  assert.equal(b.journal.task('k').state, TaskState.Sent);
});

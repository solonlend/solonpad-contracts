import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { Journal, TaskState, taskKey, taskGate, MAX_ATTEMPTS } from '../lib/journal.mjs';
import { tmp, clock } from './helpers.mjs';

test('taskKey binds chain, contract (case-insensitive), op and version', () => {
  const a = taskKey({ chainId: 5042, contract: '0xABC', op: 'seal:1' });
  assert.equal(a, '5042:0xabc:seal:1:v1');
  assert.notEqual(a, taskKey({ chainId: 4663, contract: '0xabc', op: 'seal:1' }));
  assert.notEqual(a, taskKey({ chainId: 5042, contract: '0xabc', op: 'seal:1', version: 2 }));
  assert.throws(() => taskKey({ chainId: 1, op: 'x' }));
});

test('failures back off 15/30/60s and quarantine after 5 attempts; never confirm', () => {
  const now = clock();
  const j = new Journal(join(tmp(), 's.json'), { now });
  const k = 'k';
  const delays = [];
  for (let i = 1; i <= MAX_ATTEMPTS; i++) {
    const t = j.markFailure(k, new Error(`boom ${i}`));
    delays.push(t.nextAttemptAt - now());
    assert.equal(t.state, i < MAX_ATTEMPTS ? TaskState.Retryable : TaskState.Quarantined);
  }
  assert.deepEqual(delays, [15_000, 30_000, 60_000, 60_000, 60_000]);
  assert.equal(taskGate(j.task(k), now() + 10 ** 9).go, false);
  j.reopen(k, 'operator');
  assert.equal(taskGate(j.task(k), now()).go, true);
});

test('taskGate: confirmed never repeats, sent requires reconciliation, retry waits for backoff', () => {
  assert.deepEqual(taskGate(null, 0), { go: true, reason: 'new' });
  assert.equal(taskGate({ state: TaskState.Confirmed }, 0).go, false);
  assert.equal(taskGate({ state: TaskState.Sent }, 0).reconcile, true);
  assert.equal(taskGate({ state: TaskState.Retryable, nextAttemptAt: 10 }, 5).go, false);
  assert.equal(taskGate({ state: TaskState.Retryable, nextAttemptAt: 10 }, 10).go, true);
});

test('state survives restart: bigint round-trip, sent hash+raw persisted before broadcast', () => {
  const path = join(tmp(), 'state.json');
  const j = new Journal(path);
  j.markSent('t', { hash: '0xh', nonce: 7, raw: '0xraw', from: '0xf' });
  j.setRecord('plans', 'p', { fees18: 123456789012345678901234n, ids: [1, 2] });
  const k = new Journal(path);
  assert.equal(k.task('t').state, TaskState.Sent);
  assert.equal(k.task('t').raw, '0xraw');
  assert.equal(k.record('plans', 'p').fees18, 123456789012345678901234n);
  assert.deepEqual(k.inflight().map(t => t.key), ['t']);
  k.markConfirmed('t', { hash: '0xh', blockNumber: 9 });
  assert.equal(new Journal(path).task('t').raw, undefined, 'raw tx dropped once confirmed');
});

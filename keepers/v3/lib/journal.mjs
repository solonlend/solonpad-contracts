// Journal = atomic JSON state (tasks + keeper records) + append-only JSONL event log.
// Task key = (chainId, contract, operationId, actionVersion) per DESIGN §9.2. The tx
// hash and signed raw tx are written BEFORE broadcast, so a crash between broadcast
// and receipt is reconciled from chain on restart instead of being re-sent blind.
import { readFileSync, writeFileSync, renameSync, appendFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';

export const TaskState = Object.freeze({
  Ready: 'Ready',
  Sent: 'Sent',
  Confirmed: 'Confirmed',
  Retryable: 'Retryable',
  Quarantined: 'Quarantined',
});

export const BACKOFF_MS = [15_000, 30_000, 60_000];
export const MAX_ATTEMPTS = 5;

export function taskKey({ chainId, contract, op, version = 1 }) {
  if (chainId === undefined || !contract || !op) throw new Error('taskKey needs chainId, contract, op');
  return `${chainId}:${String(contract).toLowerCase()}:${op}:v${version}`;
}

const replacer = (_, v) => (typeof v === 'bigint' ? `${v.toString()}n` : v);
const reviver = (_, v) => (typeof v === 'string' && /^-?\d+n$/.test(v) ? BigInt(v.slice(0, -1)) : v);

export class Journal {
  constructor(path, { now = () => Date.now() } = {}) {
    this.path = path;
    this.eventsPath = path.replace(/\.json$/, '') + '.events.jsonl';
    this.now = now;
    mkdirSync(dirname(path), { recursive: true });
    this.state = existsSync(path) ? JSON.parse(readFileSync(path, 'utf8'), reviver) : { tasks: {}, records: {} };
    this.state.tasks ??= {};
    this.state.records ??= {};
  }

  save() {
    const tmp = `${this.path}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.state, replacer, 2) + '\n');
    renameSync(tmp, this.path);
  }

  event(type, fields = {}) {
    appendFileSync(this.eventsPath, JSON.stringify({ at: new Date(this.now()).toISOString(), type, ...fields }, replacer) + '\n');
  }

  task(key) {
    return this.state.tasks[key] ?? null;
  }

  upsertTask(key, patch) {
    const prev = this.state.tasks[key] ?? { key, state: TaskState.Ready, attempts: 0, createdAt: this.now() };
    const next = { ...prev, ...patch, updatedAt: this.now() };
    this.state.tasks[key] = next;
    this.save();
    this.event('task', { key, state: next.state, hash: next.hash, note: patch.note, error: patch.lastError });
    return next;
  }

  // Durable before-broadcast record.
  markSent(key, { hash, nonce, raw, from, meta }) {
    return this.upsertTask(key, { state: TaskState.Sent, hash, nonce, raw, from, meta, sentAt: this.now() });
  }

  markConfirmed(key, { hash, blockNumber }) {
    return this.upsertTask(key, { state: TaskState.Confirmed, hash, blockNumber, raw: undefined, confirmedAt: this.now() });
  }

  // Failure never advances keeper records; it only schedules the next attempt.
  markFailure(key, error, { quarantine = false } = {}) {
    const prev = this.task(key) ?? { attempts: 0 };
    const attempts = (prev.attempts ?? 0) + 1;
    const exhausted = attempts >= MAX_ATTEMPTS;
    const state = quarantine || exhausted ? TaskState.Quarantined : TaskState.Retryable;
    const delay = BACKOFF_MS[Math.min(attempts - 1, BACKOFF_MS.length - 1)];
    return this.upsertTask(key, {
      state,
      attempts,
      raw: undefined,
      lastError: String(error?.shortMessage ?? error?.message ?? error).slice(0, 300),
      nextAttemptAt: this.now() + delay,
    });
  }

  // A Quarantined task needs an operator (or a proven chain-state change) to reopen.
  reopen(key, note) {
    return this.upsertTask(key, { state: TaskState.Ready, attempts: 0, nextAttemptAt: 0, note });
  }

  inflight() {
    return Object.values(this.state.tasks).filter(t => t.state === TaskState.Sent);
  }

  record(ns, id) {
    return this.state.records[ns]?.[id] ?? null;
  }

  setRecord(ns, id, patch) {
    this.state.records[ns] ??= {};
    const next = { ...(this.state.records[ns][id] ?? {}), ...patch, updatedAt: this.now() };
    this.state.records[ns][id] = next;
    this.save();
    this.event('record', { ns, id, patch });
    return next;
  }

  clearRecord(ns, id) {
    if (this.state.records[ns]?.[id] === undefined) return;
    delete this.state.records[ns][id];
    this.save();
    this.event('record-cleared', { ns, id });
  }

  records(ns) {
    return Object.values(this.state.records[ns] ?? {});
  }

  /// [id, record] pairs of a namespace (r13 keepers key records by ref / order id).
  entries(ns) {
    return Object.entries(this.state.records[ns] ?? {});
  }
}

// May this task be attempted now? Pure; used by TxSender and unit tests.
export function taskGate(task, now) {
  if (!task) return { go: true, reason: 'new' };
  switch (task.state) {
    case TaskState.Confirmed:
      return { go: false, reason: 'confirmed' };
    case TaskState.Quarantined:
      return { go: false, reason: 'quarantined' };
    case TaskState.Sent:
      return { go: false, reason: 'inflight', reconcile: true };
    case TaskState.Retryable:
      return now >= (task.nextAttemptAt ?? 0) ? { go: true, reason: 'retry' } : { go: false, reason: 'backoff' };
    default:
      return { go: true, reason: 'ready' };
  }
}

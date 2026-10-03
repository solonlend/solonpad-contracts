// Canonical keeper (r13, N6): every LayerZero settlement on the hub must be proven canonically within
// RECONCILE_WINDOW (8 days) or the hub halts minting. The proof travels
//   RH ReserveVault.checkpoint() (ArbSys L2->L1)  --[rollup challenge period]-->  L1 Outbox.executeTransaction
//   -> EthereumBridger.acceptCheckpoint -> CCTP -> Arc CanonicalGate.relay -> hub.reconcile(result, index, proof)
// This process automates the two ends and watches the middle:
//   1. RH: checkpoint() when results are pending (hourly by default; also a batch-size trigger).
//   2. Arc: for every checkpoint the gate holds, reconcile each result of a hub order not yet reconciled (Merkle
//      proof built off-chain exactly like ReserveVault.merkleRoot, lib/merkle.mjs).
//   3. Watch: age of the oldest unproven settlement (warn 5 d, critical 7 d), mintsHalted, checkpoints not arriving
//      on Arc. The middle is automated by two more processes: bin/outbox-executor.mjs (L1 Outbox.executeTransaction after
//      the challenge period) and bin/cctp-relayer.mjs (Iris attestation -> CanonicalGate.relay); runbook §8.2.
import { Contract, getAddress } from 'ethers';
import { StockHubAbi, ReserveVaultAbi, CanonicalGateAbi } from '../lib/abis.mjs';
import { leafOf, proofFor } from '../lib/merkle.mjs';
import { taskKey } from '../lib/journal.mjs';

const DAY = 86_400;
export const CANONICAL_DEFAULTS = Object.freeze({
  checkpointEverySec: 3_600,
  checkpointBatch: 64,
  warnAgeSec: 5 * DAY,
  criticalAgeSec: 7 * DAY,
  outboxAlertSec: 7 * DAY + 12 * 3600, // a checkpoint sent on RH and still not on the Arc gate after this
  maxReconcilePerTick: 32,
  scanChunk: 5_000,
  startLookback: 20_000,
});

export class CanonicalKeeper {
  constructor({ cfg, arc, rh, journal, logger, alert, now = null }) {
    Object.assign(this, { cfg, arc, rh, journal, logger, alert });
    const c = cfg.contracts ?? {};
    for (const k of ['stockHub', 'canonicalGate', 'reserveVault']) if (!c[k]) throw new Error(`canonical keeper: contracts.${k} required`);
    this.p = { ...CANONICAL_DEFAULTS, ...(cfg.canonical?.params ?? {}) };
    this.hub = new Contract(c.stockHub, StockHubAbi, arc.provider);
    this.gate = new Contract(c.canonicalGate, CanonicalGateAbi, arc.provider);
    this.vault = new Contract(c.reserveVault, ReserveVaultAbi, rh.provider);
    this.clock = now;
    this.results = new Map();
  }

  // Chain time of the latest block (refreshed each tick): quote deadlines and ages follow the chain, also on forks.
  now() { return this.clock ? this.clock() : this.nowSec ?? Math.floor(Date.now() / 1000); }
  async refreshClock() { if (!this.clock) this.nowSec = (await this.arc.provider.getBlock('latest')).timestamp; }
  note(kind, detail) { this.summary.actions.push({ kind, ...detail }); }

  async tick() {
    await this.refreshClock();
    this.summary = { actions: [], deferred: [], watch: {} };
    await this.arc.tx.reconcileAll();
    await this.rh.tx.reconcileAll();
    await this.scanResults();
    await this.checkpointPhase();
    await this.reconcilePhase();
    await this.watchPhase();
    return this.summary;
  }

  async result(seq) {
    if (!this.results.has(seq)) this.results.set(seq, await this.vault.resultAt(seq));
    return this.results.get(seq);
  }

  // Remember when each result was produced on RH (OrderExecuted block time): the age clock of the watch.
  async scanResults() {
    const head = await this.rh.provider.getBlockNumber();
    const cur = this.journal.record('scan', 'results') ?? {};
    let from = cur.next ?? Math.max(0, head - this.p.startLookback);
    const ev = this.vault.interface;
    while (from <= head) {
      const to = Math.min(head, from + this.p.scanChunk - 1);
      const logs = await this.rh.provider.getLogs({ address: this.vault.target, fromBlock: from, toBlock: to, topics: [[ev.getEvent('OrderExecuted').topicHash, ev.getEvent('Checkpointed').topicHash]] });
      const times = new Map();
      for (const l of logs) {
        if (!times.has(l.blockNumber)) times.set(l.blockNumber, (await this.rh.provider.getBlock(l.blockNumber)).timestamp);
        const e = ev.parseLog(l);
        if (e.name === 'OrderExecuted') this.journal.setRecord('results', String(e.args.seq), { ref: e.args.ref, at: times.get(l.blockNumber) });
        else this.journal.setRecord('checkpoints', `${e.args.fromSeq}-${e.args.toSeq}`, { root: e.args.root, at: times.get(l.blockNumber), tx: l.transactionHash, toSeq: Number(e.args.toSeq) });
      }
      from = to + 1;
      this.journal.setRecord('scan', 'results', { next: from });
    }
  }

  async checkpointPhase() {
    const [n, through] = await Promise.all([this.vault.resultCount(), this.vault.checkpointedThrough()]);
    const pending = Number(n) - Number(through);
    if (pending <= 0) return;
    const last = this.journal.record('state', 'checkpoint')?.at ?? 0;
    if (this.now() - last < this.p.checkpointEverySec && pending < this.p.checkpointBatch) {
      this.summary.deferred.push({ checkpoint: `next in ${this.p.checkpointEverySec - (this.now() - last)} s`, pending });
      return;
    }
    const res = await this.rh.tx.call(taskKey({ chainId: this.rh.chainId, contract: this.vault.target, op: `checkpoint:${through}:${n}` }), this.vault, 'checkpoint', [], { label: `checkpoint results ${through}..${Number(n) - 1}` });
    this.note('checkpoint', { from: Number(through), to: Number(n) - 1, status: res.status });
    if (res.status === 'confirmed' || res.status === 'dry-run') this.journal.setRecord('state', 'checkpoint', { at: this.now() });
    else await this.alert('checkpoint', `RH checkpoint(${through}..${Number(n) - 1}) ${res.status}: ${String(res.error?.shortMessage ?? res.error?.message ?? '').slice(0, 160)}`);
  }

  async reconcilePhase() {
    const count = Number(await this.gate.checkpointCount());
    const orders = Number(await this.hub.orderCount());
    let budget = this.p.maxReconcilePerTick;
    // The cursor only moves over a contiguous prefix of fully reconciled checkpoints: a checkpoint with a failed or
    // deferred reconcile keeps it, so the failed one is retried next tick while later ones are still worked now.
    let cursor = (this.journal.record('state', 'gate') ?? {}).fullyReconciled ?? 0;
    for (let i = cursor; i < count && budget > 0; i++) {
      const cp = await this.gate.checkpointAt(i);
      const from = Number(cp.fromSeq), to = Number(cp.toSeq);
      const leaves = [];
      for (let s = from; s <= to; s++) leaves.push(leafOf(await this.result(s)));
      let open = 0;
      for (let s = from; s <= to && budget > 0; s++) {
        const r = await this.result(s);
        const id = BigInt(r.ref);
        if (id >= BigInt(orders)) continue; // migration refs / foreign: not hub orders (migration minted separately)
        if (await this.hub.reconciled(r.ref)) continue;
        open++;
        budget--;
        const proof = proofFor(leaves, s - from);
        const res = await this.arc.tx.call(taskKey({ chainId: this.arc.chainId, contract: this.hub.target, op: `reconcile:${r.ref}:${i}` }), this.hub, 'reconcile',
          [[r.ref, r.underlying, r.outcome, r.amountIn, r.amountOut, r.seq], i, proof], { label: `reconcile order ${id} (checkpoint ${i}, seq ${s})` });
        this.note('reconcile', { id: Number(id), checkpoint: i, seq: s, status: res.status });
        if (res.status === 'confirmed') open--;
      }
      if (open === 0 && budget > 0 && i === cursor) this.journal.setRecord('state', 'gate', { fullyReconciled: ++cursor });
    }
    // The hub pops proven settlements off its unreconciled queue only in checkStale (also run lazily by every LZ
    // mint): prune it now so unreconciledCount is the real backlog.
    if (this.summary.actions.some(a => a.kind === 'reconcile' && a.status === 'confirmed')) {
      const res = await this.arc.tx.call(taskKey({ chainId: this.arc.chainId, contract: this.hub.target, op: `checkStale:${this.now()}` }), this.hub, 'checkStale', [], { label: 'hub.checkStale (prune proven settlements)' });
      this.note('checkStale', { status: res.status });
    }
  }

  async watchPhase() {
    const [halted, unrec, through] = await Promise.all([this.hub.mintsHalted(), this.hub.unreconciledCount(), this.vault.checkpointedThrough()]);
    this.summary.watch = { mintsHalted: halted, unreconciled: Number(unrec), rhCheckpointedThrough: Number(through) };
    if (halted) await this.alert('halted', 'hub mintsHalted = true (canonical proof missed the 8-day window or a dispute): buys stop minting — runbook §canonical');
    if (unrec === 0n) return;
    // Oldest result of a hub order still unreconciled (results are produced in seq order).
    const orders = BigInt(await this.hub.orderCount());
    const results = Object.fromEntries(this.journal.entries('results'));
    let oldest = null;
    for (const seq of Object.keys(results).map(Number).sort((a, b) => a - b)) {
      const rec = results[seq];
      if (BigInt(rec.ref) >= orders) continue;
      if (await this.hub.reconciled(rec.ref)) continue;
      oldest = { seq, ...rec }; break;
    }
    if (!oldest) return;
    const age = this.now() - oldest.at;
    this.summary.watch.oldestUnproven = { seq: oldest.seq, ref: oldest.ref, ageH: Math.round(age / 360) / 10 };
    const days = (age / DAY).toFixed(1);
    if (age >= this.p.criticalAgeSec) await this.alert('age-critical', `CRITICAL: result #${oldest.seq} (order ${BigInt(oldest.ref)}) unproven for ${days} d — hub halts minting at 8 d. Check outbox-executor / cctp-relayer (logs, ETH on Ethereum, bridger USDC) now — runbook §8.2`);
    else if (age >= this.p.warnAgeSec) await this.alert('age-warn', `result #${oldest.seq} (order ${BigInt(oldest.ref)}) unproven for ${days} d (halt at 8 d): check RH checkpoint -> outbox-executor -> cctp-relayer -> Arc gate`);
    const gateCount = Number(await this.gate.checkpointCount());
    for (const [k, cp] of this.journal.entries('checkpoints')) {
      if (this.now() - cp.at < this.p.outboxAlertSec) continue;
      let arrived = false;
      for (let i = gateCount - 1; i >= 0 && !arrived; i--) arrived = Number((await this.gate.checkpointAt(i)).toSeq) >= cp.toSeq;
      if (!arrived) await this.alert(`outbox-${k}`, `RH checkpoint ${k} (tx ${cp.tx}) sent ${((this.now() - cp.at) / DAY).toFixed(1)} d ago is not on the Arc gate: check outbox-executor (L1 execution) and cctp-relayer (Iris -> gate) — runbook §8.2`);
    }
  }
}

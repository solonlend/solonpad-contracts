// Push keeper: prepares payout queues for delivered allocations (register participants,
// seal the participant index, openQueue per delivery revision) and runs the daily
// batchDistribute cycle. A batch that does not move the cursor is a failure: the day
// record is not advanced, the task backs off, and after 5 attempts it alerts.
// Users can always claim directly; nothing here gates their claim.
import { Contract, AbiCoder, keccak256 } from 'ethers';
import { RoundManagerAbi, RewardVaultAbi, DistributorAbi, PayoutVaultAbi, PriceOracleAbi, RewardSourceAbi } from '../lib/abis.mjs';
import { taskKey } from '../lib/journal.mjs';
import { sessionState } from '../lib/market.mjs';
import { checkArcPrice, requestPush, clearRequest, ArcOracleAbi } from '../lib/price-demand.mjs';
import { queueDecision, dayPlan, gasPlan, progressOf, utcDay } from './decide.mjs';
import { RewardSourceDiscovery } from '../round/sources.mjs';
import { mergeSources } from '../lib/discovery.mjs';

const coder = AbiCoder.defaultAbiCoder();

export const PUSH_DEFAULTS = Object.freeze({
  gasBudget: 300_000,
  perAccountGas: 250_000, // upper estimate of real per-account use (stage + attempt), not the cap
  fixedGas: 150_000,
  maxTxGas: 12_000_000,
  maxCostBps: 50n, // Ops batch cost <= 0.5% of pushed value
  maxEvaluatedAccounts: 4096,
  registerPage: 64,
  // On-demand push (2026-10-02): RewardDistributor prices a push with priceUSD18 within oracleMaxAge (on chain, 2h);
  // an older price is requested from the RH oracle keeper before each batch instead of skipping the day.
  priceMarginSec: 900, // the batch must land with >= 15 min of oracleMaxAge left
  demandRefreshSec: 600,
  market: {}, // lib/market.mjs gate: no demand while the US market is closed (the oracle keeper would not push)
  discoveryAlertAfter: 5,
});

export class PushKeeper {
  constructor({ cfg, provider, tx, journal, logger, alert, chainId, now = null, contractAt = null }) {
    Object.assign(this, { cfg, provider, tx, journal, logger, alert, chainId });
    this.at = contractAt ?? ((address, abi) => new Contract(address, abi, provider));
    this.clock = now; // injected clock (tests); otherwise chain time of the latest block, refreshed each tick
    this.nowSec = 0;
    this.p = { ...PUSH_DEFAULTS, ...(cfg.push?.params ?? {}) };
    this.p.maxCostBps = BigInt(this.p.maxCostBps);
    const c = cfg.contracts;
    this.distributor = new Contract(c.distributor, DistributorAbi, provider);
    this.payout = new Contract(c.payoutVault, PayoutVaultAbi, provider);
    this.manager = c.roundManager ? new Contract(c.roundManager, RoundManagerAbi, provider) : null;
    this.discovery = new RewardSourceDiscovery({ provider, journal, logger, discover: cfg.push?.discover ?? {} });
  }

  now() { return this.clock ? this.clock() : this.nowSec; }

  async refreshClock() {
    if (!this.clock) this.nowSec = (await this.provider.getBlock('latest')).timestamp;
  }

  key(contract, op) {
    return taskKey({ chainId: this.chainId, contract, op });
  }

  async tick() {
    this.summary = { actions: [], skipped: [] };
    await this.refreshClock();
    await this.tx.reconcileAll();
    await this.discoverPhase();
    await this.prepareRoundAllocations();
    await this.prepareDirectQueues();
    const queues = await this.knownQueues();
    for (const q of queues) await this.serviceQueue(q);
    return this.summary;
  }

  // ------------------------------------------------ PurchaseStock allocations in RewardVault
  async prepareRoundAllocations() {
    if (!this.manager) return;
    const vault = new Contract(await this.manager.vault(), RewardVaultAbi, this.provider);
    const last = Number(await this.manager.nextEntryId());
    for (let id = 1; id <= last; id++) {
      const a = await vault.allocations(id);
      if (a.source === '0x0000000000000000000000000000000000000000' || a.revision === 0n) continue;
      if (!(await this.registerSource(vault, a.source))) continue;
      if (!(await vault.participantIndexSealed(id))) {
        if ((await vault.sourceCursor(a.source)) < (await vault.sourceBounds(id))) continue;
        const res = await this.tx.call(this.key(vault.target, `sealIndex:${id}`), vault, 'sealParticipantIndex', [id], { label: `seal participant index alloc ${id}` });
        this.summary.actions.push({ kind: 'sealIndex', allocationId: id, status: res.status });
        if (res.status !== 'confirmed') continue;
      }
      await this.ensureQueue(vault.target, id, a.asset, a.revision, keccak256(coder.encode(['address'], [vault.target])), 0);
    }
  }

  async registerSource(vault, source) {
    for (let i = 0; i < 64; i++) {
      const [cursor, bound] = await Promise.all([vault.sourceCursor(source), vault.requiredSourceBound(source)]);
      if (cursor >= bound) return true;
      const res = await this.tx.call(this.key(vault.target, `register:${source}:${cursor}`), vault, 'registerParticipants', [source, this.p.registerPage], { label: `register participants ${source.slice(0, 8)} from ${cursor}` });
      this.summary.actions.push({ kind: 'registerParticipants', source, cursor, status: res.status });
      if (res.status !== 'confirmed') return false;
    }
    return false;
  }

  // ------------------------------------------------ staking lanes (SolonStakingV2 SourceRegistered)
  // Kind-1 (stock-quoted pool) staking lanes pay DirectStock through their StakingRewardSource; it is created on
  // first credit (createEntrySource: anyone; also registers it as a trusted payout source) and then queued daily like
  // a configured direct source. Kind-0 lanes are sealed by the round keeper and arrive as RewardVault allocations.
  // With push.discover.factory, stock-quoted coins (holder share, DirectStock) are direct sources too.
  async discoverPhase() {
    if (!this.discovery.enabled) return;
    try {
      await this.discovery.sync();
      if (this.journal.record('discoveryHealth', 'push')?.failures) this.journal.setRecord('discoveryHealth', 'push', { failures: 0 });
    } catch (error) {
      const failures = (this.journal.record('discoveryHealth', 'push')?.failures ?? 0) + 1;
      this.journal.setRecord('discoveryHealth', 'push', { failures, lastError: String(error?.message).slice(0, 200) });
      this.summary.skipped.push({ reason: 'discovery', failures, error: String(error?.message).slice(0, 120) });
      if (failures >= this.p.discoveryAlertAfter) await this.alert('push-discovery', `direct-source discovery failed ${failures} times in a row (new stock-quoted coins / staking lanes are not being added): ${String(error?.message).slice(0, 200)}`);
    }
  }

  async discoveredDirectSources() {
    const out = [];
    const today = utcDay(this.now());
    for (const lane of this.discovery.stakingLanes(1)) {
      // Outside the fee ledger (protocol-Desk lanes) staging needs funded stock (SourceCoverageError otherwise).
      const staking = this.discovery.staking;
      if (!(await staking.ledgerLane(lane.key)) && (await staking.fundedAmount(lane.key)) <= (await staking.totalStaged(lane.key))) {
        this.summary.skipped.push({ lane: lane.key, reason: 'staking lane not funded (non-ledger lane)' });
        continue;
      }
      let source = await this.discovery.entrySourceOf(lane.key);
      if (!source) {
        let credited = false;
        for (let e = Math.max(lane.firstEpoch ?? 0, today - 20); e < today && !credited; e++) credited = (await this.discovery.staking.creditTotal27(lane.key, e)) > 0n;
        if (!credited) continue;
        const res = await this.tx.call(this.key(this.discovery.staking.target, `createEntrySource:${lane.key}`), this.discovery.staking, 'createEntrySource', [lane.key], { label: `staking entry source ${lane.key.slice(0, 10)}` });
        this.summary.actions.push({ kind: 'createEntrySource', lane: lane.key, status: res.status });
        if (res.status !== 'confirmed') continue;
        source = await this.discovery.entrySourceOf(lane.key);
        if (!source) continue;
      }
      out.push({ address: source, firstEpoch: lane.firstEpoch, minRevision: 2, lane: lane.key }); // revision 1 = no credit that epoch
    }
    return [...this.discovery.directTokens(), ...out];
  }

  // ------------------------------------------------ DirectStock / staking sources (config + discovered)
  async prepareDirectQueues() {
    const today = utcDay(this.now());
    const sources = mergeSources(this.cfg.push?.directSources ?? [], this.discovery.enabled ? await this.discoveredDirectSources() : []);
    this.summary.directSources = sources.map(s => s.address);
    for (const src of sources) {
      const source = new Contract(src.address, RewardSourceAbi, this.provider);
      const kind = Number(await source.settlementKind());
      const poolId = await new Contract(src.address, ['function poolId() view returns (bytes32)'], this.provider).poolId();
      for (let epoch = Math.max(src.firstEpoch ?? 0, today - (src.lookback ?? 20)); epoch < today; epoch++) {
        let snap;
        try { snap = await source.queueSnapshot(epoch); } catch { continue; }
        if (snap.revision === 0n || snap.upperBound === 0n) continue;
        if (src.minRevision && snap.revision < BigInt(src.minRevision)) continue;
        if (src.requireBudget && (await source.epochBudget(epoch)) === 0n) continue; // stock-quoted coin: no fees that day
        const asset = await source.queueAsset(epoch);
        if (asset === '0x0000000000000000000000000000000000000000') continue;
        await this.ensureQueue(src.address, epoch, asset, snap.revision, poolId, kind);
      }
    }
  }

  queueKey(source, poolId, kind, epoch, asset, revision) {
    return keccak256(coder.encode(['address', 'bytes32', 'uint8', 'uint256', 'address', 'uint256'], [source, poolId, kind, epoch, asset, revision]));
  }

  async ensureQueue(source, epoch, asset, revision, poolId, kind) {
    const k = this.queueKey(source, poolId, kind, epoch, asset, revision);
    if (await this.distributor.queued(k)) return; // idempotent even if the journal was lost
    const res = await this.tx.call(this.key(this.distributor.target, `open:${source}:${epoch}:${revision}`), this.distributor, 'openQueue', [source, epoch, asset], { label: `openQueue ${source.slice(0, 8)} epoch ${epoch} rev ${revision}` });
    this.summary.actions.push({ kind: 'openQueue', source, epoch: Number(epoch), revision, status: res.status });
  }

  // Queue ids are array indices with no length getter: scan forward from the last known index.
  async knownQueues() {
    const scan = this.journal.record('push', 'scan') ?? { next: 0 };
    let i = Number(scan.next);
    const found = [];
    for (;;) {
      let q;
      try { q = await this.distributor.queues(i); } catch { break; }
      found.push({ id: i, source: q.source, asset: q.asset, epoch: q.epoch, revision: q.revision });
      i++;
    }
    const all = this.journal.record('push', 'queues')?.list ?? [];
    const merged = [...all, ...found.map(q => ({ ...q, epoch: q.epoch.toString(), revision: q.revision.toString() }))];
    if (found.length && this.tx.execute) {
      this.journal.setRecord('push', 'queues', { list: merged });
      this.journal.setRecord('push', 'scan', { next: i });
    }
    // Only the latest revision per (source, epoch, asset) is scanned; older ones are superseded.
    const latest = new Map();
    for (const q of merged) {
      const k = `${q.source}:${q.epoch}:${q.asset}`;
      if (!latest.has(k) || BigInt(latest.get(k).revision) < BigInt(q.revision)) latest.set(k, q);
    }
    return [...latest.values()];
  }

  // Mirrors RewardDistributor._participantAt: a source that declared a scoped index
  // (RewardVault: participants per source, bounded per allocation) is read as
  // participantAt(queue.epoch = allocationId, i); legacy sources keep the global index.
  async participantReader(queue) {
    const scoped = await this.distributor.scopedParticipantIndex(queue.source);
    if (scoped) {
      const src = new Contract(queue.source, RewardVaultAbi, this.provider);
      return i => src.participantAt(queue.epoch, i);
    }
    const src = new Contract(queue.source, RewardSourceAbi, this.provider);
    return i => src.participantAt(i);
  }

  async accountsFor(queue, upperBound) {
    const participantAt = await this.participantReader(queue);
    const n = Math.min(upperBound, this.p.maxEvaluatedAccounts);
    const out = [];
    for (let i = 0; i < n; i++) {
      const account = await participantAt(i);
      out.push({ account, rawReady: await this.payout.readyRaw(account, queue.asset) + (await this.stageableEstimate(queue, account)) });
    }
    return out;
  }

  // For RewardVault allocations we can compute the stageable delta exactly from views.
  async stageableEstimate(queue, account) {
    if (!this.manager) return 0n;
    const vaultAddr = await this.manager.vault();
    if (queue.source.toLowerCase() !== vaultAddr.toLowerCase()) return 0n;
    const vault = new Contract(vaultAddr, RewardVaultAbi, this.provider);
    const a = await vault.allocations(queue.epoch);
    const src = new Contract(a.source, ['function creditOf(address,uint256,uint8) view returns (uint256)'], this.provider);
    const credit = await src.creditOf(account, a.epoch, a.cohort);
    const owed = (credit * a.cumulativeDelivered) / a.creditTotal;
    const done = await vault.creditedToPayout(queue.epoch, account);
    return owed > done ? owed - done : 0n;
  }

  /// Is the distributor's price fresh enough for a batch? Old but usable during market hours -> push demand + wait
  /// (next tick). Anything else (closed market, unusable price, non-SolonStockOracle) -> ok: dayPlan decides as before.
  async priceReady(q, nowSec) {
    let check;
    try {
      const [oracle, maxAge] = await Promise.all([this.distributor.oracle(), this.distributor.oracleMaxAge()]);
      check = await checkArcPrice({ oracle: this.at(oracle, ArcOracleAbi), asset: q.asset, nowSec, windowSec: Number(maxAge), marginSec: this.p.priceMarginSec });
    } catch (error) {
      this.logger.warn(`push q${q.id}: price freshness read failed (${String(error?.shortMessage ?? error?.message).slice(0, 80)}); day plan decides`);
      return { ok: true };
    }
    const statusDir = this.cfg.push?.demandDir ?? this.cfg.statusDir;
    if (check.fresh) {
      if (this.tx.execute) await clearRequest({ statusDir, requester: 'push', underlyings: [check.underlying] }).catch(() => false);
      return { ok: true };
    }
    if (!check.demandable) return { ok: true };
    // Calendar only: the Arc copy of the Chainlink time is old whenever nothing was pushed (no heartbeat); the RH
    // oracle keeper applies the feed-frozen gate itself.
    if (this.p.market !== false && !sessionState(nowSec, this.p.market).open) return { ok: true };
    const reason = `awaiting oracle push: ${check.reason}`;
    if (!this.tx.execute) return { ok: false, reason, demand: 'dry-run' };
    if (!statusDir) throw new Error('push keeper: statusDir (or push.demandDir) required to request an oracle push');
    const demand = await requestPush({ statusDir, requester: 'push', underlyings: [check.underlying], reason: `payout push q${q.id}`, nowSec, refreshSec: this.p.demandRefreshSec });
    return { ok: false, reason, demand };
  }

  async serviceQueue(q) {
    const nowSec = this.now();
    const today = utcDay(nowSec);
    const [view, nextScan] = await this.distributor.previewBatch(q.id);
    const upperBound = Number(view.upperBound);
    const recId = String(q.id);
    const record = this.journal.record('pushQueues', recId);
    const decision = queueDecision({ nowSec, nextScanAt: Number(nextScan), upperBound, record });
    if (!decision.scan) {
      this.summary.skipped.push({ queueId: q.id, reason: decision.reason });
      return;
    }
    const ready = await this.priceReady(q, nowSec);
    if (!ready.ok) {
      this.summary.skipped.push({ queueId: q.id, reason: ready.reason, demand: ready.demand ?? null });
      return;
    }
    const cursor = Number(view.cursor);
    const startCursor = cursor === upperBound ? 0 : cursor;
    if (record?.planDay !== today) {
      const oracle = new Contract(await this.distributor.oracle(), PriceOracleAbi, this.provider);
      const [price, updatedAt] = await oracle.priceUSD18(q.asset);
      const fresh = price > 0n && nowSec - Number(updatedAt) <= Number(await this.distributor.oracleMaxAge());
      const fee = await this.provider.getFeeData();
      const plan = dayPlan({
        accounts: await this.accountsFor(q, upperBound), priceUSD18: fresh ? price : 0n, minimumUSD18: await this.distributor.minimumUSD18(),
        gasPriceWei: fee.maxFeePerGas ?? fee.gasPrice ?? 0n, perAccountGas: this.p.perAccountGas, fixedGas: this.p.fixedGas,
        maxCostBps: this.p.maxCostBps, cursor: startCursor,
      });
      if (!plan.run) {
        if (this.tx.execute) this.journal.setRecord('pushQueues', recId, { skippedDay: today, skipReason: plan.reason });
        this.summary.skipped.push({ queueId: q.id, reason: plan.reason });
        return;
      }
      if (this.tx.execute) this.journal.setRecord('pushQueues', recId, { planDay: today, plan: { pushable: plan.pushable, value: plan.value, cost: plan.cost } });
      else this.summary.actions.push({ kind: 'dayPlan', queueId: q.id, ...plan });
    }
    const g = gasPlan({ gasBudget: this.p.gasBudget, perAccountGas: this.p.perAccountGas, maxTxGas: this.p.maxTxGas });
    const opKey = this.key(this.distributor.target, `batch:${q.id}:${today}:${startCursor}:${Number(nextScan)}`);
    const res = await this.tx.call(opKey, this.distributor, 'batchDistribute', [q.id, g.maxAccounts, 1, g.gasBudget], { gasLimit: g.gasLimit, label: `batchDistribute q${q.id} from ${startCursor}` });
    if (res.status !== 'confirmed') {
      this.summary.actions.push({ kind: 'batchDistribute', queueId: q.id, status: res.status });
      if (this.journal.task(opKey)?.state === 'Quarantined') await this.alert(`push-${q.id}`, `batchDistribute queue ${q.id} failing repeatedly: ${this.journal.task(opKey).lastError}`);
      return;
    }
    const processed = res.receipt.logs.filter(l => {
      try { const p = this.distributor.interface.parseLog(l); return p?.name === 'AccountProcessed' && Number(p.args.queueId) === q.id; } catch { return false; }
    });
    const paid = processed.filter(l => Number(this.distributor.interface.parseLog(l).args.outcome) === 1).length;
    const [after] = await this.distributor.previewBatch(q.id);
    const prog = progressOf({ before: cursor, after: Number(after.cursor), processedEvents: processed.length / 2, upperBound });
    if (!prog.moved) {
      // Confirmed but zero progress (gas guard tripped): treat as failure, keep the day open.
      this.journal.markFailure(opKey, 'batch confirmed with zero progress');
      await this.alert(`push-${q.id}-stall`, `batchDistribute queue ${q.id} made no progress (gas guard); gasLimit ${g.gasLimit}`);
      this.summary.actions.push({ kind: 'batchDistribute', queueId: q.id, status: 'no-progress' });
      return;
    }
    const patch = { lastCursor: Number(after.cursor), lastTx: res.receipt.hash };
    if (prog.complete) patch.completedDay = today;
    this.journal.setRecord('pushQueues', recId, patch);
    this.summary.actions.push({ kind: 'batchDistribute', queueId: q.id, status: 'confirmed', from: startCursor, to: Number(after.cursor), paid, complete: prog.complete });
  }
}

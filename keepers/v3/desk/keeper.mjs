// Desk 10% payout keeper. The Desk share of every pool's fees does NOT go through RewardDistributor: DeskRewards keeps
// one stream per (pool, UTC day, asset, kind) and DeskNFT pays card holders by tokenId. Per stream (src/v3, frozen):
//   USDC-quoted (kind 0): day over -> DeskRewards.entrySource(key) (anyone; registers a DeskRewardEntry with the
//     RewardRoundManager) -> RewardRoundManager.seal(entry, day, 0, policy) (anyone; pulls the budget) -> the round keeper
//     + launcher buy the stock like any other reward entry (on-demand oracle push included) -> Settled ->
//     DeskRewards.syncPurchased(key, entryId) (anyone) -> ready.
//   stock-quoted (kind 1): day over -> ready (the stream already holds the stock).
//   ready streams of one asset -> DeskNFT.openDeskQueue(keys[]) once a card is worth the push minimum
//     -> DeskNFT.batchDistributeDesk(queueId, cards) after 00:10 UTC, 15-minute pages, fresh price (push demand otherwise).
//   Protocol cards' share: DeskRewards.fundProtocolDeskBudget (kind 0) / forwardProtocolDesk (kind 1) once the day is over.
// Streams are discovered from DeskFeeCredit logs (lib/discovery.mjs: persisted cursor, out-of-order / duplicate safe).
// Chain state decides every step (sealed, entry, delivered, deskQueued); the journal only remembers cursors, which
// queues are ours and pass counters, so a restart or a lost journal never sends a step twice.
import { Contract, Interface, AbiCoder, keccak256 } from 'ethers';
import { DeskRewardsAbi, DeskNftAbi, RoundManagerAbi, RewardSourceAbi, DistributorAbi } from '../lib/abis.mjs';
import { taskKey, TaskState } from '../lib/journal.mjs';
import { LogDiscovery } from '../lib/discovery.mjs';
import { sessionState } from '../lib/market.mjs';
import { checkArcPrice, requestPush, clearRequest, ArcOracleAbi } from '../lib/price-demand.mjs';
import { DESK_DEFAULTS, DAY, SCAN_OFFSET, P27, utcDay, epochOver, perCardRaw, kind0Stage, planGroups, deskGasPlan, passUpdate } from './decide.mjs';

const coder = AbiCoder.defaultAbiCoder();
const ZERO = '0x0000000000000000000000000000000000000000';
const DeskEntryAbi = ['function rewards() view returns (address)', 'function key() view returns (bytes32)'];
const short = k => String(k).slice(0, 10);
const errText = e => String(e?.shortMessage ?? e?.message ?? e).slice(0, 200);
export const queueUnique = (keys, asset, revisions) => keccak256(coder.encode(['bytes32[]', 'address', 'uint256[]'], [keys, asset, revisions]));

export class DeskKeeper {
  constructor({ cfg, provider, tx, journal, logger, alert, chainId, now = null, contractAt = null }) {
    Object.assign(this, { cfg, provider, tx, journal, logger, alert, chainId });
    this.at = contractAt ?? ((address, abi) => new Contract(address, abi, provider));
    this.clock = now; // injected clock (tests); otherwise chain time of the latest block, refreshed each tick
    this.nowSec = 0;
    this.p = { ...DESK_DEFAULTS, ...(cfg.desk?.params ?? {}) };
    const c = cfg.contracts ?? {};
    for (const k of ['deskRewards', 'deskNft', 'roundManager']) if (!c[k]) throw new Error(`desk keeper: contracts.${k} is required`);
    this.rewards = this.at(c.deskRewards, DeskRewardsAbi);
    this.nft = this.at(c.deskNft, DeskNftAbi);
    this.manager = this.at(c.roundManager, RoundManagerAbi);
    this.rwIface = new Interface(DeskRewardsAbi);
    this.nftIface = new Interface(DeskNftAbi);
    const discover = cfg.desk?.discover ?? {};
    this.discovery = new LogDiscovery({
      provider, journal, logger, name: 'desk', address: c.deskRewards, topics: [this.rwIface.getEvent('DeskFeeCredit').topicHash],
      fromBlock: discover.fromBlock, params: discover.params, withTimestamp: false,
      // Stream fields are fixed by the key (source, day, asset, kind): reading them now equals reading them at the log.
      // Every swap emits a credit: a stream already known costs no RPC.
      decode: async log => {
        const e = this.rwIface.parseLog(log);
        const known = this.journal.record('discover:desk', String(e.args.stream).toLowerCase());
        if (known) return { id: known.id, key: known.key, source: known.source, epoch: known.epoch, asset: known.asset, kind: known.kind };
        const s = await this.rewards.streams(e.args.stream);
        return { id: String(e.args.stream).toLowerCase(), key: e.args.stream, source: s.source, epoch: Number(s.epoch), asset: s.asset, kind: Number(s.kind) };
      },
    });
  }

  now() { return this.clock ? this.clock() : this.nowSec; }

  async refreshClock() {
    if (!this.clock) this.nowSec = (await this.provider.getBlock('latest')).timestamp;
  }

  key(contract, op) { return taskKey({ chainId: this.chainId, contract: contract.target, op }); }

  async tick() {
    this.summary = { actions: [], deferred: [], streams: { known: 0, waiting: 0, held: 0, done: 0, dust: 0 } };
    await this.refreshClock();
    await this.tx.reconcileAll();
    await this.discoverPhase();
    this.policy = await this.servicePolicy();
    await this.scanQueues();
    const ready = await this.streamsPhase();
    await this.openPhase(ready);
    await this.servicePhase();
    return this.summary;
  }

  // ---------------------------------------------------------------- helpers
  async send(op, contract, method, args, { label, gasLimit = null, alertKey } = {}) {
    const key = this.key(contract, op);
    const res = await this.tx.call(key, contract, method, args, { label, gasLimit });
    const task = this.journal.task(key);
    if (task?.state === TaskState.Quarantined) await this.alert(alertKey, `${label} keeps failing (${task.attempts} attempts): ${task.lastError ?? res.status}`);
    return { ...res, key };
  }

  async servicePolicy() {
    const policy = this.at(await this.nft.servicePolicy(), DistributorAbi);
    const [oracle, maxAge, minimum] = await Promise.all([policy.oracle(), policy.oracleMaxAge(), policy.minimumUSD18()]);
    return { oracle: this.at(oracle, ArcOracleAbi), maxAge: Number(maxAge), minimum: BigInt(minimum) };
  }

  // ---------------------------------------------------------------- discovery
  async discoverPhase() {
    try {
      await this.discovery.sync();
      if (this.journal.record('discoveryHealth', 'desk')?.failures) this.journal.setRecord('discoveryHealth', 'desk', { failures: 0 });
    } catch (error) {
      const failures = (this.journal.record('discoveryHealth', 'desk')?.failures ?? 0) + 1;
      this.journal.setRecord('discoveryHealth', 'desk', { failures, lastError: errText(error) });
      this.summary.deferred.push({ reason: 'discovery', failures, error: errText(error).slice(0, 120) });
      if (failures >= this.p.discoveryAlertAfter) await this.alert('desk-discovery', `Desk stream discovery failed ${failures} times in a row (new Desk fee streams are not being picked up): ${errText(error)}`);
    }
  }

  // Desk queues are array indices without a length getter: read forward from the persisted cursor. Queues are chain facts
  // (a lost journal re-reads them all and adopts them instead of opening duplicates).
  async scanQueues() {
    let i = Number(this.journal.record('deskScan', 'queues')?.next ?? 0);
    const start = i;
    for (;;) {
      let q;
      try { q = await this.nft.deskQueues(i); } catch { break; }
      const [keys, revisions] = await this.nft.deskQueueStreams(i);
      const prev = this.journal.record('deskQueue', String(i)) ?? {};
      this.journal.setRecord('deskQueue', String(i), {
        keys: [...keys].map(String), revisions: [...revisions].map(String), asset: q.asset, upperBound: Number(q.upperBound),
        ...(prev.ours ? {} : { adoptedCursor: Number(q.cursor) }),
      });
      i++;
    }
    if (i !== start) this.journal.setRecord('deskScan', 'queues', { next: i });
    // Which queues we service: ours, or (adopted) any queue made only of known Desk streams that is worth a push.
    const known = new Set(this.discovery.items().map(s => s.id));
    for (const [id, rec] of this.journal.entries('deskQueue')) {
      if (rec.serviced !== undefined) continue;
      if (!rec.keys.every(k => known.has(k.toLowerCase()))) continue; // discovery (confirmations) has not caught up yet
      let serviced = false;
      try { serviced = await this.queueWorth(rec); } catch { continue; }
      const patch = { serviced, adopted: true };
      if (serviced && rec.adoptedCursor === rec.upperBound) patch.done = true; // a full pass already ran before we knew it
      this.journal.setRecord('deskQueue', id, patch);
    }
    this.covered = new Set();
    for (const [, rec] of this.journal.entries('deskQueue')) if (rec.serviced) for (const k of rec.keys) this.covered.add(k.toLowerCase());
  }

  async queueWorth(rec) {
    let raw = 0n;
    for (const k of rec.keys) raw += await this.perCardOf(k);
    const [price] = await this.policy.oracle.priceUSD18(rec.asset);
    return (raw * BigInt(price)) / 10n ** 18n >= this.policy.minimum;
  }

  async perCardOf(key) {
    const s = await this.rewards.streams(key);
    return perCardRaw({ kind: Number(s.kind), counter: s.counter, totalCredit27: s.totalCredit27, purchasedRaw: Number(s.kind) === 1 ? 0n : await this.rewards.purchasedRaw(key) });
  }

  // ---------------------------------------------------------------- per-stream progress
  async streamsPhase() {
    const now = this.now();
    const today = utcDay(now);
    const ready = [];
    for (const item of this.discovery.items()) {
      this.summary.streams.known++;
      const rec = this.journal.record('deskStream', item.id);
      if (rec?.done) { this.summary.streams[rec.dust ? 'dust' : 'done']++; continue; }
      if (item.epoch < today - this.p.lookbackDays) continue; // left to manual claim
      if (!epochOver(now, item.epoch)) { this.summary.streams.waiting++; continue; }
      let protocolDone = true;
      try {
        protocolDone = await this.protocolShare(item);
        const r = item.kind === 1 ? await this.stockStream(item) : await this.usdcStream(item, rec ?? {}, protocolDone);
        if (!r) continue;
        if (this.covered.has(item.id)) {
          if (protocolDone) this.journal.setRecord('deskStream', item.id, { done: true });
          continue;
        }
        ready.push(r);
      } catch (error) {
        this.summary.deferred.push({ stream: item.key, reason: 'read failed', error: errText(error).slice(0, 120) });
      }
    }
    return ready;
  }

  // Protocol cards' delegated share -> SolonStakingV2 protocol-Desk lane (round / push keepers take it from there).
  async protocolShare(item) {
    if (this.journal.record('deskStream', item.id)?.protocolDone) return true; // final after the day: checked once
    const [credit, funded] = await Promise.all([this.rewards.delegatedCredit27(item.key), this.rewards.delegatedFunded(item.key)]);
    if (BigInt(credit) / P27 <= BigInt(funded)) {
      this.journal.setRecord('deskStream', item.id, { protocolDone: true });
      return true;
    }
    const method = item.kind === 0 ? 'fundProtocolDeskBudget' : 'forwardProtocolDesk';
    const res = await this.send(`${method}:${item.key}:${credit}`, this.rewards, method, [item.key], { label: `${method} ${short(item.key)} day ${item.epoch}`, alertKey: `desk-protocol-${short(item.key)}` });
    this.summary.actions.push({ kind: method, stream: item.key, epoch: item.epoch, status: res.status });
    return res.status === 'confirmed';
  }

  async stockStream(item) {
    const [asset, revision] = await this.rewards.deliveryInfo(item.key);
    if (asset === ZERO || BigInt(revision) === 0n) return null;
    return { key: item.key, asset, revision: BigInt(revision), perCard: BigInt(revision) / P27, readyAt: (item.epoch + 1) * DAY };
  }

  // USDC-quoted stream: walk the chain until it waits on something (re-read after every confirmed step).
  async usdcStream(item, rec, protocolDone = true) {
    const key = item.key;
    for (let step = 0; step < 5; step++) {
      const [s, sealed, entrySource] = await Promise.all([this.rewards.streams(key), this.rewards.streamSealed(key), this.rewards.entrySources(key)]);
      const src = entrySource === ZERO ? null : entrySource;
      let entryId = rec.entryId ?? null;
      if (sealed && entryId == null) entryId = await this.entryIdOf(key);
      const v = { delivered: 0n, available: 0n, pending: 0n, purchasedRaw: 0n };
      if (entryId != null) {
        [v.delivered, v.available, v.pending, v.purchasedRaw] = await Promise.all([
          this.manager.delivered(entryId), this.manager.available(entryId), this.manager.pending(entryId), this.rewards.purchasedRaw(key)]);
      }
      const sealedFor = rec.sealedSeen != null ? this.now() - rec.sealedSeen : null;
      const { stage } = kind0Stage({ now: this.now(), epoch: item.epoch, budget: BigInt(s.totalCredit27) / P27, sealed, entrySource: src, entryId, ...v, sealedFor, unbuyableAfterSec: this.p.deliverAlertSec });
      let res;
      switch (stage) {
        case 'empty':
          this.journal.setRecord('deskStream', item.id, { done: protocolDone, empty: true });
          return null;
        case 'unbuyable':
          this.journal.setRecord('deskStream', item.id, { done: protocolDone, unbuyable: true, entryId });
          this.summary.actions.push({ kind: 'unbuyable', stream: key, entryId, available: v.available });
          return null;
        case 'create-entry':
          res = await this.send(`entrySource:${key}`, this.rewards, 'entrySource', [key], { label: `Desk entry source ${short(key)} day ${item.epoch}`, alertKey: `desk-entry-${short(key)}` });
          this.summary.actions.push({ kind: 'entrySource', stream: key, epoch: item.epoch, status: res.status });
          break;
        case 'seal': {
          const policy = await this.at(src, RewardSourceAbi).rewardPolicy(item.epoch, 0);
          res = await this.send(`deskSeal:${key}`, this.manager, 'seal', [src, item.epoch, 0, policy.assetId, policy.version, policy.pricePolicy, policy.mode],
            { label: `seal Desk stream ${short(key)} day ${item.epoch}`, alertKey: `desk-seal-${short(key)}` });
          this.summary.actions.push({ kind: 'seal', stream: key, epoch: item.epoch, budget18: BigInt(s.totalCredit27) / P27, status: res.status });
          break;
        }
        case 'find-entry':
          this.summary.deferred.push({ stream: key, reason: 'sealed entry not found yet' });
          return null;
        case 'sync':
          res = await this.send(`syncPurchased:${key}:${v.delivered}`, this.rewards, 'syncPurchased', [key, entryId], { label: `syncPurchased ${short(key)} entry ${entryId}`, alertKey: `desk-sync-${short(key)}` });
          this.summary.actions.push({ kind: 'syncPurchased', stream: key, entryId, delivered: v.delivered, status: res.status });
          break;
        case 'await-round': {
          const since = rec.sealedSeen ?? this.now();
          if (rec.entryId !== entryId || rec.sealedSeen == null) rec = this.journal.setRecord('deskStream', item.id, { entryId, sealedSeen: since });
          let why = null;
          if (entryId != null && this.now() - since > this.p.deliverAlertSec) {
            why = Number((await this.manager.entryStatus(entryId)).reason ?? 0);
            // BelowMinimum: the group waits for more entries (normal at low volume). Ready / CostLimit / Pending this long:
            // the round keeper / launcher lane is not getting it bought.
            if (why !== 1) await this.alert(`desk-round-${entryId}`, `Desk stream ${short(key)} (day ${item.epoch}) sealed as reward entry ${entryId} ${Math.round((this.now() - since) / 3600)}h ago and still not bought (entryStatus ${['Ready', 'BelowMinimum', 'CostLimit', 'Pending'][why] ?? why}; available ${v.available}, pending ${v.pending}, delivered ${v.delivered}): check the round keeper / launcher`);
          }
          this.summary.deferred.push({ stream: key, entryId, reason: 'await-round', ...(why != null ? { entryStatus: why } : {}) });
          return null;
        }
        case 'ready': {
          if (rec.entryId !== entryId) this.journal.setRecord('deskStream', item.id, { entryId });
          const [asset, revision] = await this.rewards.deliveryInfo(key);
          return { key, asset, revision: BigInt(revision), perCard: perCardRaw({ kind: 0, counter: s.counter, totalCredit27: s.totalCredit27, purchasedRaw: v.purchasedRaw }), readyAt: (item.epoch + 1) * DAY };
        }
        default: // wait-epoch (filtered earlier)
          return null;
      }
      if (res.status !== 'confirmed') return null;
    }
    return null;
  }

  // RewardRoundManager entry id of a Desk stream. Entries are read forward once from a persisted cursor; only Desk ones
  // (DeskRewardEntry: rewards() == our DeskRewards, key() = stream key) are remembered, so the journal stays small and a
  // stream sealed by anybody (or before a lost journal) is still found.
  async entryIdOf(key) {
    const want = String(key).toLowerCase();
    const hit = this.journal.record('deskEntry', want);
    if (hit) return hit.entryId;
    const scan = Number(this.journal.record('deskScan', 'entries')?.next ?? 1);
    const last = Number(await this.manager.nextEntryId());
    for (let id = scan; id <= last; id++) {
      const e = await this.manager.entry(id);
      const k = await this.deskKeyOf(e.source);
      if (k) this.journal.setRecord('deskEntry', k, { entryId: id, source: e.source });
    }
    if (last + 1 > scan) this.journal.setRecord('deskScan', 'entries', { next: last + 1 });
    return this.journal.record('deskEntry', want)?.entryId ?? null;
  }

  async deskKeyOf(source) {
    try {
      const entry = this.at(source, DeskEntryAbi);
      if (String(await entry.rewards()).toLowerCase() !== String(this.rewards.target).toLowerCase()) return null;
      return String(await entry.key()).toLowerCase();
    } catch { return null; } // coin / staking sources have no rewards()/key()
  }

  // ---------------------------------------------------------------- queues
  async openPhase(ready) {
    if (!ready.length) return;
    const prices = new Map();
    for (const a of new Set(ready.map(r => r.asset))) {
      try { prices.set(a, BigInt((await this.policy.oracle.priceUSD18(a))[0])); } catch { prices.set(a, 0n); }
    }
    const plan = planGroups({ ready, prices, minimumUSD18: this.policy.minimum, maxKeys: this.p.maxKeysPerQueue, marginBps: this.p.marginBps });
    for (const d of plan.dust) {
      this.journal.setRecord('deskStream', String(d.key).toLowerCase(), { done: true, dust: true, valueUSD18: d.valueUSD18 });
      this.summary.actions.push({ kind: 'dust', stream: d.key, valueUSD18: d.valueUSD18 });
    }
    this.summary.streams.held += plan.hold.length;
    const byKey = new Map(ready.map(r => [r.key, r]));
    for (const g of plan.open) {
      const revisions = g.keys.map(k => byKey.get(k).revision);
      const unique = queueUnique(g.keys, g.asset, revisions);
      if (await this.nft.deskQueued(unique)) {
        // Somebody opened exactly this queue: adopt it (worth a push by our own check just now). Not scanned yet -> next tick.
        const hit = this.journal.entries('deskQueue').find(([, r]) => queueUnique(r.keys, r.asset, r.revisions.map(BigInt)) === unique);
        if (!hit) { this.summary.deferred.push({ reason: 'queue exists, adopting next tick', keys: g.keys }); continue; }
        this.journal.setRecord('deskQueue', hit[0], { serviced: true, adopted: true });
        for (const k of g.keys) { this.covered.add(k.toLowerCase()); this.journal.setRecord('deskStream', k.toLowerCase(), { queueId: Number(hit[0]) }); }
        this.summary.actions.push({ kind: 'adoptQueue', queueId: Number(hit[0]), keys: g.keys });
        continue;
      }
      const res = await this.send(`openDesk:${unique}`, this.nft, 'openDeskQueue(bytes32[])', [g.keys], { label: `openDeskQueue ${g.keys.length} streams ${short(g.asset)}`, alertKey: `desk-open-${short(unique)}` });
      this.summary.actions.push({ kind: 'openDeskQueue', keys: g.keys, asset: g.asset, valueUSD18: g.valueUSD18, status: res.status });
      if (res.status !== 'confirmed') continue;
      const before = Number(this.journal.record('deskScan', 'queues')?.next ?? 0);
      await this.scanQueues();
      const after = Number(this.journal.record('deskScan', 'queues')?.next ?? 0);
      for (let i = before; i < after; i++) {
        const rec = this.journal.record('deskQueue', String(i));
        if (queueUnique(rec.keys, rec.asset, rec.revisions.map(BigInt)) !== unique) continue;
        this.journal.setRecord('deskQueue', String(i), { ours: true, serviced: true, adopted: false, done: false, openedAt: this.now() });
        for (const k of rec.keys) {
          this.covered.add(k.toLowerCase());
          this.journal.setRecord('deskStream', k.toLowerCase(), { queueId: i });
        }
      }
    }
  }

  // Price for the push: RewardDistributor.oracleMaxAge window on the SolonStockOracle. An old price would make the
  // whole page pay nobody (and still advance the cursor), so we never batch on it: request an on-demand push and wait.
  async priceReady(asset, queueId, nowSec) {
    let check;
    try {
      check = await checkArcPrice({ oracle: this.policy.oracle, asset, nowSec, windowSec: this.policy.maxAge, marginSec: this.p.priceMarginSec });
    } catch (error) {
      return { ok: false, reason: `price read failed: ${errText(error).slice(0, 80)}` };
    }
    const statusDir = this.cfg.desk?.demandDir ?? this.cfg.statusDir;
    if (check.fresh) {
      if (this.tx.execute && statusDir) await clearRequest({ statusDir, requester: 'desk', underlyings: [check.underlying] }).catch(() => false);
      return { ok: true };
    }
    if (!check.demandable) return { ok: false, reason: `price not usable: ${check.reason}` };
    if (this.p.market !== false && !sessionState(nowSec, this.p.market).open) return { ok: false, reason: 'market closed: waiting for a session price' };
    const reason = `awaiting oracle push: ${check.reason}`;
    if (!this.tx.execute) return { ok: false, reason, demand: 'dry-run' };
    if (!statusDir) throw new Error('desk keeper: statusDir (or desk.demandDir) required to request an oracle push');
    // Stamped with the wall clock like the round keeper (ensureFreshPrice): the oracle keeper compares stamps with its pushes.
    const demand = await requestPush({ statusDir, requester: 'desk', underlyings: [check.underlying], reason: `Desk payout q${queueId}`, refreshSec: this.p.demandRefreshSec });
    return { ok: false, reason, demand };
  }

  async servicePhase() {
    const now = this.now();
    for (const [id, rec0] of this.journal.entries('deskQueue')) {
      let rec = rec0;
      if (!rec.serviced || rec.done) continue;
      const q = await this.nft.deskQueues(id);
      const upperBound = Number(q.upperBound);
      if (now % DAY < SCAN_OFFSET + this.p.scanMarginSec) { this.summary.deferred.push({ queueId: Number(id), reason: 'scan-window' }); continue; }
      if (now < Number(q.nextScanAt)) { this.summary.deferred.push({ queueId: Number(id), reason: 'scheduled', nextScanAt: Number(q.nextScanAt) }); continue; }
      const ready = await this.priceReady(q.asset, id, now);
      if (!ready.ok) {
        const since = rec.priceWaitSince ?? now;
        if (rec.priceWaitSince == null) rec = this.journal.setRecord('deskQueue', id, { priceWaitSince: since });
        if (now - since > this.p.priceAlertSec) await this.alert(`desk-price-${id}`, `Desk queue ${id} has waited ${Math.round((now - since) / 3600)}h for a usable price (${ready.reason})`);
        this.summary.deferred.push({ queueId: Number(id), reason: ready.reason, demand: ready.demand ?? null });
        continue;
      }
      if (rec.priceWaitSince != null) rec = this.journal.setRecord('deskQueue', id, { priceWaitSince: null });
      const g = deskGasPlan({ keys: rec.keys.length, maxTxGas: this.p.maxTxGas, fixedGas: this.p.fixedGas, perCardGas: this.p.perCardGas, perKeyCardGas: this.p.perKeyCardGas });
      const cursor = Number(q.cursor);
      const start = cursor === upperBound ? 0 : cursor;
      const res = await this.send(`deskBatch:${id}:${Number(q.nextScanAt)}:${start}`, this.nft, 'batchDistributeDesk(uint256,uint256)', [BigInt(id), g.cards],
        { gasLimit: g.gasLimit, label: `batchDistributeDesk q${id} from ${start}`, alertKey: `desk-batch-${id}` });
      if (res.status !== 'confirmed') {
        this.summary.actions.push({ kind: 'batchDistributeDesk', queueId: Number(id), status: res.status });
        continue;
      }
      let paid = 0, failed = 0;
      for (const l of res.receipt?.logs ?? []) {
        if (l.address && String(l.address).toLowerCase() !== String(this.nft.target).toLowerCase()) continue;
        let ev;
        try { ev = this.nftIface.parseLog(l); } catch { continue; }
        if (ev?.name === 'DeskPushed') paid++;
        else if (ev?.name === 'DeskPushBlocked') failed++;
      }
      const after = Number((await this.nft.deskQueues(id)).cursor);
      const upd = passUpdate(rec, { start, after, upperBound, paid, failed, maxPasses: this.p.maxPasses });
      if (!upd.moved) {
        this.journal.markFailure(res.key, 'batch confirmed with zero progress');
        await this.alert(`desk-queue-${id}-stall`, `batchDistributeDesk queue ${id} made no progress (gas guard: ${rec.keys.length} streams need ${500_000 * rec.keys.length + 100_000} gas per card; gasLimit ${g.gasLimit})`);
        this.summary.actions.push({ kind: 'batchDistributeDesk', queueId: Number(id), status: 'no-progress' });
        continue;
      }
      this.journal.setRecord('deskQueue', id, { ...upd.patch, lastTx: res.receipt?.hash ?? null });
      if (upd.alert) await this.alert(`desk-queue-${id}`, `Desk queue ${id}: ${upd.patch.lastPass.failed} card pushes still reverting after ${upd.patch.passes} daily passes (DeskPushBlocked); left to manual DeskNFT.claim`);
      this.summary.actions.push({ kind: 'batchDistributeDesk', queueId: Number(id), status: 'confirmed', from: start, to: after, cards: g.cards, paid, failed, complete: upd.complete, gasUsed: res.receipt?.gasUsed ?? null });
    }
  }
}

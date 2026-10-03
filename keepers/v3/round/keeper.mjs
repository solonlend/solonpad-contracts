// Round keeper: seal -> enqueue -> (fee plan, signed quote) executeAndStart -> Relay funding
// -> poke -> submit -> finalize, with cancel/refund/quarantine handling. Chain state is the
// source of truth every tick; the journal only prevents duplicate sends and remembers
// off-chain facts (funding dispatch, planned orders) that the chain cannot tell us.
import { Contract } from 'ethers';
import { marketGate } from '../lib/market.mjs';
import {
  RoundManagerAbi, BatcherAbi, RegistryAbi, StockAdapterAbi, RewardSourceAbi, PriceOracleAbi, Erc20Abi, StockOracleAbi, StockHubFeeAbi,
} from '../lib/abis.mjs';
import { taskKey } from '../lib/journal.mjs';
import { ensureFreshPrice, ArcOracleAbi } from '../lib/price-demand.mjs';
import { stockQuoteDigest, encodeStockQuoteData, signChecked, newNonce } from '../lib/quotes.mjs';
import { planFundingFees } from '../lib/relay.mjs';
import {
  DAY, ROUND_MAX, Status, StatusName, ACTIVE, TERMINAL, sealableEpochs, planBatch, entriesHash, orderIdFor,
  minRawOut, checkAdapterQuote, nextRoundAction, shouldAdvance, alignBudget18, roundCap, planRoundCosts, decodeRevert, USDC_GRID,
} from './decide.mjs';
import { definitelyNotSent, emptyProofSource } from './funding.mjs';
import { RewardSourceDiscovery } from './sources.mjs';
import { mergeSources } from '../lib/discovery.mjs';

export const ROUND_DEFAULTS = Object.freeze({
  lookbackEpochs: 30,
  maxActiveRounds: 1, // zero-float sequential mode
  maxRoundBudget18: ROUND_MAX,
  quoteTtlSec: 600,
  slippageBps: 99n, // < SolonStockAdapter.ORACLE_FLOOR_BPS (100); minRaw is also clamped to the floor (F3)
  // Price freshness = the adapter oracle's own on-chain maxAge (SolonStockOracle.assetOf(asset).params.maxAge, 15 min
  // on mainnet: the startFunding floor calls rawFor -> execPrice). A number here can only tighten it.
  priceMaxAgeSec: null,
  legacyPriceMaxAgeSec: 3600, // only for a pre-r7 adapter without an oracle floor (no on-chain window to read)
  priceMarginSec: 120, // the start must land with at least this much of maxAge left
  demandRefreshSec: 600, // re-request a push that has not landed after 10 min
  extraFixedCost18: 0n, // any further external cost to count in the signed fixedCost18 (LZ is now quoted live)
  maxFeeBps: 50n, // Relay fee ceiling vs budget (0.5%, §5.1)
  hubFeeBps: 25n, // fallback when the hub has no fees() view; the live buyFeeBps is used otherwise
  lzBufferBps: 2_000n, // LZ order fee quoted at plan time + 20% (unused part stays with the order / Ops)
  costBasis: 'external', // signed fixedCost18 = Relay + LZ (design); 'all' adds the hub fee (r10 model)
  market: {}, // lib/market.mjs gate params; false = off (tests / anvil only)
  fundingAlertSec: 15 * 60,
  quarantineAfterSec: 6 * 3600,
  cancelAfterSec: null, // null = alert only; set to auto-request cancel (>= 30 min)
  orphanWatchSec: 7 * DAY,
  advanceThreshold: 16,
  fundingQuoteAlertAfter: 3, // consecutive Relay funding-quote failures for a group before alerting (decimals M2)
  discoveryAlertAfter: 5, // consecutive failed source-discovery scans before alerting (known sources keep running)
});

const PRECISION27 = 10n ** 27n; // SolonStakingV2.PRECISION: budget18 = creditTotal27 / 1e27

export class RoundKeeper {
  constructor({ cfg, provider, tx, journal, logger, alert, lane, proofSource = emptyProofSource, quoteSigner = null, chainId, now = null, contractAt = null }) {
    Object.assign(this, { cfg, provider, tx, journal, logger, alert, lane, proofSource, quoteSigner, chainId });
    this.at = contractAt ?? ((address, abi) => new Contract(address, abi, provider));
    this.clock = now; // injected clock (tests); otherwise chain time of the latest block, refreshed each tick
    this.nowSec = 0;
    this.p = { ...ROUND_DEFAULTS, ...(cfg.round?.params ?? {}) };
    for (const k of ['maxRoundBudget18', 'slippageBps', 'extraFixedCost18', 'maxFeeBps', 'hubFeeBps', 'lzBufferBps']) this.p[k] = BigInt(this.p[k]);
    const c = cfg.contracts;
    this.manager = new Contract(c.roundManager, RoundManagerAbi, provider);
    this.batcher = new Contract(c.batcher, BatcherAbi, provider);
    this.registry = new Contract(c.stockRegistry, RegistryAbi, provider);
    this.oracle = c.rewardPriceOracle ? this.at(c.rewardPriceOracle, PriceOracleAbi) : null;
    this.discovery = new RewardSourceDiscovery({ provider, journal, logger, discover: cfg.round?.discover ?? {}, at: this.at });
    this.summary = null;
  }

  now() { return this.clock ? this.clock() : this.nowSec; }

  async refreshClock() {
    if (!this.clock) this.nowSec = (await this.provider.getBlock('latest')).timestamp;
  }

  key(op) {
    return taskKey({ chainId: this.chainId, contract: this.manager.target, op });
  }

  note(kind, detail) {
    this.summary.actions.push({ kind, ...detail });
  }

  async tick() {
    this.summary = { actions: [], deferred: [], seams: [] };
    await this.refreshClock();
    await this.tx.reconcileAll();
    await this.discoverPhase();
    await this.sealPhase();
    await this.stakingSealPhase();
    await this.enqueuePhase();
    const active = await this.roundsPhase();
    await this.batchPhase(active);
    await this.roundsPhase(); // progress anything started this tick (funding dispatch)
    return this.summary;
  }

  // ---------------------------------------------------------------- source discovery
  // New coins (factory LaunchState Locked) and staking lanes (SolonStakingV2 SourceRegistered) join the schedule
  // without a config change. A failed scan keeps the known sources running and alerts after a few in a row.
  async discoverPhase() {
    if (!this.discovery.enabled) return;
    try {
      const res = await this.discovery.sync();
      for (const [name, r] of Object.entries(res)) if (r.added.length) this.note('discovered', { scanner: name, added: r.added });
      this.summary.sources = this.sourceList().map(s => s.address);
      if (this.journal.record('discoveryHealth', 'round')?.failures) this.journal.setRecord('discoveryHealth', 'round', { failures: 0 });
    } catch (error) {
      const failures = (this.journal.record('discoveryHealth', 'round')?.failures ?? 0) + 1;
      this.journal.setRecord('discoveryHealth', 'round', { failures, lastError: String(error?.message).slice(0, 200) });
      this.summary.deferred.push({ reason: 'Discovery', failures, error: String(error?.message).slice(0, 120) });
      if (failures >= this.p.discoveryAlertAfter) await this.alert('round-discovery', `reward-source discovery failed ${failures} times in a row (new coins are not being added): ${String(error?.message).slice(0, 200)}`);
    }
  }

  // Configured sources (operator overrides) united with discovered USDC-quoted coins, deduplicated by address.
  sourceList() {
    return mergeSources(this.cfg.round?.sources ?? [], this.discovery.roundTokens());
  }

  // ---------------------------------------------------------------- seal
  async sealPhase() {
    const now = this.now();
    const today = Math.floor(now / DAY);
    for (const src of this.sourceList()) {
      if (src.kind && src.kind !== 'token') continue; // configured non-token entries: staking lanes are discovered (stakingSealPhase)
      const source = this.at(src.address, RewardSourceAbi);
      const cache = new Map();
      // RPC budget: epochs up to the source's watermark are final and never re-read (see advanceWatermark).
      const from = Math.max(src.firstEpoch ?? 0, today - this.p.lookbackEpochs, this.watermark(src.address) + 1);
      for (let epoch = from; epoch < today; epoch++) {
        const [budget, sealed, nextRoundAt] = await Promise.all([
          source.epochBudget(epoch), source.rewardSealed(epoch), source.nextRoundAt(epoch).catch(() => null),
        ]);
        cache.set(epoch, { budget, sealed, nextRoundAt: nextRoundAt == null ? null : Number(nextRoundAt), nowSec: now });
      }
      // A past epoch's budget never grows (V3RewardToken credits the current day), so sealed or empty = final.
      this.advanceWatermark(src.address, from, today, e => cache.get(e).sealed || cache.get(e).budget === 0n);
      const epochs = sealableEpochs({ today, firstEpoch: from, lookback: this.p.lookbackEpochs, views: e => cache.get(e) });
      for (const epoch of epochs) {
        const policy = await source.rewardPolicy(epoch, 0);
        const args = [src.address, epoch, 0, policy.assetId, policy.version, policy.pricePolicy, policy.mode];
        const res = await this.tx.call(this.key(`seal:${src.address}:${epoch}:0`), this.manager, 'seal', args, { label: `seal ${src.address.slice(0, 8)} epoch ${epoch}` });
        this.note('seal', { source: src.address, epoch, status: res.status });
      }
    }
  }

  watermark(id) {
    return Number(this.journal.record('sealDone', String(id).toLowerCase())?.through ?? -1);
  }

  // Every epoch <= through is final (no seal will ever be needed): advance over the contiguous final prefix.
  advanceWatermark(id, from, today, isFinal) {
    const start = Math.max(this.watermark(id), from - 1); // epochs before firstEpoch / the lookback are never sealed
    let through = start;
    for (let e = from; e < today && e === through + 1 && isFinal(e); e++) through = e;
    if (through > start) this.journal.setRecord('sealDone', String(id).toLowerCase(), { through });
  }

  // Staking 5% share of USDC-quoted pools (kind-0 lanes): RewardRoundManager.seal(StakingRewardSource, epoch) is the only
  // way the lane's budget enters a round (StakingRewardSource.sealReward is manager-only). The entry source is created
  // on first need (createEntrySource also registers it with the manager and the payout vault). An epoch is sealable when
  // it is over, unsealed and holds >= 1 budget wei; carry still pending release (no stakers earlier) is probed by
  // simulation because sealSource releases it into the epoch before reading the total.
  async stakingSealPhase() {
    const lanes = this.discovery.stakingLanes(0);
    if (!lanes.length) return;
    const staking = this.discovery.staking;
    const today = Math.floor(this.now() / DAY);
    for (const lane of lanes) {
      const carry = await staking.carryState(lane.key);
      const carryPending = carry.pendingEvents > 0n && carry.deposited27 > carry.released27;
      const epochs = [];
      const views = new Map();
      const from = Math.max(lane.firstEpoch ?? 0, today - this.p.lookbackEpochs, this.watermark(lane.key) + 1);
      for (let epoch = from; epoch < today; epoch++) {
        const [sealed, credit] = await Promise.all([staking.rewardSealed(lane.key, epoch), staking.creditTotal27(lane.key, epoch)]);
        views.set(epoch, { sealed, credit });
        if (!sealed && (credit >= PRECISION27 || carryPending)) epochs.push({ epoch, probe: credit < PRECISION27, budget: credit / PRECISION27 });
      }
      // Final: sealed, or no budget and no locked carry that sealSource could still release into the epoch.
      this.advanceWatermark(lane.key, from, today, e => views.get(e).sealed || (views.get(e).credit < PRECISION27 && !carryPending));
      if (!epochs.length) continue;
      // Lanes outside the fee ledger (protocol-Desk, V2) seal only from funded native balance (BudgetUnfundedError otherwise).
      if (!(await staking.ledgerLane(lane.key))) {
        const available = await staking.nativeAvailable(lane.key);
        if (epochs.reduce((sum, e) => sum + e.budget, 0n) > available) { // each seal spends nativeAvailable: compare the total
          this.summary.deferred.push({ reason: 'StakingLaneUnfunded', lane: lane.key, available, need: epochs.map(e => e.budget) });
          continue;
        }
      }
      let source = await this.discovery.entrySourceOf(lane.key);
      if (!source) {
        const res = await this.tx.call(taskKey({ chainId: this.chainId, contract: staking.target, op: `createEntrySource:${lane.key}` }), staking, 'createEntrySource', [lane.key], { label: `staking entry source ${lane.key.slice(0, 10)}` });
        this.note('createEntrySource', { lane: lane.key, status: res.status, epochs: epochs.map(e => e.epoch) });
        if (res.status !== 'confirmed') continue; // dry-run stops here: the seal needs the source address
        source = await this.discovery.entrySourceOf(lane.key);
        if (!source) continue;
      }
      const entry = this.at(source, RewardSourceAbi);
      for (const { epoch, probe } of epochs) {
        const policy = await entry.rewardPolicy(epoch, 0);
        const args = [source, epoch, 0, policy.assetId, policy.version, policy.pricePolicy, policy.mode];
        if (probe) {
          try { await this.manager.seal.staticCall(...args); } catch { continue; } // nothing to release into this epoch
        }
        const res = await this.tx.call(this.key(`seal:${source}:${epoch}:0`), this.manager, 'seal', args, { label: `seal staking ${lane.key.slice(0, 10)} epoch ${epoch}` });
        this.note('seal', { source, lane: lane.key, epoch, status: res.status });
      }
    }
  }

  // ---------------------------------------------------------------- enqueue (strict FIFO)
  async enqueuePhase() {
    const next = Number(await this.batcher.nextToEnqueue());
    const last = Number(await this.manager.nextEntryId());
    for (let id = next; id <= last; id++) {
      const res = await this.tx.call(taskKey({ chainId: this.chainId, contract: this.batcher.target, op: `enqueue:${id}` }), this.batcher, 'enqueue', [id], { label: `enqueue entry ${id}` });
      this.note('enqueue', { entryId: id, status: res.status });
      if (res.status !== 'confirmed') break; // enqueue must be in order; dry-run shows the head only
    }
  }

  // ---------------------------------------------------------------- existing rounds
  async roundsPhase() {
    const last = Number(await this.manager.nextRoundId());
    let active = 0;
    for (let id = 1; id <= last; id++) {
      const rec = this.journal.record('rounds', String(id));
      if (rec?.terminal) continue;
      const round = await this.manager.round(id);
      const status = Number(round.status);
      if (TERMINAL.has(status) && !(status === Status.Settled && rec?.feesRefunded !== true)) {
        this.journal.setRecord('rounds', String(id), { terminal: true, status: StatusName[status] });
        continue;
      }
      if (ACTIVE.has(status)) active++;
      await this.progressRound(id, round, rec ?? {});
    }
    return active;
  }

  async probeResult(round) {
    try {
      const proof = await this.proofSource.proofFor(round.orderId);
      const adapter = this.at(round.adapter, StockAdapterAbi);
      const r = await adapter.consumeResult.staticCall(round.orderId, proof, { from: this.manager.target });
      return { status: Number(r.status), raw: r.raw, refund: r.refund18, proof };
    } catch {
      return null;
    }
  }

  async progressRound(id, round, rec) {
    const status = Number(round.status);
    const adapter = this.at(round.adapter, StockAdapterAbi);
    if (status === Status.Settled) {
      // Ops fee remainder back to the fixed Ops vault (anyone may call after funding).
      if ((await adapter.feeBalance(round.orderId)) > 0n) {
        const res = await this.tx.call(taskKey({ chainId: this.chainId, contract: adapter.target, op: `refundFees:${round.orderId}` }), adapter, 'refundUnusedFees', [round.orderId], { label: `refund unused ops fees round ${id}` });
        this.note('refundFees', { roundId: id, status: res.status });
        if (res.status !== 'confirmed') return;
      }
      this.journal.setRecord('rounds', String(id), { terminal: true, status: 'Settled', feesRefunded: true, delivered: round.delivered });
      return;
    }
    const needsFunded = status === Status.Funding || (status === Status.Quarantined && Number(round.submittedAt) === 0);
    const needsProbe = status === Status.Funding || status === Status.Funded || status === Status.Submitted || status === Status.Quarantined || status === Status.Refunded;
    const now = this.now();
    if (status === Status.Refunded && !rec.refundedAt && this.tx.execute) rec = this.journal.setRecord('rounds', String(id), { refundedAt: now });
    if (status === Status.Refunded && now - Number(rec.refundedAt ?? now) > this.p.orphanWatchSec) {
      this.journal.setRecord('rounds', String(id), { terminal: true, status: 'Refunded' });
      return;
    }
    const ctx = {
      now,
      funded: needsFunded ? await adapter.funded(round.orderId) : false,
      dispatched: Boolean(rec.dispatchStartedAt),
      dispatchedAt: rec.dispatchStartedAt ?? 0,
      result: needsProbe ? await this.probeResult(round) : null,
      orphanConsumed: status === Status.Refunded ? await this.manager.orphanConsumed(id) : false,
      fundingAlertSec: this.p.fundingAlertSec,
      quarantineAfterSec: this.p.quarantineAfterSec,
      cancelAfterSec: this.p.cancelAfterSec,
    };
    const decision = nextRoundAction(round, ctx);
    const tag = `round ${id} (${StatusName[status]})`;
    switch (decision.action) {
      case 'poke':
      case 'submit':
      case 'cancelUnsent':
      case 'requestCancel': {
        const res = await this.tx.call(this.key(`round:${id}:${decision.action}:${status}`), this.manager, decision.action, [id], { label: `${decision.action} ${tag}` });
        this.note(decision.action, { roundId: id, status: res.status });
        break;
      }
      case 'finalize': {
        const proof = ctx.result?.proof ?? (await this.proofSource.proofFor(round.orderId));
        const res = await this.tx.call(this.key(`round:${id}:finalize:${status}`), this.manager, 'finalize', [id, proof], { label: `finalize ${tag}: ${decision.reason ?? 'result ready'}` });
        this.note('finalize', { roundId: id, status: res.status, outcome: ctx.result?.status ?? 0 });
        if (res.status === 'confirmed' && ctx.result?.status === 2) this.journal.setRecord('rounds', String(id), { refundedAt: now });
        break;
      }
      case 'dispatchFunding':
        await this.dispatchFunding(id, round, rec);
        break;
      case 'start':
        await this.startReserved(id, round);
        break;
      case 'alert': {
        const mins = Math.round((now - Number(decision.since ?? now)) / 60);
        const msg = decision.level === 'quarantine'
          ? `round ${id} result unknown ${mins} min after submit (no verified fill/refund proof); on-chain state unchanged, funds/capacity stay reserved until a proof is relayed via finalize`
          : `round ${id} ${decision.reason} ${mins} min after Relay dispatch (request ${rec.requestId ?? '?'}); verify Relay status and hub receipt — no re-dispatch will be attempted`;
        await this.alert(`round-${id}-${decision.level}`, msg);
        this.note('alert', { roundId: id, reason: decision.reason });
        break;
      }
      default:
        break;
    }
  }

  async dispatchFunding(id, round, rec) {
    if (!this.tx.execute) {
      this.note('dispatchFunding', { roundId: id, status: 'dry-run', lane: this.lane?.name });
      return;
    }
    const orderRec = this.journal.record('orders', round.orderId) ?? {};
    const fees18 = BigInt(orderRec.fees18 ?? 0n);
    // Intent is durable BEFORE the lane is called: after a crash we never dispatch twice.
    this.journal.setRecord('rounds', String(id), { orderId: round.orderId, dispatchStartedAt: this.now(), lane: this.lane.name });
    try {
      const out = await this.lane.dispatch({ orderId: round.orderId, budget18: round.budget18, fees18 });
      this.journal.setRecord('rounds', String(id), { requestId: out.requestId, dispatchTx: out.txHash, dispatchedAt: this.now() });
      this.note('dispatchFunding', { roundId: id, status: 'sent', requestId: out.requestId });
    } catch (error) {
      if (definitelyNotSent(error)) {
        this.journal.setRecord('rounds', String(id), { dispatchStartedAt: null, lastDispatchError: String(error.message).slice(0, 200) });
        if (error.seam) this.summary.seams.push(error.seam);
        this.note('dispatchFunding', { roundId: id, status: error.quiet ? 'queued' : 'not-sent', error: error.message });
        // r13: a reward order still waiting its turn in the scheduler is normal (the launcher funds it), not an alert.
        if (!error.quiet) await this.alert(`round-${id}-dispatch`, `round ${id} funding not dispatched: ${error.message}`);
      } else {
        this.journal.setRecord('rounds', String(id), { dispatchAmbiguous: true, lastDispatchError: String(error.message).slice(0, 200) });
        await this.alert(`round-${id}-dispatch-ambiguous`, `round ${id} Relay dispatch outcome UNKNOWN (${error.message}); treated as sent, verify manually`);
        this.note('dispatchFunding', { roundId: id, status: 'ambiguous' });
      }
    }
  }

  // ---------------------------------------------------------------- new batches
  async priceFor(asset, maxAgeSec) {
    if (!this.oracle) throw new Error('round pricing: contracts.rewardPriceOracle not configured');
    const [price, updatedAt] = await this.oracle.priceUSD18(asset);
    let limit = Math.min(Number(maxAgeSec ?? Infinity), Number(this.p.priceMaxAgeSec ?? Infinity));
    if (!Number.isFinite(limit)) limit = Number(this.p.legacyPriceMaxAgeSec);
    if (price === 0n || this.now() - Number(updatedAt) > limit) throw new Error(`stale or missing stock price (age limit ${limit}s)`);
    return price;
  }

  // On-demand push (2026-10-02): the start needs the adapter oracle Live (rawFor floor, maxAge on chain). An old but
  // otherwise usable observation -> push demand for the RH oracle keeper and defer; a later tick (never this one: the
  // oracle keeper may hold the same signer lock) sees the landed observation and starts.
  async freshPrice(adapter, asset) {
    let oracle;
    try { oracle = (await adapter.config()).oracle; } catch { oracle = null; }
    if (!oracle) return { ok: true, maxAge: null, reason: 'adapter has no oracle (pre-r7)' };
    try {
      const r = await ensureFreshPrice({
        oracle: this.at(oracle, ArcOracleAbi), asset, nowSec: this.now(), statusDir: this.cfg.round?.demandDir ?? this.cfg.statusDir,
        requester: 'round', execute: this.tx.execute, marginSec: this.p.priceMarginSec, refreshSec: this.p.demandRefreshSec, reason: 'reward round start',
      });
      return { ok: r.ok, maxAge: r.check.maxAge, demand: r.demand, demandable: r.check.demandable, reason: r.check.reason, age: r.check.age };
    } catch (error) {
      return { ok: false, maxAge: null, demandable: false, reason: `oracle read failed: ${String(error?.shortMessage ?? error?.message).slice(0, 80)}` };
    }
  }

  async groupsWithIds() {
    const last = Number(await this.manager.nextEntryId());
    const upto = Number(await this.batcher.nextToEnqueue()) - 1;
    const groups = new Map();
    for (let id = 1; id <= Math.min(last, upto); id++) {
      let rec = this.journal.record('entries', String(id));
      if (!rec?.group) rec = this.journal.setRecord('entries', String(id), { group: await this.manager.groupKey(id) });
      if (!groups.has(rec.group)) groups.set(rec.group, []);
      groups.get(rec.group).push(id);
    }
    return groups;
  }

  // Single-order limit: the configured ceiling, never above the live RoundManager.runLimit()
  // (CapacityController.lRun, which governance may lower at once or raise after 48h).
  async runLimit() {
    let live = null;
    try { live = BigInt(await this.manager.runLimit()); } catch { live = null; } // pre-2026-09-30 deployments
    const cap = this.p.maxRoundBudget18;
    return live != null && live < cap ? live : cap;
  }

  async batchPhase(activeRounds) {
    const groups = await this.groupsWithIds();
    for (const [group, ids] of groups) {
      const cursor = Number(await this.batcher.cursor(group));
      const skippable = new Map();
      let queued = 0n; // what previewBatch can take: non-pending available in its 64-entry window
      let head = null; // first id previewBatch would take (its minimumBudget is the round's minimum)
      for (const id of ids.slice(cursor, cursor + 64)) {
        const [a, p] = await Promise.all([this.manager.available(id), this.manager.pending(id)]);
        skippable.set(id, a === 0n || p > 0n);
        if (p === 0n) queued += a;
        if (head == null && p === 0n && a > 0n) head = id;
      }
      const n = shouldAdvance({ groupIds: ids, cursor, isSkippable: id => skippable.get(id), threshold: this.p.advanceThreshold });
      if (n) {
        const res = await this.tx.call(taskKey({ chainId: this.chainId, contract: this.batcher.target, op: `advance:${group}:${cursor}` }), this.batcher, 'advance', [group, n]);
        this.note('advance', { group, from: cursor, n, status: res.status });
      }
      const runLimit = await this.runLimit();
      // F2: the hub only takes whole 6-dp USDC; plan with maxBudget floored to that grid (dust stays queued).
      // A queue above L_run is cut into near-equal rounds (roundCap) so no tail is left below the minimum.
      const headMinimum = head == null ? 0n : await this.manager.minimumBudget(head);
      let maxBudget = roundCap({ queued, runLimit, minimum: headMinimum });
      let preview = await this.batcher.previewBatch(group, maxBudget);
      if (preview.total % USDC_GRID !== 0n) {
        maxBudget = alignBudget18(preview.total);
        if (maxBudget === 0n) {
          this.summary.deferred.push({ group, reason: 'Dust', total: preview.total });
          continue;
        }
        preview = await this.batcher.previewBatch(group, maxBudget);
        if (preview.total % USDC_GRID !== 0n) {
          this.summary.deferred.push({ group, reason: 'Unaligned', total: preview.total });
          continue;
        }
      }
      const pIds = [...preview.ids].map(Number);
      const minimum = pIds.length ? await this.manager.minimumBudget(pIds[0]) : 0n;
      const plan = planBatch({ ids: pIds, budgets: [...preview.budgets], total: preview.total, minimum, activeRounds, maxActiveRounds: this.p.maxActiveRounds, runLimit });
      if (plan.action !== 'execute') {
        this.summary.deferred.push({ group, reason: plan.reason, total: preview.total, minimum });
        continue;
      }
      const started = await this.startBatch(group, plan, maxBudget);
      if (started) activeRounds++;
    }
  }

  async buildOrder(ids, amounts) {
    const entries = [];
    for (const id of ids) entries.push(await this.manager.entry(id));
    const hash = entriesHash(entries, amounts);
    const sourceNonce = await this.manager.executionNonce(hash);
    const route = await this.registry.resolve(entries[0].assetId, entries[0].adapterVersion);
    return { entries, hash, sourceNonce, route };
  }

  // M1: never start a stock purchase on a closed market or a frozen feed (the adapter's oracle, as the floor uses).
  async marketCheck(adapter, asset) {
    if (this.p.market === false) return { ok: true };
    let oracle;
    try { oracle = (await adapter.config()).oracle; } catch { oracle = null; }
    if (!oracle) return { ok: true, reason: 'adapter has no oracle (pre-r7)' };
    try {
      const [o] = await this.at(oracle, StockOracleAbi).latest(asset);
      return marketGate({ nowSec: this.now(), sourceUpdatedAt: Number(o.sourceUpdatedAt), params: this.p.market });
    } catch (error) {
      return { ok: false, closed: false, alert: true, reason: `oracle.latest failed: ${String(error?.shortMessage ?? error?.message).slice(0, 80)}` };
    }
  }

  // F4: hub buy fee (live buyFeeBps, fallback param) + Relay fee (lane quote) + LZ order fee (hub.quoteOrder).
  async planCosts(budget18, adapter) {
    const config = await adapter.config();
    const hub = this.at(config.hub, StockHubFeeAbi);
    let hubFeeBps = this.p.hubFeeBps;
    try { hubFeeBps = BigInt((await hub.fees())[0]); } catch { /* older hub: configured fallback */ }
    const relay = await planFundingFees({ budget18, quoteMinOut6: a => this.lane.quoteMinOut6(a), maxFeeBps: this.p.maxFeeBps });
    if (relay.defer) return { defer: relay.defer, fees18: relay.fees18 };
    const lzFee18 = BigInt(await hub.quoteOrder(config.underlying));
    const costs = planRoundCosts({ budget18, relayFee18: relay.fees18, lzFee18, hubFeeBps, lzBufferBps: this.p.lzBufferBps, extraFixedCost18: this.p.extraFixedCost18, costBasis: this.p.costBasis });
    return { ...costs, hubFeeBps };
  }

  // minRaw: slippage below the signed policy price, clamped to the adapter's oracle floor (F3).
  async planMinRaw(adapter, asset, total, price) {
    const decimals = Number(await this.at(asset, Erc20Abi).decimals());
    let floorRaw = null;
    try {
      const { oracle } = await adapter.config();
      if (oracle) floorRaw = BigInt(await this.at(oracle, StockOracleAbi).rawFor(asset, total));
    } catch { floorRaw = null; } // not Live: the start would revert anyway; the price check already passed
    return minRawOut({ budget18: total, priceUSD18: price, decimals, slippageBps: this.p.slippageBps, floorRaw });
  }

  async startBatch(group, plan, maxBudget) {
    const now = this.now();
    const { hash, sourceNonce, route } = await this.buildOrder(plan.ids, plan.budgets);
    const adapter = this.at(route.adapter, StockAdapterAbi);
    // Order (2026-10-02): calendar -> price freshness (push demand) -> frozen feed. The Arc copy of the Chainlink time
    // only moves when a push lands, so with no heartbeat an old copy first asks for a push; the gate is applied to
    // the landed observation (the RH oracle keeper never pushes a frozen feed).
    const gate = await this.marketCheck(adapter, route.asset);
    const holdMarket = async g => {
      this.summary.deferred.push({ group, reason: 'MarketClosed', detail: g.reason });
      if (g.alert) await this.alert(`round-market-${route.asset}`, `reward rounds for ${route.asset} held: ${g.reason}`);
      return false;
    };
    if (!gate.ok && gate.closed !== false) return holdMarket(gate);
    const fresh = await this.freshPrice(adapter, route.asset);
    if (!fresh.ok) {
      if (!fresh.demandable && !gate.ok) return holdMarket(gate); // frozen feed / failed read: a push cannot help
      this.summary.deferred.push({ group, reason: fresh.demandable ? 'AwaitingPrice' : 'NoPrice', detail: fresh.reason, demand: fresh.demand ?? null });
      return false;
    }
    if (!gate.ok) return holdMarket(gate);
    // Reuse an unexpired plan for the same slices so previously deposited Ops fees are not stranded.
    const planKey = `${hash}:${sourceNonce}`;
    let saved = this.journal.record('plans', planKey);
    if (saved && (Number(saved.deadline) - 60 <= now || saved.expired)) {
      await this.flagStrandedFees(saved, route.adapter);
      saved = null;
    }
    let order = saved;
    if (!order) {
      let price;
      try { price = await this.priceFor(route.asset, fresh.maxAge); } catch (error) {
        this.summary.deferred.push({ group, reason: 'NoPrice', error: error.message });
        return false;
      }
      const minRaw = await this.planMinRaw(adapter, route.asset, plan.total, price);
      let costs;
      try {
        costs = await this.planCosts(plan.total, adapter);
      } catch (error) {
        this.summary.deferred.push({ group, reason: 'FundingQuote', error: error.message });
        // A Relay refusal (e.g. currency/decimals mismatch) repeats every tick: never let the round stall silently.
        const fails = (this.journal.record('fundingQuote', group)?.failures ?? 0) + 1;
        this.journal.setRecord('fundingQuote', group, { failures: fails, lastError: error.message, lastErrorAt: now });
        if (fails >= this.p.fundingQuoteAlertAfter) {
          await this.alert(`round-funding-quote-${group}`, `reward round funding quote failed ${fails} times in a row for group ${group.slice(0, 10)}: ${String(error.message).slice(0, 200)}`);
        }
        return false;
      }
      if (this.journal.record('fundingQuote', group)?.failures) this.journal.setRecord('fundingQuote', group, { failures: 0 });
      if (costs.defer) {
        this.summary.deferred.push({ group, reason: costs.defer, fees18: costs.fees18 });
        return false;
      }
      const check = checkAdapterQuote({ budget18: plan.total, fixedCost18: costs.fixedCost18, runLimit: maxBudget });
      if (!check.ok) {
        this.summary.deferred.push({ group, reason: check.reason, fixedCost18: costs.fixedCost18 });
        return false;
      }
      const deadline = now + this.p.quoteTtlSec;
      const orderId = orderIdFor({ chainId: this.chainId, manager: this.manager.target, entriesHash: hash, minRaw, deadline, sourceNonce });
      order = { planKey, orderId, ids: plan.ids, amounts: plan.budgets, total: plan.total, minRaw, deadline, fees18: costs.fees18, fixedCost18: costs.fixedCost18, hubFee18: costs.hubFee18, lzFee18: costs.lzFee18, nonce: newNonce(), adapter: route.adapter, group };
      if (this.tx.execute) this.journal.setRecord('plans', planKey, order);
    }
    if (this.tx.execute) this.journal.setRecord('orders', order.orderId, { fees18: order.fees18, planKey });

    const have = await adapter.feeBalance(order.orderId);
    if (have < BigInt(order.fees18)) {
      const res = await this.tx.call(taskKey({ chainId: this.chainId, contract: adapter.target, op: `depositFees:${order.orderId}:${order.fees18}` }), adapter, 'depositFees', [order.orderId], { value: BigInt(order.fees18) - have, label: `deposit ops fees ${order.orderId.slice(0, 10)}` });
      this.note('depositFees', { orderId: order.orderId, fees18: order.fees18, status: res.status });
      if (res.status !== 'confirmed' && res.status !== 'dry-run') return false;
    }
    const quoteData = await this.signStockQuote(adapter, order);
    if (!quoteData) {
      // Dry-run / no quote signer. Since 03d87c2 the FIFO reservation is internal and only
      // reachable through the atomic executeAndStart, so it cannot be simulated without a
      // signed quote; the preview above (previewBatch + minimumBudget) is the admission check.
      this.note('executeAndStart', { orderId: order.orderId, total: order.total, status: 'no-quote-signer' });
      return false;
    }
    const res = await this.tx.call(this.key(`start:${order.orderId}:${order.fees18}`), this.batcher, 'executeAndStart', [order.ids, maxBudget, order.minRaw, order.deadline, quoteData], { label: `executeAndStart ${order.ids.length} entries $${order.total / 10n ** 18n}` });
    this.note('executeAndStart', { orderId: order.orderId, entries: order.ids, total: order.total, fees18: order.fees18, fixedCost18: order.fixedCost18, status: res.status });
    if (res.status === 'simulation-failed') {
      await this.onStartRejected(group, order, res.error);
      return false;
    }
    if (res.status === 'confirmed') {
      const roundId = this.roundIdFromReceipt(res.receipt);
      this.journal.setRecord('rounds', String(roundId), { orderId: order.orderId, group, startedAt: this.now() });
      this.journal.setRecord('plans', planKey, { consumedBy: roundId });
      return true;
    }
    return false;
  }

  // F3: a start the chain refuses is never silently backed off: decode, alert, and adapt where the revert says how.
  async onStartRejected(group, order, error) {
    const r = decodeRevert(error);
    let action = 'retry after backoff';
    if (r.name === 'InsufficientValue' && this.tx.execute) {
      // HubSettlement.beginReward: value - budget < hub fee. Top the Ops fees up by the shortfall (+1 micro-USDC).
      const [got, need] = r.args.map(BigInt);
      const fees18 = BigInt(order.fees18) + (need > got ? need - got : 0n) + USDC_GRID;
      this.journal.setRecord('plans', order.planKey, { fees18 });
      action = `fees raised to ${fees18}`;
    } else if ((r.name === 'InvalidQuote' || r.name === 'BadRewardOrder') && this.tx.execute) {
      this.journal.setRecord('plans', order.planKey, { expired: true }); // re-plan from fresh chain state next tick
      action = 're-plan next tick';
    }
    this.summary.deferred.push({ group, reason: 'SimulationFailed', revert: r.name ?? r.message, action });
    await this.alert(`round-start-${group}`, `executeAndStart for order ${order.orderId.slice(0, 10)} ($${order.total / 10n ** 18n}) rejected in simulation: ${r.name ?? r.message}; ${action}`);
  }

  roundIdFromReceipt(receipt) {
    for (const log of receipt.logs) {
      if (log.address.toLowerCase() !== this.manager.target.toLowerCase()) continue;
      try {
        const parsed = this.manager.interface.parseLog(log);
        if (parsed?.name === 'RoundState') return Number(parsed.args.roundId);
      } catch { /* other event */ }
    }
    throw new Error('RoundState event missing from executeAndStart receipt');
  }

  async signStockQuote(adapter, order) {
    if (!this.quoteSigner) {
      this.summary.seams.push('quote signer (QUOTE_SIGNER_KEY_PATH or phase-5 remote signer)');
      return null;
    }
    const config = await adapter.config();
    const q = { orderId: order.orderId, budget18: order.total, minRawOut: order.minRaw, deadline: order.deadline, nonce: order.nonce, fees18: order.fees18, fixedCost18: order.fixedCost18 };
    if (await adapter.nonceUsed(q.nonce)) throw new Error('quote nonce already used');
    const signature = await signChecked({
      local: stockQuoteDigest({ chainId: this.chainId, adapter: adapter.target, config, q }),
      onchain: () => adapter.quoteDigest(q),
      quoteSigner: this.quoteSigner,
      expectedSigner: config.signer,
    });
    return encodeStockQuoteData(q, signature);
  }

  async startReserved(id, round) {
    // Since 03d87c2 reserve+start is atomic (executeAndStart), so a live Reserved round should
    // not exist; kept for rounds reserved by an older batcher. Start it with our signed quote.
    const orderRec = this.journal.record('orders', round.orderId);
    const adapter = this.at(round.adapter, StockAdapterAbi);
    const fees18 = BigInt(orderRec?.fees18 ?? 0n);
    const planned = orderRec?.planKey ? this.journal.record('plans', orderRec.planKey) : null;
    const fixedCost18 = planned?.fixedCost18 != null ? BigInt(planned.fixedCost18) : fees18 + this.p.extraFixedCost18;
    const order = { orderId: round.orderId, total: round.budget18, minRaw: round.minRawOut, deadline: round.deadline, nonce: newNonce(), fees18, fixedCost18 };
    if ((await adapter.feeBalance(round.orderId)) < fees18) return;
    const quoteData = await this.signStockQuote(adapter, order);
    if (!quoteData) return;
    const res = await this.tx.call(this.key(`round:${id}:start`), this.manager, 'start', [id, quoteData], { label: `start reserved round ${id}` });
    this.note('start', { roundId: id, status: res.status });
  }

  async flagStrandedFees(plan, adapterAddress) {
    const adapter = this.at(adapterAddress, StockAdapterAbi);
    const [bal, order] = await Promise.all([adapter.feeBalance(plan.orderId), adapter.orders(plan.orderId)]);
    if (bal > 0n && Number(order.state) === 0 && !plan.consumedBy) {
      await this.alert(`stranded-${plan.orderId}`, `ops fees ${bal} wei stranded on adapter for expired order ${plan.orderId}; opsVault must call refundUnusedFees(orderId)`);
    }
    if (this.tx.execute) this.journal.setRecord('plans', plan.planKey, { expired: true });
  }
}

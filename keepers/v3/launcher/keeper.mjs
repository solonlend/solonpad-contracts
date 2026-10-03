// Launcher (r13, path 2a): the one process that funds queued stock buys on Arc. Public buys, reward-round buys and
// pool-A restock buys all wait in OrderScheduler; each tick launches the head(s):
//   nextLaunch -> Relay quote WITHOUT destination txs (user = hub, recipient = ReserveVault, Arc USDC -> RH USDG)
//   -> validate (lib/relay.mjs validateDepositQuote) -> route fee from the order's own reserve -> EIP-712 sign
//   requestId = protocol.v2.orderId (N2) -> OrderScheduler.launchNext(id, abi.encode(fee, quote))
//   -> verify the route's Sent + the depository's RelayErc20Deposit (depositor hub, token 0x3600, amount6, id = orderId).
// r14: Relay prices Arc native USDC as its 0x3600 ERC-20 view (6 dp) and fails native deposits with
// ORIGIN_CURRENCY_MISMATCH (live probe tx 0xb55e59e2…, 2026-10-01); the r14 route deposits through depositErc20 on the
// view, so the quote's payment currency must be the route's nativeToken and the deposit event is the ERC-20 one.
// Relay then pays USDG to the vault as a plain transfer (the RH float); the RH vault buys inside lzReceive from the
// float, so the Relay fill only refills it. Chain state is the truth every tick; the journal makes a launch
// idempotent (one key per order + orderId) and remembers the Relay request for the fill watch.
import { Contract, AbiCoder, Interface, getAddress, hexlify, randomBytes, zeroPadValue, toBeHex } from 'ethers';
import { StockHubAbi, SchedulerAbi, FundingRouteAbi, RelayDepositoryAbi, HubStatus, HubStatusName } from '../lib/abis.mjs';
import { buildDepositQuoteRequest, validateDepositQuote, planRouteFee, RelayRejected } from '../lib/relay.mjs';
import { taskKey } from '../lib/journal.mjs';

const coder = AbiCoder.defaultAbiCoder();
const SCALE = 10n ** 12n; // Arc native USDC (18 dp) -> USDG / 0x3600 (6 dp)
const depositIface = new Interface(RelayDepositoryAbi);
const routeIface = new Interface(FundingRouteAbi);
export const ref32 = id => zeroPadValue(toBeHex(BigInt(id)), 32);

export const LAUNCH_DEFAULTS = Object.freeze({
  maxPerTick: 6,
  quoteTtlSec: 300, // route signature validity; the Relay order itself lives longer
  lzFeeBufferBps: 1_000n, // keep 10% over the live LayerZero quote in the order's reserve for the auto-dispatch
  maxShortfallBps: 100n, // Relay expected output may undershoot the principal by <= 1% (the RH float absorbs it)
  shortfallAlertBps: 30n,
  fillAlertSec: 10 * 60, // Relay request not "success" this long after the deposit -> alert
  queueAlertSec: 20 * 60, // queue head waiting this long -> alert
  failAlertAfter: 3,
  originCurrency: '0x0000000000000000000000000000000000000000', // Arc native USDC
  paymentCurrency: '0x3600000000000000000000000000000000000000', // what Relay's order (and the r14 route) pays: the 6-dp view
});

export class Launcher {
  constructor({ cfg, provider, tx, journal, logger, alert, relayClient, quoteSigner, chainId, now = null }) {
    Object.assign(this, { cfg, provider, tx, journal, logger, alert, relayClient, quoteSigner, chainId });
    const c = cfg.contracts ?? {};
    for (const k of ['stockHub', 'scheduler']) if (!c[k]) throw new Error(`launcher: contracts.${k} required`);
    this.p = { ...LAUNCH_DEFAULTS, ...(cfg.launcher?.params ?? {}) };
    for (const k of ['lzFeeBufferBps', 'maxShortfallBps', 'shortfallAlertBps']) this.p[k] = BigInt(this.p[k]);
    this.hub = new Contract(c.stockHub, StockHubAbi, provider);
    this.scheduler = new Contract(c.scheduler, SchedulerAbi, provider);
    this.vault = getAddress(cfg.launcher?.reserveVault ?? c.reserveVault);
    this.rh = { chainId: cfg.launcher?.rhChainId ?? cfg.relay?.rhChainId ?? 4663, usdg: cfg.launcher?.rhUsdg ?? cfg.relay?.rhUsdg };
    this.clock = now;
    this.routes = new Map();
  }

  // Chain time of the latest block (refreshed each tick): quote deadlines and ages follow the chain, also on forks.
  now() { return this.clock ? this.clock() : this.nowSec ?? Math.floor(Date.now() / 1000); }
  async refreshClock() { if (!this.clock) this.nowSec = (await this.provider.getBlock('latest')).timestamp; }
  key(op) { return taskKey({ chainId: this.chainId, contract: this.scheduler.target, op }); }
  note(kind, detail) { this.summary?.actions.push({ kind, ...detail }); }

  makeRoute(address) { return new Contract(address, FundingRouteAbi, this.provider); }

  async route(address) {
    if (!this.routes.has(address)) {
      const r = this.makeRoute(address);
      const [signer, caller, destination, depository, nativeToken] = await Promise.all([r.signer(), r.caller(), r.destination(), r.depository(),
        r.nativeToken().catch(() => null)]);
      // A pre-r14 route (depositNative, no nativeToken) is refused: Relay fails those deposits (ORIGIN_CURRENCY_MISMATCH).
      if (!nativeToken || getAddress(nativeToken) !== getAddress(this.p.paymentCurrency)) throw new Error(`route ${address}: nativeToken ${nativeToken} is not ${this.p.paymentCurrency} (pre-r14 route?)`);
      if (getAddress(caller) !== getAddress(this.hub.target)) throw new Error(`route ${address}: caller ${caller} is not the hub`);
      if (getAddress(destination) !== this.vault) throw new Error(`route ${address}: destination ${destination} is not the vault`);
      if (this.quoteSigner && getAddress(signer) !== getAddress(this.quoteSigner.address)) throw new Error(`route ${address}: signer ${signer} != quote signer`);
      this.routes.set(address, { contract: r, depository: getAddress(depository), nativeToken: getAddress(nativeToken) });
    }
    return this.routes.get(address);
  }

  async tick() {
    await this.refreshClock();
    this.summary = { actions: [], deferred: [] };
    await this.tx.reconcileAll();
    for (let n = 0; n < this.p.maxPerTick; n++) {
      const [found, lane, id] = await this.scheduler.nextLaunch();
      if (!found) break;
      const out = await this.launchOne(id, Number(lane));
      if (out !== 'launched') break;
    }
    await this.watchQueue();
    await this.watchFills();
    return this.summary;
  }

  // Relay EXACT_INPUT quote for `amount18` of Arc USDC delivered to the vault as USDG; validated, never executed.
  async quote(amount18) {
    const body = buildDepositQuoteRequest({
      user: this.hub.target, recipient: this.vault, amount: amount18, originChainId: this.chainId, destinationChainId: this.rh.chainId,
      originCurrency: this.p.originCurrency, destinationCurrency: this.rh.usdg,
    });
    let raw;
    try { raw = await this.relayClient.quote(body); } catch (error) { error.sent = false; throw error; }
    return validateDepositQuote(raw, { ...body, amount: amount18, nativeScale: SCALE, paymentCurrency: this.p.paymentCurrency });
  }

  // Expected USDG (6 dp) for an exact input of `amount18` (round keeper fee planning shares this).
  async quoteMinOut6(amount18) { return (await this.quote(amount18)).expectedOut; }

  async plan(id, o) {
    // Both lanes later pay the LayerZero order from the same reserve (public: auto-dispatch at launch; reward:
    // submitFundedBuy), so the route fee only takes what is left above the live LZ quote + buffer.
    const lzFee = BigInt(await this.hub.quoteDispatch(id));
    const keep = lzFee + (lzFee * this.p.lzFeeBufferBps) / 10_000n;
    const budget = o.extra > keep ? o.extra - keep : 0n; // what the order's reserve can give the route
    const maxFee = (budget / SCALE) * SCALE;
    const need6 = o.amountIn / SCALE;
    const plan = await planRouteFee({ amountIn: o.amountIn, needOut: need6, quoteOut: a => this.quoteMinOut6(a), grid: SCALE, maxFee });
    const fee = plan.defer === 'CostLimit' ? maxFee : plan.defer ? null : plan.fee;
    if (fee == null) return { defer: plan.defer };
    if ((o.amountIn + fee) % SCALE !== 0n) return { defer: 'UnalignedDeposit' }; // the hub keeps principals whole 6-dp
    const q = await this.quote(o.amountIn + fee);
    const shortBps = q.expectedOut >= need6 ? 0n : ((need6 - q.expectedOut) * 10_000n) / need6;
    if (shortBps > this.p.maxShortfallBps) return { defer: `RelayShortfall ${shortBps} bps`, q };
    return { fee, q, lzFee, shortBps };
  }

  async sign(route, id, amountIn, fee, orderId) {
    if (!this.quoteSigner) throw Object.assign(new Error('launcher: no quote signer (QUOTE_SIGNER_KEY_PATH)'), { sent: false });
    const q = { requestId: orderId, deadline: BigInt(this.now() + this.p.quoteTtlSec), nonce: BigInt(hexlify(randomBytes(16))) };
    const digest = await route.quoteDigest(ref32(id), amountIn, fee, amountIn / SCALE, q);
    const sig = this.quoteSigner.signDigest(digest);
    return coder.encode(['tuple(bytes32 requestId,uint256 deadline,uint256 nonce)', 'bytes'], [[q.requestId, q.deadline, q.nonce], sig]);
  }

  async launchOne(id, lane) {
    const o = await this.hub.getOrder(id);
    const tag = `order ${id} (lane ${lane}, $${Number(o.amountIn / 10n ** 16n) / 100})`;
    if (Number(o.status) !== HubStatus.Pending) { this.note('skip', { id, status: HubStatusName[Number(o.status)] }); return 'skip'; }
    let plan;
    try { plan = await this.plan(id, { lane: Number(o.lane), amountIn: BigInt(o.amountIn), extra: BigInt(o.extra) }); } catch (error) {
      return this.failed(id, tag, error instanceof RelayRejected ? `quote rejected: ${error.reason}` : `quote: ${String(error?.message).slice(0, 160)}`);
    }
    if (plan.defer) return this.failed(id, tag, `deferred: ${plan.defer}`);
    const { contract: route, depository, nativeToken } = await this.route(getAddress(o.route));
    const quote = await this.sign(route, id, BigInt(o.amountIn), plan.fee, plan.q.orderId);
    const routeData = coder.encode(['uint256', 'bytes'], [plan.fee, quote]);
    // Durable intent before the send (crash -> same orderId; a launched order is never Pending again).
    this.journal.setRecord('launches', String(id), { orderId: plan.q.orderId, relayRequestId: plan.q.requestId, fee: plan.fee.toString(), amountIn: o.amountIn.toString(), expectedOut6: plan.q.expectedOut.toString(), shortBps: Number(plan.shortBps), quotedAt: this.now(), lane });
    const res = await this.tx.call(this.key(`launch:${id}:${plan.q.orderId}`), this.scheduler, 'launchNext', [id, routeData], { label: `launchNext ${tag}` });
    if (res.status === 'dry-run') { this.note('launch', { id, status: 'dry-run', fee: plan.fee, orderId: plan.q.orderId }); return 'dry-run'; }
    if (res.status !== 'confirmed') return this.failed(id, tag, `launchNext ${res.status}${res.error ? `: ${String(res.error?.shortMessage ?? res.error?.message).slice(0, 120)}` : ''}`);
    const proof = this.checkReceipt(res.receipt, id, route.target, depository, plan.q.orderId, BigInt(o.amountIn) + plan.fee, nativeToken);
    const after = await this.hub.getOrder(id);
    const st = HubStatusName[Number(after.status)];
    this.journal.setRecord('launches', String(id), { launchedAt: this.now(), tx: res.receipt.hash, status: st, deposit: proof.deposit, failures: 0 });
    this.note('launch', { id, lane, status: st, fee: plan.fee, orderId: plan.q.orderId, relayRequestId: plan.q.requestId, expectedOut6: plan.q.expectedOut, deposit: proof.deposit });
    if (!proof.ok) await this.alert(`launch-${id}-deposit`, `${tag} launched (${res.receipt.hash}) but the Relay deposit check failed: ${proof.why}`);
    if (plan.shortBps >= this.p.shortfallAlertBps) await this.alert(`launch-${id}-short`, `${tag}: Relay expected output ${plan.shortBps} bps under the principal (order reserve too small for the Relay fee); the RH float absorbs it`);
    if (st === 'Cancelled') await this.alert(`launch-${id}-refunded`, `${tag} was refunded at launch (Unfundable: route fee > reserve or asset cap)`);
    if (st === 'Funded' && Number(after.lane) === 0) await this.dispatchFunded(id, tag);
    return 'launched';
  }

  // The route's Sent(ref, requestId = orderId) and the depository's own RelayErc20Deposit(hub, 0x3600, total / 1e12, orderId).
  checkReceipt(receipt, id, route, depository, orderId, total, nativeToken = this.p.paymentCurrency) {
    const sent = receipt.logs.filter(l => getAddress(l.address) === getAddress(route)).map(l => { try { return routeIface.parseLog(l); } catch { return null; } }).find(e => e?.name === 'Sent');
    const dep = receipt.logs.filter(l => getAddress(l.address) === depository).map(l => { try { return depositIface.parseLog(l); } catch { return null; } }).find(e => e?.name === 'RelayErc20Deposit');
    if (!sent || sent.args.ref !== ref32(id) || sent.args.requestId !== orderId) return { ok: false, why: 'no matching route Sent', deposit: null };
    if (!dep) return { ok: false, why: 'no depository deposit event', deposit: null };
    const deposit = { event: dep.name, from: dep.args.from, token: dep.args.token, amount: dep.args.amount.toString(), id: dep.args.id };
    const ok = dep.args.id === orderId && getAddress(dep.args.from) === getAddress(this.hub.target) && getAddress(dep.args.token) === getAddress(nativeToken)
      && BigInt(dep.args.amount) === total / SCALE;
    return { ok, why: ok ? null : 'deposit id/depositor/token/amount mismatch', deposit };
  }

  // A public buy whose reserve could not also pay the LayerZero fee stays Funded: send it, the keeper pays the fee.
  async dispatchFunded(id, tag) {
    const fee = BigInt(await this.hub.quoteDispatch(id));
    const value = fee + fee / 10n;
    const res = await this.tx.call(taskKey({ chainId: this.chainId, contract: this.hub.target, op: `dispatch:${id}` }), this.hub, 'dispatch', [id], { value, label: `dispatch ${tag}` });
    this.note('dispatch', { id, status: res.status, value });
    await this.alert(`launch-${id}-dispatch`, `${tag}: reserve did not cover the LayerZero fee; keeper dispatched it (${res.status}, ${value} wei)`);
  }

  async failed(id, tag, why) {
    const rec = this.journal.record('launches', String(id)) ?? {};
    const failures = (rec.failures ?? 0) + 1;
    this.journal.setRecord('launches', String(id), { failures, lastError: why, lastErrorAt: this.now() });
    this.summary.deferred.push({ id, why, failures });
    this.logger.warn(`launch ${tag}: ${why} (${failures} in a row)`);
    if (failures >= this.p.failAlertAfter) await this.alert(`launch-${id}-fail`, `${tag} not launched after ${failures} tries: ${why} — the queue behind it waits`);
    return 'failed';
  }

  async watchQueue() {
    for (const lane of [0, 1]) {
      const [, waiting] = await this.scheduler.queueLength(lane);
      if (waiting === 0n) continue;
      const [found, , id] = await this.scheduler.nextLaunch();
      if (found) continue; // launchable: this tick or the next takes it
      this.summary.deferred.push({ lane, waiting: Number(waiting), why: 'head not launchable (capacity/asset cap)' });
    }
    const [found, lane, id] = await this.scheduler.nextLaunch();
    if (!found) return;
    const o = await this.hub.getOrder(id);
    const age = this.now() - Number(o.createdAt);
    if (age > this.p.queueAlertSec) await this.alert(`queue-${id}`, `order ${id} (lane ${lane}) waiting ${Math.round(age / 60)} min at the scheduler head`);
  }

  // Relay request status for every launched order until "success" (fill on RH); alerts on failure/refund/slowness.
  async watchFills() {
    for (const [id, rec] of this.journal.entries('launches')) {
      if (!rec.launchedAt || rec.fill === 'success' || rec.fill === 'abandoned' || !rec.relayRequestId) continue;
      let status = null;
      try { status = (await this.relayClient.status(rec.relayRequestId))?.status ?? null; } catch (error) { status = `error: ${String(error?.message).slice(0, 80)}`; }
      if (status === 'success') { this.journal.setRecord('launches', id, { fill: 'success', filledSeenAt: this.now() }); this.note('fill', { id, status }); continue; }
      const age = this.now() - rec.launchedAt;
      if (status === 'failure' || status === 'refund' || status === 'refunded') {
        this.journal.setRecord('launches', id, { fill: status });
        await this.alert(`fill-${id}`, `order ${id}: Relay request ${rec.relayRequestId} ${status} (orderId ${rec.orderId}); the RH float already bought — principal is ${status === 'failure' ? 'stuck with Relay' : 'refunded to the hub (Arc float)'}; rebalance per runbook`);
      } else if (age > this.p.fillAlertSec) {
        await this.alert(`fill-${id}`, `order ${id}: Relay request ${rec.relayRequestId} still "${status}" ${Math.round(age / 60)} min after the deposit (orderId ${rec.orderId})`);
      }
    }
  }
}

// Round-keeper funding lane on top of the launcher (replaces the phase-5 seam): the reward order already waits in
// the scheduler; "dispatch" = let the launcher launch the heads, then report whether this order left.
export class Queued extends Error {
  constructor(what) { super(`queued: ${what}`); this.sent = false; this.quiet = true; }
}

export class SchedulerFundingLane {
  constructor({ launcher, hub }) { Object.assign(this, { launcher, hub }); this.name = 'scheduler'; }

  quoteMinOut6(amount18) { return this.launcher.quoteMinOut6(amount18); }

  async findOrder(orderId) {
    const open = await this.hub.openOrders();
    for (const id of [...open].reverse()) {
      const o = await this.hub.getOrder(id);
      if (o.capKey === orderId) return { id, o };
    }
    return null;
  }

  async dispatch({ orderId }) {
    let found = await this.findOrder(orderId);
    if (!found) throw new Queued(`reward order ${orderId} not open on the hub`);
    if (Number(found.o.status) === HubStatus.Pending) {
      await this.launcher.tick();
      found = await this.findOrder(orderId);
    }
    if (!found || Number(found.o.status) === HubStatus.Pending) throw new Queued(`reward order ${orderId} waits in the scheduler`);
    const rec = this.launcher.journal.record('launches', String(found.id)) ?? {};
    return { lane: this.name, requestId: rec.relayRequestId ?? rec.orderId ?? null, txHash: rec.tx ?? null };
  }
}

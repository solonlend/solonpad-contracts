// Refund keeper (r13, path 2a) — ArcStocks A01 "reserve stays whole", without a contract change.
// In 2a the Relay fill is a plain transfer, so the hub never gets `receiveReturn` for an order:
//   - a buy the vault answered Failed sits in Returning (its principal is now RH float, not a liability there);
//   - a sell the hub float could not pay at once (daily allowance / float short) sits in Proceeds.
// Both close only when money is credited for that ref through the order's route. The route's return executor is the
// Relay router, whose multicall is permissionless (N3): the keeper (= the hub's float recipient B) takes exactly the
// missing amount out of the hub float (withdrawFloat, fixed recipient) and credits it straight back for the ref
// (router.multicall -> route.receiveReturnFor{value}(ref)) -> the hub pays the user (buy: principal + fee + reserve;
// sell: proceeds less the locked fee). Net: the Arc float stands in for money that is in the RH float — rebalanced
// daily by Ops (float watch). A Proceeds sell is credited only after its RH proceeds were returned (vault liability
// 0), so the hub float is refilled by the same amount. Two transactions; the journal makes each step happen once.
// The 30-minute A01 cancel of a dispatched, unanswered buy is the contract's own float refund (requestCancel).
import { Contract, Interface, getAddress } from 'ethers';
import { StockHubAbi, FundingRouteAbi, RelayRouterAbi, ReserveVaultAbi, HubStatus, HubStatusName } from '../lib/abis.mjs';
import { taskKey, TaskState } from '../lib/journal.mjs';
import { ref32 } from '../launcher/keeper.mjs';

const routeIface = new Interface(FundingRouteAbi);
const half = (got, due) => got * 2n >= due && got !== 0n; // HubSettlement.isBack

export const REFUND_DEFAULTS = Object.freeze({
  maxPerTick: 4,
  dailyCap18: 2_000n * 10n ** 18n, // never move more than the launch float per 24h without a human
  lzStuckSec: 30 * 60,
  proceedsGraceSec: 15 * 60, // a Proceeds sell whose RH proceeds are still there after this -> alert
  refundOverdueSec: 30 * 60, // runbook §7.6: any Returning / Proceeds order still open after this -> alert, whatever the cause
});

// Pure: what one open order needs from the refund keeper.
export function refundNeed(o, { rhProceeds = null } = {}) {
  const st = Number(o.status);
  const held = BigInt(o.held);
  if (Number(o.kind) === 0 && st === HubStatus.Returning && Number(o.outcome) === 3) {
    const due = BigInt(o.amountIn);
    if (half(held, due)) return null; // already closing on its own
    return { kind: 'failed-buy', credit: due - held };
  }
  if (Number(o.kind) === 1 && st === HubStatus.Proceeds) {
    const gross = BigInt(o.amountOut) + BigInt(o.fee); // settle stored net in amountOut and the fee in fee
    if (half(held, BigInt(o.amountOut))) return null;
    if (rhProceeds !== 0n) return { kind: 'proceeds', wait: 'RH proceeds not returned yet' };
    return { kind: 'proceeds', credit: gross - held };
  }
  return null;
}

export class RefundKeeper {
  constructor({ cfg, provider, rhProvider = null, tx, journal, logger, alert, wallet, payer = null, chainId, now = null }) {
    Object.assign(this, { cfg, provider, tx, journal, logger, alert, chainId });
    const c = cfg.contracts ?? {};
    if (!c.stockHub) throw new Error('refund keeper: contracts.stockHub required');
    this.p = { ...REFUND_DEFAULTS, ...(cfg.refund?.params ?? {}) };
    this.p.dailyCap18 = BigInt(this.p.dailyCap18);
    this.hub = new Contract(c.stockHub, StockHubAbi, provider);
    this.router = new Contract(cfg.refund?.relayRouter ?? cfg.relay?.relayRouter, RelayRouterAbi, provider);
    this.vault = rhProvider && c.reserveVault ? new Contract(c.reserveVault, ReserveVaultAbi, rhProvider) : null;
    // Split wallets (mainnet): `wallet` = hub keeper (withdrawFloat is keeper/owner only), `payer` = the refund-only
    // wallet HUB_FLOAT_B that receives the float and signs the Relay credit-back. Without a payer one wallet does both.
    this.withdrawer = wallet?.address ? getAddress(wallet.address) : null;
    this.payTx = payer?.tx ?? tx;
    const selfAddr = payer?.wallet?.address ?? wallet?.address ?? cfg.refund?.address;
    this.self = selfAddr ? getAddress(selfAddr) : null;
    this.clock = now;
  }

  // Chain time of the latest block (refreshed each tick): quote deadlines and ages follow the chain, also on forks.
  now() { return this.clock ? this.clock() : this.nowSec ?? Math.floor(Date.now() / 1000); }
  async refreshClock() { if (!this.clock) this.nowSec = (await this.provider.getBlock('latest')).timestamp; }
  key(op) { return taskKey({ chainId: this.chainId, contract: this.hub.target, op }); }
  note(kind, detail) { this.summary.actions.push({ kind, ...detail }); }

  async tick() {
    await this.refreshClock();
    this.summary = { actions: [], deferred: [] };
    this.closedNow = new Set();
    await this.tx.reconcileAll();
    if (this.payTx !== this.tx) await this.payTx.reconcileAll();
    if (!this.self) throw new Error('refund keeper: no signer address (KEEPER_KEY_PATH) and no refund.address');
    const [a, b] = await Promise.all([this.hub.floatRecipientA(), this.hub.floatRecipientB()]);
    if (![a, b].map(getAddress).includes(this.self)) throw new Error(`refund keeper ${this.self} is not a hub float recipient (${a}, ${b})`);
    if (this.payTx !== this.tx) {
      const k = getAddress(await this.hub.keeper());
      if (k !== this.withdrawer) throw new Error(`refund keeper: withdraw signer ${this.withdrawer} is not the hub keeper (${k})`);
    }
    await this.finishPending();
    let n = 0, failed = null;
    for (const id of await this.hub.openOrders()) {
      const o = await this.hub.getOrder(id);
      await this.watchStuck(id, o);
      // One order's refund throwing must not hide the others' overdue alerts: finish the scan, then fail the tick.
      try {
        if (n < this.p.maxPerTick && await this.handle(id, o)) n++;
      } catch (error) { failed ??= error; }
      await this.watchOverdue(id, o);
    }
    if (failed) throw failed;
    return this.summary;
  }

  // One open order; true when a refund was attempted (counts against maxPerTick).
  async handle(id, o) {
    const rhProceeds = Number(o.kind) === 1 && Number(o.status) === HubStatus.Proceeds && this.vault ? BigInt(await this.vault.proceeds(ref32(id))) : null;
    const need = refundNeed(o, { rhProceeds: this.vault ? rhProceeds : 0n });
    if (!need) return false;
    if (need.wait) {
      this.summary.deferred.push({ id: Number(id), why: need.wait });
      const age = this.now() - Number(o.settledAt);
      if (age > this.p.proceedsGraceSec) await this.alert(`proceeds-${id}`, `sell ${id} in Proceeds ${Math.round(age / 60)} min: RH proceeds not returned yet (vault worker / Relay)`);
      return false;
    }
    await this.credit(id, o, need);
    return true;
  }

  // Runbook §7.6: a refund request (failed buy in Returning, unpaid sell in Proceeds) open longer than refundOverdueSec
  // is an alert on its own — not only when a float / cap / Relay alert happened to fire first. settledAt is when the
  // order entered that state (HubSettlement sets it with the status). Orders this tick just closed are skipped.
  async watchOverdue(id, o) {
    const st = Number(o.status);
    if (st !== HubStatus.Returning && st !== HubStatus.Proceeds) return;
    if (this.closedNow?.has(Number(id))) return;
    const age = this.now() - Number(o.settledAt);
    if (age <= this.p.refundOverdueSec) return;
    const what = st === HubStatus.Returning ? 'failed buy (Returning)' : 'unpaid sell (Proceeds)';
    const usd = Number(BigInt(st === HubStatus.Returning ? o.amountIn : o.amountOut) / 10n ** 16n) / 100;
    (this.summary.overdue ??= []).push({ id: Number(id), status: HubStatusName[st], ageMin: Math.round(age / 60) });
    await this.alert(`refund-overdue-${id}`, `order ${id} ${what} ${usd} USDC not refunded after ${Math.round(age / 60)} min (limit ${Math.round(this.p.refundOverdueSec / 60)}): check refund keeper / hub float / daily cap; manual rescue per runbook §7.6`);
  }

  usedToday() {
    const day = Math.floor(this.now() / 86_400);
    const rec = this.journal.record('refundDay', String(day)) ?? {};
    return { day, used: BigInt(rec.used ?? 0) };
  }

  async credit(id, o, need) {
    const tag = `${need.kind} ${id} (${Number(need.credit / 10n ** 16n) / 100} USDC)`;
    const rec = this.journal.record('refunds', String(id)) ?? {};
    if (!rec.withdrawn) {
      const { day, used } = this.usedToday();
      const wkey = this.key(`refund:${id}:withdraw`);
      // A withdrawal already broadcast (Sent / Confirmed) has left the hub float and is not yet in the daily total:
      // re-checking cap and float here would strand it with the keeper, so go straight to its receipt.
      const prior = this.journal.task(wkey)?.state;
      const resuming = prior === TaskState.Sent || prior === TaskState.Confirmed;
      if (!resuming && used + need.credit > this.p.dailyCap18) {
        this.summary.deferred.push({ id: Number(id), why: 'daily cap' });
        await this.alert(`refund-cap-${day}`, `refund keeper daily cap reached (${Number(used / 10n ** 16n) / 100} USDC used); ${tag} waits for a human (runbook)`);
        return;
      }
      const avail = resuming ? need.credit : await this.hub.available();
      if (avail < need.credit) {
        this.summary.deferred.push({ id: Number(id), why: 'hub float short', avail, need: need.credit });
        await this.alert(`refund-float-${id}`, `${tag} cannot be refunded: hub float ${Number(avail / 10n ** 16n) / 100} USDC < need — rebalance RH -> Arc now (runbook)`);
        return;
      }
      const w = await this.tx.call(wkey, this.hub, 'withdrawFloat', [this.self, need.credit], { label: `withdrawFloat for ${tag}` });
      this.note('withdrawFloat', { id: Number(id), status: w.status, amount: need.credit });
      if (w.status !== 'confirmed') return;
      this.journal.setRecord('refunds', String(id), { withdrawn: need.credit.toString(), kind: need.kind, withdrawTx: w.receipt.hash, at: this.now() });
      this.journal.setRecord('refundDay', String(day), { used: (used + need.credit).toString() });
    }
    await this.creditBack(id, o.route, BigInt((this.journal.record('refunds', String(id)) ?? {}).withdrawn), tag);
  }

  async creditBack(id, routeAddr, amount, tag) {
    const route = this.routeAt(routeAddr);
    const exec = getAddress(await route.returnExecutor());
    if (exec !== getAddress(this.router.target)) throw new Error(`route ${routeAddr} return executor ${exec} is not the configured Relay router`);
    const call = [route.target, false, amount, routeIface.encodeFunctionData('receiveReturnFor', [ref32(id)])];
    const data = this.router.interface.encodeFunctionData('multicall', [[call], this.self, this.self, '0x']);
    const res = await this.payTx.send({ key: this.key(`refund:${id}:credit`), to: this.router.target, data, value: amount, label: `router.multicall receiveReturnFor ${tag}` });
    this.note('creditReturn', { id: Number(id), status: res.status, amount });
    if (res.status !== 'confirmed') return;
    const after = await this.hub.getOrder(id);
    const st = HubStatusName[Number(after.status)];
    this.journal.setRecord('refunds', String(id), { creditTx: res.receipt.hash, done: true, statusAfter: st });
    this.note('closed', { id: Number(id), status: st, owed: after.owed });
    if (['Cancelled', 'Filled'].includes(st)) this.closedNow?.add(Number(id));
    if (!['Cancelled', 'Filled'].includes(st)) await this.alert(`refund-${id}-open`, `${tag}: credited ${amount} but the order is still ${st}`);
  }

  // A withdrawal whose credit never went out, for an order that no longer needs it (closed some other way): the money
  // goes back into the hub float, never stays with the keeper.
  async finishPending() {
    for (const [id, rec] of this.journal.entries('refunds')) {
      if (rec.done || rec.returned || !rec.withdrawn) continue;
      const o = await this.hub.getOrder(id);
      if (refundNeed(o, { rhProceeds: 0n })?.credit) continue; // still needed: credit() resumes it
      const res = await this.payTx.call(this.key(`refund:${id}:refill`), this.hub, 'fundFloat', [], { value: BigInt(rec.withdrawn), label: `fundFloat (unused refund ${id})` });
      this.note('refill', { id: Number(id), status: res.status });
      if (res.status === 'confirmed') this.journal.setRecord('refunds', id, { returned: true });
    }
  }

  routeAt(addr) { return new Contract(addr, FundingRouteAbi, this.provider); }

  async watchStuck(id, o) {
    const st = Number(o.status);
    if (st !== HubStatus.Dispatched) return;
    const age = this.now() - Number(o.dispatchedAt);
    if (age > this.p.lzStuckSec) await this.alert(`lz-${id}`, `order ${id} (${Number(o.kind) === 0 ? 'buy' : 'sell'}) dispatched ${Math.round(age / 60)} min ago without a vault result (LayerZero); a buyer may cancel now (A01 float refund)`);
  }
}

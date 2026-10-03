// Pool-A restock/range keeper (design §9.5/§12.8). One evaluation = fresh HTTP reads -> decideRestock -> at most one
// vault call. Event subscriptions (bin/restock-keeper.mjs: Arc pool-A Swap, oracle PriceAccepted, relayed price,
// NVDA.sol arriving at the vault) only trigger an evaluation; a periodic tick is the fallback.
// Quotes: the vault accepts a reference tick only through OracleRefTickSigner (ERC-1271): the "signature" is the
// ABI-encoded quote and its refTick must be within 10 ticks of execPrice's tick, so the keeper reads the signer's
// refTickOf right before sending and cannot choose the price.
import { AbiCoder, Interface } from 'ethers';
import { requestPush, clearRequest } from '../lib/price-demand.mjs';
import { decideRestock, minSharesFor, minUsdcFor, DEFAULTS } from './decide.mjs';

export const VaultAbi = [
  'function currentTick() view returns (int24)',
  'function liquidity() view returns (uint128)',
  'function tickLower() view returns (int24)',
  'function tickUpper() view returns (int24)',
  'function token() view returns (address)',
  'function underlying() view returns (address)',
  'function hub() view returns (address)',
  'function priceSigner() view returns (address)',
  'function poolKey() view returns (tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks))',
  'function nonceUsed(uint256) view returns (bool)',
  'function rebalanceRange(int24 lower,int24 upper,tuple(int24 refTick,uint24 maxDeviation,uint256 deadline,uint256 nonce) q,bytes sig)',
  'function pushPrice(tuple(int24 refTick,uint24 maxDeviation,uint256 deadline,uint256 nonce) q,bytes sig,uint256 maxIn)',
  'function restockMint(uint256 usdcIn,uint256 minShares,uint256 feeReserve,tuple(int24 refTick,uint24 maxDeviation,uint256 deadline,uint256 nonce) q,bytes sig)',
  'function restockRedeem(uint256 shares,uint256 minUsdc,uint256 lzFee,tuple(int24 refTick,uint24 maxDeviation,uint256 deadline,uint256 nonce) q,bytes sig)',
  'event Restock(bool mint,uint256 hubOrderId,uint256 amount,uint256 value)',
  'event RangeSet(int24 tickLower,int24 tickUpper,uint128 liquidity,int24 refTick)',
  'event PricePushed(int24 fromTick,int24 toTick,int24 refTick)',
];
export const OracleAbi = [
  'function latest(address) view returns (tuple(uint256 price18,uint256 multiplier,uint256 quoteUsd18,uint256 twapPrice18,uint64 sourceUpdatedAt,uint80 roundId,uint64 observedAt,uint64 sourceBlock) o, uint8 s)',
  'function quoteOf(address) view returns (tuple(uint128 price18,uint64 sourceUpdatedAt,uint64 updatedAt))',
  'function poke(address) returns (uint8)',
  'function assetOf(address) view returns (tuple(address token,address source,tuple(uint32 maxAge,uint16 maxMoveBps,uint16 confirmBps,uint16 maxDepegBps,uint32 maxSourceAge,uint16 maxTwapBps) params,bool paused))',
  'event PriceAccepted(address indexed underlying,uint256 price18,uint64 sourceUpdatedAt,bool confirmedJump)',
];
export const SignerAbi = ['function refTickOf(address) view returns (int24)'];
export const HubAbi = ['function getOrder(uint256) view returns (tuple(address user,address underlying,uint8 kind,uint8 status,uint64 createdAt,uint64 settledAt,uint256 amountIn,uint256 minOut,uint256 amountOut,uint256 fee,uint128 rawOut,bool lzSettled,bool orphaned,uint64 dispatchedAt,uint8 lane,uint16 feeBps,uint256 extra,uint256 held))'];
// HubSettlement.Status: Filled = 2, Cancelled = 3, Escalated = 4 are final for the keeper.
const FINAL = new Set([2, 3, 4]);
const vaultIface = new Interface(VaultAbi);
const coder = AbiCoder.defaultAbiCoder();
const QUOTE = 'tuple(int24 refTick,uint24 maxDeviation,uint256 deadline,uint256 nonce)';
export { DEMAND_FILE } from '../lib/price-demand.mjs';

/// On-chain reads for one evaluation (all HTTP, at trigger time).
export function chainReader({ provider, vault, oracle, signer, hub, token, manager }) {
  return {
    async vault() {
      const [tick, liquidity, lower, upper, usdc, stock, slot0] = await Promise.all([
        vault.currentTick(), vault.liquidity(), vault.tickLower(), vault.tickUpper(), provider.getBalance(vault.target),
        token.balanceOf(vault.target), manager ? manager.sqrtPriceX96() : Promise.resolve(1n),
      ]);
      return { initialized: slot0 !== 0n, poolTick: Number(tick), liquidity, tickLower: Number(lower), tickUpper: Number(upper), tickSpacing: 200, idleUsdc: usdc, idleStock: stock };
    },
    async oracle() {
      const [[o, s], maxAge] = await Promise.all([oracle.latest(token.target), oracle.assetOf(token.target).then(a => Number(a.params.maxAge)).catch(() => null)]);
      let refTick = null;
      if (Number(s) === 1) { try { refTick = Number(await signer.refTickOf(token.target)); } catch { /* not Live any more */ } }
      return { status: Number(s), refTick, price18: o.price18, sourceUpdatedAt: Number(o.sourceUpdatedAt), observedAt: Number(o.observedAt), maxAge };
    },
    async signerTick() { return Number(await signer.refTickOf(token.target)); },
    async order(id) { const o = await hub.getOrder(id); return { status: Number(o.status) }; },
  };
}

export class RestockKeeper {
  constructor({ reader, vault, tx, journal, logger, alert = null, execute = false, params = {}, statusDir, underlying = null, now = () => Math.floor(Date.now() / 1000), randomNonce = () => BigInt(Date.now()) * 1000n + BigInt(Math.floor(Math.random() * 1000)) }) {
    Object.assign(this, { reader, vault, tx, journal, logger, alert, execute, statusDir, underlying, now, randomNonce });
    this.p = { ...DEFAULTS, ...params };
    if (typeof this.p.feeReserve18 === 'string') this.p.feeReserve18 = BigInt(this.p.feeReserve18);
  }

  async refreshPending(now) {
    const pending = this.journal.record('restock', 'pending');
    if (!pending) return null;
    if (pending.id != null) {
      const o = await this.reader.order(pending.id);
      if (FINAL.has(o.status)) {
        this.journal.clearRecord('restock', 'pending');
        this.journal.event('restock-final', { id: pending.id, status: o.status });
        this.logger.info(`restock order ${pending.id} final (status ${o.status})`);
        return null;
      }
    }
    if (now - pending.at > this.p.pendingTimeoutSec) {
      await this.alert?.('restock-pending', `pool-A restock order ${pending.id} not final after ${Math.round((now - pending.at) / 3600)}h: cancelRestock/escalate`);
    }
    return pending;
  }

  async tick() {
    const now = this.now();
    const pending = await this.refreshPending(now);
    const [v, oracle] = await Promise.all([this.reader.vault(), this.reader.oracle()]);
    const last = this.journal.record('restock', 'last') ?? {};
    const state = { ...v, oracle, pending, now, lastActionAt: last.at ?? 0 };
    const decision = decideRestock(state, this.p);
    if (oracle.status === 1 && this.execute) await clearRequest({ statusDir: this.statusDir, requester: 'restock' }).catch(() => false);
    this.journal.event('restock-decision', { action: decision.action, reason: decision.reason, alert: Boolean(decision.alert) });
    // M1: a routine market close is announced once per closed episode (not every tick), then observed silently.
    const closedSince = this.journal.record('restock', 'marketClosed')?.since ?? null;
    if (decision.marketClosed && !closedSince) {
      if (this.execute) this.journal.setRecord('restock', 'marketClosed', { since: now });
      await this.alert?.('restock-market-closed', `pool A paused (observing): ${decision.reason}`);
    } else if (!decision.marketClosed && closedSince && this.execute) {
      this.journal.setRecord('restock', 'marketClosed', { since: null });
    }
    if (decision.action === 'hold' || decision.action === 'stop') {
      if (decision.alert) await this.alert?.(`restock-${decision.action}`, `pool A: ${decision.reason}`);
      return { decision };
    }
    if (decision.action === 'demandPush') return { decision, status: await this.writeDemand(now, decision.reason) };
    if (!this.execute) {
      // Dry-run still simulates the exact vault call (eth_call): quote, signer tolerance and minimums are checked.
      const sim = await this.send(decision, now);
      this.logger.info(`DRY-RUN restock would ${decision.action} (simulation: ${sim.status})`, decision);
      this.journal.event('restock-result', { action: decision.action, status: sim.status });
      return { decision, status: sim.status === 'dry-run' ? 'dry-run' : sim.status };
    }
    // Journal the intent first: a crash leaves a record to reconcile, never a blind retry.
    this.journal.setRecord('restock', 'last', { at: now, action: decision.action, status: 'started' });
    const out = await this.send(decision, now);
    const done = out.status === 'confirmed';
    this.journal.setRecord('restock', 'last', { status: done ? 'done' : out.status, tx: out.receipt?.hash ?? null });
    if (done && (decision.action === 'restockMint' || decision.action === 'restockRedeem')) {
      const id = restockOrderId(out.receipt);
      this.journal.setRecord('restock', 'pending', { id, mint: decision.action === 'restockMint', at: now });
    }
    if (!done && out.status !== 'dry-run') await this.alert?.(`restock-${decision.action}`, `pool A ${decision.action} ${out.status}`);
    return { decision, status: done ? 'done' : out.status, tx: out.receipt?.hash ?? null };
  }

  /// Fresh signer tick at send time; quote nonce random (the vault rejects reuse).
  async send(d, now) {
    const refTick = await this.reader.signerTick();
    const maxDeviation = d.action === 'rebalanceRange' ? this.p.rangeGapTicks : this.p.quoteDeviationTicks;
    const q = { refTick, maxDeviation, deadline: BigInt(now + 300), nonce: this.randomNonce() };
    const sig = coder.encode([QUOTE], [[q.refTick, q.maxDeviation, q.deadline, q.nonce]]);
    const key = `restock:${d.action}:${q.nonce}`;
    switch (d.action) {
      case 'rebalanceRange':
        return this.tx.call(key, this.vault, 'rebalanceRange', [d.lower, d.upper, q, sig], { label: `rebalanceRange ${d.lower}..${d.upper}` });
      case 'pushPrice':
        return this.tx.call(key, this.vault, 'pushPrice', [q, sig, d.maxIn], { label: `pushPrice ${d.side} ${d.maxIn}` });
      case 'restockMint': {
        const minShares = minSharesFor(d.usdcIn, refTick, maxDeviation);
        const fee = this.p.feeReserve18;
        // Not payable: the vault pays usdcIn + fee reserve from its own idle USDC.
        return this.tx.call(key, this.vault, 'restockMint', [d.usdcIn, minShares, fee, q, sig], { label: `restockMint ${d.usdcIn}` });
      }
      case 'restockRedeem': {
        const minUsdc = minUsdcFor(d.shares, refTick, maxDeviation);
        return this.tx.call(key, this.vault, 'restockRedeem', [d.shares, minUsdc, 0n, q, sig], { label: `restockRedeem ${d.shares}` });
      }
      default:
        throw new Error(`unknown action ${d.action}`);
    }
  }

  /// Ask the RH oracle keeper for a fresh push (shared status dir, lib/price-demand.mjs). The request is not re-stamped
  /// while it waits (demandRefreshSec), so a push still in flight is never asked for twice.
  async writeDemand(now, reason) {
    // Dry-run never asks for a push: the oracle keeper runs --execute, and a dry restock (mainnet launch: 24h dry run)
    // never fixes the pool, so its demand would repeat every time the pushed price ages out (~$0.30 each).
    if (!this.execute) {
      this.logger.info(`DRY-RUN restock would request an oracle push (${reason})`);
      return 'dry-run';
    }
    const status = await requestPush({ statusDir: this.statusDir, requester: 'restock', underlyings: [this.underlying], reason: `pool-A restock: ${reason}`, nowSec: now, refreshSec: this.p.demandRefreshSec });
    if (status === 'demand-written') this.logger.info(`oracle push requested (${reason})`);
    return status;
  }
}

export function restockOrderId(receipt) {
  for (const log of receipt?.logs ?? []) {
    try {
      const ev = vaultIface.parseLog(log);
      if (ev?.name === 'Restock') return Number(ev.args.hubOrderId);
    } catch { /* other contracts' logs */ }
  }
  return null;
}

// Pool A (protocol NVDA.sol / native USDC, plain v4, LP fee 1%, spacing 200) restock/range decisions, design §9.5/§12.8.
// Pure: the keeper reads chain state, this decides, the keeper builds the oracle-bound quote and sends.
//
// Ticks are pool-A ticks: currency0 = native USDC, currency1 = NVDA.sol, price = NVDA.sol per USDC = 1.0001^tick,
// so a LOWER pool tick than the oracle tick means NVDA.sol is DEARER in the pool than on Chainlink.
// StockPoolVault can only use IDLE inventory (whatever is not in its single position):
//   - pushPrice: swap idle NVDA.sol (pool dear) or idle USDC (pool cheap) toward the oracle, stopping exactly at it;
//   - restockMint / restockRedeem: real RH purchase / sale through the stock hub (asynchronous, minutes);
//   - rebalanceRange: move the whole position (re-adds ALL idle inventory) — only while the pool is within
//     RANGE_DEVIATION (50 ticks) of the oracle.
// r9 starting structure (owner decision 2026-10-01): $1,000 NVDA.sol + $1,000 USDC in the range, $1,000 USDC kept in
// the vault as IDLE reserve. The reserve lives in the vault because that is the only money the vault can use without
// a new custody path (pushPrice / restockMint spend idle inventory only). The range takes min(USDC, NVDA.sol) per
// side, so seeding mints just `poolStockUsd` of NVDA.sol and the unmatched USDC stays idle = the reserve. It pays for
// pushes when the pool is cheap and for restockMint when it is dear; recycling surplus idle NVDA.sol (restockRedeem)
// refills it. Below `reserveAlertBps` of `reserveUsd` the keeper alerts for a treasury top-up.
// Every on-chain action needs a Live oracle price (OracleRefTickSigner -> execPrice, observation <= 15 min); an
// observation that is merely old during market hours turns into an on-demand push request for the oracle keeper.

import { marketGate } from '../lib/market.mjs';

export const OracleStatus = Object.freeze({ None: 0, Live: 1, Stale: 2, Divergent: 3, Suspect: 4, Paused: 5 });
const STATUS_NAME = ['None', 'Live', 'Stale', 'Divergent', 'Suspect', 'Paused'];

export const DEFAULTS = Object.freeze({
  deviationBps: 130, // §9.5: 1% pool fee + 0.25% mint/redeem + bridge cost
  rangeHalfWidthBps: 200, // ±2% position
  recenterEdgeBps: 50,
  rangeGapTicks: 50, // StockPoolVault.RANGE_DEVIATION
  quoteDeviationTicks: 60, // tolerance carried by restock quotes (vault MAX_DEVIATION 200): ~0.6% vs oracle
  minTradeUsd: 50,
  maxTradeUsd: 1000, // per hub order / per push
  poolStockUsd: 1000, // r9: NVDA.sol side of the range (seeded by restockMint); the USDC side matches it
  reserveUsd: 1000, // r9: idle USDC kept outside the range for anchoring / restockMint
  reserveAlertBps: 5000, // alert when idle USDC < 50% of reserveUsd (treasury top-up)
  idleStockKeepUsd: 250, // idle NVDA.sol kept for quick pushes; the rest is redeemed
  feeReserve18: 2n * 10n ** 18n, // native USDC sent with restockMint for the route/LZ fees (unused part refunded)
  maxSourceAgeSec: 26 * 3600, // SolonStockOracle.maxSourceAge: older Chainlink update = market closed
  cooldownSec: 60,
  pendingTimeoutSec: 6 * 3600,
  demandRefreshSec: 600, // re-request a push that has not landed after 10 min (lib/price-demand.mjs)
  // Review M1: US market gate (lib/market.mjs params: mode, heartbeatSec, heartbeatMarginSec). `false` disables it
  // and is meant for unit tests / local anvil only.
  market: {},
});

const E18 = 10n ** 18n;
const LOG_B = Math.log(1.0001);

export const tickOfPrice18 = price18 => Math.floor(Math.log(1e18 / Number(price18)) / LOG_B);
/// Pool NVDA.sol price vs oracle, bps; positive = dearer in the pool.
export const devBps = (poolTick, refTick) => (Math.pow(1.0001, refTick - poolTick) - 1) * 1e4;
const usd = (raw, price18) => Number((raw * price18) / E18) / 1e18;
const dollars18 = d => BigInt(Math.floor(d)) * E18;

export function alignRange({ refTick, halfWidthBps, tickSpacing }) {
  const half = Math.log(1 + halfWidthBps / 1e4) / LOG_B;
  return {
    tickLower: Math.floor((refTick - half) / tickSpacing) * tickSpacing,
    tickUpper: Math.ceil((refTick + half) / tickSpacing) * tickSpacing,
  };
}

// The vault's floors (StockPoolVault.restockMint/restockRedeem), evaluated in float; the keeper's minimums are
// taken one tick better than the floor so float error can never put them under it, yet stay ~0.01% from it.
const SCALE = 1e18;
const toBig = x => BigInt(Math.floor(x));
export const sharesBound = (usdcIn, refTick, maxDev) =>
  toBig((Number(usdcIn) * Math.pow(1.0001, refTick - maxDev) * 9975) / 10000);
export const usdcBound = (shares, refTick, maxDev) =>
  toBig((Number(shares) / Math.pow(1.0001, refTick + maxDev) * 9975) / 10000);
export const minSharesFor = (usdcIn, refTick, maxDev) => sharesBound(usdcIn, refTick, maxDev - 1);
export const minUsdcFor = (shares, refTick, maxDev) => usdcBound(shares, refTick, maxDev - 1);
void SCALE;

// state: { now, initialized, poolTick, liquidity (bigint), tickLower, tickUpper, tickSpacing, idleUsdc, idleStock
//          (bigint 18 dp), oracle: { status, refTick|null, price18 (bigint, last observation), sourceUpdatedAt,
//          observedAt }, pending: { id, mint, at } | null, lastActionAt }
export function decideRestock(state, params = {}) {
  const p = { ...DEFAULTS, ...params };
  const o = state.oracle;
  if (!state.initialized) return { action: 'hold', reason: 'pool A not initialized (timelock initialize first)' };
  if (!(o?.price18 > 0n)) return { action: 'stop', reason: 'no oracle price', alert: true };

  // M1: while the US market is closed (or the feed is frozen) the oracle may still be Live on the last close for up
  // to 26h. Nothing is anchored, restocked or re-ranged then: observe the deviation only.
  // 2026-10-02 (no heartbeat): o.sourceUpdatedAt is the Arc copy of the Chainlink time and only moves when a push
  // lands, so an open-calendar "frozen feed" on a Stale (old) observation is first answered with a push request
  // below; the RH oracle keeper refuses to push a really frozen feed.
  // o.maxAge = SolonStockOracle.assetOf(token).params.maxAge (read on chain; unknown -> any Stale counts as old).
  const relayOld = o.status === OracleStatus.Stale && (o.maxAge == null || state.now - Number(o.observedAt ?? 0) > Number(o.maxAge));
  if (p.market !== false) {
    const g = marketGate({ nowSec: state.now, sourceUpdatedAt: o.sourceUpdatedAt, params: p.market });
    if (!g.ok && !(relayOld && !g.closed)) {
      const dev = devBps(state.poolTick, o.refTick ?? tickOfPrice18(o.price18));
      return { action: 'stop', reason: `${g.reason}: observe only (deviation ${dev.toFixed(0)} bps), no anchoring/restock/range change`, marketClosed: g.closed, alert: g.alert, deviationBps: dev };
    }
  }

  if (o.status !== OracleStatus.Live) {
    // With the market gate on, the calendar (above) decides "closed"; the legacy 26h rule stays for market:false.
    const closed = p.market === false && state.now - Number(o.sourceUpdatedAt) > p.maxSourceAgeSec;
    const frozen = p.market !== false && o.status === OracleStatus.Stale && !relayOld;
    if (o.status !== OracleStatus.Stale || closed || frozen) {
      const why = closed ? 'market closed (Chainlink update older than 26h)'
        : frozen ? 'oracle Stale on a recent observation (feed frozen or source read failed)' : `oracle ${STATUS_NAME[o.status] ?? o.status}`;
      // A closed market is routine; anything else is worth a human look.
      return { action: 'stop', reason: `${why}: no restock, no range change`, alert: !closed };
    }
    // Only the observation is old: would we act on the last price? Then ask the oracle keeper for a fresh push.
    const would = decideRestock({ ...state, oracle: { ...o, status: OracleStatus.Live, refTick: tickOfPrice18(o.price18), sourceUpdatedAt: state.now } }, p);
    if (['hold', 'stop'].includes(would.action)) return { action: 'hold', reason: `oracle observation old; ${would.reason}` };
    return { action: 'demandPush', reason: `oracle observation old; would ${would.action} (${would.reason})` };
  }

  const ref = o.refTick;
  if (state.lastActionAt && state.now - state.lastActionAt < p.cooldownSec) return { action: 'hold', reason: 'cooldown' };
  const pending = state.pending;
  const dev = devBps(state.poolTick, ref);
  const gap = Math.abs(state.poolTick - ref);
  const stockUsd = usd(state.idleStock, o.price18);
  const usdcUsd = Number(state.idleUsdc / 10n ** 12n) / 1e6;
  const pushStock = () => ({ action: 'pushPrice', side: 'stock', maxIn: capRaw(state.idleStock, o.price18, p.maxTradeUsd) });
  const pushUsdc = () => ({ action: 'pushPrice', side: 'usdc', maxIn: minBig(state.idleUsdc, dollars18(p.maxTradeUsd)) });

  // ---- empty position: seed the NVDA.sol part, move the empty pool to the oracle, set the first range
  if (state.liquidity === 0n) {
    const total = usdcUsd + stockUsd;
    const target = Math.min(p.poolStockUsd, Math.max(0, (total - p.reserveUsd) / 2));
    if (stockUsd < target - p.minTradeUsd) {
      if (pending) return { action: 'hold', reason: `seeding: restock order ${pending.id} pending` };
      const need = Math.min(Math.floor(target - stockUsd), p.maxTradeUsd, Math.floor(usdcUsd - Number(p.feeReserve18 / E18)));
      if (need < p.minTradeUsd) return { action: 'hold', reason: 'seeding: not enough idle USDC', alert: true };
      return { action: 'restockMint', usdcIn: dollars18(need), reason: `seeding NVDA.sol: $${stockUsd.toFixed(0)} of $${target.toFixed(0)}` };
    }
    if (gap > p.rangeGapTicks) {
      // No liquidity in the pool: the swap only moves the price; 1 wei is enough and nothing else is spent.
      const side = state.poolTick > ref ? 'usdc' : 'stock';
      const have = side === 'usdc' ? state.idleUsdc : state.idleStock;
      if (have === 0n) return { action: 'hold', reason: `empty pool ${gap} ticks off the oracle and no idle ${side}`, alert: true };
      return { action: 'pushPrice', side, maxIn: 1n, reason: `empty pool ${gap} ticks off the oracle` };
    }
    return { action: 'rebalanceRange', ...range(ref, state, p), reason: 'first range at the oracle price' };
  }

  // ---- anchoring (§9.5: > 1.3% off the oracle)
  if (Math.abs(dev) > p.deviationBps) {
    if (dev > 0) {
      if (stockUsd >= p.minTradeUsd) return { ...pushStock(), reason: `pool +${dev.toFixed(0)} bps: sell idle NVDA.sol` };
      if (pending) return { action: 'hold', reason: `pool +${dev.toFixed(0)} bps; restock order ${pending.id} pending` };
      const usdcIn = Math.min(p.maxTradeUsd, Math.floor(usdcUsd - Number(p.feeReserve18 / E18)));
      if (usdcIn >= p.minTradeUsd) return { action: 'restockMint', usdcIn: dollars18(usdcIn), reason: `pool +${dev.toFixed(0)} bps, no idle NVDA.sol: mint` };
      return { action: 'hold', reason: `pool +${dev.toFixed(0)} bps but no idle inventory (top up the vault)`, alert: true };
    }
    if (usdcUsd >= p.minTradeUsd) return { ...pushUsdc(), reason: `pool ${dev.toFixed(0)} bps: buy back with idle USDC` };
    return { action: 'hold', reason: `pool ${dev.toFixed(0)} bps but no idle USDC (top up the vault)`, alert: true };
  }

  // ---- inside the band: keep the range around the oracle, recycle surplus NVDA.sol into the USDC buffer
  const edge = Math.log(1 + p.recenterEdgeBps / 1e4) / LOG_B;
  if (ref <= state.tickLower + edge || ref >= state.tickUpper - edge) {
    if (gap > p.rangeGapTicks) {
      const side = state.poolTick > ref ? 'usdc' : 'stock';
      if ((side === 'usdc' ? usdcUsd : stockUsd) >= p.minTradeUsd || (side === 'usdc' ? state.idleUsdc : state.idleStock) > 0n) {
        return { ...(side === 'usdc' ? pushUsdc() : pushStock()), reason: `range edge; pool ${gap} ticks off the oracle: push before re-centring` };
      }
      return { action: 'hold', reason: 'range edge but the pool is off the oracle and there is no idle inventory', alert: true };
    }
    return { action: 'rebalanceRange', ...range(ref, state, p), reason: 'oracle price near the range edge' };
  }
  if (!pending && stockUsd - p.idleStockKeepUsd >= p.minTradeUsd) {
    const keepRaw = (dollars18(p.idleStockKeepUsd) * E18) / o.price18;
    const shares = minBig(state.idleStock - keepRaw, capRaw(state.idleStock, o.price18, p.maxTradeUsd));
    return { action: 'restockRedeem', shares, reason: `recycle idle NVDA.sol $${stockUsd.toFixed(0)} above $${p.idleStockKeepUsd}` };
  }
  const low = usdcUsd < (p.reserveUsd * p.reserveAlertBps) / 10_000;
  const why = `deviation ${dev.toFixed(1)} bps within band${pending ? `; restock order ${pending.id} pending` : ''}`;
  if (low) return { action: 'hold', reason: `${why}; USDC reserve low ($${usdcUsd.toFixed(0)} of $${p.reserveUsd}): top up the vault`, deviationBps: dev, alert: true };
  return { action: 'hold', reason: why, deviationBps: dev };
}

function range(ref, state, p) {
  const { tickLower, tickUpper } = alignRange({ refTick: ref, halfWidthBps: p.rangeHalfWidthBps, tickSpacing: state.tickSpacing });
  return { lower: tickLower, upper: tickUpper };
}
const minBig = (a, b) => (a < b ? a : b);
const capRaw = (raw, price18, maxUsd) => minBig(raw, (dollars18(maxUsd) * E18) / price18);

// Pure decision logic for the round keeper (no I/O). Mirrors RewardRoundManager /
// RewardBatcher / SolonStockAdapter rules at 03d87c2 so the keeper never sends a tx
// the contract would reject, and never takes a step the state machine forbids.
import { AbiCoder, Interface, keccak256 } from 'ethers';
import { ENTRY_TUPLE } from '../lib/abis.mjs';

const coder = AbiCoder.defaultAbiCoder();
export const E18 = 10n ** 18n;
export const DAY = 86_400;
export const ROUND_MIN_BASE = 100n * E18; // §5.1 r5 base minimum
export const ROUND_MAX = 10_000n * E18; // default L_run (CapacityController.lRun; read live via RoundManager.runLimit)
export const MAX_BATCH_ENTRIES = 64;
export const CANCEL_MIN_AGE = 30 * 60; // RoundManager.requestCancel

export const Status = Object.freeze({
  None: 0, Reserved: 1, Funding: 2, Funded: 3, Submitted: 4, Settled: 5, Quarantined: 6, Refunded: 7, CancelledUnsent: 8,
});
export const StatusName = Object.fromEntries(Object.entries(Status).map(([k, v]) => [v, k]));
export const TERMINAL = new Set([Status.Settled, Status.CancelledUnsent]);
export const ACTIVE = new Set([Status.Reserved, Status.Funding, Status.Funded, Status.Submitted, Status.Quarantined]);
// Since 03d87c2 finalize() with an empty/unverified result (outcome 0) is a no-op, so the
// contract never enters Quarantined any more. The status is still decoded (older deployments)
// but "result unknown for too long" is a keeper-side watch + alert, never a finalize tx.

// RewardRoundManager.minimumBudget: cost > $0.5 ? 200 x cost : $100.
export const minimumBudget = fixedCost18 => (fixedCost18 > E18 / 2n ? fixedCost18 * 200n : ROUND_MIN_BASE);

// Which epochs of a PurchaseStock token source are ready to seal (V3RewardToken.sealReward).
export function sealableEpochs({ today, firstEpoch, lookback = 30, views }) {
  const out = [];
  const from = Math.max(firstEpoch ?? 0, today - lookback);
  for (let epoch = from; epoch < today; epoch++) {
    const v = views(epoch);
    if (!v) continue;
    if (v.sealed || v.budget === 0n) continue;
    if (v.nextRoundAt != null && v.nowSec < v.nextRoundAt) continue;
    out.push(epoch);
  }
  return out;
}

// Batch admission from Batcher.previewBatch + manager.minimumBudget(head).
export function planBatch({ ids, budgets, total, minimum, activeRounds = 0, maxActiveRounds = 1, marketOpen = true, runLimit = ROUND_MAX }) {
  if (activeRounds >= maxActiveRounds) return { action: 'defer', reason: 'Pending' }; // zero-float: sequential
  if (!ids.length) return { action: 'defer', reason: 'Empty' };
  if (ids.length > MAX_BATCH_ENTRIES || ids.length !== budgets.length) return { action: 'defer', reason: 'InvalidPreview' };
  if (minimum > runLimit) return { action: 'defer', reason: 'CostLimit' };
  if (total < minimum) return { action: 'defer', reason: 'BelowMinimum' };
  if (total > runLimit) return { action: 'defer', reason: 'InvalidPreview' };
  if (!marketOpen) return { action: 'defer', reason: 'MarketClosed' };
  return { action: 'execute', ids, budgets, total };
}

// RewardRoundManager.reserveBatch: entriesHash = fold keccak(abi.encode(prev, Entry, amount)).
export function entriesHash(entries, amounts) {
  let h = '0x' + '00'.repeat(32);
  entries.forEach((e, i) => {
    h = keccak256(coder.encode(['bytes32', ENTRY_TUPLE, 'uint256'], [h, entryTuple(e), amounts[i]]));
  });
  return h;
}

export const entryTuple = e => [e.source, e.pool, e.epoch, e.cohort, e.budget18, e.creditTotal, e.allocationId, e.assetId, e.adapterVersion, e.pricePolicy, e.eligibilityMode];

export function orderIdFor({ chainId, manager, entriesHash: hash, minRaw, deadline, sourceNonce }) {
  return keccak256(coder.encode(['uint256', 'address', 'bytes32', 'uint256', 'uint256', 'uint256'], [chainId, manager, hash, minRaw, deadline, sourceNonce]));
}

// Reward principal sent to RH must be whole 6-dp USDC: HubSettlement.beginReward reverts BadRewardOrder unless
// budget18 % 1e12 == 0 (fork F2). The batch is planned with maxBudget floored to that grid; previewBatch then takes
// a partial last entry and the sub-micro remainder stays queued for the next round.
export const USDC_GRID = 10n ** 12n;
export const alignBudget18 = total => BigInt(total) - (BigInt(total) % USDC_GRID);

// Round size for a group whose queue holds more than one order (10-02). A plain cut at L_run can leave a
// small last round: a $1,800 day at L_run $250 is 7 x $250 + $50, and $50 is under the $100 round minimum, so it
// waits for budget that may never come; a $100 tail can also fail the adapter's cost cap (Relay + LZ <= budget/200).
// So the queue is split into n = ceil(queued / L_run) near-equal rounds (8 x $225): every round is above L_run/2.
// queued = what previewBatch can take (non-pending available in its 64-entry window). Grid-aligned, never above L_run.
// When an even round (or the aligned last one) would fall under the round minimum — L_run < 2 x minimum, e.g. a
// guardian cut to $150 — the plain L_run cut is kept: one full round now beats several rounds the contract refuses.
export function roundCap({ queued, runLimit, minimum = 0n }) {
  const cap = alignBudget18(runLimit);
  queued = BigInt(queued);
  if (cap === 0n || queued <= cap) return cap;
  const n = (queued + cap - 1n) / cap;
  const even = alignBudget18((queued + n - 1n) / n + USDC_GRID - 1n); // ceil(queued / n), rounded up to the grid
  if (even > cap) return cap;
  const last = alignBudget18(queued) - (n - 1n) * even;
  return even < BigInt(minimum) || last < BigInt(minimum) ? cap : even;
}

// SolonStockAdapter.ORACLE_FLOOR_BPS (r7): startFunding reverts InvalidQuote when
// minRaw * 10_000 < oracle.rawFor(asset, budget) * (10_000 - 100).
export const ORACLE_FLOOR_BPS = 100n;
export const oracleFloorRaw = rawFor => (BigInt(rawFor) * (10_000n - ORACLE_FLOOR_BPS) + 9_999n) / 10_000n;

// minRawOut from a signed-policy price (USD18 per whole share) and slippage tolerance, rounded UP, and never under
// the adapter's oracle floor (fork F3: 100 bps + two floor divisions put r8's minRaw 1 wei under it). floorRaw =
// the oracle's own rawFor(asset, budget) when available (exactly what the adapter compares against).
export function minRawOut({ budget18, priceUSD18, decimals = 18, slippageBps = 99n, floorRaw = null }) {
  if (priceUSD18 <= 0n) throw new Error('no price');
  const raw = (budget18 * 10n ** BigInt(decimals)) / priceUSD18;
  let min = (raw * (10_000n - BigInt(slippageBps)) + 9_999n) / 10_000n;
  const floor = oracleFloorRaw(floorRaw ?? raw);
  if (min < floor) min = floor;
  if (min === 0n) throw new Error('minRaw rounds to zero');
  return min;
}

// Reward-round cost model (fork F4). What the adapter forwards to the hub is budget + fees18; the hub keeps its buy
// fee (budget x buyFeeBps, HubSettlement.beginReward) and pays the Relay route fee and the LZ order fee from the
// rest. The signed fixedCost18 — capped by the adapter at budget/200 — is the EXTERNAL cost only (Relay + LZ), per
// the design decision that the cap measures what leaves the protocol; costBasis 'all' reproduces the r10 model.
// The adapter only checks the signed value, so 'external' is accepted before and after the contract-side change.
export function planRoundCosts({ budget18, relayFee18, lzFee18, hubFeeBps, lzBufferBps = 2_000n, extraFixedCost18 = 0n, costBasis = 'external' }) {
  if (!['external', 'all'].includes(costBasis)) throw new Error(`costBasis ${costBasis} (external | all)`);
  const hubFee18 = (BigInt(budget18) * BigInt(hubFeeBps)) / 10_000n;
  const lz = (BigInt(lzFee18) * (10_000n + BigInt(lzBufferBps)) + 9_999n) / 10_000n;
  const external = BigInt(relayFee18) + lz;
  const fees18 = hubFee18 + external;
  const fixedCost18 = external + BigInt(extraFixedCost18) + (costBasis === 'all' ? hubFee18 : 0n);
  return { fees18, fixedCost18, hubFee18, relayFee18: BigInt(relayFee18), lzFee18: lz };
}

// Custom errors a round start can hit (adapter, hub, oracle, batcher); used to make simulation failures actionable.
export const ROUND_ERRORS = new Interface([
  'error InvalidQuote()', 'error InvalidOrder()', 'error BadRewardOrder()', 'error InsufficientValue(uint256 got,uint256 need)',
  'error PriceNotLive(address asset,uint8 status)', 'error NotRewardAdapter()', 'error EnforcedPause()', 'error Unauthorized()',
  'error UnknownAsset(address asset)',
]);
export function decodeRevert(error) {
  const data = [error?.data, error?.info?.error?.data, error?.error?.data, error?.revert?.data].find(d => typeof d === 'string' && d.startsWith('0x'));
  if (data) {
    try {
      const e = ROUND_ERRORS.parseError(data);
      if (e) return { name: e.name, args: [...e.args], data };
    } catch { /* unknown selector */ }
    try {
      const [msg] = AbiCoder.defaultAbiCoder().decode(['string'], '0x' + data.slice(10));
      if (data.startsWith('0x08c379a0')) return { name: `Error(${msg})`, args: [msg], data };
    } catch { /* not Error(string) */ }
  }
  return { name: null, args: [], data: data ?? null, message: String(error?.shortMessage ?? error?.message ?? error).slice(0, 160) };
}

// SolonStockAdapter.startFunding checks: budget >= $100, fixedCost18 <= budget/200; the upper bound is
// the stock layer's single-order limit (RoundManager.runLimit = CapacityController.lRun).
export function checkAdapterQuote({ budget18, fixedCost18, runLimit = ROUND_MAX }) {
  if (budget18 < ROUND_MIN_BASE || budget18 > runLimit) return { ok: false, reason: 'budget outside adapter band' };
  if (fixedCost18 > budget18 / 200n) return { ok: false, reason: 'CostLimit' };
  return { ok: true };
}

// Next step for one on-chain round. ctx: { now, funded, dispatched, dispatchedAt, result: {status,raw,refund}|null,
//   orphanConsumed, fundingAlertSec, quarantineAfterSec, cancelAfterSec|null, orphanWatchSec }
export function nextRoundAction(round, ctx) {
  const s = Number(round.status);
  const now = ctx.now;
  const submittedAt = Number(round.submittedAt ?? 0);
  switch (s) {
    case Status.Reserved:
      if (now > Number(round.deadline)) return { action: 'cancelUnsent' };
      return { action: 'start' };
    case Status.Funding: {
      if (ctx.result && ctx.result.status === 2) return { action: 'finalize', reason: 'bridge refund proven' };
      if (ctx.funded) return { action: 'poke' };
      if (!ctx.dispatched) return { action: 'dispatchFunding' };
      if (now - ctx.dispatchedAt > ctx.fundingAlertSec) return { action: 'alert', reason: 'funding not received', level: 'quarantine-watch', since: ctx.dispatchedAt };
      return { action: 'wait', reason: 'funding in flight' };
    }
    case Status.Funded:
      if (ctx.result && ctx.result.status === 2) return { action: 'finalize', reason: 'bridge refund proven' };
      return { action: 'submit' };
    case Status.Submitted:
    case Status.Quarantined: {
      if (s === Status.Quarantined && submittedAt === 0) {
        if (ctx.funded) return { action: 'poke', reason: 'quarantined funding arrived' };
        if (ctx.result && ctx.result.status === 2) return { action: 'finalize' };
        return { action: 'wait', reason: 'quarantined funding unresolved' };
      }
      if (ctx.result && (ctx.result.status === 1 || ctx.result.status === 2)) return { action: 'finalize' };
      if (ctx.cancelAfterSec != null && !round.cancelRequested && now >= submittedAt + Math.max(CANCEL_MIN_AGE, ctx.cancelAfterSec)) {
        return { action: 'requestCancel' };
      }
      if (now - submittedAt > ctx.quarantineAfterSec) return { action: 'alert', reason: 'result unknown', level: 'quarantine', since: submittedAt };
      return { action: 'wait', reason: 'awaiting result' };
    }
    case Status.Refunded:
      if (!ctx.orphanConsumed && ctx.result?.status === 1) return { action: 'finalize', reason: 'late fill -> orphan to treasury' };
      return { action: 'done', reason: 'refunded; entries back in FIFO' };
    case Status.Settled:
    case Status.CancelledUnsent:
      return { action: 'done' };
    default:
      return { action: 'wait', reason: `unknown status ${s}` };
  }
}

// Whether the head of a batcher group should be advanced. Mirrors RewardBatcher.advance at
// 03d87c2: the head skips entries with nothing available OR still pending in a round (both
// clog the 64-window). Skipping a pending entry is safe: when its round ends Refunded or
// CancelledUnsent, manager -> batcher.onRoundFinalized restores the cursor to it.
export function shouldAdvance({ groupIds, cursor, isSkippable, threshold = 16 }) {
  let n = 0;
  for (let i = cursor; i < groupIds.length && n < MAX_BATCH_ENTRIES; i++) {
    if (!isSkippable(groupIds[i])) break;
    n++;
  }
  return n >= threshold ? Math.min(n, MAX_BATCH_ENTRIES) : 0;
}

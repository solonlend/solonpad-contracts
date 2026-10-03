// Pure decision logic for the daily push (DESIGN §5.3, RewardDistributor at 03d87c2).
// The contract already enforces per-account >= max($2, 200 x cost) on-chain; the keeper
// adds the Ops-side rule (batch cost <= 0.5% of value pushed), schedules the 00:10 UTC
// daily cycle with 15-minute continuations, and sizes gas so a batch cannot silently
// make zero progress (estimateGas would find the early-return path and under-fund it).
export const DAY = 86_400;
export const SCAN_OFFSET = 600; // 00:10 UTC
export const MAX_ACCOUNTS = 32;
export const MIN_GAS_BUDGET = 300_000; // RewardDistributor.batchDistribute: child gas >= 300k (03d87c2)
export const MAX_GAS_BUDGET = 2_000_000;
export const RESERVE = 100_000; // distributor reserves 2 x gasBudget + 100k before each account
export const E18 = 10n ** 18n;

export const utcDay = nowSec => Math.floor(nowSec / DAY);
export const scanWindowOpen = nowSec => nowSec % DAY >= SCAN_OFFSET;

export function queueDecision({ nowSec, nextScanAt, upperBound, record }) {
  if (!scanWindowOpen(nowSec)) return { scan: false, reason: 'before 00:10 UTC' };
  if (upperBound === 0) return { scan: false, reason: 'empty queue' };
  const today = utcDay(nowSec);
  if (record?.completedDay === today) return { scan: false, reason: 'cycle complete today' };
  if (record?.skippedDay === today) return { scan: false, reason: record.skipReason ?? 'skipped today' };
  if (nowSec < nextScanAt) return { scan: false, reason: 'scan schedule (15 min continuation)' };
  return { scan: true };
}

// accounts: [{ rawReady: bigint (readyRaw + estimated stageable) }]; values in USD18 at priceUSD18.
export function dayPlan({ accounts, priceUSD18, minimumUSD18, gasPriceWei, perAccountGas, fixedGas, pageSize = MAX_ACCOUNTS, maxCostBps = 50n, cursor = 0 }) {
  if (priceUSD18 === 0n) return { run: false, reason: 'no fresh price (oracle stale: automatic push paused, claim unaffected)' };
  let pushable = 0;
  let value = 0n;
  for (const a of accounts.slice(cursor)) {
    const usd = (a.rawReady * priceUSD18) / E18;
    if (usd >= minimumUSD18) { pushable++; value += usd; }
  }
  const remaining = accounts.length - cursor;
  const pages = Math.ceil(remaining / pageSize);
  const gas = BigInt(pages) * BigInt(fixedGas) + BigInt(remaining) * BigInt(perAccountGas);
  const cost = gas * gasPriceWei; // Arc gas token is native USDC (18 dp) => wei == USD18
  if (pushable === 0) return { run: false, reason: 'nobody over the push threshold', pushable, value, cost };
  if (cost * 10_000n > value * maxCostBps) return { run: false, reason: `cost ${cost} > ${maxCostBps} bps of ${value}`, pushable, value, cost };
  return { run: true, pushable, value, cost, pages };
}

export function clampGasBudget(gasBudget) {
  if (!Number.isInteger(gasBudget)) throw new Error('gasBudget must be an integer');
  return Math.min(MAX_GAS_BUDGET, Math.max(MIN_GAS_BUDGET, gasBudget));
}

// Pick (maxAccounts, gasLimit) so the in-contract guard `gasleft() >= 2*gasBudget+100k`
// holds for every account we ask for. perAccountGas = our upper estimate of real use.
export function gasPlan({ gasBudget, perAccountGas, maxTxGas, wanted = MAX_ACCOUNTS, overhead = 120_000 }) {
  const budget = clampGasBudget(gasBudget);
  const floor = 2 * budget + RESERVE + overhead;
  if (maxTxGas < floor + perAccountGas) throw new Error(`maxTxGas ${maxTxGas} cannot fit one account at gasBudget ${budget}`);
  const fit = Math.floor((maxTxGas - floor) / perAccountGas);
  const maxAccounts = Math.max(1, Math.min(MAX_ACCOUNTS, wanted, fit));
  return { gasBudget: budget, maxAccounts, gasLimit: BigInt(floor + maxAccounts * perAccountGas) };
}

// Did the batch move? Anything less is a failure: the day record is NOT advanced.
export function progressOf({ before, after, processedEvents, upperBound }) {
  const wrapped = before === upperBound; // contract restarts from 0 on a completed queue
  const moved = wrapped ? after > 0 || processedEvents > 0 : after > before;
  return { moved, complete: after === upperBound && (moved || processedEvents > 0) };
}

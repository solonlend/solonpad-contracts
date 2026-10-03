import test from 'node:test';
import assert from 'node:assert/strict';
import {
  E18, minimumBudget, planBatch, sealableEpochs, nextRoundAction, Status, minRawOut, checkAdapterQuote, shouldAdvance,
  entriesHash, orderIdFor, ROUND_MAX,
} from '../round/decide.mjs';

test('minimum round is max($100, 200 x fixed cost) exactly as RewardRoundManager.minimumBudget', () => {
  assert.equal(minimumBudget(0n), 100n * E18);
  assert.equal(minimumBudget(E18 / 2n), 100n * E18, '$0.50 is not > $0.50');
  assert.equal(minimumBudget(E18 / 2n + 1n), (E18 / 2n + 1n) * 200n);
  assert.equal(minimumBudget(952_916n * 10n ** 12n), 190_583_200n * 10n ** 12n, '§5.1 example: $0.952916 -> $190.58');
});

test('planBatch: defers below minimum / above cost limit / while a round is active; executes otherwise', () => {
  const base = { ids: [1, 2], budgets: [60n * E18, 50n * E18], total: 110n * E18, minimum: 100n * E18 };
  assert.equal(planBatch(base).action, 'execute');
  assert.equal(planBatch({ ...base, total: 99n * E18 }).reason, 'BelowMinimum');
  assert.equal(planBatch({ ...base, minimum: 10_001n * E18 }).reason, 'CostLimit');
  assert.equal(planBatch({ ...base, activeRounds: 1 }).reason, 'Pending', 'zero-float: one round in flight');
  assert.equal(planBatch({ ...base, activeRounds: 1, maxActiveRounds: 2 }).action, 'execute');
  assert.equal(planBatch({ ...base, ids: [] , budgets: [] }).reason, 'Empty');
  assert.equal(planBatch({ ...base, total: ROUND_MAX + 1n }).reason, 'InvalidPreview');
  assert.equal(planBatch({ ...base, marketOpen: false }).reason, 'MarketClosed');
});

test('run limit follows the stock layer lRun: $10k default, and a governance-lowered limit binds at once', () => {
  assert.equal(ROUND_MAX, 10_000n * E18, 'owner decision 2026-09-30: per-order $10,000');
  const base = { ids: [1], budgets: [5_000n * E18], total: 5_000n * E18, minimum: 100n * E18 };
  assert.equal(planBatch(base).action, 'execute', '$5k was above the old $1k cap');
  assert.equal(planBatch({ ...base, runLimit: 1_000n * E18 }).reason, 'InvalidPreview');
  assert.equal(planBatch({ ...base, minimum: 2_000n * E18, total: 2_000n * E18, runLimit: 1_000n * E18 }).reason, 'CostLimit');
  assert.equal(checkAdapterQuote({ budget18: 5_000n * E18, fixedCost18: E18 }).ok, true);
  assert.equal(checkAdapterQuote({ budget18: 5_000n * E18, fixedCost18: E18, runLimit: 1_000n * E18 }).ok, false);
});

test('sealableEpochs: only closed epochs with budget, unsealed and past nextRoundAt', () => {
  const views = e => ({ 10: { budget: 5n, sealed: false, nextRoundAt: 11 * 86400, nowSec: 12 * 86400 },
    11: { budget: 0n, sealed: false, nowSec: 12 * 86400 }, 9: { budget: 5n, sealed: true, nowSec: 12 * 86400 },
    8: { budget: 5n, sealed: false, nextRoundAt: 13 * 86400, nowSec: 12 * 86400 } }[e]);
  assert.deepEqual(sealableEpochs({ today: 12, firstEpoch: 0, lookback: 5, views }), [10]);
  assert.deepEqual(sealableEpochs({ today: 12, firstEpoch: 11, lookback: 5, views }), [], 'never below firstEpoch; today excluded');
});

const ctx = (o = {}) => ({ now: 10_000, funded: false, dispatched: false, dispatchedAt: 0, result: null, orphanConsumed: false, fundingAlertSec: 900, quarantineAfterSec: 3600, cancelAfterSec: null, ...o });

test('state machine: Reserved -> start, or cancelUnsent after deadline', () => {
  assert.equal(nextRoundAction({ status: Status.Reserved, deadline: 20_000 }, ctx()).action, 'start');
  assert.equal(nextRoundAction({ status: Status.Reserved, deadline: 9_000 }, ctx()).action, 'cancelUnsent');
});

test('state machine: Funding dispatches once, pokes when funded, alerts (never re-dispatches) when late', () => {
  const r = { status: Status.Funding };
  assert.equal(nextRoundAction(r, ctx()).action, 'dispatchFunding');
  assert.equal(nextRoundAction(r, ctx({ dispatched: true, dispatchedAt: 9_500 })).action, 'wait');
  assert.equal(nextRoundAction(r, ctx({ dispatched: true, dispatchedAt: 1_000 })).action, 'alert');
  assert.equal(nextRoundAction(r, ctx({ dispatched: true, funded: true })).action, 'poke');
  assert.equal(nextRoundAction(r, ctx({ dispatched: true, result: { status: 2 } })).action, 'finalize', 'proven bridge refund');
});

test('state machine: Funded -> submit; Submitted finalizes only on a proven result, alerts (never finalizes) after timeout, cancel only when enabled', () => {
  assert.equal(nextRoundAction({ status: Status.Funded }, ctx()).action, 'submit');
  assert.equal(nextRoundAction({ status: Status.Funded }, ctx({ result: { status: 2 } })).action, 'finalize', 'refund proven before submit');
  const sub = { status: Status.Submitted, submittedAt: 9_000, cancelRequested: false };
  assert.equal(nextRoundAction(sub, ctx()).action, 'wait');
  assert.equal(nextRoundAction(sub, ctx({ result: { status: 1 } })).action, 'finalize');
  assert.equal(nextRoundAction(sub, ctx({ result: { status: 0 } })).action, 'wait', 'empty result: finalize would be a no-op');
  const late = nextRoundAction(sub, ctx({ now: 9_000 + 3601 }));
  assert.deepEqual([late.action, late.level], ['alert', 'quarantine'], 'result unknown: alert only (03d87c2 finalize with empty proof changes nothing)');
  const q = { status: Status.Quarantined, submittedAt: 1_000, cancelRequested: false };
  assert.equal(nextRoundAction(q, ctx()).action, 'alert', 'no auto-cancel by default; overdue result is alerted');
  assert.equal(nextRoundAction({ ...q, submittedAt: 9_000 }, ctx()).action, 'wait');
  assert.equal(nextRoundAction(q, ctx({ cancelAfterSec: 60 })).action, 'requestCancel', 'cancel floor is 30 min, 9000s elapsed');
  assert.equal(nextRoundAction({ ...q, submittedAt: 9_000 }, ctx({ cancelAfterSec: 60 })).action, 'wait', 'under 30 min');
  assert.equal(nextRoundAction({ ...q, cancelRequested: true }, ctx({ cancelAfterSec: 60 })).action, 'alert', 'cancel already requested; still overdue -> alert, no second cancel');
  assert.equal(nextRoundAction(q, ctx({ result: { status: 2 } })).action, 'finalize');
});

test('state machine: quarantined-before-submit pokes when funding lands; refunded consumes a late fill once', () => {
  const q0 = { status: Status.Quarantined, submittedAt: 0 };
  assert.equal(nextRoundAction(q0, ctx({ funded: true })).action, 'poke');
  assert.equal(nextRoundAction(q0, ctx()).action, 'wait');
  assert.equal(nextRoundAction({ status: Status.Refunded }, ctx({ result: { status: 1 } })).action, 'finalize');
  assert.equal(nextRoundAction({ status: Status.Refunded }, ctx({ result: { status: 1 }, orphanConsumed: true })).action, 'done');
  assert.equal(nextRoundAction({ status: Status.Settled }, ctx()).action, 'done');
  assert.equal(nextRoundAction({ status: Status.CancelledUnsent }, ctx()).action, 'done');
});

test('minRawOut and adapter quote checks', () => {
  assert.equal(minRawOut({ budget18: 180n * E18, priceUSD18: 180n * E18, decimals: 18, slippageBps: 100n }), 99n * 10n ** 16n);
  assert.throws(() => minRawOut({ budget18: 1n, priceUSD18: 0n }));
  assert.equal(checkAdapterQuote({ budget18: 200n * E18, fixedCost18: E18 }).ok, true);
  assert.equal(checkAdapterQuote({ budget18: 200n * E18, fixedCost18: E18 + 1n }).reason, 'CostLimit');
  assert.equal(checkAdapterQuote({ budget18: 99n * E18, fixedCost18: 0n }).ok, false);
});

test('shouldAdvance counts skippable head entries (nothing available or pending) like RewardBatcher.advance', () => {
  const ids = Array.from({ length: 40 }, (_, i) => i + 1);
  assert.equal(shouldAdvance({ groupIds: ids, cursor: 0, isSkippable: id => id <= 20, threshold: 16 }), 20);
  assert.equal(shouldAdvance({ groupIds: ids, cursor: 0, isSkippable: id => id <= 10, threshold: 16 }), 0);
  assert.equal(shouldAdvance({ groupIds: ids, cursor: 5, isSkippable: id => id !== 6, threshold: 1 }), 0, 'blocked head');
});

test('entriesHash/orderId are deterministic and bind every field', () => {
  const e = { source: '0x' + '11'.repeat(20), pool: '0x' + '22'.repeat(32), epoch: 10n, cohort: 0, budget18: 5n, creditTotal: 7n, allocationId: 1n, assetId: '0x' + '33'.repeat(32), adapterVersion: 1, pricePolicy: '0x' + '44'.repeat(32), eligibilityMode: 0 };
  const h = entriesHash([e], [5n]);
  assert.notEqual(h, entriesHash([e], [4n]));
  assert.notEqual(h, entriesHash([{ ...e, epoch: 11n }], [5n]));
  const o = orderIdFor({ chainId: 5042, manager: '0x' + '55'.repeat(20), entriesHash: h, minRaw: 1n, deadline: 2n, sourceNonce: 0n });
  assert.notEqual(o, orderIdFor({ chainId: 5042, manager: '0x' + '55'.repeat(20), entriesHash: h, minRaw: 1n, deadline: 2n, sourceNonce: 1n }));
});

// ---- fork findings F2/F3/F4 (FORK-E2E-v3.md §4.2)
import { alignBudget18, oracleFloorRaw, planRoundCosts, ORACLE_FLOOR_BPS, decodeRevert } from '../round/decide.mjs';
import { ROUND_DEFAULTS } from '../round/keeper.mjs';
import { Interface } from 'ethers';

test('F2: a batch budget is floored to whole 6-dp USDC (HubSettlement.beginReward: budget18 % 1e12 == 0)', () => {
  const total = 350_175_316_592_261_904_761n; // case B, $350.175316592261904761
  assert.equal(alignBudget18(total), 350_175_316_000_000_000_000n);
  assert.equal(alignBudget18(total) % 10n ** 12n, 0n);
  assert.equal(alignBudget18(100n * E18), 100n * E18);
  assert.equal(alignBudget18(10n ** 12n - 1n), 0n, 'sub-micro dust only');
});

test('F3: default slippage <= 99 bps and minRaw is never under the adapter oracle floor (ORACLE_FLOOR_BPS = 100)', () => {
  assert.ok(ROUND_DEFAULTS.slippageBps <= 99n);
  assert.equal(ORACLE_FLOOR_BPS, 100n);
  const budget18 = 350_175_316n * 10n ** 12n;
  const priceUSD18 = 231_604_391_200_000_000_000n;
  const rawFor = (budget18 * E18) / priceUSD18; // SolonStockOracle.rawFor (mulDiv, rounded down)
  // r8 keeper: 100 bps + two floor divisions -> 1 wei under the floor (case A InvalidQuote)
  const old = (rawFor * 9_900n) / 10_000n - 1n;
  assert.ok(old * 10_000n < rawFor * 9_900n, 'reproduces the r8 shortfall');
  for (const slippageBps of [0n, 50n, 99n, 100n, 300n]) {
    const m = minRawOut({ budget18, priceUSD18, slippageBps, floorRaw: rawFor });
    assert.ok(m * 10_000n >= rawFor * (10_000n - ORACLE_FLOOR_BPS), `slippage ${slippageBps}: adapter check passes`);
  }
  assert.equal(oracleFloorRaw(10_001n), 9_901n, 'ceil(10001 x 0.99) = 9900.99 -> 9901');
  // rounded up: 99 bps of 1e18 raw is exact; of an odd raw it rounds toward the user, never under
  assert.equal(minRawOut({ budget18: 100n * E18, priceUSD18: 3n * E18, slippageBps: 99n }), ((100n * E18 * E18) / (3n * E18) * 9_901n + 9_999n) / 10_000n);
});

test('F4: fees = hub 25 bps + Relay + LZ (buffered); the signed cost (adapter <= budget/200) counts only Relay + LZ', () => {
  const budget18 = 230_580_000n * 10n ** 12n; // $230.58, case D
  const c = planRoundCosts({ budget18, relayFee18: 335_000_000_000_000_000n, lzFee18: 300_000_000_000_000_000n, hubFeeBps: 25n, lzBufferBps: 2_000n });
  assert.equal(c.hubFee18, (budget18 * 25n) / 10_000n, 'same rounding as HubSettlement.beginReward');
  assert.equal(c.lzFee18, 360_000_000_000_000_000n, 'LZ quote + 20%');
  assert.equal(c.fees18, c.hubFee18 + 335_000_000_000_000_000n + 360_000_000_000_000_000n);
  assert.equal(c.fixedCost18, 695_000_000_000_000_000n, 'external only: $0.695');
  assert.equal(checkAdapterQuote({ budget18, fixedCost18: c.fixedCost18 }).ok, true, '$0.695 <= $1.15: the $230 round starts');
  // r10 harness model (hub fee inside the capped cost): $1.27 > $1.15 -> CostLimit
  const all = planRoundCosts({ budget18, relayFee18: 335_000_000_000_000_000n, lzFee18: 300_000_000_000_000_000n, hubFeeBps: 25n, lzBufferBps: 2_000n, costBasis: 'all' });
  assert.equal(checkAdapterQuote({ budget18, fixedCost18: all.fixedCost18 }).reason, 'CostLimit');
  assert.throws(() => planRoundCosts({ budget18, relayFee18: 0n, lzFee18: 0n, hubFeeBps: 25n, costBasis: 'nope' }));
});

test('simulation reverts are decoded for the alert (InvalidQuote / BadRewardOrder / InsufficientValue)', () => {
  const i = new Interface(['error InvalidQuote()', 'error BadRewardOrder()', 'error InsufficientValue(uint256,uint256)']);
  assert.equal(decodeRevert({ data: i.encodeErrorResult('InvalidQuote', []) }).name, 'InvalidQuote');
  assert.equal(decodeRevert({ info: { error: { data: i.encodeErrorResult('BadRewardOrder', []) } } }).name, 'BadRewardOrder');
  const v = decodeRevert({ error: { data: i.encodeErrorResult('InsufficientValue', [5n, 9n]) } });
  assert.equal(v.name, 'InsufficientValue');
  assert.deepEqual(v.args, [5n, 9n]);
  assert.equal(decodeRevert({ message: 'boom' }).name, null);
});

test('F4 r12 adapter rule: fees18 <= fixedCost18 + budget x buyFeeBps / 1e4 and fixedCost18 <= budget/200 (both bases, any extra)', () => {
  for (const budget18 of [100n * E18, 230_580_000n * 10n ** 12n, 10_000n * E18]) {
    for (const costBasis of ['external', 'all']) {
      for (const extraFixedCost18 of [0n, 10n ** 17n]) {
        const c = planRoundCosts({ budget18, relayFee18: 335n * 10n ** 15n, lzFee18: 3n * 10n ** 17n, hubFeeBps: 25n, extraFixedCost18, costBasis });
        assert.ok(c.fees18 <= c.fixedCost18 + (budget18 * 25n) / 10_000n, `${budget18} ${costBasis} ${extraFixedCost18}`);
      }
    }
  }
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { scanWindowOpen, queueDecision, dayPlan, gasPlan, clampGasBudget, progressOf, E18, RESERVE } from '../push/decide.mjs';

const day = 20_000 * 86_400;

test('daily cycle opens at 00:10 UTC and respects the 15-minute continuation schedule', () => {
  assert.equal(scanWindowOpen(day + 599), false);
  assert.equal(scanWindowOpen(day + 600), true);
  assert.equal(queueDecision({ nowSec: day + 700, nextScanAt: day + 800, upperBound: 5 }).scan, false);
  assert.equal(queueDecision({ nowSec: day + 900, nextScanAt: day + 800, upperBound: 5 }).scan, true);
  assert.equal(queueDecision({ nowSec: day + 900, nextScanAt: 0, upperBound: 0 }).reason, 'empty queue');
  assert.equal(queueDecision({ nowSec: day + 900, nextScanAt: 0, upperBound: 5, record: { completedDay: 20_000 } }).scan, false, 'no second cycle the same day');
  assert.equal(queueDecision({ nowSec: day + 86_400 + 900, nextScanAt: 0, upperBound: 5, record: { completedDay: 20_000 } }).scan, true, 'next day rescans');
});

const plan = o => dayPlan({ priceUSD18: 180n * E18, minimumUSD18: 2n * E18, gasPriceWei: 40n * 10n ** 9n, perAccountGas: 150_000, fixedGas: 150_000, ...o });

const usd = n => (BigInt(n) * E18) / 180n + 1n; // raw for ~$n at $180/share

test('push threshold is per account >= $2 (cumulative readyRaw); nobody over it => no run', () => {
  const r = plan({ accounts: Array.from({ length: 32 }, () => ({ rawReady: usd(1) })) });
  assert.equal(r.run, false);
  assert.equal(r.reason, 'nobody over the push threshold');
  const ok = plan({ accounts: Array.from({ length: 32 }, () => ({ rawReady: usd(2) })), perAccountGas: 100_000 });
  assert.equal(ok.run, true);
  assert.equal(ok.pushable, 32);
});

test('Ops cost must stay <= 0.5% of pushed value (design example: 32 x $2 at 40 gwei)', () => {
  const full = plan({ accounts: Array.from({ length: 32 }, () => ({ rawReady: usd(2) })), perAccountGas: 100_000 });
  assert.ok(full.cost * 10_000n <= full.value * 50n, `cost ${full.cost} value ${full.value}`);
  const lone = plan({ accounts: [{ rawReady: usd(2) }] });
  assert.equal(lone.run, false, 'a whole batch for one $2 account costs 0.6%');
  assert.match(lone.reason, /cost/);
  const skipCursor = plan({ accounts: [{ rawReady: usd(100) }, { rawReady: 0n }], cursor: 1 });
  assert.equal(skipCursor.run, false, 'only accounts from the current cursor count');
});

test('stale oracle pauses automatic push only', () => {
  assert.match(plan({ accounts: [{ rawReady: E18 }], priceUSD18: 0n }).reason, /claim unaffected/);
});

test('gasPlan keeps 2 x gasBudget + 100k headroom so the contract guard cannot trip', () => {
  const g = gasPlan({ gasBudget: 300_000, perAccountGas: 250_000, maxTxGas: 12_000_000 });
  assert.equal(g.maxAccounts, 32);
  assert.ok(g.gasLimit >= BigInt(2 * 300_000 + RESERVE + 32 * 250_000));
  const tight = gasPlan({ gasBudget: 300_000, perAccountGas: 250_000, maxTxGas: 2_000_000 });
  assert.equal(tight.maxAccounts, 4);
  assert.ok(tight.gasLimit <= 2_000_000n);
  assert.throws(() => gasPlan({ gasBudget: 2_000_000, perAccountGas: 250_000, maxTxGas: 3_000_000 }));
  assert.equal(clampGasBudget(50_000), 300_000, "RewardDistributor rejects gasBudget < 300k since 03d87c2");
  assert.equal(clampGasBudget(150_000), 300_000);
  assert.equal(clampGasBudget(5_000_000), 2_000_000);
});

test('zero progress is failure; wrap-around from a completed cycle counts as progress', () => {
  assert.deepEqual(progressOf({ before: 3, after: 3, processedEvents: 0, upperBound: 10 }), { moved: false, complete: false });
  assert.deepEqual(progressOf({ before: 3, after: 10, processedEvents: 7, upperBound: 10 }), { moved: true, complete: true });
  assert.deepEqual(progressOf({ before: 10, after: 10, processedEvents: 10, upperBound: 10 }), { moved: true, complete: true });
  assert.deepEqual(progressOf({ before: 10, after: 4, processedEvents: 4, upperBound: 10 }), { moved: true, complete: false });
});

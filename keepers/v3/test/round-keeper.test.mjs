import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { Journal } from '../lib/journal.mjs';
import { RoundKeeper } from '../round/keeper.mjs';
import { Phase5Seam, RelayFundingLane } from '../round/funding.mjs';
import { nextRoundAction, Status } from '../round/decide.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const A = n => '0x' + String(n).repeat(40);
const cfg = { contracts: { roundManager: A(1), batcher: A(2), stockRegistry: A(3) }, round: {} };
const round = { status: Status.Funding, orderId: '0x' + 'ab'.repeat(32), budget18: 200n * 10n ** 18n, adapter: A(4), submittedAt: 0 };

function keeper(lane, execute = true) {
  const journal = new Journal(join(tmp(), 'j.json'));
  const alerts = [];
  const k = new RoundKeeper({ cfg, provider: null, tx: { execute }, journal, logger: quietLogger, alert: async (key, t) => alerts.push(t), lane, chainId: 5042, now: () => 1_000 });
  k.summary = { actions: [], deferred: [], seams: [] };
  return { k, journal, alerts };
}

test('funding dispatch: phase-5 seam is a definite not-sent -> intent cleared, may retry later', async () => {
  const { k, journal } = keeper({ name: 'relay', dispatch: async () => { throw new Phase5Seam('hub'); } });
  await k.dispatchFunding(1, round, {});
  const rec = journal.record('rounds', '1');
  assert.equal(rec.dispatchStartedAt, null);
  assert.deepEqual(k.summary.seams, ['hub']);
  assert.equal(nextRoundAction(round, { now: 1_000, dispatched: Boolean(rec.dispatchStartedAt) }).action, 'dispatchFunding');
});

test('funding dispatch: ambiguous failure is treated as SENT -> never dispatched twice', async () => {
  let calls = 0;
  const { k, journal, alerts } = keeper({ name: 'relay', dispatch: async () => { calls++; throw new Error('socket hang up'); } });
  await k.dispatchFunding(1, round, {});
  const rec = journal.record('rounds', '1');
  assert.equal(rec.dispatchAmbiguous, true);
  assert.ok(rec.dispatchStartedAt > 0);
  assert.match(alerts[0], /UNKNOWN/);
  const d = nextRoundAction(round, { now: 1_000, dispatched: true, dispatchedAt: rec.dispatchStartedAt, fundingAlertSec: 900 });
  assert.equal(d.action, 'wait');
  assert.equal(calls, 1);
});

test('funding dispatch: intent is durable before the lane runs (crash mid-dispatch cannot double-spend)', async () => {
  let seen;
  const { k, journal } = keeper({ name: 'relay', dispatch: async () => { seen = journal.record('rounds', '1'); return { requestId: '0xreq', txHash: '0xtx' }; } });
  await k.dispatchFunding(1, round, {});
  assert.ok(seen.dispatchStartedAt > 0, 'recorded before dispatch');
  assert.equal(journal.record('rounds', '1').requestId, '0xreq');
});

test('funding dispatch: dry-run never calls the lane', async () => {
  const { k } = keeper({ name: 'relay', dispatch: async () => { throw new Error('must not run'); } }, false);
  await k.dispatchFunding(1, round, {});
  assert.equal(k.summary.actions[0].status, 'dry-run');
});

test('relay lane: rejected quote is pre-send and hub seam is reported before any signing', async () => {
  const lane = new RelayFundingLane({ relayClient: { quote: async () => ({ steps: [] }) }, user: A(5), recipient: A(6) });
  await assert.rejects(lane.dispatch({ orderId: round.orderId, budget18: round.budget18, fees18: 0n }), e => e.sent === false || e.name === 'RelayRejected' || /rejected/.test(e.message));
});

// decimals M4: IngressKeeper.maybeCollect measures the native fee from the block before the collect (not 'latest' read
// before sending) and quarantines evidence whose native delta disagrees with the 0x3600 view Transfer.
import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { Interface, zeroPadValue } from 'ethers';
import { Journal } from '../lib/journal.mjs';
import { IngressKeeper } from '../ingress/keeper.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const E18 = 10n ** 18n;
const ZERO = '0x0000000000000000000000000000000000000000';
const VIEW = '0x3600000000000000000000000000000000000000';
const A = n => '0x' + n.toString(16).padStart(40, '0');
const me = A(0xdd);
const transferTopic = new Interface(['event Transfer(address indexed from, address indexed to, uint256 value)']);

function world({ balances, view6 }) {
  const alerts = [];
  const calls = [];
  const log = { address: VIEW, index: 4, ...transferTopic.encodeEventLog('Transfer', [A(0x5b), me, view6]) };
  const provider = {
    getBalance: async (addr, tag = 'latest') => { calls.push(tag); return balances[String(tag)]; },
    getBlock: async () => ({ timestamp: 1_790_000_000 }),
  };
  const k = new IngressKeeper({
    cfg: { contracts: { v2Ingress: A(1), v2Router: A(2), buybackExecutor: A(3) }, ingress: { params: { collectEnabled: true } } },
    provider, journal: new Journal(join(tmp(), 'i.json')), logger: quietLogger, chainId: 5042, now: () => 1_790_000_000,
    alert: async (key, text) => alerts.push({ key, text }),
    priceSource: { platformFeesUsd18: async () => 500n * E18 },
    tx: {
      from: me,
      call: async () => ({ status: 'confirmed', receipt: { hash: '0x' + 'ab'.repeat(32), blockNumber: 101, gasUsed: 0n, gasPrice: 0n, logs: [log] } }),
    },
  });
  k.summary = { actions: [], seams: [], quarantined: [] };
  const source = { name: 'v4', key: zeroPadValue('0x01', 32), tokens: [ZERO], policyVersion: 1, collect: { splitter: A(9), positionId: 7 } };
  return { k, alerts, calls, source };
}

test('decimals M4: before-balance is pinned to the block before the collect receipt', async () => {
  const { k, calls, source } = world({ balances: { latest: 0n, 100: 50n * E18, 101: 57n * E18 + 1n }, view6: 7_000_000n });
  await k.maybeCollect(source);
  assert.ok(!calls.includes('latest'), `balance reads: ${calls}`);
  const lots = k.journal.records('lots');
  assert.equal(lots.length, 1);
  assert.equal(lots[0].evidence.actualPlatformAmount, 7n * E18 + 1n);
  assert.ok(!lots[0].quarantined);
});

test('decimals M4: native delta not matching the 0x3600 Transfer is quarantined and alerted, not funded', async () => {
  // 5 USDC of unrelated native inflow lands in the same block as the 7 USDC collect.
  const { k, alerts, source } = world({ balances: { latest: 50n * E18, 100: 50n * E18, 101: 62n * E18 }, view6: 7_000_000n });
  await k.maybeCollect(source);
  const lots = k.journal.records('lots');
  assert.equal(lots.length, 1);
  assert.equal(lots[0].quarantined, true);
  assert.match(lots[0].reason, /native delta/);
  assert.equal(alerts.length, 1);
  assert.equal(k.summary.quarantined.length, 1);
});

// Large daily payout budgets vs the single-order limit (10-02): a coin whose day budget exceeds L_run must be
// bought in several sequential rounds that add up to the budget to the wei, with nothing left stuck in the queue.
// The batcher fake is a line-by-line port of RewardBatcher.previewBatch (FIFO, pending skip, partial last slice,
// sub-1e12 tail trim) and executeAndStart's FIFO recheck; RewardRoundManager.reserveBatch's min/run-limit require.
import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { Interface, Wallet } from 'ethers';
import { Journal } from '../lib/journal.mjs';
import { RoundKeeper } from '../round/keeper.mjs';
import { RoundManagerAbi } from '../lib/abis.mjs';
import { roundCap, USDC_GRID } from '../round/decide.mjs';
import { stockQuoteDigest, digestSignerFor } from './round-fakes.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const E18 = 10n ** 18n;
const A = n => '0x' + n.toString(16).padStart(40, '0');
const THU = Math.floor(Date.parse('2026-10-01T18:00:00Z') / 1000);
const PRICE = 231_604_391_200_000_000_000n;
const MIN = 100n * E18;
const mgrIface = new Interface(RoundManagerAbi);

function world({ budgets, runLimit = 250n * E18 }) {
  const signer = Wallet.createRandom();
  const C = { manager: A(1), batcher: A(2), registry: A(3), adapter: A(4), hub: A(5), oracle: A(6), asset: A(7), underlying: A(8), vault: A(9), ops: A(10), rewardOracle: A(11) };
  const config = { coordinator: C.manager, vault: C.vault, asset: C.asset, underlying: C.underlying, hub: C.hub, signer: signer.address, path: '0x' + '11'.repeat(32), destinationChain: 4663n, opsVault: C.ops, oracle: C.oracle };
  const w = { now: THU, rounds: [], rejected: [], available: new Map(budgets.map((b, i) => [i + 1, b])), pending: new Map(), nonces: new Map() };
  const queue = budgets.map((_, i) => i + 1);
  const entry = id => ({ source: A(100 + id), pool: '0x' + '00'.repeat(32), epoch: 1n, cohort: 0n, budget18: budgets[id - 1], creditTotal: 1n, allocationId: BigInt(id), assetId: '0x' + '22'.repeat(32), adapterVersion: 1n, pricePolicy: '0x' + '00'.repeat(32), eligibilityMode: 0n });
  // RewardBatcher.previewBatch
  const preview = max => {
    if (!(max > 0n && max <= runLimit)) throw new Error('previewBatch: require(maxBudget > 0 && <= runLimit)');
    const ids = []; const amounts = []; let total = 0n;
    for (const id of queue) {
      if (ids.length >= 64 || total >= max) break;
      if ((w.pending.get(id) ?? 0n) > 0n) continue;
      const a = w.available.get(id);
      if (a === 0n) continue;
      const take = a < max - total ? a : max - total;
      ids.push(id); amounts.push(take); total += take;
    }
    let tail = total % USDC_GRID;
    while (tail !== 0n) {
      const last = amounts.at(-1);
      if (last > tail) { amounts[amounts.length - 1] = last - tail; total -= tail; tail = 0n; } else { total -= last; tail -= last; amounts.pop(); ids.pop(); }
    }
    return { ids: ids.map(BigInt), budgets: amounts, total };
  };
  const fakes = {
    [C.adapter]: { target: C.adapter, config: async () => config, feeBalance: async () => 0n, nonceUsed: async () => false, quoteDigest: async q => stockQuoteDigest({ chainId: 5042, adapter: C.adapter, config, q }) },
    [C.hub]: { fees: async () => [25n, 25n, 0n], quoteOrder: async () => 300_000_000_000_000_000n },
    [C.oracle]: {
      rawFor: async (asset, usd) => (usd * E18) / PRICE,
      latest: async () => [{ price18: PRICE, sourceUpdatedAt: BigInt(THU - 600), observedAt: BigInt(w.now - 60) }, 1n],
      assetOf: async () => ({ token: C.asset, params: { maxAge: 900n } }),
      priceUSD18: async () => [PRICE, BigInt(w.now - 60)],
      underlyingOf: async () => C.underlying,
    },
    [C.rewardOracle]: { priceUSD18: async () => [PRICE, BigInt(w.now - 60)] },
    [C.asset]: { decimals: async () => 18n },
  };
  const k = new RoundKeeper({
    cfg: { contracts: { roundManager: C.manager, batcher: C.batcher, stockRegistry: C.registry, rewardPriceOracle: C.rewardOracle }, round: {}, statusDir: tmp() },
    provider: null, journal: new Journal(join(tmp(), 'r.json')), logger: quietLogger, chainId: 5042, now: () => w.now,
    alert: async () => {}, lane: { name: 'fake', quoteMinOut6: async amt => (amt * 9_985n) / 10_000n / 10n ** 12n },
    quoteSigner: digestSignerFor(signer), contractAt: addr => fakes[addr],
    tx: {
      execute: true,
      call: async (key, contract, method, args) => {
        if (method !== 'executeAndStart') return { status: 'confirmed' };
        const [ids, maxBudget] = args;
        const p = preview(maxBudget); // RewardBatcher._executeBatch recomputes and checks FIFO
        if (JSON.stringify(p.ids.map(Number)) !== JSON.stringify(ids.map(Number))) { w.rejected.push('FIFO'); return { status: 'simulation-failed', error: new Error('FIFO') }; }
        if (p.total < MIN || p.total > runLimit) { w.rejected.push('cost or run limit'); return { status: 'simulation-failed', error: new Error('cost or run limit') }; }
        const roundId = w.rounds.length + 1;
        p.ids.forEach((id, i) => { w.pending.set(Number(id), p.budgets[i]); w.available.set(Number(id), w.available.get(Number(id)) - p.budgets[i]); });
        w.rounds.push({ roundId, ids: p.ids.map(Number), amounts: p.budgets, total: p.total, settled: false });
        const h = JSON.stringify([p.ids.map(String), p.budgets.map(String)]);
        w.nonces.set(h, (w.nonces.get(h) ?? 0n) + 1n); // reserveBatch: executionNonce[entriesHash]++ via the order
        const log = { address: C.manager, ...mgrIface.encodeEventLog('RoundState', [BigInt(roundId), 2]) };
        return { status: 'confirmed', receipt: { logs: [log] } };
      },
    },
  });
  k.manager = {
    target: C.manager, interface: mgrIface, nextEntryId: async () => BigInt(queue.length), groupKey: async () => '0x' + '33'.repeat(32),
    available: async id => w.available.get(Number(id)), pending: async id => w.pending.get(Number(id)) ?? 0n,
    minimumBudget: async () => MIN, runLimit: async () => runLimit, entry: async id => entry(Number(id)),
    executionNonce: async () => BigInt(w.rounds.length), // differs per round, as the contract's per-hash nonce does
  };
  k.batcher = { target: C.batcher, nextToEnqueue: async () => BigInt(queue.length + 1), cursor: async () => 0n, previewBatch: async (g, m) => preview(m) };
  k.registry = { resolve: async () => ({ asset: C.asset, underlying: C.underlying, hub: C.hub, adapter: C.adapter, fixedCost18: 0n }) };
  // Settle the open round (bought + finalized): the reserved slices are consumed, pending clears.
  const settle = () => {
    for (const r of w.rounds.filter(x => !x.settled)) { r.ids.forEach(id => w.pending.set(id, 0n)); r.settled = true; }
  };
  // Drive the keeper like the daemon: one tick, round settles, next tick ... (maxActiveRounds = 1, sequential).
  const run = async (maxTicks = 40) => {
    for (let t = 0; t < maxTicks; t++) {
      k.summary = { actions: [], deferred: [], seams: [] };
      const open = w.rounds.filter(x => !x.settled).length;
      const before = w.rounds.length;
      await k.batchPhase(open);
      w.now += 300;
      if (w.rounds.length === before) return { lastDeferred: k.summary.deferred, ticks: t + 1 };
      settle();
    }
    throw new Error('did not converge');
  };
  return { k, w, run, settle };
}

const sum = xs => xs.reduce((a, b) => a + b, 0n);
const left = w => sum([...w.available.values()]);

test('$1,800 budget at L_run $250: 8 rounds of $225, total = budget to the wei, nothing stuck (was 7 x $250 + $50 below the $100 minimum)', async () => {
  const budget = 1_800n * E18;
  const { w, run } = world({ budgets: [budget] });
  const end = await run();
  assert.equal(w.rejected.length, 0, w.rejected.join());
  assert.equal(w.rounds.length, 8);
  for (const r of w.rounds) {
    assert.ok(r.total <= 250n * E18 && r.total >= MIN, `round ${r.roundId} = ${r.total}`);
    assert.equal(r.total % USDC_GRID, 0n);
  }
  assert.equal(sum(w.rounds.map(r => r.total)), budget, 'rounds add up to the budget exactly');
  assert.equal(left(w), 0n, 'no wei left in the queue');
  assert.equal(end.lastDeferred[0]?.reason, 'Empty');
});

test('unaligned $1,800.000000000000000123 budget: every whole micro-USDC is bought; only the 123-wei sub-micro dust stays queued (hub takes whole 6-dp USDC)', async () => {
  const budget = 1_800n * E18 + 123n;
  const { w, run } = world({ budgets: [budget] });
  const end = await run();
  assert.equal(w.rejected.length, 0, w.rejected.join());
  assert.ok(w.rounds.every(r => r.total >= MIN && r.total <= 250n * E18 && r.total % USDC_GRID === 0n));
  assert.equal(sum(w.rounds.map(r => r.total)) + left(w), budget, 'bought + queued = budget to the wei');
  assert.equal(left(w), 123n, 'residual = budget mod 1e12 and stays available for the next round of the group');
  assert.match(end.lastDeferred[0]?.reason, /Empty|BelowMinimum/);
});

test('two coins in the same payout group ($1,800 + $30.5): FIFO across entries, all rounds within [$100, $250], sum exact', async () => {
  const budgets = [1_800n * E18, 30_500_000n * USDC_GRID];
  const { w, run } = world({ budgets });
  await run();
  assert.equal(w.rejected.length, 0);
  assert.equal(sum(w.rounds.map(r => r.total)), sum(budgets));
  assert.equal(left(w), 0n);
  assert.ok(w.rounds.every(r => r.total >= MIN && r.total <= 250n * E18));
  assert.deepEqual(w.rounds[0].ids, [1], 'oldest entry first');
});

test('an exact multiple keeps full-size rounds ($1,000 -> 4 x $250); $1,350 -> 6 x $225, never a $100 tail that fails the cost cap', async () => {
  const exact = world({ budgets: [1_000n * E18] });
  await exact.run();
  assert.deepEqual(exact.w.rounds.map(r => r.total / E18), [250n, 250n, 250n, 250n]);
  assert.equal(left(exact.w), 0n);
  const { w, run } = world({ budgets: [1_350n * E18] });
  await run();
  assert.deepEqual(w.rounds.map(r => r.total / E18), [225n, 225n, 225n, 225n, 225n, 225n]);
  assert.equal(left(w), 0n);
});

test('a budget that fits one order is one round (no split), and L_run raised to $1,000 takes $1,800 in 2 x $900', async () => {
  const one = world({ budgets: [240n * E18] });
  await one.run();
  assert.deepEqual(one.w.rounds.map(r => r.total), [240n * E18]);
  const big = world({ budgets: [1_800n * E18], runLimit: 1_000n * E18 });
  await big.run();
  assert.deepEqual(big.w.rounds.map(r => r.total / E18), [900n, 900n]);
});

test('L_run under 2 x minimum (guardian cut to $150): $160 queued -> one $150 round now (not 2 x $80 the contract refuses); $200 + 1 wei at L_run $200 -> $200, no $99.999999 tail', async () => {
  const low = world({ budgets: [160n * E18], runLimit: 150n * E18 });
  const end = await low.run();
  assert.equal(low.w.rejected.length, 0);
  assert.deepEqual(low.w.rounds.map(r => r.total), [150n * E18]);
  assert.equal(end.lastDeferred[0]?.reason, 'BelowMinimum', '$10 waits for more budget (as before the split)');
  const edge = world({ budgets: [200n * E18 + 1n], runLimit: 200n * E18 });
  await edge.run();
  assert.deepEqual(edge.w.rounds.map(r => r.total), [200n * E18]);
  assert.equal(left(edge.w), 1n);
  assert.equal(roundCap({ queued: 160n * E18, runLimit: 150n * E18, minimum: MIN }), 150n * E18);
  assert.equal(roundCap({ queued: 200n * E18 + 1n, runLimit: 200n * E18, minimum: MIN }), 200n * E18);
});

test('roundCap: L_run when the queue fits one order; otherwise ceil(queued / L_run) near-equal grid-aligned rounds, never above L_run', () => {
  const L = 250n * E18;
  assert.equal(roundCap({ queued: 200n * E18, runLimit: L }), L);
  assert.equal(roundCap({ queued: 1_000n * E18, runLimit: L }), L);
  assert.equal(roundCap({ queued: 1_350n * E18, runLimit: L }), 225n * E18);
  assert.equal(roundCap({ queued: 1_800n * E18, runLimit: L }), 225n * E18);
  assert.equal(roundCap({ queued: 260n * E18, runLimit: L }), 130n * E18);
  const odd = roundCap({ queued: 1_800n * E18 + 123n, runLimit: L });
  assert.equal(odd % USDC_GRID, 0n);
  assert.ok(odd <= L && odd * 8n >= 1_800n * E18);
  assert.equal(roundCap({ queued: 1_800n * E18, runLimit: L + 7n }), 225n * E18, 'runLimit floored to the grid first');
});

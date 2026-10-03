// r13 (path 2a) keepers: Relay deposit-quote validation, launcher, vault worker, refund keeper, canonical keeper,
// float watch. Chain contracts are in-memory fakes; the quote fixtures are real api.relay.link responses (2026-10-01).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Interface, Wallet, AbiCoder, keccak256, toUtf8Bytes, getAddress } from 'ethers';
import { validateDepositQuote, planRouteFee, RelayRejected } from '../lib/relay.mjs';
import { makeMockRelayClient } from '../lib/relay-mock.mjs';
import { digestSigner } from '../lib/signer.mjs';
import { Journal } from '../lib/journal.mjs';
import { RelayRouterAbi, FundingRouteAbi, RelayDepositoryAbi, HubStatus } from '../lib/abis.mjs';
import { Launcher, SchedulerFundingLane, Queued, ref32 } from '../launcher/keeper.mjs';
import { VaultWorker } from '../vault/keeper.mjs';
import { RefundKeeper, refundNeed } from '../refund/keeper.mjs';
import { CanonicalKeeper } from '../canonical/keeper.mjs';
import { decideFloat, FLOAT_DEFAULTS } from '../float/watch.mjs';
import { RoundKeeper } from '../round/keeper.mjs';
import { leafOf, rootOf } from '../lib/merkle.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const fx = name => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));
const E18 = 10n ** 18n, SCALE = 10n ** 12n;
const A = n => getAddress('0x' + String(n).repeat(40));
const HUB = A(1), VAULT = A(2), SCHED = A(3), ROUTE = A(4), DEPO = getAddress('0x4cD00E387622C35bDDB9b4c962C136462338BC31'), ROUTER = getAddress('0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f');
const USDG = getAddress('0x5fc5360d0400a0fd4f2af552add042d716f1d168');
const NATIVE = '0x0000000000000000000000000000000000000000';
const ARC_USDC = '0x3600000000000000000000000000000000000000';
const signerWallet = new Wallet(keccak256(toUtf8Bytes('r13-test-signer')));
const quoteSigner = digestSigner(signerWallet);
const journal = () => new Journal(join(tmp(), 'j.json'));
const collect = () => { const a = []; const f = async (k, t) => a.push({ k, t }); f.list = a; return f; };

// ---------------------------------------------------------------- quote validation (real responses)
test('validateDepositQuote: real Arc->RH 2a quote (orderId, payment 6 dp, plain transfer to the vault)', () => {
  const { request: rq, response } = fx('relay-2a-arc-rh.json');
  const q = validateDepositQuote(response, { ...rq, amount: BigInt(rq.amount), nativeScale: SCALE, paymentCurrency: ARC_USDC });
  assert.equal(q.orderId, response.protocol.v2.orderId);
  assert.notEqual(q.orderId, q.requestId); // N2: the deposit id is the orderId, not the API request id
  assert.ok(q.expectedOut > 998n * 10n ** 6n && q.expectedOut < 1000n * 10n ** 6n);
});

test('validateDepositQuote: real RH->Arc return quote (USDG in, native USDC to the hub, no calls)', () => {
  const { request: rq, response } = fx('relay-2a-rh-arc.json');
  const q = validateDepositQuote(response, { ...rq, amount: BigInt(rq.amount), nativeScale: 1n });
  assert.ok(q.expectedOut > 499n * E18);
});

test('validateDepositQuote rejects destination calls, foreign recipients/refunds, amount mismatch, lifi, no orderId', () => {
  const { request: rq, response } = fx('relay-2a-arc-rh.json');
  const exp = { ...rq, amount: BigInt(rq.amount), nativeScale: SCALE, paymentCurrency: ARC_USDC };
  const mutate = f => { const c = structuredClone(response); f(c); return c; };
  const od = c => c.protocol.v2.orderData;
  const cases = [
    ['calls', c => { od(c).output.calls = [{ to: A(9), data: '0x' }]; }, /destination calls/],
    ['recipient', c => { od(c).output.payments[0].recipient = A(9); }, /output recipient/],
    ['currency', c => { od(c).output.payments[0].currency = A(9); }, /output currency/],
    ['two payments', c => { od(c).output.payments.push(od(c).output.payments[0]); }, /one output payment/],
    ['refund', c => { od(c).inputs[0].refunds[0].recipient = A(9); }, /origin refund recipient/],
    ['amount', c => { od(c).inputs[0].payment.amount = '1'; }, /payment amount/],
    ['lifi', c => { c.steps[0].id = 'lifiIntents'; }, /lifi/],
    ['orderId', c => { delete c.protocol.v2.orderId; }, /orderId/],
    ['chain', c => { od(c).inputs[0].payment.chainId = 'base'; }, /payment chain/],
    ['payment currency', c => { od(c).inputs[0].payment.currency = NATIVE; }, /payment currency/],
  ];
  for (const [name, f, re] of cases) assert.throws(() => validateDepositQuote(mutate(f), exp), e => e instanceof RelayRejected && re.test(e.message), name);
  assert.throws(() => validateDepositQuote(response, { ...exp, minOut: 2_000n * 10n ** 6n }), /expected out/);
});

test('planRouteFee: whole 6-dp fee so the expected output covers the principal; CostLimit beyond the reserve', async () => {
  const quoteOut = async a => (a * 9992n) / 10_000n / SCALE - 10_000n; // 8 bps + $0.01
  const p = await planRouteFee({ amountIn: 1_000n * E18, needOut: 1_000n * 10n ** 6n, quoteOut, grid: SCALE });
  assert.equal(p.fee % SCALE, 0n);
  assert.ok(p.expectedOut >= 1_000n * 10n ** 6n);
  assert.ok(p.fee < 2n * E18, `fee ${p.fee}`);
  assert.equal((await planRouteFee({ amountIn: 1_000n * E18, needOut: 1_000n * 10n ** 6n, quoteOut, grid: SCALE, maxFee: 10n ** 17n })).defer, 'CostLimit');
});

// ---------------------------------------------------------------- launcher
const coder = AbiCoder.defaultAbiCoder();
const routeIface = new Interface(FundingRouteAbi), depoIface = new Interface(RelayDepositoryAbi);

function order(over = {}) {
  return { user: A(7), underlying: A(8), kind: 0, status: HubStatus.Pending, createdAt: 900, settledAt: 0, amountIn: 1_000n * E18 - 2_500_000_000_000_000_000n, minOut: 1n,
    amountOut: 0n, fee: 0n, rawOut: 0n, lzSettled: false, orphaned: false, dispatchedAt: 0, lane: 0, feeBps: 25, cancelRequested: false, disputed: false, advanced: false,
    outcome: 0, route: ROUTE, extra: 3n * E18, held: 0n, owed: 0n, custodyRaw: 0n, refundReady: 0n, capKey: '0x' + '00'.repeat(32), voided: false, ...over };
}

function launcherFixture({ orders, extraLz = 2n * 10n ** 17n, txStatus = 'confirmed', relay = makeMockRelayClient(), nativeDeposit = false } = {}) {
  const sent = [];
  const queue = [...orders.keys()];
  const hub = {
    target: HUB,
    getOrder: async id => orders.get(Number(id)),
    quoteDispatch: async () => extraLz,
    openOrders: async () => [...orders.keys()].filter(id => orders.get(id).status !== HubStatus.Cancelled).map(BigInt),
  };
  const scheduler = {
    target: SCHED, interface: new Interface(['function launchNext(uint256,bytes)']),
    nextLaunch: async () => { const id = queue.find(i => orders.get(i).status === HubStatus.Pending); return id == null ? [false, 0, 0n] : [true, orders.get(id).lane, BigInt(id)]; },
    queueLength: async () => [BigInt(queue.length), 0n],
  };
  const route = {
    target: ROUTE,
    quoteDigest: async (ref, amountIn, fee, minOut, q) => keccak256(coder.encode(['bytes32', 'uint256', 'uint256', 'uint256', 'bytes32', 'uint256', 'uint256'], [ref, amountIn, fee, minOut, q.requestId, q.deadline, q.nonce])),
  };
  const tx = {
    execute: true,
    reconcileAll: async () => [],
    async call(key, contract, method, args, opts = {}) {
      sent.push({ key, to: contract.target, method, args, value: opts.value ?? 0n });
      if (method !== 'launchNext' || txStatus !== 'confirmed') return { status: txStatus };
      const [id, routeData] = args;
      const o = orders.get(Number(id));
      const [fee, quote] = coder.decode(['uint256', 'bytes'], routeData);
      const [[requestId]] = coder.decode(['tuple(bytes32,uint256,uint256)', 'bytes'], quote);
      o.status = o.extra - fee >= extraLz ? HubStatus.Dispatched : HubStatus.Funded;
      const logs = [
        { address: ROUTE, ...routeIface.encodeEventLog('Sent', [ref32(id), requestId, o.amountIn, fee, o.amountIn / SCALE]) },
        nativeDeposit // pre-r14 route shape (Relay: ORIGIN_CURRENCY_MISMATCH)
          ? { address: DEPO, ...depoIface.encodeEventLog('RelayNativeDeposit', [HUB, o.amountIn + fee, requestId]) }
          : { address: DEPO, ...depoIface.encodeEventLog('RelayErc20Deposit', [HUB, ARC_USDC, (o.amountIn + fee) / SCALE, requestId]) },
      ];
      return { status: 'confirmed', receipt: { hash: '0x' + 'aa'.repeat(32), logs } };
    },
  };
  const alert = collect();
  const j = journal();
  const L = new Launcher({ cfg: { contracts: { stockHub: HUB, scheduler: SCHED, reserveVault: VAULT }, relay: { rhUsdg: USDG } }, provider: null, tx, journal: j, logger: quietLogger, alert, relayClient: relay, quoteSigner, chainId: 5042, now: () => 1_000 });
  L.hub = hub; L.scheduler = scheduler;
  L.routes.set(ROUTE, { contract: route, depository: DEPO, nativeToken: getAddress(ARC_USDC) });
  return { L, sent, alert, j, relay, orders };
}

test('launcher: Relay orderId signed as the route requestId; fee from the reserve, LZ fee kept; deposit verified', async () => {
  const orders = new Map([[0, order()]]);
  const { L, sent, alert, j, relay } = launcherFixture({ orders });
  const sum = await L.tick();
  const launch = sent.find(s => s.method === 'launchNext');
  assert.ok(launch, JSON.stringify(sum, (_, v) => (typeof v === 'bigint' ? v.toString() : v)));
  const [fee, quote] = coder.decode(['uint256', 'bytes'], launch.args[1]);
  const [[requestId, deadline], sig] = coder.decode(['tuple(bytes32,uint256,uint256)', 'bytes'], quote);
  const last = relay.quotes.at(-1);
  assert.equal(requestId, last.orderId);
  assert.equal(BigInt(last.body.amount), orders.get(0).amountIn + fee); // the quote is for exactly what the route deposits
  assert.equal(last.body.user, HUB); assert.equal(last.body.recipient, VAULT);
  assert.equal(fee % SCALE, 0n);
  assert.ok(fee <= 3n * E18 - (2n * 10n ** 17n * 11n) / 10n);
  assert.equal(deadline, 1_300n);
  assert.ok(sig.length > 2);
  const rec = j.record('launches', '0');
  assert.equal(rec.status, 'Dispatched');
  assert.equal(rec.deposit.id, last.orderId);
  assert.equal(alert.list.length, 0, JSON.stringify(alert.list));
});

test('launcher r14: deposit proof is RelayErc20Deposit(hub, 0x3600, total/1e12, orderId); a native deposit is flagged', async () => {
  {
    const orders = new Map([[0, order()]]);
    const { L, j, alert } = launcherFixture({ orders });
    await L.tick();
    const rec = j.record('launches', '0');
    const fee = BigInt(rec.fee);
    assert.equal(rec.deposit.event, 'RelayErc20Deposit');
    assert.equal(getAddress(rec.deposit.token), getAddress(ARC_USDC));
    assert.equal(BigInt(rec.deposit.amount), (orders.get(0).amountIn + fee) / SCALE);
    assert.equal(alert.list.length, 0);
  }
  {
    const orders = new Map([[0, order()]]);
    const { L, alert } = launcherFixture({ orders, nativeDeposit: true });
    await L.tick();
    assert.ok(alert.list.some(a => /Relay deposit check failed: no depository deposit event/.test(a.t)), JSON.stringify(alert.list));
  }
});

test('launcher r14: a pre-r14 route (no nativeToken) is refused before signing; an r14 route is accepted', async () => {
  const orders = new Map([[0, order()]]);
  const { L, sent } = launcherFixture({ orders });
  const fake = nativeToken => ({ target: ROUTE, signer: async () => signerWallet.address, caller: async () => HUB, destination: async () => VAULT, depository: async () => DEPO, nativeToken });
  L.routes.clear();
  L.makeRoute = () => fake(async () => { throw new Error('missing selector'); });
  await assert.rejects(L.route(ROUTE), /pre-r14 route/);
  L.makeRoute = () => fake(async () => NATIVE);
  await assert.rejects(L.route(ROUTE), /pre-r14 route/);
  L.makeRoute = () => fake(async () => ARC_USDC);
  assert.equal((await L.route(ROUTE)).nativeToken, getAddress(ARC_USDC));
  assert.equal(sent.length, 0);
});

test('launcher: reserve smaller than the Relay fee -> launched anyway (float absorbs), shortfall alert; LZ unpaid -> keeper dispatch', async () => {
  const orders = new Map([[0, order({ extra: 2n * 10n ** 17n })]]);
  const { L, sent, alert } = launcherFixture({ orders, extraLz: 25n * 10n ** 16n, relay: makeMockRelayClient({ feeBps: 40n }) });
  await L.tick();
  assert.ok(sent.find(s => s.method === 'launchNext'));
  assert.ok(alert.list.some(a => /bps under the principal/.test(a.t)), JSON.stringify(alert.list));
  assert.ok(sent.find(s => s.method === 'dispatch'), 'Funded public buy dispatched by the keeper');
});

test('launcher: Relay shortfall above 1% defers the launch; alert after 3 failures; never signs', async () => {
  const orders = new Map([[0, order({ extra: 0n })]]);
  const { L, sent, alert, j } = launcherFixture({ orders, extraLz: 0n, relay: makeMockRelayClient({ feeBps: 200n }) });
  for (let i = 0; i < 3; i++) await L.tick();
  assert.equal(sent.filter(s => s.method === 'launchNext').length, 0);
  assert.equal(j.record('launches', '0').failures, 3);
  assert.match(alert.list.at(-1).t, /not launched after 3 tries: deferred: RelayShortfall/);
});

test('launcher: fill watch alerts on a refunded / slow Relay request', async () => {
  const statuses = new Map();
  const relay = makeMockRelayClient({ statuses, defaultStatus: 'pending' });
  const orders = new Map([[0, order()]]);
  const { L, alert, j } = launcherFixture({ orders, relay });
  await L.tick();
  const rid = j.record('launches', '0').relayRequestId;
  statuses.set(rid, 'refund');
  await L.watchFills();
  assert.ok(alert.list.some(a => /refund/.test(a.t)));
});

test('scheduler lane (round keeper): a reward order still queued is a quiet not-sent; launched -> sent', async () => {
  const capKey = '0x' + 'cd'.repeat(32);
  const orders = new Map([[0, order()], [1, order({ lane: 1, capKey })]]);
  const { L } = launcherFixture({ orders });
  L.p.maxPerTick = 1; // only the public head this tick
  const lane = new SchedulerFundingLane({ launcher: L, hub: L.hub });
  await assert.rejects(lane.dispatch({ orderId: capKey }), e => e instanceof Queued && e.quiet && e.sent === false);
  const out = await lane.dispatch({ orderId: capKey });
  assert.equal(out.lane, 'scheduler');
  assert.ok(out.requestId);
  // round keeper: quiet -> no alert
  const alerts = collect();
  const rk = new RoundKeeper({ cfg: { contracts: { roundManager: A(5), batcher: A(6), stockRegistry: A(9) }, round: {} }, provider: null, tx: { execute: true }, journal: journal(), logger: quietLogger, alert: alerts, lane: { name: 'scheduler', dispatch: async () => { throw new Queued('x'); } }, chainId: 5042, now: () => 1 });
  rk.summary = { actions: [], deferred: [], seams: [] };
  await rk.dispatchFunding(1, { orderId: capKey, budget18: 100n * E18 }, {});
  assert.equal(alerts.list.length, 0);
  assert.equal(rk.summary.actions[0].status, 'queued');
});

// ---------------------------------------------------------------- refund keeper
test('refundNeed: failed buy -> principal less held; Proceeds sell -> gross after RH return only; others none', () => {
  const fb = order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18, held: 0n });
  assert.deepEqual(refundNeed(fb), { kind: 'failed-buy', credit: 500n * E18 });
  assert.equal(refundNeed({ ...fb, held: 300n * E18 }), null); // >= half back: closes on its own
  const sell = order({ kind: 1, status: HubStatus.Proceeds, amountOut: 99n * E18, fee: E18 / 4n });
  assert.deepEqual(refundNeed(sell, { rhProceeds: 5n }), { kind: 'proceeds', wait: 'RH proceeds not returned yet' });
  assert.deepEqual(refundNeed(sell, { rhProceeds: 0n }), { kind: 'proceeds', credit: 99n * E18 + E18 / 4n });
  assert.equal(refundNeed(order({ status: HubStatus.Dispatched })), null);
});

function refundFixture({ orders, available = 2_000n * E18, self = A(6) }) {
  const sent = [];
  const hub = {
    target: HUB,
    floatRecipientA: async () => A(9), floatRecipientB: async () => self,
    openOrders: async () => [...orders.keys()].map(BigInt),
    getOrder: async id => orders.get(Number(id)),
    available: async () => available,
    interface: new Interface(['function withdrawFloat(address,uint256)', 'function fundFloat()']),
  };
  const tx = {
    execute: true, reconcileAll: async () => [],
    async call(key, contract, method, args, opts = {}) { sent.push({ key, method, args, value: opts.value }); if (method === 'withdrawFloat') available -= args[1]; return { status: 'confirmed', receipt: { hash: '0x01' } }; },
    async send(req) {
      sent.push({ ...req, method: 'multicall' });
      const id = Number(BigInt(new Interface(FundingRouteAbi).decodeFunctionData('receiveReturnFor', new Interface(RelayRouterAbi).decodeFunctionData('multicall', req.data)[0][0][3])[0]));
      const o = orders.get(id); o.status = HubStatus.Cancelled; o.held = 0n;
      return { status: 'confirmed', receipt: { hash: '0x02' } };
    },
  };
  const alert = collect();
  const K = new RefundKeeper({ cfg: { contracts: { stockHub: HUB }, relay: { relayRouter: ROUTER } }, provider: null, tx, journal: journal(), logger: quietLogger, alert, wallet: { address: self }, chainId: 5042, now: () => 86_400 * 3 });
  K.hub = hub;
  K.vault = { proceeds: async () => 0n };
  // route.returnExecutor() view
  const origCredit = K.creditBack.bind(K);
  K.creditBack = async (id, routeAddr, amount, tag) => {
    const route = { target: routeAddr, returnExecutor: async () => ROUTER };
    const call = [route.target, false, amount, new Interface(FundingRouteAbi).encodeFunctionData('receiveReturnFor', [ref32(id)])];
    const data = new Interface(RelayRouterAbi).encodeFunctionData('multicall', [[call], self, self, '0x']);
    const res = await tx.send({ key: K.key(`refund:${id}:credit`), to: ROUTER, data, value: amount });
    K.journal.setRecord('refunds', String(id), { done: true, creditTx: res.receipt.hash });
    void origCredit;
  };
  return { K, sent, alert, orders };
}

test('refund keeper: failed buy -> withdrawFloat(self, principal) then router.multicall(route.receiveReturnFor(ref)) once', async () => {
  const orders = new Map([[5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18 })]]);
  const { K, sent } = refundFixture({ orders });
  await K.tick();
  assert.deepEqual(sent.map(s => s.method), ['withdrawFloat', 'multicall']);
  assert.equal(sent[0].args[1], 500n * E18);
  assert.equal(sent[1].value, 500n * E18);
  assert.equal(sent[1].to, ROUTER);
  await K.tick();
  assert.equal(sent.length, 2, 'idempotent');
});

test('refund keeper: hub float short or daily cap -> alert, nothing sent; not a float recipient -> refuses', async () => {
  const orders = new Map([[5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18 })]]);
  const a = refundFixture({ orders, available: 100n * E18 });
  await a.K.tick();
  assert.equal(a.sent.length, 0);
  assert.match(a.alert.list[0].t, /rebalance RH -> Arc/);
  const b = refundFixture({ orders: new Map([[5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 2_500n * E18 })]]), available: 5_000n * E18 });
  await b.K.tick();
  assert.equal(b.sent.length, 0);
  assert.match(b.alert.list[0].t, /daily cap/);
  const c = refundFixture({ orders });
  c.K.self = A(3);
  await assert.rejects(c.K.tick(), /not a hub float recipient/);
});

// Mainnet (10-02): HUB_FLOAT_B is a refund-only wallet, not the hub keeper. The hub keeper signs
// withdrawFloat(refund wallet, principal) (only keeper/owner may), the refund wallet signs the Relay credit-back; a
// leaked hub keeper key can only move float to the refund wallet, a leaked refund key only what is in flight.
test('refund keeper (split wallets): hub keeper withdraws to the refund wallet; the refund wallet credits back and refills', async () => {
  const KEEPER = A(4), REFUND = A(6);
  const orders = new Map([[5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18 })]]);
  let available = 2_000n * E18;
  const hub = {
    target: HUB, keeper: async () => KEEPER,
    floatRecipientA: async () => A(9), floatRecipientB: async () => REFUND,
    openOrders: async () => [...orders.keys()].map(BigInt),
    getOrder: async id => orders.get(Number(id)),
    available: async () => available,
  };
  const log = [];
  const mk = who => ({
    execute: true, reconcileAll: async () => { log.push({ who, method: 'reconcile' }); return []; },
    async call(key, contract, method, args, opts = {}) { log.push({ who, method, args, value: opts.value }); if (method === 'withdrawFloat') available -= args[1]; return { status: 'confirmed', receipt: { hash: '0x01' } }; },
    async send(req) {
      log.push({ who, method: 'multicall', to: req.to, value: req.value, data: req.data });
      const o = orders.get(5); o.status = HubStatus.Cancelled; o.held = 0n;
      return { status: 'confirmed', receipt: { hash: '0x02' } };
    },
  });
  const K = new RefundKeeper({ cfg: { contracts: { stockHub: HUB }, relay: { relayRouter: ROUTER } }, provider: null, tx: mk('keeper'), journal: journal(), logger: quietLogger,
    alert: collect(), wallet: { address: KEEPER }, payer: { wallet: { address: REFUND }, tx: mk('refund') }, chainId: 5042, now: () => 86_400 * 3 });
  K.hub = hub;
  K.vault = { proceeds: async () => 0n };
  K.routeAt = addr => ({ target: addr, returnExecutor: async () => ROUTER });
  await K.tick();
  const acts = log.filter(l => l.method !== 'reconcile');
  assert.deepEqual(acts.map(l => `${l.who}:${l.method}`), ['keeper:withdrawFloat', 'refund:multicall']);
  assert.equal(acts[0].args[0], REFUND, 'float goes to the refund wallet, never to the hub keeper');
  assert.equal(acts[1].value, 500n * E18);
  const mc = new Interface(RelayRouterAbi).decodeFunctionData('multicall', acts[1].data);
  assert.equal(mc[1], REFUND); assert.equal(mc[2], REFUND);
  assert.deepEqual([...new Set(log.filter(l => l.method === 'reconcile').map(l => l.who))].sort(), ['keeper', 'refund']);
  // An unused withdrawal (order closed some other way) is refilled by the wallet that holds it.
  K.journal.setRecord('refunds', '7', { withdrawn: (10n * E18).toString() });
  orders.set(7, order({ status: HubStatus.Cancelled }));
  log.length = 0;
  await K.tick();
  assert.deepEqual(log.filter(l => l.method === 'fundFloat').map(l => l.who), ['refund']);
  // The withdraw signer must be the hub keeper.
  hub.keeper = async () => A(3);
  await assert.rejects(K.tick(), /not the hub keeper/);
});

// Runbook §7.6 / launch gate 10-02: a refund request (failed buy Returning, unpaid sell Proceeds) still open 30 minutes
// after it entered that state alerts on its own, whatever blocked it. now() = 86_400 * 3 in refundFixture.
test('refund keeper: Returning / Proceeds open > 30 min -> refund-overdue alert; younger, just-closed or Dispatched -> none', async () => {
  const NOW = 86_400 * 3, MIN = 60;
  // Float short: nothing can be sent, the order stays Returning 31 min -> float alert AND overdue alert.
  const a = refundFixture({ orders: new Map([[5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18, settledAt: NOW - 31 * MIN })]]), available: 100n * E18 });
  const sa = await a.K.tick();
  assert.deepEqual(a.alert.list.map(x => x.k), ['refund-float-5', 'refund-overdue-5']);
  assert.match(a.alert.list[1].t, /order 5 failed buy \(Returning\) 500 USDC not refunded after 31 min \(limit 30\)/);
  assert.deepEqual(sa.overdue, [{ id: 5, status: 'Returning', ageMin: 31 }]);
  // Same order 29 min old: float alert only.
  const b = refundFixture({ orders: new Map([[5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18, settledAt: NOW - 29 * MIN })]]), available: 100n * E18 });
  const sb = await b.K.tick();
  assert.deepEqual(b.alert.list.map(x => x.k), ['refund-float-5']);
  assert.equal(sb.overdue, undefined);
  // 40 min old but refunded in this very tick (float back): no overdue alert.
  const c = refundFixture({ orders: new Map([[5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18, settledAt: NOW - 40 * MIN })]]) });
  await c.K.tick();
  assert.deepEqual(c.sent.map(x => x.method), ['withdrawFloat', 'multicall']);
  assert.deepEqual(c.alert.list, []);
  // Sell in Proceeds 45 min, RH proceeds not back: the 15-min proceeds alert and the 30-min overdue alert.
  const d = refundFixture({ orders: new Map([[8, order({ kind: 1, status: HubStatus.Proceeds, amountOut: 99n * E18, fee: E18 / 4n, settledAt: NOW - 45 * MIN })]]) });
  d.K.vault = { proceeds: async () => 5n };
  await d.K.tick();
  assert.deepEqual(d.alert.list.map(x => x.k), ['proceeds-8', 'refund-overdue-8']);
  assert.match(d.alert.list[1].t, /unpaid sell \(Proceeds\) 99 USDC not refunded after 45 min/);
  // Over the per-tick refund budget the order is not worked this tick, but still watched.
  const e = refundFixture({ orders: new Map([[5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18, settledAt: NOW - 31 * MIN })]]) });
  e.K.p.maxPerTick = 0;
  await e.K.tick();
  assert.equal(e.sent.length, 0);
  assert.deepEqual(e.alert.list.map(x => x.k), ['refund-overdue-5']);
  // Dispatched for 2 h is the LayerZero alert's business (lz-<id>), not a refund request.
  const f = refundFixture({ orders: new Map([[6, order({ status: HubStatus.Dispatched, dispatchedAt: NOW - 120 * MIN, settledAt: 0 })]]) });
  await f.K.tick();
  assert.deepEqual(f.alert.list.map(x => x.k), ['lz-6']);
  // Configurable (cfg.refund.params.refundOverdueSec).
  const g = refundFixture({ orders: new Map([[5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18, settledAt: NOW - 11 * MIN })]]), available: 100n * E18 });
  g.K.p.refundOverdueSec = 10 * MIN;
  await g.K.tick();
  assert.ok(g.alert.list.some(x => x.k === 'refund-overdue-5' && /limit 10/.test(x.t)));
});

test('refund keeper: one order whose refund throws does not hide the next order\'s overdue alert; the tick still fails', async () => {
  const NOW = 86_400 * 3;
  const orders = new Map([
    [5, order({ status: HubStatus.Returning, outcome: 3, amountIn: 500n * E18, settledAt: NOW - 40 * 60 })],
    [6, order({ status: HubStatus.Returning, outcome: 3, amountIn: 300n * E18, settledAt: NOW - 50 * 60 })]]);
  const { K, alert } = refundFixture({ orders });
  K.credit = async id => { if (Number(id) === 5) throw new Error('rpc timeout'); };
  await assert.rejects(K.tick(), /rpc timeout/);
  assert.deepEqual(alert.list.map(x => x.k), ['refund-overdue-5', 'refund-overdue-6']);
});

// ---------------------------------------------------------------- vault worker
test('vault worker: executes a waiting buy once fundable; returns proceeds with a signed orderId quote', async () => {
  const REF = ref32(9), REF2 = ref32(10);
  const sent = [];
  const st = { settled: { [REF]: false, [REF2]: true }, funding: {}, proceeds: { [REF2]: 498_250_000n }, free: 3_000n * 10n ** 6n };
  const vault = {
    target: VAULT,
    interface: new Interface(['event OrderWaitingFunds(bytes32 indexed ref, uint256 needed, uint256 funded)', 'event OrderExecuted(bytes32 indexed ref, address indexed underlying, uint8 outcome, uint128 amountIn, uint128 amountOut, uint64 seq, string reason)']),
    floatEnabled: async () => true, freeSettlement: async () => st.free,
    settled: async r => st.settled[r], waitingOrder: async () => ({ underlying: A(8), amountIn: 1_000n * 10n ** 6n }),
    funding: async r => st.funding[r] ?? 0n, proceeds: async r => st.proceeds[r] ?? 0n,
    settlement: async () => USDG, returnRoute: async () => ROUTE,
  };
  const tx = { execute: true, reconcileAll: async () => [], async call(key, c, method, args) { sent.push({ method, args }); if (method === 'returnFunds') st.proceeds[REF2] = 0n; return { status: 'confirmed' }; } };
  const relay = makeMockRelayClient();
  const W = new VaultWorker({ cfg: { contracts: { reserveVault: VAULT, stockHub: HUB } }, provider: { getBlockNumber: async () => 10, getLogs: async () => [] }, tx, journal: journal(), logger: quietLogger, alert: collect(), relayClient: relay, quoteSigner, chainId: 4663, now: () => 50 });
  W.vault = vault;
  W.route = { quoteDigest: async () => keccak256('0x01') };
  W.journal.setRecord('waiting', REF, { seenAt: 1 });
  W.journal.setRecord('returnable', REF2, { outcome: 1 });
  const sum = await W.tick();
  assert.deepEqual(sent.map(s => s.method), ['executeFunded', 'returnFunds'], JSON.stringify(sum, (_, v) => (typeof v === 'bigint' ? v.toString() : v)));
  const [ref, minOut, quote] = sent[1].args;
  assert.equal(ref, REF2);
  const [[requestId]] = AbiCoder.defaultAbiCoder().decode(['tuple(bytes32,uint256,uint256)', 'bytes'], quote);
  assert.equal(requestId, relay.quotes[0].orderId);
  assert.equal(relay.quotes[0].body.user, VAULT); assert.equal(relay.quotes[0].body.recipient, HUB);
  assert.equal(minOut, relay.quotes[0].out);
  await W.tick();
  assert.equal(sent.length, 2, 'returned once; executed once');
});

// ---------------------------------------------------------------- canonical keeper
test('canonical keeper: reconciles every hub result of a gate checkpoint with a proof against its root; age alerts', async () => {
  const results = Array.from({ length: 5 }, (_, i) => ({ ref: ref32(i), underlying: A(8), outcome: i === 3 ? 2 : 0, amountIn: 100n, amountOut: 5n, seq: BigInt(i) }));
  const root = rootOf(results.slice(0, 5).map(leafOf));
  const reconciled = new Set();
  const calls = [];
  const arcTx = { reconcileAll: async () => [], async call(key, c, method, args) { calls.push({ method, args }); if (method === 'reconcile') reconciled.add(args[0][0]); return { status: 'confirmed' }; } };
  const rhTx = { reconcileAll: async () => [], async call(key, c, method) { calls.push({ method }); return { status: 'confirmed' }; } };
  const alert = collect();
  const K = new CanonicalKeeper({ cfg: { contracts: { stockHub: HUB, canonicalGate: A(5), reserveVault: VAULT } }, arc: { provider: null, tx: arcTx, chainId: 5042 }, rh: { provider: { getBlockNumber: async () => 1, getLogs: async () => [] }, tx: rhTx, chainId: 4663 }, journal: journal(), logger: quietLogger, alert, now: () => 9 * 86_400 });
  K.vault = { target: VAULT, interface: new Interface(['event OrderExecuted(bytes32 indexed ref, address indexed underlying, uint8 outcome, uint128 amountIn, uint128 amountOut, uint64 seq, string reason)', 'event Checkpointed(uint64 fromSeq, uint64 toSeq, bytes32 root)']),
    resultCount: async () => 6n, checkpointedThrough: async () => 5n, resultAt: async s => results[Number(s)] };
  K.gate = { checkpointCount: async () => 1n, checkpointAt: async () => ({ root, fromSeq: 0n, toSeq: 4n }) };
  K.hub = { target: HUB, orderCount: async () => 4n, reconciled: async r => reconciled.has(r), mintsHalted: async () => false, unreconciledCount: async () => BigInt(4 - reconciled.size) };
  K.journal.setRecord('results', '0', { ref: ref32(0), at: 1 });
  await K.tick();
  const rec = calls.filter(c => c.method === 'reconcile');
  assert.equal(rec.length, 4, 'orders 0..3 (seq 4 = ref 4 is not a hub order)');
  for (const c of rec) {
    // recompute the root from leaf + proof the way MerkleProof (sorted pairs) does
    const [ref, underlying, outcome, amountIn, amountOut, seq] = c.args[0];
    let h = leafOf({ ref, underlying, outcome, amountIn, amountOut, seq });
    for (const p of c.args[2]) h = BigInt(h) < BigInt(p) ? keccak256(h + p.slice(2)) : keccak256(p + h.slice(2));
    assert.equal(h, root);
  }
  assert.ok(calls.some(c => c.method === 'checkpoint'), 'result 5 pending -> RH checkpoint');
  // a result older than 7 days still unproven -> critical
  reconciled.clear();
  K.hub.reconciled = async () => false;
  K.hub.unreconciledCount = async () => 1n;
  await K.watchPhase();
  assert.ok(alert.list.some(a => /CRITICAL/.test(a.t)), JSON.stringify(alert.list));
});

// ---------------------------------------------------------------- float watch
test('decideFloat: thresholds, drift and a whole-dollar rebalance suggestion in the right direction', () => {
  const base = { hub: HUB, vault: VAULT, rhFloatOn: true, hubFloatOn: true, returning: 0, proceeds: 0, rhWaiting: 0 };
  const ok = decideFloat({ ...base, rhFree6: 3_000n * 10n ** 6n, arcAvail18: 2_000n * E18 }, FLOAT_DEFAULTS);
  assert.equal(ok.alerts.length, 0); assert.equal(ok.suggestion, null);
  const skew = decideFloat({ ...base, rhFree6: 4_000n * 10n ** 6n, arcAvail18: 900n * E18, returning: 1 }, FLOAT_DEFAULTS);
  assert.ok(skew.alerts.some(a => a.key === 'arc-low'));
  assert.deepEqual([skew.suggestion.dir, skew.suggestion.usd], ['RH->Arc', 1000]);
  const drift = decideFloat({ ...base, rhFree6: 2_500n * 10n ** 6n, arcAvail18: 2_000n * E18, rhFloatOn: false }, FLOAT_DEFAULTS);
  assert.ok(drift.alerts.some(a => a.key === 'drift') && drift.alerts.some(a => a.key === 'rh-off'));
  assert.equal(drift.suggestion, null); // 500 short on RH but Arc has no excess
});

// Runbook §1.4 #4: the ReserveVault gets only 0.01 ETH at launch (~100 LZ result messages); refill on this alert.
test('decideFloat: ReserveVault ETH below the low-water mark (LZ result fees) -> warn', () => {
  const base = { hub: HUB, vault: VAULT, rhFloatOn: true, hubFloatOn: true, returning: 0, proceeds: 0, rhWaiting: 0, rhFree6: 3_000n * 10n ** 6n, arcAvail18: 2_000n * E18 };
  assert.equal(decideFloat({ ...base, vaultEthWei: 10n ** 16n }, FLOAT_DEFAULTS).alerts.length, 0);
  const low = decideFloat({ ...base, vaultEthWei: 2n * 10n ** 15n }, FLOAT_DEFAULTS);
  assert.ok(low.alerts.some(a => a.key === 'vault-eth-low' && a.level === 'warn' && /0\.0020 ETH/.test(a.text)));
  assert.equal(decideFloat(base, FLOAT_DEFAULTS).alerts.length, 0, 'no reading -> no alert');
});

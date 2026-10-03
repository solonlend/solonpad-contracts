import test from 'node:test';
import assert from 'node:assert/strict';
import { validateRelayQuote, planFundingFees, buildQuoteRequest, RelayRejected, RELAY_SELECTORS } from '../lib/relay.mjs';
import { DEFAULTS } from '../lib/config.mjs';

const hub = '0x1111111111111111111111111111111111111111';
const vault = '0x2222222222222222222222222222222222222222';
const amount = 10n * 10n ** 18n;
const good = () => ({
  requestId: '0xreq',
  steps: [{ id: 'deposit', kind: 'transaction', items: [{ data: {
    from: hub, to: DEFAULTS.relayRouter, value: amount.toString(), chainId: 5042,
    data: RELAY_SELECTORS.routerMulticall + '00'.repeat(12) + hub.slice(2) + 'ab'.repeat(64),
  } }] }],
  details: { sender: hub, recipient: vault, currencyIn: { amount: amount.toString() },
    currencyOut: { currency: { chainId: 4663, address: DEFAULTS.rhUsdg }, amount: '9932172', minimumAmount: '9900000' } },
});
const expect = { user: hub, recipient: vault, amountWei: amount };

test('buildQuoteRequest matches the verified Arc->RH USDG request shape', () => {
  assert.deepEqual(buildQuoteRequest({ user: hub, recipient: vault, amountWei: amount }), {
    user: hub, recipient: vault, originChainId: 5042, destinationChainId: 4663,
    originCurrency: '0x0000000000000000000000000000000000000000',
    destinationCurrency: '0x5fc5360d0400a0fd4f2af552add042d716f1d168', amount: '10000000000000000000', tradeType: 'EXACT_INPUT',
  });
});

test('a well-formed quote validates and returns the exact tx to execute', () => {
  const v = validateRelayQuote(good(), expect);
  assert.equal(v.tx.to.toLowerCase(), DEFAULTS.relayRouter);
  assert.equal(v.tx.value, amount);
  assert.equal(v.tx.chainId, 5042);
  assert.equal(v.minimumOut6, 9_900_000n);
});

const mutations = {
  'lifiIntents route': q => { q.details.route = { origin: { router: 'lifiIntents' } }; },
  'second step (approve/extra tx)': q => { q.steps.push(q.steps[0]); },
  'unknown target': q => { q.steps[0].items[0].data.to = '0x3333333333333333333333333333333333333333'; },
  'wrong value': q => { q.steps[0].items[0].data.value = (amount - 1n).toString(); },
  'wrong origin chain': q => { q.steps[0].items[0].data.chainId = 1; },
  'wrong destination currency': q => { q.details.currencyOut.currency.address = '0x0000000000000000000000000000000000000000'; },
  'wrong destination chain': q => { q.details.currencyOut.currency.chainId = 8453; },
  'substituted recipient': q => { q.details.recipient = '0x4444444444444444444444444444444444444444'; },
  'unknown selector': q => { q.steps[0].items[0].data.data = '0xdeadbeef' + q.steps[0].items[0].data.data.slice(10); },
  'user not in calldata': q => { q.steps[0].items[0].data.data = RELAY_SELECTORS.routerMulticall + 'ab'.repeat(64); },
  'different sender': q => { q.steps[0].items[0].data.from = vault; },
  'signature-kind step': q => { q.steps[0].kind = 'signature'; },
};
for (const [name, mutate] of Object.entries(mutations)) {
  test(`rejects ${name}`, () => {
    const q = good();
    mutate(q);
    assert.throws(() => validateRelayQuote(q, expect), RelayRejected);
  });
}

test('rejects when the guaranteed minimum would not cover the budget', () => {
  assert.throws(() => validateRelayQuote(good(), { ...expect, minOut6: 10_000_000n }), /minimum out/);
});

test('planFundingFees tops up input so NET USDG >= budget; Ops pays the difference', async () => {
  const budget = 500n * 10n ** 18n;
  // 10 USDC -> 9.932172 USDG observed (~68 bps); model a 9 bps + $0.4 fixed route like the 500 quote.
  const quote = async inWei => (inWei * 9991n) / 10_000n / 10n ** 12n - 400_000n;
  const plan = await planFundingFees({ budget18: budget, quoteMinOut6: quote, maxFeeBps: 50n });
  assert.ok(!plan.defer);
  assert.ok((await quote(budget + plan.fees18)) >= 500_000_000n);
  assert.ok(plan.fees18 < budget / 200n, 'under 0.5%');
  const flat = await planFundingFees({ budget18: 230n * 10n ** 18n, quoteMinOut6: async a => (a * 9990n) / 10_000n / 10n ** 12n });
  assert.ok(flat.fees18 >= 230_230_000_000_000_000n && flat.fees18 < 260_000_000_000_000_000n, `10 bps route: fee ${flat.fees18} ~ $0.23 + 10% buffer`);
});

test('planFundingFees defers with CostLimit when the bridge takes > maxFeeBps', async () => {
  const quote = async inWei => (inWei * 9900n) / 10_000n / 10n ** 12n; // 1%
  const plan = await planFundingFees({ budget18: 100n * 10n ** 18n, quoteMinOut6: quote, maxFeeBps: 50n });
  assert.equal(plan.defer, 'CostLimit');
});

test('decimals M2: every amount quoted to Relay is on the 6-dp grid (budget18 + fees18, fees18 rounded up to 1e12)', async () => {
  const budget = 350_175_316n * 10n ** 12n; // aligned by the round keeper (alignBudget18)
  const inputs = [];
  // Relay prices Arc USDC as 0x3600 (6 dp): model it refusing anything off the grid instead of truncating.
  const quote = async inWei => {
    inputs.push(inWei);
    if (inWei % 10n ** 12n !== 0n) throw new RelayRejected(`unaligned input ${inWei}`);
    return (inWei * 9991n) / 10_000n / 10n ** 12n - 400_000n;
  };
  const plan = await planFundingFees({ budget18: budget, quoteMinOut6: quote, maxFeeBps: 50n });
  assert.ok(!plan.defer, JSON.stringify(plan, (_, v) => (typeof v === 'bigint' ? v.toString() : v)));
  assert.equal(plan.fees18 % 10n ** 12n, 0n, 'fees18 on the grid');
  assert.ok(inputs.length >= 2 && inputs.every(a => a % 10n ** 12n === 0n), 'all quoted inputs aligned');
  assert.ok((await quote(budget + plan.fees18)) >= budget / 10n ** 12n);
});

test('decimals M2: an off-grid budget is still quoted on the grid (fees18 absorbs the tail upwards)', async () => {
  const budget = 1n * 10n ** 18n * 230n + 1n; // 230.000000000000000001
  const inputs = [];
  const quote = async inWei => { inputs.push(inWei); return (inWei * 9990n) / 10_000n / 10n ** 12n; };
  const plan = await planFundingFees({ budget18: budget, quoteMinOut6: quote, maxFeeBps: 50n });
  assert.ok(!plan.defer);
  assert.ok(inputs.every(a => a % 10n ** 12n === 0n), `inputs ${inputs}`);
});

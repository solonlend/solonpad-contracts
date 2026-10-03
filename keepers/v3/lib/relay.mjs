// Relay funding leg (Arc native USDC -> RH USDG), sequential zero-float mode, DESIGN §8.6.
// The quote API is untrusted input: every field that decides where money goes is checked
// against the expectation before anything is signed. lifiIntents-style routes, extra
// steps, unknown targets/selectors, chain or value mismatches are rejected outright.
import { getAddress, id as selectorOf } from 'ethers';
import { DEFAULTS } from './config.mjs';

export class RelayRejected extends Error {
  constructor(reason) { super(`relay quote rejected: ${reason}`); this.reason = reason; }
}

// Selectors observed on the Arc router/depository (web/lib/rail.ts + tests/fixtures/relay).
// routerMulticall is the selector seen in the captured arc-rh quote (tests/fixtures/relay);
// depositNative is derived from the depository signature used by web/tests/relay-protocol.
// Both must be re-pinned in config from the route manifest before mainnet use.
export const RELAY_SELECTORS = Object.freeze({
  routerMulticall: '0xcd6e13f7',
  depositNative: selectorOf('depositNative(address,bytes32)').slice(0, 10),
});

const lc = a => String(a ?? '').toLowerCase();

export function buildQuoteRequest({ user, recipient, amountWei, originChainId = DEFAULTS.arcChainId, destinationChainId = DEFAULTS.rhChainId, originCurrency = DEFAULTS.arcNativeUsdc, destinationCurrency = DEFAULTS.rhUsdg }) {
  return {
    user: getAddress(user),
    recipient: getAddress(recipient),
    originChainId,
    destinationChainId,
    originCurrency,
    destinationCurrency,
    amount: BigInt(amountWei).toString(),
    tradeType: 'EXACT_INPUT',
  };
}

// expect: { user, recipient, amountWei, minOut6, allowedTargets[], allowedSelectors[], originChainId, destinationChainId, destinationCurrency }
export function validateRelayQuote(quote, expect) {
  const text = JSON.stringify(quote ?? {});
  if (/lifi/i.test(text)) throw new RelayRejected('lifi/lifiIntents route');
  const steps = quote?.steps;
  if (!Array.isArray(steps) || steps.length !== 1) throw new RelayRejected(`expected exactly one step, got ${steps?.length}`);
  const [step] = steps;
  if (step.kind !== 'transaction') throw new RelayRejected(`step kind ${step.kind}`);
  if (step.id && !/deposit/i.test(step.id)) throw new RelayRejected(`step id ${step.id}`);
  if (!Array.isArray(step.items) || step.items.length !== 1) throw new RelayRejected('expected exactly one item');
  const data = step.items[0].data ?? {};
  const originChainId = expect.originChainId ?? DEFAULTS.arcChainId;
  if (Number(data.chainId) !== originChainId) throw new RelayRejected(`chainId ${data.chainId}`);
  const targets = (expect.allowedTargets ?? [DEFAULTS.relayRouter]).map(lc);
  if (!targets.includes(lc(data.to))) throw new RelayRejected(`unknown target ${data.to}`);
  if (data.from && lc(data.from) !== lc(expect.user)) throw new RelayRejected(`from ${data.from}`);
  let value;
  try { value = BigInt(data.value ?? -1); } catch { throw new RelayRejected('bad value'); }
  if (value !== BigInt(expect.amountWei)) throw new RelayRejected(`value ${value} != ${expect.amountWei}`);
  if (typeof data.data !== 'string' || !/^0x[0-9a-fA-F]{8,}$/.test(data.data)) throw new RelayRejected('missing calldata');
  const selectors = (expect.allowedSelectors ?? [RELAY_SELECTORS.routerMulticall]).map(lc);
  if (!selectors.includes(lc(data.data.slice(0, 10)))) throw new RelayRejected(`selector ${data.data.slice(0, 10)}`);
  // The recipient/user must appear in the calldata (defence against a swapped refund/recipient field).
  if (!lc(data.data).includes(lc(expect.user).slice(2))) throw new RelayRejected('user not bound in calldata');
  const details = quote.details ?? {};
  const out = details.currencyOut ?? {};
  const destChain = expect.destinationChainId ?? DEFAULTS.rhChainId;
  if (Number(out.currency?.chainId) !== destChain) throw new RelayRejected(`destination chain ${out.currency?.chainId}`);
  if (lc(out.currency?.address) !== lc(expect.destinationCurrency ?? DEFAULTS.rhUsdg)) throw new RelayRejected(`destination currency ${out.currency?.address}`);
  if (details.recipient && lc(details.recipient) !== lc(expect.recipient)) throw new RelayRejected(`recipient ${details.recipient}`);
  if (details.sender && lc(details.sender) !== lc(expect.user)) throw new RelayRejected(`sender ${details.sender}`);
  if (details.currencyIn?.amount && BigInt(details.currencyIn.amount) !== BigInt(expect.amountWei)) throw new RelayRejected('currencyIn amount');
  const minimum = BigInt(out.minimumAmount ?? out.amount ?? 0);
  if (expect.minOut6 != null && minimum < BigInt(expect.minOut6)) throw new RelayRejected(`minimum out ${minimum} < ${expect.minOut6}`);
  return {
    requestId: quote.requestId ?? step.requestId ?? null,
    tx: { to: getAddress(data.to), data: data.data, value, chainId: originChainId },
    amountOut6: BigInt(out.amount ?? minimum),
    minimumOut6: minimum,
  };
}

// Exact-input sizing so the NET USDG covers the full budget (reward principal never pays
// bridge cost, §8.6): budget + fees18 in, minimumAmount >= budget out. fees18 is paid by
// Ops (deposited separately on the adapter). Returns { fees18 } or { defer: reason }.
export async function planFundingFees({ budget18, quoteMinOut6, maxFeeBps = 50n, bufferBps = 1_000n, maxIterations = 4 }) {
  const need6 = (budget18 + 10n ** 12n - 1n) / 10n ** 12n;
  const cap = (budget18 * maxFeeBps) / 10_000n;
  // Relay prices Arc USDC as the 0x3600 view (6 dp, AGENTS.md §4.6): only ever quote budget18 + fees18 on the 1e12
  // grid; fees18 is rounded UP so the sub-micro tail is paid by Ops, never cut from the principal.
  const onGrid = fees => fees + ((10n ** 12n - ((budget18 + fees) % 10n ** 12n)) % 10n ** 12n);
  let fees18 = onGrid(0n);
  for (let i = 0; i < maxIterations; i++) {
    const input = budget18 + fees18;
    const min6 = BigInt(await quoteMinOut6(input));
    if (min6 >= need6) return { fees18, minOut6: need6, quotedMinOut6: min6 };
    if (min6 <= 0n) return { defer: 'NoRoute', fees18 };
    // Rescale the input by the observed net rate (handles % and fixed fees), plus a small buffer.
    const scaled = (need6 * 10n ** 12n * input + min6 * 10n ** 12n - 1n) / (min6 * 10n ** 12n);
    const fee = scaled - budget18;
    fees18 = onGrid(fee + (fee * bufferBps) / 10_000n + 10n ** 12n); // buffer is a share of the FEE, not of principal
    if (fees18 > cap) return { defer: 'CostLimit', fees18 };
  }
  return { defer: 'QuoteNotConverging', fees18 };
}

export function makeRelayClient({ api = DEFAULTS.relayApi, fetchImpl = globalThis.fetch, timeoutMs = 20_000 } = {}) {
  return {
    async quote(body) {
      const res = await fetchImpl(`${api}/quote`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs),
      });
      if (!res.ok) throw new Error(`relay quote HTTP ${res.status}`);
      return res.json();
    },
    async status(requestId) {
      const res = await fetchImpl(`${api}/intents/status/v2?requestId=${encodeURIComponent(requestId)}`, { signal: AbortSignal.timeout(timeoutMs) });
      if (!res.ok) throw new Error(`relay status HTTP ${res.status}`);
      return res.json();
    },
  };
}

// ---------------------------------------------------------------- r13: path 2a (plain-transfer fills, no txs)
// The Relay order is created by the quote API; Solon never executes Relay's own step. The route deposits
// amountIn + routeFee into the depository v2 tagged with the quote's protocol.v2.orderId (N2: that id, not the
// API requestId, is what the depository event carries and what the solver matches). What the keeper must prove
// from the untrusted quote before signing: the order pays exactly `amount` from `user` on the origin chain, refunds
// go back to `user` there, the ONLY output is a payment of `destinationCurrency` to `recipient` with no destination
// calls, and the expected output covers `minOut`.
export const CHAIN_NAMES = Object.freeze({ 5042: 'arc', 4663: 'robinhood', 421614: 'arbitrum-sepolia', 5042002: 'arc-testnet' });

export function buildDepositQuoteRequest({ user, recipient, amount, originChainId, destinationChainId, originCurrency, destinationCurrency }) {
  return {
    user: getAddress(user), recipient: getAddress(recipient), originChainId, destinationChainId, originCurrency, destinationCurrency,
    amount: BigInt(amount).toString(), tradeType: 'EXACT_INPUT',
  };
}

// expect: { user, recipient, amount (origin units), originChainId, destinationChainId, originCurrency, destinationCurrency,
//           minOut (destination units, on the EXPECTED amount), nativeScale (origin native -> payment units divisor, Arc 1e12),
//           paymentCurrency (optional: the token the order's input payment must be in, Arc 0x3600) }
export function validateDepositQuote(quote, expect) {
  if (/lifi/i.test(JSON.stringify(quote ?? {}))) throw new RelayRejected('lifi/lifiIntents route');
  const v2 = quote?.protocol?.v2;
  const orderId = v2?.orderId;
  if (typeof orderId !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(orderId) || /^0x0{64}$/.test(orderId)) throw new RelayRejected('no protocol.v2.orderId');
  const od = v2.orderData ?? {};
  const inputs = od.inputs ?? [];
  if (inputs.length !== 1) throw new RelayRejected(`expected one input, got ${inputs.length}`);
  const pay = inputs[0].payment ?? {};
  const originName = CHAIN_NAMES[expect.originChainId];
  if (pay.chainId !== originName) throw new RelayRejected(`payment chain ${pay.chainId}`);
  // r14: Arc native USDC is paid as the 0x3600 view (the r14 route's depositErc20 token) -> the order must say so.
  if (expect.paymentCurrency && lc(pay.currency) !== lc(expect.paymentCurrency)) throw new RelayRejected(`payment currency ${pay.currency} != ${expect.paymentCurrency}`);
  const scale = BigInt(expect.nativeScale ?? 1n);
  // Relay prices Arc native USDC as the 6-dp view: the order pays floor(amount / 1e12). Launch amounts are whole 6-dp
  // (hub principal + a grid-aligned route fee), so for them this is exact; fee planning may quote unaligned inputs.
  if (BigInt(pay.amount ?? -1) !== BigInt(expect.amount) / scale) throw new RelayRejected(`payment amount ${pay.amount} != ${expect.amount}/${scale}`);
  const refunds = inputs[0].refunds ?? [];
  const originRefund = refunds.find(r => r.chainId === originName);
  if (!originRefund || lc(originRefund.recipient) !== lc(expect.user)) throw new RelayRejected(`origin refund recipient ${originRefund?.recipient}`);
  const out = od.output ?? {};
  if (out.chainId !== CHAIN_NAMES[expect.destinationChainId]) throw new RelayRejected(`output chain ${out.chainId}`);
  if (Array.isArray(out.calls) && out.calls.length) throw new RelayRejected('destination calls present (2a needs a plain transfer)');
  const pays = out.payments ?? [];
  if (pays.length !== 1) throw new RelayRejected(`expected one output payment, got ${pays.length}`);
  if (lc(pays[0].recipient) !== lc(expect.recipient)) throw new RelayRejected(`output recipient ${pays[0].recipient}`);
  if (lc(pays[0].currency) !== lc(expect.destinationCurrency)) throw new RelayRejected(`output currency ${pays[0].currency}`);
  const details = quote.details ?? {};
  if (details.recipient && lc(details.recipient) !== lc(expect.recipient)) throw new RelayRejected(`recipient ${details.recipient}`);
  if (details.sender && lc(details.sender) !== lc(expect.user)) throw new RelayRejected(`sender ${details.sender}`);
  const expected = BigInt(pays[0].expectedAmount ?? details.currencyOut?.amount ?? 0);
  const minimum = BigInt(pays[0].minimumAmount ?? details.currencyOut?.minimumAmount ?? 0);
  if (expect.minOut != null && expected < BigInt(expect.minOut)) throw new RelayRejected(`expected out ${expected} < ${expect.minOut}`);
  return { orderId, requestId: quote.requestId ?? quote.steps?.[0]?.requestId ?? null, expectedOut: expected, minimumOut: minimum, deadline: Number(out.deadline ?? 0) };
}

// Route fee for an exact-input deposit whose EXPECTED output covers the principal: amountIn + fee in, >= amountIn out
// (destination units). The fee is whole 6-dp (Arc native deposit = a whole USDC amount; Relay prices it as 0x3600).
// `quoteOut(input)` -> expected output (destination units). Returns { fee, expectedOut } or { defer }.
export async function planRouteFee({ amountIn, needOut, quoteOut, grid = 1n, maxFee, maxIterations = 4 }) {
  let fee = 0n;
  for (let i = 0; i < maxIterations; i++) {
    const out = BigInt(await quoteOut(amountIn + fee));
    if (out >= needOut) return { fee, expectedOut: out };
    if (out <= 0n) return { defer: 'NoRoute', fee };
    const short = needOut - out; // destination units
    const next = fee + (short * amountIn) / needOut + (short * amountIn) / needOut / 10n + grid;
    fee = ((next + grid - 1n) / grid) * grid;
    if (maxFee != null && fee > maxFee) return { defer: 'CostLimit', fee };
  }
  return { defer: 'QuoteNotConverging', fee };
}

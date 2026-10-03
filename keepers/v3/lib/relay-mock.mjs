// Quote/status stand-in for Relay where Relay does not run (Arc testnet + the RH stand-in, unit tests). Same response
// shape as api.relay.link /quote (protocol.v2 order: one input paid by `user`, origin refund to `user`, one output
// payment to `recipient`, no destination calls), so the production validators and keepers run unchanged.
// Pricing: out = in x (1 - feeBps) - fixed. The "solver" side (paying the vault / hub) is testnet/mock-relay.mjs.
import { keccak256, hexlify, randomBytes } from 'ethers';
import { CHAIN_NAMES } from './relay.mjs';

const DECIMALS = { native: 18n, token: 6n };
// Arc native USDC's ERC-20 view: what the real API's order pays for originCurrency 0x0 on Arc (fixture relay-2a-arc-rh).
export const ARC_USDC_VIEW = '0x3600000000000000000000000000000000000000';

export function makeMockRelayClient({ feeBps = 8n, fixedUsd18 = 10n ** 16n, statuses = new Map(), defaultStatus = 'success', decimalsOf = c => (/^0x0{40}$/i.test(c) ? DECIMALS.native : DECIMALS.token) } = {}) {
  return {
    quotes: [],
    async quote(body) {
      const inDec = decimalsOf(body.originCurrency), outDec = decimalsOf(body.destinationCurrency);
      const amount = BigInt(body.amount);
      const in18 = amount * 10n ** (18n - inDec);
      const out18 = in18 - (in18 * BigInt(feeBps)) / 10_000n - BigInt(fixedUsd18);
      const out = out18 > 0n ? out18 / 10n ** (18n - outDec) : 0n;
      const orderId = keccak256(randomBytes(32));
      const requestId = keccak256(randomBytes(32));
      const pay = inDec === 18n ? amount / 10n ** 12n : amount; // Relay prices Arc native USDC as the 6-dp ERC-20 view
      const q = {
        requestId,
        steps: [{ id: 'deposit', kind: 'transaction', requestId, items: [{ status: 'incomplete', data: { chainId: body.originChainId } }] }],
        details: { sender: body.user, recipient: body.recipient, currencyIn: { amount: amount.toString() }, currencyOut: { amount: out.toString(), minimumAmount: ((out * 98n) / 100n).toString() } },
        protocol: { v2: { orderId, orderData: {
          inputs: [{ payment: { chainId: CHAIN_NAMES[body.originChainId], currency: inDec === 18n ? ARC_USDC_VIEW : body.originCurrency, amount: pay.toString() },
            refunds: [{ chainId: CHAIN_NAMES[body.originChainId], recipient: body.user, currency: body.originCurrency }] }],
          output: { chainId: CHAIN_NAMES[body.destinationChainId], payments: [{ recipient: body.recipient, currency: body.destinationCurrency, expectedAmount: out.toString(), minimumAmount: ((out * 98n) / 100n).toString() }], calls: [] },
        } } },
      };
      this.quotes.push({ body, orderId, requestId, out });
      return q;
    },
    async status(requestId) { return { status: statuses.get(requestId) ?? defaultStatus }; },
  };
}

// The quote client a keeper should use: the real api.relay.link, or (config relay.mock = true) the stand-in above —
// refused on any mainnet chain id, so a production config can never price against the mock.
const TESTNETS = new Set([5042002, 421614, 46630, 31337]);
export async function relayClientFor(cfg, ...chainIds) {
  if (!cfg.relay?.mock) {
    const { makeRelayClient } = await import('./relay.mjs');
    return makeRelayClient({ api: cfg.relay?.relayApi });
  }
  for (const id of chainIds) if (!TESTNETS.has(Number(id))) throw new Error(`relay.mock is testnet-only (chain ${id})`);
  return makeMockRelayClient(cfg.relay.mockParams ?? {});
}

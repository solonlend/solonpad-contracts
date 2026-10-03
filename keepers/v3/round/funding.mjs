// Funding lanes for the sequential zero-float round (DESIGN §8.6):
//   Reserved -> start(): adapter forwards budget+fees to the phase-5 SolonFundingHub on Arc
//   Funding  -> lane.dispatch(): hub deposits into Relay (Arc native USDC -> RH USDG)
//   Funded   <- adapter.funded(orderId): hub has authenticated the RH receipt
// The Relay deposit must be sent BY THE HUB (it holds the funds); the keeper only fetches
// and validates the quote and asks the hub to execute exactly that call.
// r13: production uses launcher/keeper.mjs SchedulerFundingLane (the reward order waits in OrderScheduler and the
//      launcher funds it through Relay); RelayFundingLane below is the pre-2a seam kept for its unit tests.
//      CCTP+OFT fallback lane is still a seam (only for never-sent orders).
import { buildQuoteRequest, validateRelayQuote, RelayRejected } from '../lib/relay.mjs';

export class Phase5Seam extends Error {
  constructor(what) { super(`phase-5 integration seam not wired: ${what}`); this.seam = what; this.sent = false; }
}

// Errors thrown with sent === false are guaranteed pre-broadcast; anything else is ambiguous.
export const definitelyNotSent = error => error?.sent === false || error instanceof RelayRejected;

export class RelayFundingLane {
  constructor({ relayClient, user, recipient, allowedTargets, allowedSelectors, destinationCurrency, hubDispatcher = null }) {
    Object.assign(this, { relayClient, user, recipient, allowedTargets, allowedSelectors, destinationCurrency, hubDispatcher });
    this.name = 'relay';
  }

  async quote(amountWei, minOut6 = null) {
    let raw;
    try {
      raw = await this.relayClient.quote(buildQuoteRequest({ user: this.user, recipient: this.recipient, amountWei, destinationCurrency: this.destinationCurrency }));
    } catch (error) { error.sent = false; throw error; }
    return validateRelayQuote(raw, {
      user: this.user, recipient: this.recipient, amountWei, minOut6,
      allowedTargets: this.allowedTargets, allowedSelectors: this.allowedSelectors, destinationCurrency: this.destinationCurrency,
    });
  }

  async quoteMinOut6(amountWei) {
    return (await this.quote(amountWei)).minimumOut6;
  }

  async dispatch({ orderId, budget18, fees18 }) {
    const need6 = (budget18 + 10n ** 12n - 1n) / 10n ** 12n;
    const validated = await this.quote(budget18 + fees18, need6);
    if (!this.hubDispatcher) throw new Phase5Seam('SolonFundingHub relay dispatch (hubDispatcher)');
    const sent = await this.hubDispatcher.dispatch({ orderId, tx: validated.tx, requestId: validated.requestId });
    return { lane: this.name, requestId: validated.requestId, txHash: sent?.hash ?? null, minimumOut6: validated.minimumOut6 };
  }
}

// Local/anvil lane: a fixture "solver" marks USDG arrival on the mock hub.
export class MockFundingLane {
  constructor({ feeBps = 10n, arrive }) {
    this.feeBps = BigInt(feeBps);
    this.arrive = arrive; // async ({orderId, amount18}) => {hash}
    this.name = 'mock';
  }

  async quoteMinOut6(amountWei) {
    return (BigInt(amountWei) * (10_000n - this.feeBps)) / 10_000n / 10n ** 12n;
  }

  async dispatch({ orderId, budget18 }) {
    const receipt = await this.arrive({ orderId, amount18: budget18 });
    return { lane: this.name, requestId: `mock-${orderId.slice(2, 10)}`, txHash: receipt?.hash ?? null };
  }
}

// ===> PHASE-5 INTEGRATION SEAM: authenticated RH/LZ result proof for finalize/applyResult.
export const emptyProofSource = { async proofFor() { return '0x'; }, name: 'empty' };

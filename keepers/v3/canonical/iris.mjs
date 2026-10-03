// Circle attestation service (Iris) v2 client: GET {base}/v2/messages/{sourceDomainId}?transactionHash={hash}.
// Semantics per Circle's docs (read 2026-10-01):
//   https://developers.circle.com/cctp/howtos/resolve-stuck-attestation  — 404 = not yet observed (keep polling),
//     { messages: [] } = found but not processed, status "pending" = awaiting confirmations, "complete" = ready to mint;
//     limit 35 requests/s, exceeding it blocks ALL requests for 5 minutes with HTTP 429 (poll >= 5 s, back off).
//   https://developers.circle.com/cctp/references/technical-guide — base URLs: mainnet https://iris-api.circle.com,
//     testnet https://iris-api-sandbox.circle.com; MessageV2 / BurnMessageV2 layouts.
export const IRIS_MAINNET = 'https://iris-api.circle.com';
export const IRIS_SANDBOX = 'https://iris-api-sandbox.circle.com';
const BLOCK_MS = 5 * 60_000;

export class IrisClient {
  constructor({ baseUrl = IRIS_MAINNET, fetchImpl = globalThis.fetch, now = () => Date.now(), timeoutMs = 15_000, logger = null } = {}) {
    Object.assign(this, { baseUrl: baseUrl.replace(/\/$/, ''), fetchImpl, now, timeoutMs, logger });
    this.blockedUntil = 0;
  }

  /// -> { state: 'complete' | 'pending' | 'rate-limited' | 'error', messages: [{ message, attestation, status, ... }], error? }
  ///    'complete' only when every message of the tx is complete with an attestation.
  async messages(sourceDomain, txHash) {
    if (this.now() < this.blockedUntil) return { state: 'rate-limited', messages: [] };
    let res;
    try {
      res = await this.fetchImpl(`${this.baseUrl}/v2/messages/${sourceDomain}?transactionHash=${txHash}`, { signal: AbortSignal.timeout(this.timeoutMs) });
    } catch (e) {
      return { state: 'error', messages: [], error: `fetch: ${e?.name ?? 'error'}` };
    }
    if (res.status === 404) return { state: 'pending', messages: [] };
    if (res.status === 429) {
      this.blockedUntil = this.now() + BLOCK_MS;
      this.logger?.warn('Iris 429: backing off 5 minutes');
      return { state: 'rate-limited', messages: [] };
    }
    if (!res.ok) return { state: 'error', messages: [], error: `HTTP ${res.status}` };
    let body;
    try { body = await res.json(); } catch { return { state: 'error', messages: [], error: 'bad JSON' }; }
    const messages = Array.isArray(body?.messages) ? body.messages : [];
    if (!messages.length) return { state: 'pending', messages };
    const done = messages.every(m => m.status === 'complete' && /^0x[0-9a-fA-F]+$/.test(m.attestation ?? '') && /^0x[0-9a-fA-F]+$/.test(m.message ?? ''));
    return { state: done ? 'complete' : 'pending', messages };
  }
}

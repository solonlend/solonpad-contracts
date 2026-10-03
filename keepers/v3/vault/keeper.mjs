// RH vault worker (r13, path 2a). Two jobs on Robinhood Chain, both permissionless calls on the ReserveVault:
//   1. executeFunded: a buy that reached the vault while the float was short waits (OrderWaitingFunds); once Relay's
//      plain USDG transfer (or a top-up) makes it fundable, execute it.
//   2. returnFunds: a settled ref with USDG liabilities (a sell's proceeds; unspent funding) is sent back to the hub
//      through the RH return route: Relay quote RH USDG -> Arc USDC without txs (user = vault, recipient = hub),
//      signed with requestId = protocol.v2.orderId. On Arc the plain transfer refills the hub float, which already
//      paid the seller. Failed buys in 2a carry no liability here (the float advanced them): nothing to return.
// Events are scanned in bounded windows from a journal cursor; chain views decide every action.
import { Contract, AbiCoder, getAddress, hexlify, randomBytes } from 'ethers';
import { ReserveVaultAbi, FundingRouteAbi } from '../lib/abis.mjs';
import { buildDepositQuoteRequest, validateDepositQuote, RelayRejected } from '../lib/relay.mjs';
import { taskKey } from '../lib/journal.mjs';

const coder = AbiCoder.defaultAbiCoder();
const SCALE = 10n ** 12n;

export const VAULT_DEFAULTS = Object.freeze({
  scanChunk: 5_000,
  startLookback: 20_000, // first run: blocks to look back
  quoteTtlSec: 300,
  minReturn6: 1_000_000n, // $1: smaller liabilities wait (a Relay leg costs ~$0.03)
  maxReturnShortBps: 100n, // Relay expected output may be at most 1% under the liability
  waitAlertSec: 10 * 60,
  maxPerTick: 8,
  destinationCurrency: '0x0000000000000000000000000000000000000000', // Arc native USDC
});

export class VaultWorker {
  constructor({ cfg, provider, tx, journal, logger, alert, relayClient, quoteSigner, chainId, now = null }) {
    Object.assign(this, { cfg, provider, tx, journal, logger, alert, relayClient, quoteSigner, chainId });
    const c = cfg.contracts ?? {};
    if (!c.reserveVault || !c.stockHub) throw new Error('vault worker: contracts.reserveVault and contracts.stockHub required');
    this.p = { ...VAULT_DEFAULTS, ...(cfg.vault?.params ?? {}) };
    for (const k of ['minReturn6', 'maxReturnShortBps']) this.p[k] = BigInt(this.p[k]);
    this.vault = new Contract(c.reserveVault, ReserveVaultAbi, provider);
    this.hub = getAddress(c.stockHub);
    this.arcChainId = cfg.vault?.arcChainId ?? cfg.relay?.arcChainId ?? 5042;
    this.clock = now;
  }

  // Chain time of the latest block (refreshed each tick): quote deadlines and ages follow the chain, also on forks.
  now() { return this.clock ? this.clock() : this.nowSec ?? Math.floor(Date.now() / 1000); }
  async refreshClock() { if (!this.clock) this.nowSec = (await this.provider.getBlock('latest')).timestamp; }
  key(op) { return taskKey({ chainId: this.chainId, contract: this.vault.target, op }); }
  note(kind, detail) { this.summary.actions.push({ kind, ...detail }); }

  async tick() {
    await this.refreshClock();
    this.summary = { actions: [], deferred: [] };
    await this.tx.reconcileAll();
    await this.scan();
    await this.executeWaiting();
    await this.returnLiabilities();
    return this.summary;
  }

  async scan() {
    const head = await this.provider.getBlockNumber();
    const cur = this.journal.record('scan', 'vault') ?? {};
    let from = cur.next ?? Math.max(0, head - this.p.startLookback);
    const ev = this.vault.interface;
    while (from <= head) {
      const to = Math.min(head, from + this.p.scanChunk - 1);
      const logs = await this.provider.getLogs({ address: this.vault.target, fromBlock: from, toBlock: to,
        topics: [[ev.getEvent('OrderWaitingFunds').topicHash, ev.getEvent('OrderExecuted').topicHash]] });
      for (const l of logs) {
        const e = ev.parseLog(l);
        if (e.name === 'OrderWaitingFunds') this.journal.setRecord('waiting', e.args.ref, { seenAt: this.now(), needed: e.args.needed.toString() });
        else if (Number(e.args.outcome) !== 0) this.journal.setRecord('returnable', e.args.ref, { outcome: Number(e.args.outcome), seq: Number(e.args.seq) }); // Sold / Failed
      }
      from = to + 1;
      this.journal.setRecord('scan', 'vault', { next: from });
    }
  }

  async executeWaiting() {
    const waiting = this.journal.entries('waiting');
    if (!waiting.length) return;
    const [floatOn, free] = await Promise.all([this.vault.floatEnabled(), this.vault.freeSettlement()]);
    for (const [ref, rec] of waiting) {
      if (await this.vault.settled(ref)) { this.journal.clearRecord('waiting', ref); continue; }
      const w = await this.vault.waitingOrder(ref);
      if (getAddress(w.underlying) === getAddress('0x0000000000000000000000000000000000000000')) { this.journal.clearRecord('waiting', ref); continue; }
      const own = await this.vault.funding(ref);
      if (own >= w.amountIn || (floatOn && free >= w.amountIn)) {
        const res = await this.tx.call(this.key(`executeFunded:${ref}`), this.vault, 'executeFunded', [ref], { label: `executeFunded ${ref.slice(0, 10)}` });
        this.note('executeFunded', { ref, status: res.status, amountIn: w.amountIn });
        if (res.status === 'confirmed') this.journal.clearRecord('waiting', ref);
      } else {
        this.summary.deferred.push({ ref, why: 'float short', need: w.amountIn, free });
        const age = this.now() - (rec.seenAt ?? this.now());
        if (age > this.p.waitAlertSec) await this.alert(`waiting-${ref}`, `RH buy ${ref} waiting ${Math.round(age / 60)} min: needs ${Number(w.amountIn) / 1e6} USDG, free float ${Number(free) / 1e6} — top up the RH float (runbook rebalance)`);
      }
    }
  }

  async returnRoute() {
    if (!this.route) this.route = new Contract(await this.vault.returnRoute(), FundingRouteAbi, this.provider);
    return this.route;
  }

  async returnLiabilities() {
    let n = 0;
    for (const [ref] of this.journal.entries('returnable')) {
      if (n >= this.p.maxPerTick) break;
      const owed = (await this.vault.funding(ref)) + (await this.vault.proceeds(ref));
      if (owed === 0n) { this.journal.clearRecord('returnable', ref); continue; }
      if (owed < this.p.minReturn6) { this.summary.deferred.push({ ref, why: 'below minReturn', owed }); continue; }
      n++;
      let q;
      try {
        const body = buildDepositQuoteRequest({ user: this.vault.target, recipient: this.hub, amount: owed, originChainId: this.chainId,
          destinationChainId: this.arcChainId, originCurrency: await this.vault.settlement(), destinationCurrency: this.p.destinationCurrency });
        q = validateDepositQuote(await this.relayClient.quote(body), { ...body, amount: owed, nativeScale: 1n });
      } catch (error) {
        const why = error instanceof RelayRejected ? `quote rejected: ${error.reason}` : `quote: ${String(error?.message).slice(0, 160)}`;
        this.summary.deferred.push({ ref, why });
        await this.alert(`return-${ref}-quote`, `RH return of ${Number(owed) / 1e6} USDG for ${ref} not quoted: ${why}`);
        continue;
      }
      const need18 = owed * SCALE;
      const shortBps = q.expectedOut >= need18 ? 0n : ((need18 - q.expectedOut) * 10_000n) / need18;
      if (shortBps > this.p.maxReturnShortBps) { this.summary.deferred.push({ ref, why: `Relay shortfall ${shortBps} bps` }); continue; }
      if (!this.quoteSigner) throw new Error('vault worker: no quote signer (QUOTE_SIGNER_KEY_PATH)');
      const route = await this.returnRoute();
      const sq = { requestId: q.orderId, deadline: BigInt(this.now() + this.p.quoteTtlSec), nonce: BigInt(hexlify(randomBytes(16))) };
      const minOut = q.expectedOut;
      const digest = await route.quoteDigest(ref, owed, 0n, minOut, sq);
      const quote = coder.encode(['tuple(bytes32 requestId,uint256 deadline,uint256 nonce)', 'bytes'], [[sq.requestId, sq.deadline, sq.nonce], this.quoteSigner.signDigest(digest)]);
      this.journal.setRecord('returns', ref, { orderId: q.orderId, relayRequestId: q.requestId, owed6: owed.toString(), expectedOut18: minOut.toString(), at: this.now() });
      const res = await this.tx.call(this.key(`returnFunds:${ref}:${q.orderId}`), this.vault, 'returnFunds', [ref, minOut, quote], { label: `returnFunds ${ref.slice(0, 10)} ${Number(owed) / 1e6} USDG` });
      this.note('returnFunds', { ref, status: res.status, owed6: owed, orderId: q.orderId, relayRequestId: q.requestId, expectedOut18: minOut });
      if (res.status === 'confirmed') this.journal.clearRecord('returnable', ref);
    }
  }
}

// CCTP v2 relayer for the canonical lane. Both CCTP legs of the lane carry a hook whose destinationCaller is our own
// contract, so MessageTransmitterV2.receiveMessage can only be reached through it:
//   checkpoint  Ethereum (domain 0)  EthereumBridger.CheckpointForwarded  -> Arc  CanonicalGate.relay(message, attestation)
//   deliver     Arc (domain 26)      CanonicalGate.DeliverSent           -> Eth  EthereumBridger.relay(message, attestation,
//                                    l2GasLimit, l2MaxFeePerGas){ value = retryable submission fee + L2 gas }
// Both wrappers call receiveMessage first (Circle verifies the attestation, nonce replay protection) and then decode the hook.
// Attestations come from Circle's Iris v2 API (iris.mjs). Idempotent: MessageTransmitterV2.usedNonces(nonce) on the
// destination is the truth (relayed by us or by anyone); TxSender journals each tx before broadcast. Retries every tick
// (quarantine auto-reopened hourly); alerts for long-pending attestations, failed relays, low ETH.
// Docs: https://developers.circle.com/cctp/references/technical-guide (MessageV2/BurnMessageV2, destinationCaller),
//       https://developers.circle.com/cctp/references/contract-interfaces (receiveMessage, usedNonces),
//       https://developers.circle.com/cctp/concepts/supported-chains-and-domains (Ethereum 0, Arc 26).
import { Contract, getAddress, getBytes, hexlify, dataSlice, formatEther } from 'ethers';
import { taskKey } from '../lib/journal.mjs';
import { IrisClient } from './iris.mjs';
import { reopenQuarantined, QUIET, RH_L1 } from './outbox-executor.mjs';

const MT_V2 = '0x81D40F21F12A8F0E3252Bccb954D722d4c464B64'; // MessageTransmitterV2, same address on Ethereum and Arc
export const CCTP_DEFAULTS = Object.freeze({
  scanChunk: 5_000,
  startLookback: { arc: 50_000, eth: 20_000 },
  pendingAlertSec: 2 * 3600,     // Standard (finalized) attestations: Ethereum ~15-19 min, Arc ~seconds
  deliverL2GasLimit: 1_500_000,  // vault.deliver on RH (fork: ticket gasLimit 1.5M covers deliver + swap)
  l2FeeMultiplier: 3,            // L2 maxFeePerGas = max(RH gas price x this, floor)
  l2MinFeeWei: '100000000',      // 0.1 gwei floor
  l1BaseFeeMultiplier: 2,        // submission fee is computed by the bridger at block.basefee: buffer for its rise
  maxTicketWei: '20000000000000000', // 0.02 ETH: above -> alert, no tx
  minEthWei: '5000000000000000',
});

/// Circle MessageV2 header + BurnMessageV2 body (byte offsets as in CctpV2.sol / Circle's technical guide).
export function parseCctpV2(message) {
  const b = getBytes(message);
  const u = (o, n) => Number(BigInt(hexlify(b.slice(o, o + n))));
  const addr = o => getAddress(dataSlice(hexlify(b.slice(o, o + 32)), 12));
  return { sourceDomain: u(4, 4), destinationDomain: u(8, 4), nonce: hexlify(b.slice(12, 44)), sender: addr(44), recipient: addr(76), destinationCaller: addr(108),
    minFinality: u(140, 4), finalityExecuted: u(144, 4), mintRecipient: addr(148 + 36), messageSender: addr(148 + 100), hookData: hexlify(b.slice(148 + 228)) };
}

const GATE_ABI = ['event DeliverSent(bytes32 indexed ref, address indexed to, uint8 mode)', 'function relay(bytes message, bytes attestation)'];
const BRIDGER_ABI = ['event CheckpointForwarded(uint256 indexed index, bytes32 root)', 'function relay(bytes message, bytes attestation, uint256 gasLimit, uint256 maxFeePerGas) payable returns (uint256)', 'function relayed(bytes32) view returns (bool)'];
const MT_ABI = ['function usedNonces(bytes32) view returns (uint256)'];
const INBOX_ABI = ['function calculateRetryableSubmissionFee(uint256 dataLength, uint256 baseFee) view returns (uint256)'];

export class CctpRelayer {
  constructor({ cfg, arc, eth, rh, journal, logger, alert, iris = null, now = null }) {
    Object.assign(this, { cfg, arc, eth, rh, journal, logger, alert });
    const c = cfg.contracts ?? {};
    for (const k of ['canonicalGate', 'ethBridger']) if (!c[k]) throw new Error(`cctp relayer: contracts.${k} required`);
    const cc = cfg.cctp ?? {};
    this.p = { ...CCTP_DEFAULTS, ...(cc.params ?? {}) };
    this.domains = { arc: cc.arcDomain ?? 26, eth: cc.ethDomain ?? 0 };
    this.gate = new Contract(c.canonicalGate, GATE_ABI, arc.provider);
    this.bridger = new Contract(c.ethBridger, BRIDGER_ABI, eth.provider);
    this.mt = { arc: new Contract(cc.arcMessageTransmitter ?? MT_V2, MT_ABI, arc.provider), eth: new Contract(cc.ethMessageTransmitter ?? MT_V2, MT_ABI, eth.provider) };
    this.inbox = new Contract(cc.rhL1Inbox ?? RH_L1.inbox, INBOX_ABI, eth.provider);
    this.iris = iris ?? new IrisClient({ baseUrl: cc.irisUrl, logger });
    this.startBlock = cc.startBlock ?? {};
    this.clock = now;
    this.lanes = [
      { name: 'checkpoint', src: 'eth', dst: 'arc', emitter: this.bridger, event: 'CheckpointForwarded', messageSender: getAddress(c.ethBridger) },
      { name: 'deliver', src: 'arc', dst: 'eth', emitter: this.gate, event: 'DeliverSent', messageSender: getAddress(c.canonicalGate) },
    ];
  }

  // Attestation ages follow the source chain's time (latest block, refreshed each tick); also right on forks.
  now(chain = null) { return this.clock ? this.clock() : (chain && this.nowSec?.[chain]) ?? Math.floor(Date.now() / 1000); }
  note(kind, detail) { this.summary.actions.push({ kind, ...detail }); }
  async warn(key, text) { this.logger.warn(text); await this.alert(key, text); }
  chain(name) { return this[name]; }

  async tick() {
    this.summary = { actions: [], pending: [], watch: {} };
    if (!this.clock) this.nowSec = { arc: (await this.arc.provider.getBlock('latest')).timestamp, eth: (await this.eth.provider.getBlock('latest')).timestamp };
    await this.arc.tx.reconcileAll();
    await this.eth.tx.reconcileAll();
    for (const lane of this.lanes) {
      await this.scan(lane);
      await this.relayLane(lane);
    }
    return this.summary;
  }

  // Source txs of the lane: one record per tx hash (Iris is queried by tx hash).
  async scan(lane) {
    const p = this.chain(lane.src).provider;
    const head = await p.getBlockNumber();
    const cur = this.journal.record('scan', lane.name) ?? {};
    let from = cur.next ?? (this.startBlock[lane.src] ?? Math.max(0, head - this.p.startLookback[lane.src]));
    const topic = lane.emitter.interface.getEvent(lane.event).topicHash;
    while (from <= head) {
      const to = Math.min(head, from + this.p.scanChunk - 1);
      for (const log of await p.getLogs({ address: lane.emitter.target, fromBlock: from, toBlock: to, topics: [topic] })) {
        const id = `${lane.name}:${log.transactionHash}`;
        if (this.journal.record('src', id)) continue;
        const at = (await p.getBlock(log.blockNumber)).timestamp;
        this.journal.setRecord('src', id, { lane: lane.name, tx: log.transactionHash, block: log.blockNumber, at });
        this.note('source', { lane: lane.name, tx: log.transactionHash });
      }
      from = to + 1;
      this.journal.setRecord('scan', lane.name, { next: from });
    }
  }

  async relayLane(lane) {
    for (const [id, rec] of this.journal.entries('src')) {
      if (rec.lane !== lane.name || rec.done) continue;
      const r = await this.iris.messages(this.domains[lane.src], rec.tx);
      if (r.state !== 'complete') {
        const age = this.now(lane.src) - rec.at;
        this.summary.pending.push({ lane: lane.name, tx: rec.tx, iris: r.state, ageMin: Math.round(age / 60) });
        if (age >= this.p.pendingAlertSec) await this.warn(`pending-${id}`, `CCTP ${lane.name} ${lane.src}->${lane.dst}: attestation for ${rec.tx} still ${r.state}${r.error ? ` (${r.error})` : ''} after ${(age / 3600).toFixed(1)} h`);
        continue;
      }
      let open = 0;
      for (const [i, m] of r.messages.entries()) {
        let msg;
        try { msg = parseCctpV2(m.message); } catch { continue; }
        // Only our hook: the right route and sent by our contract (other CCTP burns in the same tx are not ours).
        if (msg.sourceDomain !== this.domains[lane.src] || msg.destinationDomain !== this.domains[lane.dst] || msg.messageSender !== lane.messageSender) continue;
        if ((await this.mt[lane.dst].usedNonces(msg.nonce)) !== 0n) { this.note('already-received', { lane: lane.name, tx: rec.tx, nonce: msg.nonce }); continue; }
        open++;
        if (await this.relay(lane, rec, i, m, msg)) open--;
      }
      if (open === 0) this.journal.setRecord('src', id, { done: true, doneAt: this.now() });
    }
  }

  async relay(lane, rec, i, m, msg) {
    const dst = this.chain(lane.dst);
    const key = taskKey({ chainId: dst.chainId, contract: lane.name === 'checkpoint' ? this.gate.target : this.bridger.target, op: `cctp:${msg.sourceDomain}:${msg.nonce}` });
    reopenQuarantined(dst.journal ?? this.journal, key);
    let res;
    if (lane.name === 'checkpoint') {
      res = await dst.tx.call(key, this.gate, 'relay', [m.message, m.attestation], { label: `CanonicalGate.relay (checkpoint from ${rec.tx})` });
    } else {
      const t = await this.ticket(msg);
      if (!t) return false;
      res = await dst.tx.call(key, this.bridger, 'relay', [m.message, m.attestation, t.gasLimit, t.maxFeePerGas], { value: t.value, label: `EthereumBridger.relay (delivery from ${rec.tx}, ticket ${formatEther(t.value)} ETH)` });
    }
    this.note('relay', { lane: lane.name, tx: rec.tx, index: i, nonce: msg.nonce, status: res.status, relayTx: res.receipt?.hash ?? null });
    if (!QUIET.includes(res.status)) await this.warn(`relay-${lane.name}-${msg.nonce}`, `CCTP ${lane.name} relay of ${rec.tx} ${res.status}: ${String(res.error?.shortMessage ?? res.error?.message ?? res.reason ?? '').slice(0, 160)} (retrying each tick)`);
    return res.status === 'confirmed';
  }

  // Retryable ticket economics for EthereumBridger.relay -> Inbox.createRetryableTicket (excess refunded on RH to us).
  async ticket(msg) {
    const gasLimit = BigInt(this.p.deliverL2GasLimit);
    const rhGas = (await this.rh.provider.getFeeData()).gasPrice ?? 0n;
    let maxFeePerGas = rhGas * BigInt(this.p.l2FeeMultiplier);
    if (maxFeePerGas < BigInt(this.p.l2MinFeeWei)) maxFeePerGas = BigInt(this.p.l2MinFeeWei);
    const l1Base = (await this.eth.provider.getBlock('latest'))?.baseFeePerGas ?? 0n;
    const dataLength = getBytes(msg.hookData).length + 4; // deliver(Deliver) calldata <= hook (uint8 tag + Deliver) + selector
    const submission = await this.submissionFee(dataLength, l1Base * BigInt(this.p.l1BaseFeeMultiplier));
    const value = submission + gasLimit * maxFeePerGas;
    if (value > BigInt(this.p.maxTicketWei)) {
      await this.warn('ticket-cap', `retryable ticket would cost ${formatEther(value)} ETH > cap ${formatEther(BigInt(this.p.maxTicketWei))}: delivery not relayed (cctp.params.maxTicketWei)`);
      return null;
    }
    const from = this.eth.wallet?.address;
    if (from) {
      const bal = await this.eth.provider.getBalance(from);
      if (bal < value + BigInt(this.p.minEthWei)) await this.warn('eth-low', `CCTP relayer ${from} has ${formatEther(bal)} ETH on Ethereum: top up (deliveries pay the RH retryable ticket)`);
    }
    return { gasLimit, maxFeePerGas, value };
  }

  async submissionFee(dataLength, baseFee) { return this.inbox.calculateRetryableSubmissionFee(dataLength, baseFee); }
}

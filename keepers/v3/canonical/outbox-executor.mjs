// Outbox executor (canonical lane, step RH -> Ethereum): every ReserveVault.checkpoint() leaves RH as an ArbSys L2->L1
// message to EthereumBridger.acceptCheckpoint. Once the rollup confirms it (~6.4 days on Arbitrum-style challenge
// periods) this process executes it on the Ethereum Outbox, the way the Arbitrum SDK does (see arb-outbox.mjs):
//   scan RH ArbSys L2ToL1Tx(destination = bridger, caller = vault) -> wait for a confirmed send root covering the
//   position -> NodeInterface.constructOutboxProof -> verify (send hash, Merkle root, Outbox.roots) -> executeTransaction.
// acceptCheckpoint then burns 1 USDC towards Arc with the checkpoint as CCTP hook (cctp-relayer takes it from there);
// a checkpoint accepted while the bridger had no USDC is forwarded here (bridger.forward()) once it is funded.
// Idempotent: Outbox.isSpent(position) is the truth (executed by us or by anyone); TxSender journals each tx before
// broadcast. Retries: a failed execution stays open and is retried each tick (TxSender back-off); alerts are keyed.
import { Contract, getAddress, zeroPadValue, formatEther } from 'ethers';
import { taskKey, TaskState } from '../lib/journal.mjs';
import { ArbOutboxSource, ARBSYS, OUTBOX_ABI, arbSysIface, parseL2ToL1, itemHash, merkleRootFrom } from './arb-outbox.mjs';

const DAY = 86_400;
// RH mainnet rollup contracts on Ethereum (docs/FORK-E2E-v3.md §2, runbook §3; re-checked on chain 2026-10-01:
// Outbox.bridge() = Bridge 0xDf87…64b3, Outbox.rollup() = 0x23A19d23e89166adedbDcB432518AB01e4272D94).
export const RH_L1 = Object.freeze({ outbox: '0xf0ce991ea4A0d2400A4AB49b20ae333f6Dce3DE9', bridge: '0xDf8755334ce7A73cCF6b581C02eA649AE3E864b3', inbox: '0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D' });
export const ETH_USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
export const OUTBOX_DEFAULTS = Object.freeze({
  scanChunk: 5_000,
  startLookback: 50_000,      // RH blocks scanned on the first run when outbox.startBlock is not set
  maxGas: 600_000,            // executeTransaction + acceptCheckpoint + CCTP burn (fork: ~ 270k); above -> alert, no tx
  gasBufferBps: 13_000,
  confirmAlertSec: 7 * DAY,   // a send still unconfirmed after this (challenge period ~6.4 d) -> alert
  minEthWei: '5000000000000000', // 0.005 ETH on the executor wallet
  l1LookbackBlocks: 100_000,  // SendRootUpdated search depth on Ethereum (confirmations land every ~30 min)
  requarantineMs: 3_600_000,
});
// Deadline-critical: a task quarantined after MAX_ATTEMPTS failures is reopened after `ms` (default 1 h) instead of
// waiting for an operator, so retries continue at an hourly pace until the 8-day window (alerts keep firing meanwhile).
export function reopenQuarantined(journal, key, ms = 3_600_000, nowMs = Date.now()) {
  const t = journal.task(key);
  if (t?.state === TaskState.Quarantined && nowMs - (t.updatedAt ?? 0) >= ms) journal.reopen(key, 'auto-reopen (canonical lane deadline)');
}
export const QUIET = ['confirmed', 'dry-run', 'inflight', 'gas-cap', 'backoff'];
const BRIDGER_ABI = ['function checkpointCount() view returns (uint256)', 'function forwardedThrough() view returns (uint256)', 'function forward()', 'event CheckpointAccepted(uint256 indexed index, bytes32 root, uint64 fromSeq, uint64 toSeq)'];

export class OutboxExecutor {
  constructor({ cfg, eth, rh, journal, logger, alert, source = null, now = null }) {
    Object.assign(this, { cfg, eth, rh, journal, logger, alert });
    const c = cfg.contracts ?? {};
    for (const k of ['reserveVault', 'ethBridger']) if (!c[k]) throw new Error(`outbox executor: contracts.${k} required`);
    this.vault = getAddress(c.reserveVault);
    const o = cfg.outbox ?? {};
    this.p = { ...OUTBOX_DEFAULTS, ...(o.params ?? {}) };
    this.outboxAddr = getAddress(o.address ?? RH_L1.outbox);
    this.outbox = new Contract(this.outboxAddr, OUTBOX_ABI, eth.provider);
    this.bridger = new Contract(c.ethBridger, BRIDGER_ABI, eth.provider);
    this.usdc = new Contract(o.usdc ?? ETH_USDC, ['function balanceOf(address) view returns (uint256)'], eth.provider);
    this.source = source ?? new ArbOutboxSource({ l1: eth.provider, l2: rh.provider, outbox: this.outboxAddr, lookbackBlocks: this.p.l1LookbackBlocks });
    this.startBlock = o.startBlock ?? null;
    this.clock = now;
  }

  // Ages follow Ethereum chain time (refreshed each tick), like the canonical keeper; also right on forks.
  now() { return this.clock ? this.clock() : this.nowSec ?? Math.floor(Date.now() / 1000); }
  note(kind, detail) { this.summary.actions.push({ kind, ...detail }); }
  async warn(key, text) { this.logger.warn(text); await this.alert(key, text); }

  async tick() {
    this.summary = { actions: [], waiting: [], watch: {} };
    if (!this.clock) this.nowSec = (await this.eth.provider.getBlock('latest')).timestamp;
    await this.eth.tx.reconcileAll();
    await this.scan();
    await this.executePhase();
    try { await this.forwardPhase(); } catch (e) { await this.warn('forward-read', `bridger forward check failed: ${String(e?.shortMessage ?? e?.message).slice(0, 160)}`); }
    return this.summary;
  }

  // ArbSys L2ToL1Tx(destination = bridger) on RH; keep only sends whose caller is the vault (anyone can message the bridger;
  // the bridger itself rejects other senders, so executing them would only burn our gas).
  async scan() {
    const head = await this.rh.provider.getBlockNumber();
    const cur = this.journal.record('scan', 'l2') ?? {};
    let from = cur.next ?? (this.startBlock ?? Math.max(0, head - this.p.startLookback));
    const topics = [arbSysIface.getEvent('L2ToL1Tx').topicHash, zeroPadValue(this.bridger.target, 32)];
    while (from <= head) {
      const to = Math.min(head, from + this.p.scanChunk - 1);
      for (const log of await this.rh.provider.getLogs({ address: ARBSYS, fromBlock: from, toBlock: to, topics })) {
        const s = parseL2ToL1(log);
        if (s.caller !== this.vault) continue;
        if (this.journal.record('sends', s.position.toString())) continue;
        this.journal.setRecord('sends', s.position.toString(), { ...s, seenAt: this.now() });
        this.note('l2-send', { position: Number(s.position), l2Tx: s.l2Tx });
      }
      from = to + 1;
      this.journal.setRecord('scan', 'l2', { next: from });
    }
  }

  open() {
    return this.journal.entries('sends').filter(([, r]) => !r.done).sort((a, b) => Number(a[0]) - Number(b[0]));
  }

  async executePhase() {
    const open = this.open();
    this.summary.watch.open = open.length;
    if (!open.length) return;
    let conf;
    try { conf = await this.source.latestConfirmed(); } catch (e) { await this.warn('confirmed-state', `cannot read the confirmed RH send root: ${String(e?.message).slice(0, 200)}`); return; }
    this.summary.watch.confirmedSendCount = conf ? Number(conf.sendCount) : null;
    for (const [pos, rec] of open) {
      const s = { ...rec, position: BigInt(pos) };
      if (await this.source.isSpent(s.position)) {
        this.journal.setRecord('sends', pos, { done: 'spent', doneAt: this.now() });
        this.note('already-executed', { position: Number(pos) });
        continue;
      }
      const age = this.now() - Number(s.timestamp);
      if (!conf || conf.sendCount <= s.position) {
        this.summary.waiting.push({ position: Number(pos), ageH: Math.round(age / 360) / 10, confirmedSendCount: conf ? Number(conf.sendCount) : null });
        if (age >= this.p.confirmAlertSec) await this.warn(`unconfirmed-${pos}`, `RH checkpoint send #${pos} (tx ${s.l2Tx}) not confirmed on the L1 rollup after ${(age / DAY).toFixed(1)} d (confirmed sendCount ${conf?.sendCount ?? 'none'}): hub halts minting at 8 d`);
        continue;
      }
      await this.execute(pos, s, conf);
    }
  }

  async execute(pos, s, conf) {
    const { send, root, proof } = await this.source.proof(conf.sendCount, s.position);
    const item = itemHash(s);
    if (send.toLowerCase() !== item.toLowerCase() || merkleRootFrom(proof, s.position, item) !== root || root.toLowerCase() !== conf.sendRoot.toLowerCase()) {
      await this.warn(`proof-${pos}`, `outbox proof for send #${pos} does not verify (send ${send} vs item ${item}, root ${root} vs confirmed ${conf.sendRoot}) — not executing`);
      return;
    }
    if (!(await this.source.rootKnown(root))) {
      await this.warn(`root-${pos}`, `send root ${root} is not in Outbox.roots on Ethereum — not executing send #${pos}`);
      return;
    }
    const args = [proof, s.position, s.caller, s.destination, BigInt(s.arbBlockNum), BigInt(s.ethBlockNum), BigInt(s.timestamp), BigInt(s.callvalue), s.data];
    const from = this.eth.wallet?.address;
    if (from) {
      const bal = await this.eth.provider.getBalance(from);
      if (bal < BigInt(this.p.minEthWei)) await this.warn('eth-low', `outbox executor ${from} has ${formatEther(bal)} ETH on Ethereum (< ${formatEther(BigInt(this.p.minEthWei))}): top up (runbook §1.4 #9)`);
    }
    let gasLimit = null;
    try {
      const est = await this.eth.provider.estimateGas({ from, to: this.outboxAddr, data: this.outbox.interface.encodeFunctionData('executeTransaction', args) });
      if (est > BigInt(this.p.maxGas)) {
        await this.warn(`gas-${pos}`, `executeTransaction for send #${pos} estimates ${est} gas > cap ${this.p.maxGas}: not sent (raise outbox.params.maxGas after checking why)`);
        return;
      }
      gasLimit = (est * BigInt(this.p.gasBufferBps)) / 10_000n;
      if (gasLimit > BigInt(this.p.maxGas)) gasLimit = BigInt(this.p.maxGas);
    } catch { /* simulation inside TxSender reports the revert and backs off */ }
    const key = taskKey({ chainId: this.eth.chainId, contract: this.outboxAddr, op: `execute:${pos}` });
    reopenQuarantined(this.journal, key, this.p.requarantineMs);
    const res = await this.eth.tx.call(key, this.outbox, 'executeTransaction', args,
      { gasLimit, label: `Outbox.executeTransaction RH send #${pos} (checkpoint -> bridger)` });
    this.note('execute', { position: Number(pos), status: res.status, tx: res.receipt?.hash ?? res.hash ?? null });
    if (res.status === 'confirmed') this.journal.setRecord('sends', pos, { done: 'executed', tx: res.receipt?.hash ?? null, doneAt: this.now() });
    else if (!QUIET.includes(res.status)) await this.warn(`execute-${pos}`, `Outbox.executeTransaction for RH send #${pos} ${res.status}: ${String(res.error?.shortMessage ?? res.error?.message ?? res.reason ?? '').slice(0, 160)} (retrying each tick)`);
    else if (res.status === 'gas-cap') await this.warn(`gascap-${pos}`, `Outbox.executeTransaction for RH send #${pos} deferred: L1 gas price above chains.eth.maxFeePerGasCap`);
  }

  // A checkpoint accepted while the bridger held < 1 USDC is still on Ethereum: forward it once funded.
  async forwardPhase() {
    const [n, through] = await Promise.all([this.bridger.checkpointCount(), this.bridger.forwardedThrough()]);
    const pending = Number(n) - Number(through);
    this.summary.watch.bridgerUnforwarded = pending;
    if (pending <= 0) return;
    const bal = await this.usdc.balanceOf(this.bridger.target);
    if (bal < 1_000_000n * BigInt(pending)) {
      await this.warn('bridger-usdc', `EthereumBridger holds ${Number(bal) / 1e6} USDC but ${pending} accepted checkpoint(s) wait to be forwarded (1 USDC each): fund it with bridger.fund()`);
      if (bal < 1_000_000n) return;
    }
    const key = taskKey({ chainId: this.eth.chainId, contract: this.bridger.target, op: `forward:${through}:${n}` });
    reopenQuarantined(this.journal, key, this.p.requarantineMs);
    const res = await this.eth.tx.call(key, this.bridger, 'forward', [], { label: `EthereumBridger.forward (${pending} checkpoint(s))` });
    this.note('forward', { from: Number(through), to: Number(n) - 1, status: res.status });
    if (!QUIET.includes(res.status)) await this.warn('forward', `EthereumBridger.forward ${res.status}: ${String(res.error?.shortMessage ?? res.error?.message ?? '').slice(0, 160)}`);
  }
}

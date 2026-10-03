// Oracle push keeper (RH side). Events only wake it up; every decision re-reads chain state over HTTP:
//   ChainlinkStockSource.observe(u)  -> exactly what poke would relay (price, TWAP, USDG, feed updatedAt)
//   EVM block.number (= L1 block on RH) -> the observation's sourceBlock; Arc ignores a non-increasing one
//   StockPriceSender.quote(us)        -> LayerZero native fee
// and sends poke through TxSender (simulate -> journal -> broadcast; dry-run unless --execute).
// Pushes by anyone (PricesSent of our sender) count as "last pushed": the payload is reconstructed from the
// tx input (which stocks) and observe() at that block.
import { Contract, Interface } from 'ethers';
import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync, watch } from 'node:fs';
import { join } from 'node:path';
import { taskKey } from '../lib/journal.mjs';
import { decidePush, recordPush, parseDemand, mergeParams, twapDivergent, makeDebouncer } from './decide.mjs';

export const SenderAbi = [
  'function poke(address[] underlyings) payable returns (bytes32 guid)',
  'function quote(address[] underlyings) view returns (uint256)',
  'function source() view returns (address)',
  'function arcEid() view returns (uint32)',
  'function peers(uint32) view returns (bytes32)',
  'event PricesSent(bytes32 indexed guid, uint64 rhBlock, uint256 count, uint256 fee)',
  'event ObservationSkipped(address indexed underlying, bytes reason)',
];
export const SourceAbi = [
  'function observe(address underlying) view returns ((uint256 price18, uint256 multiplier, uint256 quoteUsd18, uint256 twapPrice18, uint64 sourceUpdatedAt, uint80 roundId, uint64 observedAt, uint64 sourceBlock) o)',
];
// Verified on RH 2026-10-01 (cast keccak + real logs of the three DualAggregator 1.0.0 aggregators).
export const TOPICS = Object.freeze({
  AnswerUpdated: '0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f', // AnswerUpdated(int256 indexed,uint256 indexed,uint256)
  NewTransmission: '0xc797025feeeaf2cd924c99e9205acb8ec04d5cad21c41ce637a38fb6dee6016a', // OCR2, same tx as AnswerUpdated (not subscribed)
  Swap: '0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67', // UniswapV3Pool Swap
});
const senderIface = new Interface(SenderAbi);
export const PRICES_SENT = senderIface.getEvent('PricesSent').topicHash;
export const SUBSCRIBED_TOPICS = [TOPICS.AnswerUpdated, TOPICS.Swap, PRICES_SENT];
// EVM `NUMBER; PUSH1 0; MSTORE; PUSH1 32; PUSH1 0; RETURN`: block.number as contracts see it (L1 block on RH).
const BLOCK_NUMBER_CODE = '0x4360005260206000f3';

export const DEMAND_FILE = 'oracle-push-demand.json';
export const LAST_FILE = 'oracle-push-last.json';

function writeAtomic(path, body) {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, body);
  renameSync(tmp, path);
}

export class OracleKeeper {
  constructor({ params = {}, stocks, provider, sender, source = null, tx, journal, logger, alert = async () => {}, statusDir, chainId = 4663, execute = false, feeBufferBps = 1_000n, maxFeeWei = 10n ** 15n, now = () => Math.floor(Date.now() / 1000), debounceMs = 3_000, timers, simulateFrom = null }) {
    Object.assign(this, { simulateFrom, stocks, provider, tx, journal, logger, alert, statusDir, chainId, execute, now });
    this.p = mergeParams(params);
    this.sender = typeof sender === 'string' ? new Contract(sender, SenderAbi, provider) : sender;
    this.source = source;
    this.feeBufferBps = BigInt(feeBufferBps);
    this.maxFeeWei = BigInt(maxFeeWei);
    this.underlyings = stocks.map(s => s.underlying);
    this.lastFile = join(statusDir, execute ? LAST_FILE : LAST_FILE.replace('.json', '.dry.json'));
    this.demandFile = join(statusDir, DEMAND_FILE);
    this.trigger = makeDebouncer(why => this.evaluate(why), debounceMs, timers);
    this.history = [];
    mkdirSync(statusDir, { recursive: true });
  }

  async init() {
    if (!this.source) this.source = new Contract(await this.sender.source(), SourceAbi, this.provider);
    return this;
  }

  // ------------------------------------------------------------ state
  get last() {
    return this.journal.record('oracle', 'last')?.stocks ?? {};
  }

  get lastPushAt() { return Number(this.journal.record('oracle', 'last')?.pushedAt ?? 0); }
  get lastL1Block() { return Number(this.journal.record('oracle', 'last')?.l1Block ?? 0); }

  saveLast(stocks, { pushedAt, l1Block, txHash, guid, reason, by }) {
    this.journal.setRecord('oracle', 'last', { stocks, pushedAt, l1Block, txHash, guid, reason, by });
    const prices = {};
    for (const [u, o] of Object.entries(stocks)) if (o.pushedAt === pushedAt) prices[u] = o.price18.toString();
    writeAtomic(this.lastFile, JSON.stringify({ txHash, guid, sentAt: pushedAt, rhBlock: l1Block, prices, reason, by }, null, 2) + '\n');
  }

  async readL1Block(blockTag = 'latest') {
    return Number(BigInt(await this.provider.call({ data: BLOCK_NUMBER_CODE, blockTag })));
  }

  async observeAll(blockTag = undefined) {
    const out = {};
    await Promise.all(this.underlyings.map(async u => {
      try {
        const o = await this.source.observe(u, blockTag != null ? { blockTag } : {});
        out[u] = { ok: true, price18: o.price18, twapPrice18: o.twapPrice18, quoteUsd18: o.quoteUsd18, sourceUpdatedAt: Number(o.sourceUpdatedAt), roundId: o.roundId };
      } catch (error) {
        out[u] = { ok: false, error: String(error?.shortMessage ?? error?.message ?? error).slice(0, 120) };
      }
    }));
    return out;
  }

  readDemand(nowSec) {
    if (!existsSync(this.demandFile)) return null;
    let body;
    try { body = readFileSync(this.demandFile, 'utf8'); } catch { return null; }
    const r = parseDemand(body, { listed: this.underlyings, nowSec, ttlSec: this.p.demandTtlSec });
    if (!r.ok) {
      if (this.lastDemandWarning !== r.reason) this.logger.warn(r.reason);
      this.lastDemandWarning = r.reason;
      return null;
    }
    return r.demand;
  }

  // ------------------------------------------------------------ events
  /// Logs from WS or catch-up. Feed rounds always re-evaluate; pool swaps only matter while a pushed
  /// observation is TWAP-Divergent on Arc; PricesSent (anyone's poke) updates "last pushed".
  async onLogs(logs) {
    let wake = false;
    const sender = String(this.sender.target).toLowerCase();
    for (const l of logs) {
      const t0 = l.topics?.[0];
      if (t0 === PRICES_SENT && String(l.address).toLowerCase() === sender) await this.adoptPush(l);
      else if (t0 === TOPICS.AnswerUpdated) wake = true;
      else if (t0 === TOPICS.Swap && this.twapWatch()) wake = true;
    }
    if (wake) this.trigger('event');
  }

  twapWatch() {
    return this.p.twapTrigger && Object.values(this.last).some(l => twapDivergent(l, this.p.maxTwapBps));
  }

  /// Reconstruct a push seen on chain (ours after a restart, or a third party's) and make it "last".
  async adoptPush(log) {
    const txHash = log.transactionHash;
    if (this.journal.record('oracle', 'last')?.txHash === txHash) return;
    const tx = await this.provider.getTransaction(txHash);
    let us;
    try { us = senderIface.decodeFunctionData('poke', tx.data)[0].map(String); } catch { us = this.underlyings; }
    const block = await this.provider.getBlock(log.blockNumber);
    const parsed = senderIface.parseLog(log);
    let obs;
    try { obs = await this.observeAll(log.blockNumber); } catch { obs = null; }
    if (!obs || Object.values(obs).every(o => !o.ok)) {
      this.logger.warn(`adopt ${txHash}: no historical state; using the current read`);
      obs = await this.observeAll();
    }
    const pushedAt = block.timestamp;
    if (pushedAt <= this.lastPushAt) return; // older than what we know
    const stocks = recordPush(this.last, { underlyings: us, observations: obs, pushedAt, l1Block: Number(parsed.args.rhBlock) });
    this.saveLast(stocks, { pushedAt, l1Block: Number(parsed.args.rhBlock), txHash, guid: parsed.args.guid, reason: 'observed on chain', by: tx.from });
    this.logger.info(`adopted push ${txHash} by ${tx.from} (${us.length} stocks)`);
  }

  /// Start-up: if we have no record, adopt the newest PricesSent in the lookback window.
  async recover(lookbackBlocks = 120_000) {
    if (this.journal.record('oracle', 'last')) return false;
    const head = await this.provider.getBlockNumber();
    const logs = await this.provider.getLogs({ address: this.sender.target, topics: [PRICES_SENT], fromBlock: Math.max(0, head - lookbackBlocks), toBlock: head });
    if (!logs.length) return false;
    await this.adoptPush(logs.at(-1));
    return true;
  }

  watchDemand() {
    try {
      this.demandWatcher = watch(this.statusDir, (_ev, file) => { if (file === DEMAND_FILE) this.trigger('demand-file'); });
    } catch (error) {
      this.logger.warn(`fs.watch unavailable (${error?.message}); demand file is checked on every tick`);
    }
  }

  // ------------------------------------------------------------ decide + push
  async evaluate(why = []) {
    const nowSec = this.now();
    const [current, l1Block] = await Promise.all([this.observeAll(), this.readL1Block()]);
    const demand = this.readDemand(nowSec);
    const d = decidePush({ nowSec, l1Block, current, last: this.last, lastPushAt: this.lastPushAt, lastL1Block: this.lastL1Block, demand, params: this.p });
    const out = { at: nowSec, why, decision: { push: d.push, reason: d.reason, reasons: d.reasons, skipped: d.skipped, blocked: d.blocked, sessionOpen: d.sessionOpen } };
    if (d.demandRefused?.length) await this.alert('oracle-demand-divergent', `push demand for ${d.demandRefused.join(', ')} not answered: the observation is TWAP-divergent (would land Divergent on Arc)`);
    const frozen = (d.blocked ?? []).filter(b => b.alert);
    if (frozen.length) await this.alert('oracle-market-gate', `not pushing ${frozen.map(b => `${b.underlying}: ${b.reason}`).join('; ')}`);
    if (d.skipped.length) {
      for (const s of d.skipped) this.logger.warn(`observe failed ${s.underlying}: ${s.reason}`);
    }
    if (d.push) out.result = await this.push(d, current, nowSec);
    this.history.push(out);
    if (this.history.length > 50) this.history.shift();
    return out;
  }

  async push(d, current, nowSec) {
    const us = d.underlyings;
    let fee;
    try { fee = await this.sender.quote(us); } catch (error) {
      this.logger.warn(`quote failed: ${error?.shortMessage ?? error?.message}`);
      return { status: 'quote-failed' };
    }
    if (fee > this.maxFeeWei) {
      await this.alert('oracle-fee-cap', `LZ fee ${fee} wei above cap ${this.maxFeeWei}; push (${d.reason}) skipped`);
      return { status: 'fee-cap', fee };
    }
    const value = (fee * (10_000n + this.feeBufferBps)) / 10_000n; // excess refunded to us by the endpoint
    // One task per "due episode": retries after a failure reuse the key (journal backoff), success closes it.
    let pending = this.journal.record('oracle', 'pending');
    if (!pending?.since) pending = this.execute ? this.journal.setRecord('oracle', 'pending', { since: nowSec, reason: d.reason }) : { since: nowSec };
    const key = taskKey({ chainId: this.chainId, contract: this.sender.target, op: `poke:${pending.since}` });
    const data = this.sender.interface.encodeFunctionData('poke', [us]);
    // Dry-run without a key simulates from `simulateFrom` (an address holding ETH: a value call from a 0-balance
    // address fails the balance check).
    const res = await this.tx.send({ key, to: this.sender.target, data, value, from: this.simulateFrom ?? undefined, label: `oracle poke ${us.length} (${d.reason})` });
    if (res.status === 'dry-run') {
      // Dry-run: remember the would-be push in the .dry journal so the next decision behaves as if it landed.
      const stocks = recordPush(this.last, { underlyings: us, observations: current, pushedAt: nowSec, l1Block: null });
      this.saveLast(stocks, { pushedAt: nowSec, l1Block: 0, txHash: null, guid: null, reason: d.reason, by: 'dry-run' });
      return { status: 'dry-run', fee, value, underlyings: us };
    }
    if (res.status !== 'confirmed') {
      const task = this.journal.task(key);
      if (task?.state === 'Quarantined') await this.alert('oracle-push', `oracle poke failing repeatedly: ${task.lastError}`);
      return { status: res.status, fee };
    }
    const r = res.receipt;
    const ev = r.logs.map(l => { try { return senderIface.parseLog(l); } catch { return null; } }).find(e => e?.name === 'PricesSent');
    const l1Block = ev ? Number(ev.args.rhBlock) : await this.readL1Block(r.blockNumber);
    let obs = await this.observeAll(r.blockNumber).catch(() => null);
    if (!obs || Object.values(obs).every(o => !o.ok)) obs = current;
    const block = await this.provider.getBlock(r.blockNumber);
    const stocks = recordPush(this.last, { underlyings: us, observations: obs, pushedAt: block?.timestamp ?? nowSec, l1Block });
    this.saveLast(stocks, { pushedAt: block?.timestamp ?? nowSec, l1Block, txHash: r.hash, guid: ev?.args.guid ?? null, reason: d.reason, by: this.tx.from });
    this.journal.setRecord('oracle', 'pending', { since: null });
    this.logger.info(`pushed ${us.length} stocks (${d.reason}) ${r.hash} guid ${ev?.args.guid}`);
    return { status: 'confirmed', txHash: r.hash, guid: ev?.args.guid ?? null, fee, l1Block };
  }

  stop() { try { this.demandWatcher?.close(); } catch {} }
}

// Incremental, restart-safe discovery of keeper inputs that grow on chain (new coins, new staking lanes).
// One scanner per (name, emitter): logs up to head - confirmations are read in chunks, sorted by (block, logIndex),
// decoded, and upserted by id; the cursor only moves after the chunk's items are written. A crash between the two
// re-reads at most one chunk and re-applies idempotently; a duplicate or out-of-order log keeps the earliest sighting.
// Discovered items are chain facts, not intents, so dry-run and --execute journals both persist them.
import { DAY } from '../round/decide.mjs';

// confirmations: Arc blocks are sub-second; 30 blocks keeps a lagging load-balanced node from serving an empty range as final.
export const DISCOVERY_DEFAULTS = Object.freeze({ confirmations: 30, chunk: 5_000, maxChunksPerTick: 40 });

const pos = x => [Number(x.block), Number(x.logIndex)];
export const earlier = (a, b) => {
  const [ab, ai] = pos(a);
  const [bb, bi] = pos(b);
  return ab < bb || (ab === bb && ai < bi);
};
export const dayOf = ts => Math.floor(Number(ts) / DAY);

export class LogDiscovery {
  // decode(log, blockTs) -> { id, ...fields } | null (not ours). Must be deterministic for the same log.
  // withTimestamp = false: decode gets null instead of the block time (saves one getBlock per log block).
  constructor({ provider, journal, name, address, topics, fromBlock, decode, params = {}, logger = null, withTimestamp = true }) {
    if (fromBlock == null || !Number.isInteger(Number(fromBlock))) throw new Error(`discovery ${name}: fromBlock is required (deployment block)`);
    Object.assign(this, { provider, journal, name, address, topics, fromBlock: Number(fromBlock), decode, logger, withTimestamp });
    this.p = { ...DISCOVERY_DEFAULTS, ...params };
    this.ns = `discover:${name}`;
    this.cursorId = `${name}:${String(address).toLowerCase()}`; // a new deployment address starts a fresh cursor
  }

  cursor() {
    return Number(this.journal.record('discoverCursor', this.cursorId)?.next ?? this.fromBlock);
  }

  items() {
    return this.journal.records(this.ns).filter(r => r.id).sort((a, b) => (earlier(a, b) ? -1 : earlier(b, a) ? 1 : 0));
  }

  upsert(item) {
    const prev = this.journal.record(this.ns, item.id);
    if (prev && !earlier(item, prev)) return false; // duplicate / later re-emission: first sighting wins
    this.journal.setRecord(this.ns, item.id, item);
    return !prev;
  }

  async sync() {
    const head = await this.provider.getBlockNumber();
    const safe = head - this.p.confirmations;
    let from = this.cursor();
    const added = [];
    const blockTs = new Map();
    const tsOf = async n => {
      if (!blockTs.has(n)) blockTs.set(n, (await this.provider.getBlock(n)).timestamp);
      return blockTs.get(n);
    };
    for (let i = 0; i < this.p.maxChunksPerTick && from <= safe; i++) {
      const to = Math.min(safe, from + this.p.chunk - 1);
      const logs = (await this.provider.getLogs({ address: this.address, topics: this.topics, fromBlock: from, toBlock: to }))
        .filter(l => !l.removed)
        .sort((a, b) => a.blockNumber - b.blockNumber || (a.index ?? a.logIndex) - (b.index ?? b.logIndex));
      for (const log of logs) {
        const item = await this.decode(log, this.withTimestamp ? await tsOf(log.blockNumber) : null);
        if (!item) continue;
        if (this.upsert({ ...item, block: log.blockNumber, logIndex: log.index ?? log.logIndex, tx: log.transactionHash })) added.push(item.id);
      }
      // A node behind the head answers getLogs with an empty range: only move past `to` once this node has that block.
      if (!(await this.provider.getBlock(to))) {
        this.logger?.warn?.(`discovery ${this.name}: node has no block ${to} yet; cursor stays at ${from}`);
        break;
      }
      from = to + 1;
      this.journal.setRecord('discoverCursor', this.cursorId, { next: from });
    }
    if (added.length) this.logger?.info?.(`discovery ${this.name}: +${added.length} (${added.join(', ')})`);
    return { added, next: from, behind: Math.max(0, safe - from + 1) };
  }
}

// Configured sources first (operator overrides: firstEpoch, kind), then discovered ones not already listed.
export function mergeSources(configured = [], discovered = []) {
  const out = [];
  const seen = new Set();
  for (const s of [...configured, ...discovered]) {
    const k = String(s.address).toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(s);
  }
  return out;
}

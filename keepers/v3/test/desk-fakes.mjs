// In-memory model of the frozen Desk payout chain (src/v3/DeskRewards.sol, DeskNFT.sol, RewardRoundManager.sol seal /
// entry / delivered / available / pending, RewardDistributor service policy, SolonStockOracle reads) for the Desk keeper
// tests. Every write enforces the same preconditions as the contract, so a keeper bug shows up as a revert here.
import { Interface, AbiCoder, keccak256 } from 'ethers';
import { DeskRewardsAbi, DeskNftAbi } from '../lib/abis.mjs';
import { TaskState } from '../lib/journal.mjs';

export const DAY = 86_400;
export const P27 = 10n ** 27n;
export const E18 = 10n ** 18n;
const coder = AbiCoder.defaultAbiCoder();
const A = n => '0x' + String(n).repeat(40);
export const ADDR = { rewards: A(1), nft: A(2), manager: A(3), policy: A(4), oracle: A(5), nvda: A(6), aapl: A(7), protocol: A(8) };
export const B32 = n => '0x' + BigInt(n).toString(16).padStart(64, '0');
const rwIface = new Interface(DeskRewardsAbi);
const nftIface = new Interface(DeskNftAbi);

class Revert extends Error {}
const need = (cond, msg) => { if (!cond) throw new Revert(msg); };

export class DeskSim {
  constructor({ now, cards = 40, price = 100n * E18 } = {}) {
    this.now = now; // seconds; tests move it
    this.cards = cards;
    this.streams = new Map();
    this.entries = [null];
    this.delivered = [0n];
    this.available = [0n];
    this.pending = [0n];
    this.queues = [];
    this.queued = new Set();
    this.paid = new Map(); // `${card}:${key}` -> raw
    this.received = new Map(); // card -> raw (all assets)
    this.blocked = new Set(); // card ids whose push reverts (delivery eligibility)
    this.logs = [];
    this.block = 100;
    this.prices = new Map([[ADDR.nvda.toLowerCase(), { price, at: null }], [ADDR.aapl.toLowerCase(), { price, at: null }]]); // at null = observed just now
    this.calls = [];
    this.routeMissing = false;
    this.protocolCalls = [];
    this.entryReason = new Map(); // RewardRoundManager.entryStatus reason (default BelowMinimum)
  }

  // ------------------------------------------------------------ fee credits (DeskRewards._credit, all first generation)
  credit({ source, epoch, asset, kind, perCard27, protocol27 = 0n }) {
    const key = keccak256(coder.encode(['bytes32', 'uint256', 'address', 'uint8'], [source, epoch, asset, kind]));
    const s = this.streams.get(key) ?? { source, epoch, asset, kind, counter: 0n, rem: 0n, supply: BigInt(this.cards), totalCredit27: 0n, received: 0n,
      sealed: false, entrySource: null, purchasedRaw: 0n, purchasedAsset: null, delegatedCredit27: 0n, delegatedFunded: 0n };
    s.counter += perCard27;
    s.totalCredit27 += perCard27 * BigInt(this.cards);
    s.delegatedCredit27 += protocol27;
    this.streams.set(key, s);
    this.block += 3;
    this.logs.push({ address: ADDR.rewards, blockNumber: this.block, index: this.logs.length, transactionHash: B32(5000 + this.logs.length), removed: false,
      ...rwIface.encodeEventLog('DeskFeeCredit', [key, source, 1n, s.counter, 0n]) });
    return key;
  }

  // round keeper + launcher stand-in: the entry's purchase settles (possibly in several rounds)
  deliver(entryId, raw, { remaining = 0n, pending = 0n } = {}) {
    this.delivered[entryId] += raw;
    this.available[entryId] = remaining;
    this.pending[entryId] = pending;
  }

  setPrice(asset, price, at) { this.prices.set(asset.toLowerCase(), { price, at }); }
  // a third party calls DeskNFT.openDeskQueue directly
  openQueueAsStranger(keys) { this.contractAt()(ADDR.nft)._tx.openDeskQueue([keys]); }
  stream(key) { return this.streams.get(key); }
  count(method) { return this.calls.filter(c => c.method === method).length; }

  claimable(card, key) {
    const s = this.streams.get(key);
    const owed = s.kind === 1 ? s.counter / P27 : (s.totalCredit27 === 0n ? 0n : (s.counter * s.purchasedRaw) / s.totalCredit27);
    return owed - (this.paid.get(`${card}:${key}`) ?? 0n);
  }

  deliveryInfo(key) {
    const s = this.streams.get(key);
    if (!s) return [ '0x0000000000000000000000000000000000000000', 0n ];
    return s.kind === 1 ? [s.asset, s.counter] : [s.purchasedAsset ?? '0x0000000000000000000000000000000000000000', s.purchasedRaw];
  }

  // ------------------------------------------------------------ fakes the keeper talks to
  provider() {
    const sim = this;
    return {
      getBlockNumber: async () => sim.block + 2, // newest credit is exactly at head - confirmations(2)
      getBlock: async n => ({ number: n === "latest" ? sim.block + 2 : n, timestamp: sim.now }),
      getLogs: async ({ address, topics, fromBlock, toBlock }) => sim.logs
        .filter(l => l.address.toLowerCase() === address.toLowerCase() && l.topics[0] === topics[0] && l.blockNumber >= fromBlock && l.blockNumber <= toBlock)
        .reverse(), // out-of-order RPC
    };
  }

  contractAt() {
    const sim = this;
    const views = {
      [ADDR.rewards.toLowerCase()]: {
        interface: rwIface, target: ADDR.rewards,
        streams: async key => { const s = sim.streams.get(key); return s ?? { source: B32(0), epoch: 0n, asset: A(0), kind: 0n, counter: 0n, rem: 0n, supply: 0n, totalCredit27: 0n, received: 0n }; },
        entrySources: async key => sim.streams.get(key)?.entrySource ?? A(0),
        streamSealed: async key => sim.streams.get(key)?.sealed ?? false,
        purchasedRaw: async key => sim.streams.get(key)?.purchasedRaw ?? 0n,
        deliveryInfo: async key => sim.deliveryInfo(key),
        delegatedCredit27: async key => sim.streams.get(key)?.delegatedCredit27 ?? 0n,
        delegatedFunded: async key => sim.streams.get(key)?.delegatedFunded ?? 0n,
        _tx: {
          entrySource([key]) {
            const s = sim.streams.get(key);
            need(s && s.supply > 0n && s.kind === 0, 'native source');
            if (!s.entrySource) s.entrySource = '0x' + 'e'.repeat(8) + key.slice(2, 34);
            return [];
          },
          syncPurchased([key, entryId]) {
            const s = sim.streams.get(key);
            const e = sim.entries[Number(entryId)];
            need(e && e.source === s.entrySource && e.epoch === s.epoch, 'entry');
            s.purchasedRaw = sim.delivered[Number(entryId)];
            s.purchasedAsset = ADDR.nvda;
            return [];
          },
          fundProtocolDeskBudget([key]) {
            const s = sim.streams.get(key);
            need(s && s.kind === 0, 'native protocol budget');
            s.delegatedFunded = s.delegatedCredit27 / P27; sim.protocolCalls.push(['fund', key]);
            return [];
          },
          forwardProtocolDesk([key]) {
            const s = sim.streams.get(key);
            need(s && s.kind === 1, 'raw stock only');
            s.delegatedFunded = s.delegatedCredit27 / P27; sim.protocolCalls.push(['forward', key]);
            return [];
          },
        },
      },
      [ADDR.manager.toLowerCase()]: {
        target: ADDR.manager,
        nextEntryId: async () => BigInt(sim.entries.length - 1),
        entry: async id => sim.entries[Number(id)] ?? { source: A(0), epoch: 0n },
        delivered: async id => sim.delivered[Number(id)] ?? 0n,
        available: async id => sim.available[Number(id)] ?? 0n,
        pending: async id => sim.pending[Number(id)] ?? 0n,
        entryStatus: async id => ({ age: 0n, dormant: false, nextCheck: 0n, reason: BigInt(sim.entryReason.get(Number(id)) ?? 1) }),
        _tx: {
          seal([source, epoch, cohort, assetId]) {
            need(!sim.routeMissing, 'missing asset route');
            const [key, s] = [...sim.streams.entries()].find(([, x]) => x.entrySource === source) ?? [];
            need(s && cohort === 0 && BigInt(epoch) === BigInt(s.epoch) && assetId === B32(77), 'source policy');
            need(!s.sealed && sim.now >= (Number(s.epoch) + 1) * DAY, 'seal');
            const budget = s.totalCredit27 / P27;
            need(budget > 0n, 'empty budget');
            s.sealed = true;
            sim.entries.push({ source, epoch: s.epoch, key });
            sim.delivered.push(0n); sim.available.push(budget); sim.pending.push(0n);
            return [];
          },
        },
      },
      [ADDR.nft.toLowerCase()]: {
        interface: nftIface, target: ADDR.nft,
        servicePolicy: async () => ADDR.policy,
        totalSupply: async () => BigInt(sim.cards),
        deskQueues: async i => { const q = sim.queues[Number(i)]; need(q, 'array out of bounds'); return { stream: q.keys[0], asset: q.asset, upperBound: q.upperBound, cursor: q.cursor, nextScanAt: q.nextScanAt }; },
        deskQueueStreams: async i => { const q = sim.queues[Number(i)]; need(q, 'array out of bounds'); return [q.keys, q.revisions]; },
        deskQueued: async u => sim.queued.has(u),
        _tx: {
          openDeskQueue([keys]) {
            need(keys.length > 0 && keys.length <= 20, 'service streams');
            let asset;
            const revisions = keys.map((k, i) => {
              need(keys.indexOf(k) === i, 'duplicate stream');
              const [cur, rev] = sim.deliveryInfo(k);
              need(cur !== A(0) && rev !== 0n, 'ready stock');
              if (i === 0) asset = cur; else need(asset === cur, 'same asset');
              return rev;
            });
            const u = keccak256(coder.encode(['bytes32[]', 'address', 'uint256[]'], [keys, asset, revisions]));
            need(!sim.queued.has(u), 'queue exists');
            sim.queued.add(u);
            sim.queues.push({ keys: [...keys], asset, revisions, upperBound: BigInt(sim.cards), cursor: 0n, nextScanAt: 0n });
            return [];
          },
          batchDistributeDesk([queueId, maxCards], { gasLimit }) {
            need(maxCards > 0 && maxCards <= 32, 'batch page');
            const q = sim.queues[Number(queueId)];
            need(sim.now % DAY >= 600 && sim.now >= Number(q.nextScanAt), 'scan schedule');
            const reserve = 500_000 * q.keys.length + 100_000;
            if (!gasLimit || Number(gasLimit) < reserve + 50_000) return []; // gas guard: returns (0,0), no progress
            if (q.cursor === q.upperBound) q.cursor = 0n;
            const start = q.cursor;
            const end = BigInt(Math.min(Number(q.cursor) + Number(maxCards), Number(q.upperBound)));
            const logs = [];
            const { price, at: seen } = sim.prices.get(q.asset.toLowerCase());
            const at = seen ?? sim.now;
            while (q.cursor < end) {
              const id = Number(++q.cursor);
              if (price === 0n || sim.now - at > 7200) continue; // executeAutomaticPush returns 0: no event
              const total = q.keys.reduce((t, k) => t + sim.claimable(id, k), 0n);
              if ((total * price) / E18 < 2n * E18) continue;
              if (sim.blocked.has(id)) { logs.push(nftIface.encodeEventLog('DeskPushBlocked', [id, q.keys[0], '0x'])); continue; } // pay reverts
              let amount = 0n;
              for (const k of q.keys) {
                const c = sim.claimable(id, k);
                sim.paid.set(`${id}:${k}`, (sim.paid.get(`${id}:${k}`) ?? 0n) + c);
                amount += c;
              }
              sim.received.set(id, (sim.received.get(id) ?? 0n) + amount);
              if (amount) logs.push(nftIface.encodeEventLog('DeskPushed', [id, q.keys[0], amount]));
            }
            if (q.cursor !== start) q.nextScanAt = BigInt(q.cursor === q.upperBound ? (Math.floor(sim.now / DAY) + 1) * DAY + 600 : sim.now + 900);
            return logs.map(l => ({ address: ADDR.nft, ...l }));
          },
        },
      },
      [ADDR.policy.toLowerCase()]: {
        oracle: async () => ADDR.oracle, oracleMaxAge: async () => 7200n, minimumUSD18: async () => 2n * E18,
      },
      [ADDR.oracle.toLowerCase()]: {
        latest: async a => { const p = sim.prices.get(a.toLowerCase()); const at = BigInt(p.at ?? sim.now); return [{ price18: p.price, observedAt: at, sourceUpdatedAt: at }, p.price ? 1n : 0n]; },
        assetOf: async () => ({ params: { maxAge: 900n } }),
        priceUSD18: async a => { const p = sim.prices.get(a.toLowerCase()); return [p.price, BigInt(p.at ?? sim.now)]; },
        underlyingOf: async a => a,
      },
    };
    const entryFake = addr => ({
      target: addr,
      rewardPolicy: async () => ({ assetId: B32(77), version: 1n, pricePolicy: B32(88), mode: 0n }),
      rewards: async () => ADDR.rewards,
      key: async () => [...sim.streams.entries()].find(([, x]) => x.entrySource === addr)?.[0],
    });
    return addr => views[String(addr).toLowerCase()] ?? entryFake(addr);
  }

  // Mirrors TxSender: a confirmed key is never re-sent; a revert is a simulation failure (counted, quarantined after 5).
  txSender(journal, { execute = true } = {}) {
    const sim = this;
    return {
      execute,
      async reconcileAll() { return []; },
      async call(key, contract, method, args = [], opts = {}) {
        const name = method.split('(')[0];
        const prev = journal.task(key);
        if (prev?.state === TaskState.Confirmed) return { status: 'confirmed', receipt: { logs: prev.logs ?? [], hash: prev.hash }, reconciled: true };
        if (prev?.state === TaskState.Quarantined) return { status: 'quarantined' };
        if (!execute) return { status: 'dry-run' }; // dry-run never changes chain state
        let logs;
        try { logs = contract._tx[name](args, opts); } catch (error) {
          if (!(error instanceof Revert)) throw error;
          journal.markFailure(key, `simulation: ${error.message}`);
          return { status: 'simulation-failed', error };
        }
        sim.calls.push({ method: name, args, key });
        const hash = B32(90_000 + sim.calls.length);
        journal.upsertTask(key, { state: TaskState.Confirmed, hash, logs });
        return { status: 'confirmed', receipt: { logs, hash } };
      },
    };
  }
}

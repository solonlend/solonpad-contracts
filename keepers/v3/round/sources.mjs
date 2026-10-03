// Reward-source discovery for the round and push keepers (frozen contracts, src/v3):
//   - V3LaunchFactory emits LaunchState(poolId, token, Locked) once per launch. V3RewardWiring.wire registers every
//     settlementKind-0 (USDC-quoted) token with RewardRoundManager.registerSource(token, pool): the token IS the round
//     source (seal -> PurchaseStock). Kind-1 (stock-quoted) tokens are DirectStock and never enter rounds.
//   - SolonStakingV2 emits SourceRegistered(key, pool, asset, kind) once per staking lane (the 5% staking share of a
//     pool's fees). Its round/payout adapter is the lazily created StakingRewardSource (createEntrySource(key), anyone):
//     kind 0 -> a round source sealed through RewardRoundManager.seal; kind 1 -> a RewardDistributor direct source (push).
//     Lanes not fed by the fee ledger (ledgerLane = false: protocol-Desk / V2 lanes) are only usable once funded
//     (nativeAvailable / fundedAmount); the keepers check that before acting.
// The first reward epoch of a discovered source is the UTC day of its registration block.
import { Contract, ZeroAddress } from 'ethers';
import { LogDiscovery, dayOf } from '../lib/discovery.mjs';
import { LaunchFactoryAbi, StakingV2Abi, RewardSourceAbi } from '../lib/abis.mjs';

export const LAUNCH_LOCKED = 3; // V3LaunchFactory.State.Locked

export class RewardSourceDiscovery {
  constructor({ provider, journal, logger, discover = {}, at = null }) {
    this.provider = provider;
    this.at = at ?? ((address, abi) => new Contract(address, abi, provider));
    const common = { provider, journal, logger, fromBlock: discover.fromBlock, params: discover.params };
    this.scanners = [];
    if (discover.factory) {
      const iface = new Contract(discover.factory, LaunchFactoryAbi).interface;
      const ev = iface.getEvent('LaunchState');
      this.scanners.push(new LogDiscovery({
        ...common, name: 'launch', address: discover.factory, topics: [ev.topicHash],
        decode: async (log, ts) => {
          const e = iface.parseLog(log);
          if (Number(e.args.state) !== LAUNCH_LOCKED) return null;
          const kind = Number(await this.at(e.args.token, RewardSourceAbi).settlementKind());
          return { id: e.args.token.toLowerCase(), type: 'token', address: e.args.token, poolId: e.args.poolId, settlementKind: kind, firstEpoch: dayOf(ts) };
        },
      }));
    }
    if (discover.staking) {
      this.staking = this.at(discover.staking, StakingV2Abi);
      const iface = new Contract(discover.staking, StakingV2Abi).interface;
      const ev = iface.getEvent('SourceRegistered');
      this.scanners.push(new LogDiscovery({
        ...common, name: 'staking', address: discover.staking, topics: [ev.topicHash],
        decode: async (log, ts) => {
          const e = iface.parseLog(log);
          return { id: e.args.key, type: 'stakingLane', key: e.args.key, pool: e.args.source, asset: e.args.asset, settlementKind: Number(e.args.kind), firstEpoch: dayOf(ts) };
        },
      }));
    }
  }

  get enabled() { return this.scanners.length > 0; }

  async sync() {
    const out = {};
    for (const s of this.scanners) out[s.name] = await s.sync();
    return out;
  }

  items(type) {
    return this.scanners.flatMap(s => s.items()).filter(i => !type || i.type === type);
  }

  // Round sources from launches: USDC-quoted coins only.
  roundTokens() {
    return this.items('token').filter(t => t.settlementKind === 0).map(t => ({ address: t.address, kind: 'token', firstEpoch: t.firstEpoch, discovered: true }));
  }

  // Stock-quoted coins pay holders DirectStock: the token is itself a trusted payout source (V3RewardWiring.wire) and a
  // RewardDistributor direct source. Its queue revision is always 1, so epochs are filtered on epochBudget instead.
  directTokens() {
    return this.items('token').filter(t => t.settlementKind === 1).map(t => ({ address: t.address, firstEpoch: t.firstEpoch, requireBudget: true, discovered: true }));
  }

  stakingLanes(kind) {
    return this.items('stakingLane').filter(l => l.settlementKind === kind);
  }

  async entrySourceOf(key) {
    const src = await this.staking.entrySource(key);
    return src === ZeroAddress ? null : src;
  }
}

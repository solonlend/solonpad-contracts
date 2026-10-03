// Arc events that make the pool-A keeper re-evaluate (they only trigger; state is re-read over HTTP):
//   PoolManager Swap of pool A (someone traded: the pool may have left the 1.3% band),
//   SolonStockOracle PriceAccepted / RelayedStockSource Relayed for our underlying (a fresh oracle price: a pending
//   demand can now be served, or the reference moved), NVDA.sol Transfer to the vault (a restock fill or a top-up).
import { id, zeroPadValue, getAddress } from 'ethers';

export const TOPICS = Object.freeze({
  Swap: id('Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)'),
  PriceAccepted: id('PriceAccepted(address,uint256,uint64,bool)'),
  Relayed: id('Relayed(address,uint256,uint64,uint80,uint64,uint64)'),
  Transfer: id('Transfer(address,address,uint256)'),
});

/// Addresses + topic0 set for the watcher, and the filter that keeps only pool-A-relevant logs.
export function restockSubscription({ poolManager, oracle, relayedSource = null, token, vault, underlying, poolId }) {
  const addresses = [poolManager, oracle, token, relayedSource].filter(Boolean).map(a => getAddress(a));
  const topics = [TOPICS.Swap, TOPICS.PriceAccepted, TOPICS.Relayed, TOPICS.Transfer];
  const u = zeroPadValue(getAddress(underlying), 32).toLowerCase();
  const v = zeroPadValue(getAddress(vault), 32).toLowerCase();
  const pid = poolId.toLowerCase();
  const relevant = log => {
    const t0 = log.topics?.[0];
    const t1 = log.topics?.[1]?.toLowerCase();
    if (t0 === TOPICS.Swap) return t1 === pid;
    if (t0 === TOPICS.PriceAccepted || t0 === TOPICS.Relayed) return t1 === u;
    if (t0 === TOPICS.Transfer) return log.topics?.[2]?.toLowerCase() === v;
    return false;
  };
  return { addresses, topics, relevant };
}

#!/usr/bin/env node
// Fetch the raw history the oracle-keeper replay runs on: Chainlink AnswerUpdated logs of the
// NVDA/AAPL/TSLA aggregators behind the RH feed proxies, and the Swap logs of the three
// deepest stock/USDG V3 pools (for the TWAP trigger). eth_getLogs is chunked adaptively
// (halve the range on an error / truncated answer). Output: data/rh-<from>-<to>.json (gitignored, ~14 MB).
//   node oracle/replay/fetch.mjs [--days=7] [--rpc=https://rpc.mainnet.chain.robinhood.com/rpc]
import { JsonRpcProvider, Contract, id, AbiCoder } from 'ethers';
import { writeFileSync, mkdirSync } from 'node:fs';
import { STOCKS } from '../stocks.mjs';

const arg = (k, d) => process.argv.find(a => a.startsWith(`--${k}=`))?.slice(k.length + 3) ?? d;
const RPC = arg('rpc', 'https://rpc.mainnet.chain.robinhood.com/rpc');
const DAYS = Number(arg('days', '7'));
const provider = new JsonRpcProvider(RPC, 4663, { staticNetwork: true });
const coder = AbiCoder.defaultAbiCoder();

export const ANSWER_UPDATED = id('AnswerUpdated(int256,uint256,uint256)');
export const SWAP = id('Swap(address,address,int256,int256,uint160,uint128,int24)');

async function blockAt(ts, lo, hi) {
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if ((await provider.getBlock(mid)).timestamp < ts) lo = mid + 1; else hi = mid;
  }
  return lo;
}

async function logs(address, topic, from, to) {
  const out = [];
  let step = 200_000;
  for (let a = from; a <= to;) {
    const b = Math.min(to, a + step - 1);
    try {
      const got = await provider.getLogs({ address, topics: [topic], fromBlock: a, toBlock: b });
      if (got.length >= 10_000 && step > 1000) { step = Math.floor(step / 2); continue; }
      out.push(...got);
      a = b + 1;
      if (got.length < 2_000 && step < 2_000_000) step *= 2;
    } catch (e) {
      if (step <= 500) throw e;
      step = Math.floor(step / 2);
    }
  }
  return out;
}

const head = await provider.getBlock('latest');
const fromTs = head.timestamp - DAYS * 86_400;
const fromBlock = await blockAt(fromTs, head.number - Math.ceil(DAYS * 86_400 * 12), head.number);
const first = await provider.getBlock(fromBlock);
const result = {
  fetchedAt: new Date().toISOString(), rpc: RPC, chainId: 4663,
  fromBlock, fromTimestamp: first.timestamp, toBlock: head.number, toTimestamp: head.timestamp,
  stocks: {},
};
for (const s of STOCKS) {
  const proxy = new Contract(s.feed, ['function aggregator() view returns (address)', 'function phaseId() view returns (uint16)'], provider);
  const aggregator = await proxy.aggregator();
  const phaseId = Number(await proxy.phaseId());
  const raw = await logs(aggregator, ANSWER_UPDATED, fromBlock, head.number);
  const rounds = raw.map(l => ({
    block: l.blockNumber, logIndex: l.index, tx: l.transactionHash,
    answer: BigInt.asIntN(256, BigInt(l.topics[1])).toString(), roundId: Number(BigInt(l.topics[2])),
    updatedAt: Number(BigInt(l.data)),
  }));
  const swapsRaw = await logs(s.pool, SWAP, fromBlock, head.number);
  // State at the window start, so the replay does not begin blind. The public RPC keeps no historical state
  // for eth_call 7 days back ("historical state ... is not available"), so read it from logs instead: the last
  // AnswerUpdated in the 4 days before the window (feed heartbeat is 24h; a weekend is < 3 days) and the last Swap
  // before the window (scanning back 200k blocks at a time).
  const before = await logs(aggregator, ANSWER_UPDATED, Math.max(0, fromBlock - 3_500_000), fromBlock - 1);
  const lastRound = before.at(-1);
  let lastSwap = null;
  for (let b = fromBlock - 1; b > fromBlock - 5_000_000 && !lastSwap; b -= 200_000) {
    const got = await provider.getLogs({ address: s.pool, topics: [SWAP], fromBlock: Math.max(0, b - 199_999), toBlock: b });
    lastSwap = got.at(-1) ?? null;
  }
  const pool = new Contract(s.pool, ['function token0() view returns (address)', 'function token1() view returns (address)'], provider);
  const [token0, token1] = await Promise.all([pool.token0(), pool.token1()]);
  const stockIsToken0 = token0.toLowerCase() === s.underlying.toLowerCase();
  const stable = stockIsToken0 ? token1 : token0;
  const stableDecimals = Number(await new Contract(stable, ['function decimals() view returns (uint8)'], provider).decimals());
  const swaps = swapsRaw.map(l => {
    const [, , sqrtPriceX96, , tick] = coder.decode(['int256', 'int256', 'uint160', 'uint128', 'int24'], l.data);
    return { block: l.blockNumber, logIndex: l.index, tick: Number(tick), sqrtPriceX96: sqrtPriceX96.toString() };
  });
  result.stocks[s.symbol] = {
    underlying: s.underlying, feedProxy: s.feed, aggregator, phaseId, pool: s.pool, stockIsToken0, stable, stableDecimals,
    initial: {
      round: lastRound ? { block: lastRound.blockNumber, answer: BigInt.asIntN(256, BigInt(lastRound.topics[1])).toString(), roundId: Number(BigInt(lastRound.topics[2])), updatedAt: Number(BigInt(lastRound.data)) } : null,
      swap: lastSwap ? { block: lastSwap.blockNumber, tick: Number(coder.decode(['int256', 'int256', 'uint160', 'uint128', 'int24'], lastSwap.data)[4]) } : null,
    },
    rounds, swaps,
  };
  console.log(`${s.symbol}: aggregator ${aggregator} phase ${phaseId}: ${rounds.length} AnswerUpdated, ${swaps.length} swaps`);
}
// Block -> timestamp: RH (Arbitrum Orbit) blocks are not evenly spaced; record exact timestamps for
// every block that carries a round, and an anchor grid (every 5k blocks, ~8 min) to interpolate swap times.
const need = new Set();
for (const s of Object.values(result.stocks)) for (const r of s.rounds) need.add(r.block);
for (let b = fromBlock; b <= head.number; b += 5_000) need.add(b);
need.add(head.number);
result.blockTimestamps = {};
const list = [...need].sort((x, y) => x - y);
for (let i = 0; i < list.length; i += 20) {
  const chunk = list.slice(i, i + 20);
  let blocks;
  for (let attempt = 0; ; attempt++) {
    try { blocks = await Promise.all(chunk.map(b => provider.getBlock(b))); break; } catch (e) {
      if (attempt >= 4) throw e;
      await new Promise(r => setTimeout(r, 1000 * 2 ** attempt));
    }
  }
  for (const b of blocks) result.blockTimestamps[b.number] = b.timestamp;
}
mkdirSync(new URL('./data/', import.meta.url), { recursive: true });
const file = new URL(`./data/rh-${fromBlock}-${head.number}.json`, import.meta.url);
writeFileSync(file, JSON.stringify(result));
console.log(`range blocks ${fromBlock}..${head.number} = ${new Date(first.timestamp * 1000).toISOString()} .. ${new Date(head.timestamp * 1000).toISOString()}`);
console.log(`wrote ${file.pathname}`);

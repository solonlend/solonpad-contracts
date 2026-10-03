#!/usr/bin/env node
// r9: probe an RH WebSocket RPC with the oracle keeper's own LogWatcher (same addresses/topics as oracle-keeper:
// Chainlink aggregators' AnswerUpdated, RH V3 pools' Swap). Read-only, no key needed beyond the RPC URLs.
//   RH_WS_URL=wss://... [RH_RPC_URL=https://...] node bin/rh-ws-probe.mjs [--seconds=120]
// Prints counts per source/topic and whether each log came over WS or the HTTP catch-up. URLs are never printed.
import { JsonRpcProvider } from 'ethers';
import WebSocket from 'ws';
import { STOCKS } from '../oracle/stocks.mjs';
import { SUBSCRIBED_TOPICS, TOPICS } from '../oracle/keeper.mjs';
import { LogWatcher } from '../oracle/watch.mjs';

const seconds = Number(process.argv.find(a => a.startsWith('--seconds='))?.split('=')[1] ?? 120);
const wsUrl = process.env.RH_WS_URL;
if (!wsUrl) throw new Error('RH_WS_URL not set');
const http = new JsonRpcProvider(process.env.RH_RPC_URL ?? 'https://rpc.mainnet.chain.robinhood.com/rpc', 4663, { staticNetwork: true });
const name = {};
for (const s of STOCKS) { name[s.aggregator.toLowerCase()] = `${s.symbol} aggregator`; name[s.pool.toLowerCase()] = `${s.symbol} pool`; }
const topicName = { [TOPICS.AnswerUpdated]: 'AnswerUpdated', [TOPICS.Swap]: 'Swap' };
const counts = {};
const firsts = [];
const logger = { info: m => console.log(`[info] ${m}`), warn: m => console.log(`[warn] ${m}`), error: m => console.log(`[error] ${m}`) };
let connects = 0;
const w = new LogWatcher({
  http, wsUrl, WebSocketImpl: WebSocket, logger,
  addresses: STOCKS.flatMap(s => [s.aggregator, s.pool]), topics: SUBSCRIBED_TOPICS,
  onConnect: () => { connects++; console.log(`[ws] connected, eth_subscribe("logs") sent at ${new Date().toISOString()}`); },
  onLogs: (logs, via) => {
    for (const l of logs) {
      const k = `${via} ${name[l.address.toLowerCase()] ?? l.address} ${topicName[l.topics[0]] ?? l.topics[0]}`;
      counts[k] = (counts[k] ?? 0) + 1;
      if (via === 'ws' && firsts.length < 3) firsts.push(`${k} block ${Number(l.blockNumber)} tx ${l.transactionHash}`);
    }
  },
  initialLookback: 200, catchUpMs: 60_000,
});
const head0 = await http.getBlockNumber();
console.log(`[probe] RH head ${head0}; listening ${seconds}s`);
await w.start();
setTimeout(() => {
  w.stop();
  console.log(JSON.stringify({ seconds, connects, stats: w.stats, counts, firstWsLogs: firsts }, null, 2));
  process.exit(0);
}, seconds * 1000);

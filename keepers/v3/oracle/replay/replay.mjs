#!/usr/bin/env node
// Replay the oracle keeper's decision function (oracle/decide.mjs: decidePush/recordPush, unchanged) over the real
// RH history fetched by fetch.mjs: Chainlink AnswerUpdated rounds and V3 pool swaps (for the 30-min TWAP).
//   node oracle/replay/replay.mjs [--file=data/rh-<a>-<b>.json] [--out=oracle/replay/summary-<date>.json]
//        [--fee-wei=..] [--gas=..] [--gas-price-wei=..] [--eth-usd=..]
// Method:
//   - decisions are evaluated at every feed round and on a 60 s grid (the keeper's tick); swaps update the TWAP
//     state continuously, so a TWAP-triggered push is found within <= 60 s (live keeper: debounce 3 s + poll 15 s);
//   - the window starts with one push of all three (not counted: the keeper was "already running");
//   - observation = what ChainlinkStockSource.observe returns: price = feed answer (8 dp -> 18 dp, branch A),
//     TWAP = 30-min time-weighted tick (floor, as the contract) -> stable per stock, USDG/USD taken as 1.0;
//   - swap times are interpolated between block timestamps sampled every 5,000 blocks (~8 min);
//   - demand pushes (restock bot) and the L1-block guard are not replayed (no history; 30 s min interval kept);
//   - monthly = 7-day count x 30/7 (the sample has 5 weekdays + 2 weekend days, the same mix as a month).
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { decidePush, recordPush, mergeParams, sessionOpen, twapDivergent, E18 } from '../decide.mjs';

const arg = (k, d) => process.argv.find(a => a.startsWith(`--${k}=`))?.slice(k.length + 3) ?? d;
const here = new URL('./', import.meta.url).pathname;
const dataDir = `${here}data/`;
const file = arg('file', null) ?? dataDir + readdirSync(dataDir).filter(f => /^rh-\d+-\d+\.json$/.test(f)).sort().at(-1);
const D = JSON.parse(readFileSync(file, 'utf8'));

// Per-push cost, measured on an RH mainnet fork (docs/ORACLE-PUSH-r8.md §2): LZ fee for 3 stocks with
// 1 required + 2 optional DVNs, poke(3) receipt gasUsed on anvil + NodeInterface L1 component, basefee at that block.
const COST = {
  lzFeeWei: BigInt(arg('fee-wei', '97047640295085')),
  gas: BigInt(arg('gas', String(696_415 + 660))),
  gasPriceWei: BigInt(arg('gas-price-wei', '21286000')),
  ethUsd8: BigInt(arg('eth-usd', '268271000000')),
};
COST.rhGasWei = COST.gas * COST.gasPriceWei;
COST.totalWei = COST.lzFeeWei + COST.rhGasWei;
const usd = wei => Number((wei * COST.ethUsd8) / 10n ** 8n) / 1e18;
COST.totalUsd = usd(COST.totalWei);

// ---------------------------------------------------------------- timeline
const anchors = Object.entries(D.blockTimestamps).map(([b, t]) => [Number(b), t]).sort((a, b) => a[0] - b[0]);
function tsOf(block) {
  if (D.blockTimestamps[block] != null) return D.blockTimestamps[block];
  let lo = 0, hi = anchors.length - 1;
  if (block <= anchors[0][0]) return anchors[0][1];
  if (block >= anchors[hi][0]) return anchors[hi][1];
  while (hi - lo > 1) { const m = (lo + hi) >> 1; if (anchors[m][0] <= block) lo = m; else hi = m; }
  const [b0, t0] = anchors[lo], [b1, t1] = anchors[hi];
  return t0 + ((t1 - t0) * (block - b0)) / (b1 - b0);
}

const stocks = Object.entries(D.stocks).map(([symbol, s]) => {
  const rounds = s.rounds.map(r => ({ t: tsOf(r.block), price18: BigInt(r.answer) * 10n ** 10n, updatedAt: r.updatedAt })).sort((a, b) => a.t - b.t);
  const swaps = s.swaps.map(w => ({ t: tsOf(w.block), tick: w.tick, k: w.block * 1e4 + w.logIndex })).sort((a, b) => a.t - b.t || a.k - b.k);
  return { symbol, u: s.underlying, stockIsToken0: s.stockIsToken0, stableDecimals: s.stableDecimals, init: s.initial, rounds, swaps };
});

const tickToStable18 = (tick, s) => {
  // raw token1 per raw token0 = 1.0001^tick; stock has 18 dp, stable `stableDecimals`.
  const p = Math.pow(1.0001, tick);
  const stablePerStock = s.stockIsToken0 ? p * 10 ** (18 - s.stableDecimals) : (1 / p) * 10 ** (18 - s.stableDecimals);
  return BigInt(Math.round(stablePerStock * 1e6)) * 10n ** 12n;
};

// Stateful cursor per stock: feed round in force and 30-min TWAP at time t (t non-decreasing).
function makeCursor(s, window = 1800) {
  let ri = -1, si = -1;
  let round = s.init.round ? { price18: BigInt(s.init.round.answer) * 10n ** 10n, updatedAt: s.init.round.updatedAt } : null;
  const hist = [{ t: -Infinity, tick: s.init.swap?.tick ?? null }]; // tick changes, ascending
  return t => {
    while (ri + 1 < s.rounds.length && s.rounds[ri + 1].t <= t) round = s.rounds[++ri];
    while (si + 1 < s.swaps.length && s.swaps[si + 1].t <= t) { const w = s.swaps[++si]; hist.push({ t: w.t, tick: w.tick }); }
    while (hist.length > 2 && hist[1].t <= t - window) hist.shift();
    let acc = 0;
    for (let i = 0; i < hist.length; i++) {
      const a = Math.max(hist[i].t, t - window);
      const b = i + 1 < hist.length ? hist[i + 1].t : t;
      if (b > a && hist[i].tick != null) acc += hist[i].tick * (b - a);
    }
    const tick = Math.floor(acc / window);
    return round ? { ok: true, price18: round.price18, twapPrice18: tickToStable18(tick, s), quoteUsd18: E18, sourceUpdatedAt: round.updatedAt } : { ok: false, error: 'no round' };
  };
}

function simulate(params) {
  const p = mergeParams(params);
  const t0 = D.fromTimestamp, t1 = D.toTimestamp;
  const cursors = stocks.map(s => [s.u, makeCursor(s)]);
  const times = new Set();
  for (let t = t0; t <= t1; t += 60) times.add(t);
  for (const s of stocks) for (const r of s.rounds) if (r.t >= t0 && r.t <= t1) times.add(r.t);
  const order = [...times].sort((a, b) => a - b);
  const read = t => Object.fromEntries(cursors.map(([u, c]) => [u, c(t)]));
  let current = read(t0);
  let last = recordPush({}, { underlyings: Object.keys(current), observations: current, pushedAt: t0, l1Block: null });
  let lastPushAt = t0;
  const pushes = [];
  let deskStaleSec = 0, sessionSec = 0, arcDivergentPushes = 0;
  let prev = t0;
  for (const t of order) {
    if (t === t0) continue;
    // Desk view: execPrice needs an observation <= 15 min old (observedAt = push time on RH; LZ delay ignored).
    if (sessionOpen(prev, p.session)) { sessionSec += t - prev; if (prev - lastPushAt > 900) deskStaleSec += t - prev; }
    prev = t;
    current = read(t);
    const d = decidePush({ nowSec: t, l1Block: null, current, last, lastPushAt, params: p });
    if (!d.push) continue;
    last = recordPush(last, { underlyings: d.underlyings, observations: current, pushedAt: t, l1Block: null });
    lastPushAt = t;
    const div = d.underlyings.filter(u => twapDivergent(current[u], p.maxTwapBps)).length;
    if (div) arcDivergentPushes++;
    const reasons = [...new Set(Object.values(d.reasons).flat())];
    pushes.push({ t, reason: d.reason, reasons, divergentStocks: div });
  }
  const days = (t1 - t0) / 86_400;
  const byReason = {};
  for (const x of pushes) byReason[x.reason] = (byReason[x.reason] ?? 0) + 1;
  const byDay = {};
  for (const x of pushes) { const k = new Date(x.t * 1000).toISOString().slice(0, 10); byDay[k] = (byDay[k] ?? 0) + 1; }
  const weekend = pushes.filter(x => [0, 6].includes(new Date(x.t * 1000).getUTCDay())).length;
  const perMonth = (pushes.length * 30) / days;
  return {
    params: { deviationBps: p.deviationBps, heartbeatSec: p.heartbeatSec, heartbeatMarginSec: p.heartbeatMarginSec, freshnessSec: p.freshnessSec, twapTrigger: p.twapTrigger },
    pushes: pushes.length, days: Number(days.toFixed(3)), perDay: Number((pushes.length / days).toFixed(2)), perMonth: Math.round(perMonth),
    weekdayPushes: pushes.length - weekend, weekendPushes: weekend, byReason, byDayUtc: byDay,
    costPerMonthUsd: Number((perMonth * COST.totalUsd).toFixed(2)),
    pushesLandingTwapDivergent: arcDivergentPushes,
    deskStaleShareOfSession: Number((deskStaleSec / Math.max(1, sessionSec)).toFixed(3)),
  };
}

// ---------------------------------------------------------------- run
const feedStats = Object.fromEntries(stocks.map(s => {
  const byDay = {};
  for (const r of s.rounds) { const k = new Date(r.t * 1000).toISOString().slice(0, 10); byDay[k] = (byDay[k] ?? 0) + 1; }
  return [s.symbol, { rounds: s.rounds.length, swaps: s.swaps.length, roundsByDayUtc: byDay }];
}));
const base = simulate({ deviationBps: 50, heartbeatSec: 7_200 }); // r8 default (0.5% + 2h) until 2026-10-02; variants.onDemand1pct = now
const sensitivity = [];
for (const deviationBps of [25, 50, 100]) for (const heartbeatSec of [3_600, 7_200]) {
  const r = simulate({ deviationBps, heartbeatSec });
  sensitivity.push({ deviationBps, heartbeatSec, perMonth: r.perMonth, costPerMonthUsd: r.costPerMonthUsd, byReason: r.byReason });
}
const variants = {
  noHeartbeat: simulate({ heartbeatSec: 10 ** 9, heartbeatMarginSec: 0 }),
  deskFreshness840: simulate({ freshnessSec: 840 }),
  noTwapTrigger: simulate({ twapTrigger: false }),
  // 2026-10-02 on-demand mode (mainnet config): 1% deviation, heartbeat off; demand pushes are added separately.
  onDemand1pct: simulate({ deviationBps: 100, heartbeatSec: 0 }),
  onDemand2pct: simulate({ deviationBps: 200, heartbeatSec: 0 }),
};
const summary = {
  generatedAt: new Date().toISOString(), source: file.replace(here, ''), fetchedAt: D.fetchedAt,
  window: { fromBlock: D.fromBlock, toBlock: D.toBlock, from: new Date(D.fromTimestamp * 1000).toISOString(), to: new Date(D.toTimestamp * 1000).toISOString() },
  method: 'decide.mjs over real rounds+swaps; eval at each round and every 60s; monthly = 7d x 30/7; USDG=1; demand not replayed',
  costPerPush: { lzFeeWei: COST.lzFeeWei.toString(), rhGas: COST.gas.toString(), rhGasPriceWei: COST.gasPriceWei.toString(), rhGasWei: COST.rhGasWei.toString(), totalWei: COST.totalWei.toString(), ethUsd: Number(COST.ethUsd8) / 1e8, totalUsd: Number(COST.totalUsd.toFixed(4)) },
  feeds: feedStats, default: base, sensitivity, variants,
};
const out = arg('out', `${here}summary-${new Date().toISOString().slice(0, 10)}.json`);
writeFileSync(out, JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({ costPerPush: summary.costPerPush, default: base, sensitivity: sensitivity.map(s => [s.deviationBps, s.heartbeatSec, s.perMonth, s.costPerMonthUsd]), variants: Object.fromEntries(Object.entries(variants).map(([k, v]) => [k, { perMonth: v.perMonth, cost: v.costPerMonthUsd, byReason: v.byReason, deskStale: v.deskStaleShareOfSession }])) }, null, 1));
console.log(`wrote ${out}`);

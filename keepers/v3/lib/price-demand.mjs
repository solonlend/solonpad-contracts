// On-demand oracle pushes (2026-10-02). Keepers whose action needs a Live execution price on Arc (round start,
// daily payout push, pool-A restock; later the stock-quote launch API and the StockFeeConverter flow) ask the RH
// oracle keeper for a push instead of paying for a heartbeat that keeps the price fresh all day:
//   1. checkArcPrice: read the Arc SolonStockOracle (latest + the asset's on-chain maxAge, never a constant here);
//   2. not fresh enough but otherwise usable (priceUSD18 != 0: only the observation age is wrong) -> requestPush
//      writes this requester's entry into ${statusDir}/oracle-push-demand.json and the action is deferred;
//   3. the oracle keeper (oracle/keeper.mjs) pushes; the requester polls observedAt on Arc on its next ticks and acts
//      once the new observation has landed (it never blocks a tick: the oracle keeper may share its signer lock).
// One file, one entry per requester ({ requests: { round: {...}, restock: {...} } }), merged under a mkdir lock and
// written by atomic rename. Concurrent requests do not cause duplicate pushes: an entry is not re-stamped while it
// waits (refreshSec), and the oracle keeper treats a push sent up to demandCoalesceSec BEFORE a request as answering
// it (it is still in flight over LayerZero). The top-level underlyings/requestedAt keep the v1 shape readable.
import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tryLock, unlock } from './lock.mjs';

export const DEMAND_FILE = 'oracle-push-demand.json';
export const DEMAND_DEFAULTS = Object.freeze({
  refreshSec: 600, // re-stamp a still-unanswered request after 10 min (a push that never landed)
  ttlSec: 1_800, // oracle keeper demandTtlSec: older entries are dropped
  marginSec: 120, // the action must land with at least this much of maxAge left
});

const wallNow = () => Math.floor(Date.now() / 1000);
const sleep = ms => new Promise(r => setTimeout(r, ms));

function readFile(file) {
  if (!existsSync(file)) return {};
  try { return JSON.parse(readFileSync(file, 'utf8')) ?? {}; } catch { return {}; }
}

/// The v2 requests from whatever is on disk (a v1 file becomes one anonymous request). Every entry is normalised to
/// { underlyings, at: { underlying: requestedAt }, requestedAt (latest), reason }: each stock keeps its own stamp, so
/// adding a stock never re-stamps one whose push may be in flight, and a landed stock is cleared alone.
export function requestsOf(body) {
  const raw = body?.requests && typeof body.requests === 'object' ? body.requests
    : Array.isArray(body?.underlyings) && Number(body?.requestedAt) > 0 ? { legacy: body } : {};
  const out = {};
  for (const [k, r] of Object.entries(raw)) {
    if (!r || !Array.isArray(r.underlyings)) continue;
    const at = {};
    for (const u of r.underlyings) at[String(u)] = Number(r.at?.[u] ?? r.requestedAt ?? 0);
    out[k] = { at, reason: String(r.reason ?? '') };
  }
  return out;
}

const keyOf = (at, u) => Object.keys(at).find(x => x.toLowerCase() === String(u).toLowerCase()) ?? String(u);

/// Pure merge: returns { body, status } — 'demand-written' when at least one stock of this requester was (re)stamped,
/// 'demand-pending' when every asked stock already has a stamp younger than refreshSec.
export function mergeRequest(body, { requester, underlyings, reason = '', nowSec, refreshSec = DEMAND_DEFAULTS.refreshSec, ttlSec = DEMAND_DEFAULTS.ttlSec }) {
  const reqs = prune(requestsOf(body), nowSec, ttlSec);
  const mine = reqs[requester] ?? { at: {}, reason: '' };
  let status = 'demand-pending';
  for (const u of underlyings) {
    const k = keyOf(mine.at, u);
    if (!(k in mine.at) || nowSec - mine.at[k] >= refreshSec) { mine.at[k] = nowSec; status = 'demand-written'; }
  }
  if (status === 'demand-written') mine.reason = String(reason).slice(0, 120);
  reqs[requester] = mine;
  return { body: summarize(reqs), status };
}

/// Drop this requester's stamps for `underlyings` (all of them when omitted). null when nothing changed.
export function dropRequest(body, requester, underlyings = null) {
  const reqs = requestsOf(body);
  const mine = reqs[requester];
  if (!mine) return null;
  const drop = underlyings ? underlyings.map(u => keyOf(mine.at, u)).filter(k => k in mine.at) : Object.keys(mine.at);
  if (!drop.length) return null;
  for (const k of drop) delete mine.at[k];
  return summarize(reqs);
}

function prune(reqs, nowSec, ttlSec) {
  for (const r of Object.values(reqs)) for (const [u, t] of Object.entries(r.at)) if (!(nowSec - t <= ttlSec)) delete r.at[u];
  return reqs;
}

function summarize(reqs) {
  const requests = {};
  for (const [k, r] of Object.entries(reqs)) {
    const us = Object.keys(r.at);
    if (us.length) requests[k] = { underlyings: us, at: r.at, requestedAt: Math.max(...Object.values(r.at)), reason: r.reason };
  }
  const live = Object.entries(requests);
  return {
    version: 2,
    underlyings: [...new Set(live.flatMap(([, r]) => r.underlyings))],
    requestedAt: live.reduce((m, [, r]) => Math.max(m, r.requestedAt), 0),
    reason: live.map(([k, r]) => `${k}: ${r.reason}`).join('; ').slice(0, 120),
    requests,
  };
}

async function withDemandLock(statusDir, fn) {
  mkdirSync(statusDir, { recursive: true });
  const path = join(statusDir, `${DEMAND_FILE}.lock`);
  let locked = false;
  for (let i = 0; i < 40 && !(locked = tryLock(path, 'price-demand', 10_000)); i++) await sleep(50);
  // A holder older than 10 s is taken over by tryLock; after 2 s of a live holder we write anyway (worst case one
  // lost stamp, rewritten by its requester on the next tick).
  if (!locked) console.warn(`price-demand: ${path} busy for 2 s; writing without the lock`);
  try { return fn(); } finally { if (locked) unlock(path); }
}

function writeAtomic(file, body) {
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(body));
  renameSync(tmp, file);
}

/// Add / refresh this requester's entry. Returns 'demand-written' | 'demand-pending'.
export async function requestPush({ statusDir, requester, underlyings, reason, nowSec = wallNow(), refreshSec, ttlSec }) {
  if (!statusDir) throw new Error('requestPush: statusDir required');
  return withDemandLock(statusDir, () => {
    const file = join(statusDir, DEMAND_FILE);
    const { body, status } = mergeRequest(readFile(file), { requester, underlyings, reason, nowSec, refreshSec, ttlSec });
    if (status === 'demand-written') writeAtomic(file, body);
    return status;
  });
}

/// Remove this requester's stamps for `underlyings` (all when omitted) once their price has landed.
export async function clearRequest({ statusDir, requester, underlyings = null }) {
  if (!statusDir) return false;
  const file = join(statusDir, DEMAND_FILE);
  if (!existsSync(file)) return false;
  return withDemandLock(statusDir, () => {
    const body = dropRequest(readFile(file), requester, underlyings);
    if (body) writeAtomic(file, body);
    return Boolean(body);
  });
}

// ------------------------------------------------------------------------------------------- Arc side

export const ArcOracleAbi = [
  'function latest(address asset) view returns (tuple(uint256 price18,uint256 multiplier,uint256 quoteUsd18,uint256 twapPrice18,uint64 sourceUpdatedAt,uint80 roundId,uint64 observedAt,uint64 sourceBlock) o, uint8 s)',
  'function assetOf(address asset) view returns (tuple(address token,address source,tuple(uint32 maxAge,uint16 maxMoveBps,uint16 confirmBps,uint16 maxDepegBps,uint32 maxSourceAge,uint16 maxTwapBps) params,bool paused))',
  'function priceUSD18(address asset) view returns (uint256 price,uint256 updatedAt)',
  'function underlyingOf(address token) view returns (address)',
];
export const STATUS_LIVE = 1;
export const STATUS_STALE = 2;

/// Freshness of one asset on the Arc SolonStockOracle against its own on-chain maxAge.
///   windowSec: how old the observation may be when the action lands (default: the asset's maxAge = the execPrice
///              window; the payout push passes RewardDistributor.oracleMaxAge). marginSec is kept back for landing.
/// Returns { fresh, demandable, underlying, status, observedAt, sourceUpdatedAt, age, maxAge, window, reason }.
///   demandable: a relayed price exists and the oracle is Live or Stale with an OLD observation. Stale also covers
///   "the relayed Chainlink time is > maxSourceAge", and with no heartbeat that time only moves when somebody pushes:
///   whether the RH feed is really frozen is the RH oracle keeper's call (its market gate), not the requester's.
///   Not demandable: paused, divergent, suspect, no relayed price, or Stale on a RECENT observation (= frozen feed).
export async function checkArcPrice({ oracle, asset, nowSec, windowSec = null, marginSec = DEMAND_DEFAULTS.marginSec }) {
  const [[o, s], a, [p], u] = await Promise.all([
    oracle.latest(asset), oracle.assetOf(asset), oracle.priceUSD18(asset), oracle.underlyingOf(asset).catch(() => null),
  ]);
  const maxAge = Number(a.params.maxAge);
  const window = windowSec ?? maxAge;
  const observedAt = Number(o.observedAt);
  const status = Number(s);
  const age = observedAt ? Math.max(0, nowSec - observedAt) : Infinity;
  const underlying = u && BigInt(u) !== 0n ? u : asset; // the RH underlying the oracle keeper lists
  const out = { underlying, status, observedAt, sourceUpdatedAt: Number(o.sourceUpdatedAt), age, maxAge, window };
  // execPrice consumers (no windowSec) need status Live; priceUSD18 consumers (windowSec, e.g. the 2h payout window)
  // bound the age themselves, so the 15-min component of the status does not apply to them.
  const recent = age + marginSec <= window;
  const fresh = p > 0n && recent && (windowSec != null || status === STATUS_LIVE);
  if (fresh) return { ...out, fresh: true, demandable: false, reason: 'fresh' };
  const relayed = BigInt(o.price18 ?? 0n) > 0n;
  if (!relayed) return { ...out, fresh: false, demandable: false, reason: 'no relayed price' };
  if (status !== STATUS_LIVE && status !== STATUS_STALE) return { ...out, fresh: false, demandable: false, reason: `oracle status ${status} (paused / divergent / suspect)` };
  if (status === STATUS_STALE && age <= maxAge) return { ...out, fresh: false, demandable: false, reason: 'recent observation but not usable: Chainlink feed frozen (sourceUpdatedAt beyond maxSourceAge)' };
  return { ...out, fresh: false, demandable: true, reason: `observation ${age === Infinity ? 'missing' : `${age}s old`} (window ${window}s, margin ${marginSec}s)` };
}

/// Fresh -> clear our demand and go; old but usable -> (execute only) request a push and defer.
/// Returns { ok, demand: 'demand-written' | 'demand-pending' | 'dry-run' | null, check }.
export async function ensureFreshPrice({ oracle, asset, nowSec, statusDir, requester, execute = true, windowSec = null, marginSec, refreshSec, reason = '', wallSec }) {
  const check = await checkArcPrice({ oracle, asset, nowSec, windowSec, marginSec });
  if (check.fresh) {
    if (execute) await clearRequest({ statusDir, requester, underlyings: [check.underlying] }).catch(() => false);
    return { ok: true, demand: null, check };
  }
  if (!check.demandable) return { ok: false, demand: null, check };
  if (!execute) return { ok: false, demand: 'dry-run', check };
  if (!statusDir) return { ok: false, demand: 'no-status-dir', check };
  const demand = await requestPush({ statusDir, requester, underlyings: [check.underlying], reason: `${reason} ${check.reason}`.trim(), nowSec: wallSec ?? wallNow(), refreshSec });
  return { ok: false, demand, check };
}

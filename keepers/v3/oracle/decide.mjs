// Pure decision logic of the RH oracle push keeper (r8, event-driven; replaces the hourly poke).
// The same functions drive the live keeper (oracle/keeper.mjs) and the 7-day replay (oracle/replay/replay.mjs).
//
// One StockPriceSender.poke carries every listed stock in one LayerZero message. Measured on an RH fork
// (docs/ORACLE-PUSH-r8.md): the LZ fee for 3 stocks is +0.07% over 1 stock and the RH gas +0.002 USD, so when any
// stock is due all readable stocks are sent (batchAll) and every heartbeat clock restarts together.
//
// Triggers, per stock, against the last observation WE KNOW was pushed (ours or anyone's PricesSent):
//   initial      nothing pushed yet (keeper start without history)
//   deviation    |price - lastPushed| > deviationBps (default 100 = 1%; 50 until 2026-10-02)
//   twap         the last pushed observation was Divergent on Arc (|Chainlink - TWAP·USDG| > maxTwapBps) and the
//                current one is not: push to clear it (a push that would *create* Divergent is never a trigger)
//   heartbeat    age of last push >= heartbeatSec - heartbeatMarginSec, only while the 24/5 session is open and the
//                feed is younger than maxSourceAgeSec (beyond it the Arc oracle marks Stale anyway)
//   freshness    optional desk mode (freshnessSec > 0): keep execPrice (maxAge 15 min) live during the session
//   demand       ${statusDir}/oracle-push-demand.json asks for it (lib/price-demand.mjs: one entry per requester) and
//                no push was sent since that request's requestedAt - demandCoalesceSec: a push still in flight over
//                LayerZero answers every request made while it travels, so concurrent requesters cost one push
// On-demand mode (2026-10-02): heartbeatSec 0 turns the heartbeat off; deviation (1%) + demand keep the price fresh
// for the keepers that need it (docs/MAINNET-RUNBOOK-v3.md §1.5 cost).
// Review M1 (r12): a stock whose market is closed (lib/market.mjs NYSE calendar: weekend, holiday, the evening before
// a holiday) or whose feed is older than the Chainlink heartbeat + margin is NEVER pushed, whatever the trigger:
// a push would keep the Arc oracle Live on a frozen price. Without pushes Arc goes Stale (15 min / consumers' 2h).
// Guards: one push per minIntervalSec (demand: demandMinIntervalSec), and never twice in the same EVM block.number
// (on RH that is the L1 block number; RelayedStockSource ignores an observation whose sourceBlock is not newer).
import { sessionState, marketGate, NYSE_HOLIDAYS } from '../lib/market.mjs';

export const ORACLE_DEFAULTS = Object.freeze({
  // 2026-10-02 on-demand mode (was 50 bps + 2h heartbeat): 1% deviation, no heartbeat; keepers that need a fresh price
  // request it (demand). heartbeatSec > 0 brings the heartbeat back (7_200 = RewardDistributor.oracleMaxAge).
  deviationBps: 100,
  heartbeatSec: 0,
  heartbeatMarginSec: 600, // with a heartbeat: push at heartbeatSec - 10 min so LZ delivery lands inside it
  maxTwapBps: 150, // SolonStockOracle maxTwapBps (VerifyV3: 150 on mainnet)
  twapTrigger: true,
  freshnessSec: 0, // desk mode off; 840 keeps a 15-min execPrice live
  maxSourceAgeSec: 26 * 3_600, // SolonStockOracle maxSourceAge
  minIntervalSec: 30,
  demandMinIntervalSec: 60,
  demandTtlSec: 1_800,
  demandCoalesceSec: 240, // a push sent <= 4 min before a request is treated as answering it (LZ delivery)
  batchAll: true,
  // Chainlink us_equities_24/5: "18:00 ET Sunday to 17:00 ET Friday", not on US market holidays (docs.chain.link,
  // selecting-data-feeds, read 2026-10-01). Holidays are operator config (YYYY-MM-DD, New York date).
  // Extra holidays (YYYY-MM-DD, New York date) on top of the built-in NYSE 2026-2027 table.
  session: { openDow: 0, openMinute: 18 * 60, closeDow: 5, closeMinute: 17 * 60, holidays: [] },
  market: {}, // lib/market.mjs params (mode, heartbeatSec, heartbeatMarginSec); false = gate off (tests / anvil only)
});

export const E18 = 10n ** 18n;

export function mergeParams(p = {}) {
  const out = { ...ORACLE_DEFAULTS, ...p, session: { ...ORACLE_DEFAULTS.session, ...(p.session ?? {}) } };
  for (const k of ['deviationBps', 'heartbeatSec', 'heartbeatMarginSec', 'maxTwapBps', 'freshnessSec', 'maxSourceAgeSec', 'minIntervalSec', 'demandMinIntervalSec', 'demandTtlSec', 'demandCoalesceSec']) {
    out[k] = Number(out[k]);
    if (!Number.isFinite(out[k]) || out[k] < 0) throw new Error(`oracle param ${k} must be a non-negative number`);
  }
  if (out.heartbeatSec > 0 && out.heartbeatMarginSec >= out.heartbeatSec) throw new Error('heartbeatMarginSec must be < heartbeatSec (heartbeatSec 0 = off)');
  return out;
}

const marketParams = (session = {}, market = {}) => ({ ...market, holidays: [...NYSE_HOLIDAYS, ...(session.holidays ?? []), ...(market?.holidays ?? [])] });

/// Is the 24/5 feed session open at nowSec? (NYSE calendar + extra holidays; see lib/market.mjs)
export function sessionOpen(nowSec, session = ORACLE_DEFAULTS.session, market = {}) {
  return sessionState(nowSec, marketParams(session, market)).open;
}

const abs = x => (x < 0n ? -x : x);
/// |a - ref| > ref * bps / 10_000 (same rounding as SolonStockOracle._moved).
export const movedBps = (a, ref, bps) => abs(BigInt(a) - BigInt(ref)) * 10_000n > BigInt(ref) * BigInt(bps);
export const gapBps = (a, ref) => (BigInt(ref) === 0n ? Infinity : Number((abs(BigInt(a) - BigInt(ref)) * 10_000n) / BigInt(ref)));

/// TWAP leg in USD as the Arc oracle compares it: twapPrice18 (stable per stock) x quoteUsd18.
export const twapUsd = o => (BigInt(o.twapPrice18 ?? 0n) * BigInt(o.quoteUsd18 ?? E18)) / E18;
/// Would the Arc oracle mark this observation Divergent on the TWAP check? (twap 0 => Divergent, fail closed)
export const twapDivergent = (o, maxTwapBps) => maxTwapBps > 0 && (BigInt(o.twapPrice18 ?? 0n) === 0n || movedBps(o.price18, twapUsd(o), maxTwapBps));

/// Validate a demand file body (v1 { underlyings, requestedAt } or v2 { requests: { <requester>: {...} } }).
/// Returns { ok, demand: { underlyings, requestedAt, at: { u: latest requestedAt }, reason } } or { ok:false, reason }.
/// Expired or invalid entries are dropped; the file is rejected only when nothing valid is left.
export function parseDemand(body, { listed, nowSec, ttlSec = ORACLE_DEFAULTS.demandTtlSec }) {
  let d;
  try { d = typeof body === 'string' ? JSON.parse(body) : body; } catch { return { ok: false, reason: 'demand file is not JSON' }; }
  const entries = d?.requests && typeof d.requests === 'object' ? Object.entries(d.requests) : [['', d]];
  const set = new Map(listed.map(u => [u.toLowerCase(), u]));
  const at = {};
  const reasons = [];
  let why = null;
  for (const [who, r] of entries) {
    const tag = who ? `demand ${who}` : 'demand';
    if (!r || !Array.isArray(r.underlyings) || r.underlyings.length === 0) { why ??= `${tag}: underlyings[] required`; continue; }
    const t = Number(r.requestedAt);
    if (!Number.isFinite(t) || t <= 0) { why ??= `${tag}: requestedAt (unix seconds) required`; continue; }
    const unknown = r.underlyings.filter(u => typeof u !== 'string' || !set.has(u.toLowerCase()));
    if (unknown.length) { why ??= `${tag}: unlisted underlying(s) ${unknown.join(',')}`; continue; }
    const requestedAt = Math.min(t, nowSec); // a clock ahead of ours must not make a demand unsatisfiable
    if (nowSec - requestedAt > ttlSec) { why ??= `${tag} expired (${nowSec - requestedAt}s > ttl ${ttlSec}s)`; continue; }
    for (const u of r.underlyings) {
      // v2 entries stamp each stock (r.at); a stamp older than the TTL is dropped, a future one clamped like requestedAt.
      const own = Number(r.at?.[u] ?? requestedAt);
      const tu = Math.min(Number.isFinite(own) && own > 0 ? own : requestedAt, nowSec);
      if (nowSec - tu > ttlSec) continue;
      const k = set.get(u.toLowerCase());
      at[k] = Math.max(at[k] ?? 0, tu);
    }
    reasons.push(who ? `${who}: ${r.reason ?? ''}` : String(r.reason ?? ''));
  }
  const underlyings = Object.keys(at);
  if (!underlyings.length) return { ok: false, reason: why ?? 'demand: no request' };
  return { ok: true, demand: { underlyings, requestedAt: Math.max(...Object.values(at)), at, reason: reasons.join('; ').slice(0, 120) } };
}

/// Core decision. Inputs:
///   nowSec; l1Block (EVM block.number on RH) | null
///   current: { [underlying]: { ok, price18, twapPrice18, quoteUsd18, sourceUpdatedAt } }  (fresh HTTP read)
///   last:    { [underlying]: { price18, twapPrice18, quoteUsd18, pushedAt, l1Block } }   (last known push)
///   lastPushAt (any stock, any pusher), lastL1Block, demand (parsed) | null, params (merged)
/// Output: { push, underlyings, reasons: {u: [..]}, reason, wait?, skipped }
export function decidePush({ nowSec, l1Block = null, current, last = {}, lastPushAt = 0, lastL1Block = 0, demand = null, params }) {
  const p = params ?? mergeParams();
  const mp = p.market === false ? null : marketParams(p.session, p.market);
  const open = sessionOpen(nowSec, p.session, p.market || {});
  const reasons = {};
  const skipped = [];
  const blocked = [];
  let demandHit = false;
  const demandRefused = [];
  for (const [u, c] of Object.entries(current)) {
    if (!c?.ok) { skipped.push({ underlying: u, reason: c?.error ?? 'source read failed' }); continue; }
    if (mp) {
      const g = marketGate({ nowSec, sourceUpdatedAt: c.sourceUpdatedAt, params: mp });
      if (!g.ok) { blocked.push({ underlying: u, reason: g.reason, alert: g.alert }); continue; }
    }
    const l = last[u];
    const r = [];
    const feedAge = nowSec - Number(c.sourceUpdatedAt ?? 0);
    if (!l || !l.price18) r.push('initial');
    else {
      if (movedBps(c.price18, l.price18, p.deviationBps)) r.push('deviation');
      if (p.twapTrigger && twapDivergent(l, p.maxTwapBps) && !twapDivergent(c, p.maxTwapBps)) r.push('twap');
      const age = nowSec - Number(l.pushedAt ?? 0);
      const live = open && feedAge <= p.maxSourceAgeSec;
      if (live && p.heartbeatSec > 0 && age >= p.heartbeatSec - p.heartbeatMarginSec) r.push('heartbeat');
      if (live && p.freshnessSec > 0 && age >= p.freshnessSec) r.push('freshness');
    }
    if (demand && demand.underlyings.includes(u)) {
      const asked = demand.at?.[u] ?? demand.requestedAt;
      // A push that would land TWAP-Divergent on Arc cannot serve the requester (execPrice / priceUSD18 refuse it),
      // and Divergent hides behind Stale once the observation ages: answering would repeat every ~15 min.
      if (Number(l?.pushedAt ?? 0) < asked - p.demandCoalesceSec) {
        if (p.twapTrigger !== false && twapDivergent(c, p.maxTwapBps)) demandRefused.push(u);
        else { r.push('demand'); demandHit = true; }
      }
    }
    if (r.length) reasons[u] = r;
  }
  const due = Object.keys(reasons);
  if (due.length === 0) return { push: false, underlyings: [], reasons, reason: demandRefused.length ? 'nothing due (demand refused: TWAP-divergent)' : blocked.length ? 'nothing due (market gate)' : 'nothing due', skipped, blocked, demandRefused, sessionOpen: open };
  const onlyDemand = due.every(u => reasons[u].every(x => x === 'demand'));
  const minGap = onlyDemand ? p.demandMinIntervalSec : p.minIntervalSec;
  if (lastPushAt && nowSec - lastPushAt < minGap) {
    return { push: false, underlyings: [], reasons, reason: 'min interval', wait: { untilSec: lastPushAt + minGap }, skipped, blocked, sessionOpen: open };
  }
  if (l1Block != null && lastL1Block && Number(l1Block) <= Number(lastL1Block)) {
    return { push: false, underlyings: [], reasons, reason: 'same RH block.number (L1 block) as the last push: Arc would ignore it', wait: { l1Block: Number(lastL1Block) + 1 }, skipped, blocked, sessionOpen: open };
  }
  const gated = new Set(blocked.map(b => b.underlying));
  const readable = Object.entries(current).filter(([u, c]) => c?.ok && !gated.has(u)).map(([u]) => u);
  const underlyings = p.batchAll ? readable : due;
  const order = ['initial', 'deviation', 'twap', 'demand', 'freshness', 'heartbeat'];
  const all = new Set(due.flatMap(u => reasons[u]));
  const reason = order.find(x => all.has(x));
  return { push: true, underlyings, reasons, reason, demandHit, demandRefused, skipped, blocked, sessionOpen: open };
}

/// After a confirmed push: the new "last" map. Observations are what the chain read at push time.
export function recordPush(last, { underlyings, observations, pushedAt, l1Block }) {
  const next = { ...last };
  for (const u of underlyings) {
    const o = observations[u];
    if (!o?.ok) continue;
    next[u] = { price18: BigInt(o.price18), twapPrice18: BigInt(o.twapPrice18 ?? 0n), quoteUsd18: BigInt(o.quoteUsd18 ?? E18), pushedAt, l1Block: l1Block ?? null };
  }
  return next;
}

/// Debouncer: many triggers within `ms` collapse into one call; a trigger during a running call schedules
/// exactly one follow-up. Timers are injectable for tests.
export function makeDebouncer(fn, ms, timers = {}) {
  const setTimer = timers.setTimeout ?? setTimeout;
  const clearTimer = timers.clearTimeout ?? clearTimeout;
  let timer = null;
  let running = false;
  let again = false;
  const reasons = new Set();
  const fire = async () => {
    timer = null;
    if (running) { again = true; return; }
    running = true;
    const why = [...reasons];
    reasons.clear();
    try { await fn(why); } finally {
      running = false;
      if (again) { again = false; schedule('follow-up'); }
    }
  };
  function schedule(why = 'event') {
    reasons.add(why);
    if (running) { again = true; return; }
    if (timer == null) timer = setTimer(fire, ms);
  }
  schedule.flush = async () => { if (timer != null) { clearTimer(timer); await fire(); } };
  schedule.pending = () => timer != null || again;
  return schedule;
}

/// Reconnect backoff: 1s, 2s, 4s ... capped, reset after a connection survived `stableMs`.
export function backoffMs(attempt, { baseMs = 1_000, maxMs = 60_000 } = {}) {
  return Math.min(maxMs, baseMs * 2 ** Math.max(0, attempt));
}

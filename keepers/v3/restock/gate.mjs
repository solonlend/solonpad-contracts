// Design §12.8 opening gate for stock-quote launches of one asset (here NVDA): pool A initialized + first range,
// starting money in place, router deployed and bound (and VerifyV3 passed), and the restock keeper running in
// dry-run for 24h without anomalies. Until it passes the UI/API keep the quote hidden. The factory's approvedQuote
// is constructor-only, so the on-chain list cannot be withheld after deployment: this gate is the switch.
// r10: the idle-USDC buffer is the r9 reserve structure, not a flat $100. minBufferUsd (when not given) =
// reserveUsd x reserveAlertBps — the same line below which the running restock keeper alerts "reserve low", so the
// gate never opens on a reserve the keeper itself flags. $1,000 reserve x 50% = $500: one ~$500 buy's move can still
// be re-anchored (r9 local e2e: an $800 buy needed a $755 restockMint), and the drill's $757 after the first range
// passes. reserveUsd comes from the manifest (poolAReserveUsd) via bin/pool-a-gate.mjs.
export const GATE_DEFAULTS = Object.freeze({ dryRunHours: 24, maxGapMinutes: 30, minBufferUsd: null, reserveUsd: 1000, reserveAlertBps: 5000 });
export const minBufferUsdOf = p => p.minBufferUsd ?? (p.reserveUsd * p.reserveAlertBps) / 10_000;

const ANOMALY = e => (e.type === 'restock-decision' && e.alert) || (e.type === 'restock-result' && e.status !== 'dry-run');

// facts: { initialized, liquidity (bigint), idleUsdc (bigint 18 dp), routerBound, approvedQuote, verifyPassed,
//          events: journal events [{ at: ISO, type, ... }] of the dry-run keeper }, nowMs
export function evaluateGate(facts, nowMs, params = {}) {
  const p = { ...GATE_DEFAULTS, ...params };
  const minBufferUsd = minBufferUsdOf(p);
  const since = nowMs - p.dryRunHours * 3600_000;
  const evs = (facts.events ?? []).filter(e => e.type?.startsWith('restock-')).map(e => ({ ...e, t: Date.parse(e.at) })).sort((a, b) => a.t - b.t);
  const window = evs.filter(e => e.t >= since);
  let maxGap = evs.length ? (evs[0].t > since ? Infinity : 0) : Infinity;
  let prev = since;
  for (const e of window) { maxGap = Math.max(maxGap, e.t - prev); prev = e.t; }
  maxGap = Math.max(maxGap, nowMs - prev);
  const anomalies = window.filter(ANOMALY);
  const checks = [
    ['factory approves NVDA.sol as a quote (constructor-only)', Boolean(facts.approvedQuote)],
    ['pool A initialized', Boolean(facts.initialized)],
    ['first range set (liquidity > 0)', facts.liquidity > 0n],
    [`idle USDC buffer >= $${minBufferUsd} (reserve $${p.reserveUsd} x ${p.reserveAlertBps / 100}%)`, facts.idleUsdc * 100n >= BigInt(Math.round(minBufferUsd * 100)) * 10n ** 18n],
    ['V3MultiHopRouter bound to this pool A', Boolean(facts.routerBound)],
    ['VerifyV3 passed for this manifest', Boolean(facts.verifyPassed)],
    [`restock keeper dry-run ${p.dryRunHours}h continuous (gap <= ${p.maxGapMinutes} min)`, maxGap <= p.maxGapMinutes * 60_000],
    [`no anomalies in the last ${p.dryRunHours}h (${anomalies.length})`, anomalies.length === 0],
  ].map(([name, ok]) => ({ name, ok }));
  return { open: checks.every(c => c.ok), checks, anomalies: anomalies.slice(-5) };
}

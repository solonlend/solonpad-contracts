// One-shot health check for the whole V3 keeper fleet (bin/health-check.mjs; launchd every 5 min):
//   - heartbeats: <statusDir>/heartbeat/<name>.json (lib/heartbeat.mjs, written every tick) — age and last tick result;
//     falls back to the mtime of <statusDir>/<name>.log for a process that predates heartbeats;
//   - gas: each role wallet's native balance (or an ERC-20 balance with `token`) against a WARN and a FAIL low-water mark;
//   - float: Arc hub float (hub.available) and RH free USDG (vault.freeSettlement) + both floatEnabled switches.
// Result levels OK < WARN < FAIL; the process exit code is 0 / 1 / 2 for the worst one. Everything here is pure
// except readHeartbeat (fs) — chain reads are injected so the decisions are unit-testable.
import { readFileSync, statSync, existsSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { formatUnits, parseUnits, getAddress, isAddress } from 'ethers';
import { heartbeatPath, stripUrls } from './heartbeat.mjs';

export const LEVEL = Object.freeze({ OK: 0, WARN: 1, FAIL: 2 });
export const LEVEL_NAME = ['OK', 'WARN', 'FAIL'];
const worst = (...ls) => Math.max(LEVEL.OK, ...ls);
const capLevel = (level, max) => (max == null ? level : Math.min(level, LEVEL[max]));

// ---------------------------------------------------------------- heartbeats
/// spec: { name, warnSec, failSec, dry?, failuresWarn? (1), failuresFail? (5), optional? }
export function readHeartbeat(statusDir, spec) {
  const file = heartbeatPath(statusDir, spec.name, { dry: Boolean(spec.dry) });
  if (existsSync(file)) {
    try { return { source: 'heartbeat', ...JSON.parse(readFileSync(file, 'utf8')) }; } catch { return { source: 'heartbeat', corrupt: true, at: statSync(file).mtimeMs }; }
  }
  const log = join(statusDir, `${spec.name}.log`);
  if (existsSync(log)) return { source: 'log-mtime', at: statSync(log).mtimeMs, ok: null };
  return null;
}

export function evaluateHeartbeat(spec, hb, nowMs) {
  const label = `heartbeat ${spec.name}${spec.dry ? ' (dry-run)' : ''}`;
  if (!hb) return { check: label, level: spec.optional ? LEVEL.WARN : LEVEL.FAIL, text: 'no heartbeat or log file: process never ran here (or wrong statusDir)' };
  const age = Math.max(0, Math.round((nowMs - Number(hb.at)) / 1000));
  let level = age > spec.failSec ? LEVEL.FAIL : age > spec.warnSec ? LEVEL.WARN : LEVEL.OK;
  const parts = [`last tick ${age}s ago (warn > ${spec.warnSec}s, fail > ${spec.failSec}s)`];
  if (hb.source === 'log-mtime') parts.push('from log mtime (no heartbeat file)');
  if (hb.corrupt) { level = worst(level, LEVEL.WARN); parts.push('heartbeat file unreadable'); }
  if (hb.ok === false) {
    const n = Math.max(1, Number(hb.failures ?? 1) || 1); // a failed tick is at least one failure
    level = worst(level, n >= Number(spec.failuresFail ?? 5) ? LEVEL.FAIL : n >= Number(spec.failuresWarn ?? 1) ? LEVEL.WARN : LEVEL.OK);
    parts.push(`last tick FAILED (${n} in a row)${hb.note ? `: ${stripUrls(hb.note)}` : ''}`);
  }
  return { check: label, level, text: parts.join('; '), ageSec: age };
}

// ---------------------------------------------------------------- gas / balances
/// [{ label, chain, address, warn ("0.02"), fail ("0.005"), unit, decimals? (18), token? (ERC-20), maxLevel? ("WARN") }]
export function parseGasTargets(list = []) {
  return list.map((t, i) => {
    if (!t?.label || !t.chain) throw new Error(`health.gas[${i}]: label and chain required`);
    if (!isAddress(t.address ?? '')) throw new Error(`health.gas[${i}] ${t.label}: bad address`);
    if (t.token != null && !isAddress(t.token)) throw new Error(`health.gas[${i}] ${t.label}: bad token address`);
    const decimals = Number(t.decimals ?? 18);
    const amt = (v, what) => {
      try { const x = parseUnits(String(v), decimals); if (x < 0n) throw new Error(); return x; } catch { throw new Error(`health.gas[${i}] ${t.label}: ${what} must be a non-negative decimal`); }
    };
    const warnWei = amt(t.warn ?? t.min, 'warn');
    const failWei = t.fail == null ? 0n : amt(t.fail, 'fail');
    if (failWei > warnWei) throw new Error(`health.gas[${i}] ${t.label}: fail (${t.fail}) above warn (${t.warn})`);
    if (t.maxLevel != null && !(t.maxLevel in LEVEL)) throw new Error(`health.gas[${i}] ${t.label}: maxLevel must be OK/WARN/FAIL`);
    return { label: t.label, chain: t.chain, address: getAddress(t.address.toLowerCase()), token: t.token ? getAddress(t.token.toLowerCase()) : null,
      warnWei, failWei, unit: t.unit ?? 'ETH', decimals, maxLevel: t.maxLevel ?? null, note: t.note ?? null };
  });
}

const fmt = (wei, decimals, unit) => `${Number(formatUnits(wei, decimals)).toFixed(decimals >= 18 ? 4 : 2)} ${unit}`;
const short = a => `${a.slice(0, 6)}…${a.slice(-4)}`;

export function evaluateGas(t, balance) {
  const check = `gas ${t.label} (${t.chain} ${short(t.address)})`;
  if (balance instanceof Error || balance == null) return { check, level: capLevel(LEVEL.FAIL, t.maxLevel), text: `balance unreadable: ${balance?.message ?? 'no reading'}` };
  const level = capLevel(balance < t.failWei ? LEVEL.FAIL : balance < t.warnWei ? LEVEL.WARN : LEVEL.OK, t.maxLevel);
  const text = `${fmt(balance, t.decimals, t.unit)} (warn < ${fmt(t.warnWei, t.decimals, t.unit)}, fail < ${fmt(t.failWei, t.decimals, t.unit)})${level && t.note ? ` — ${t.note}` : ''}`;
  return { check, level, text, balance };
}

// ---------------------------------------------------------------- float
export const FLOAT_HEALTH_DEFAULTS = Object.freeze({ arcWarnUsd: 1000, arcFailUsd: 100, rhWarnUsd: 1000, rhFailUsd: 100 });

/// s: { arcAvail18, hubFloatOn, rhFree6, rhFloatOn } (each value or an Error)
export function evaluateFloat(s, p = FLOAT_HEALTH_DEFAULTS) {
  const out = [];
  const side = (check, v, scale, warnUsd, failUsd, unit) => {
    if (v instanceof Error || v == null) return out.push({ check, level: LEVEL.FAIL, text: `unreadable: ${v?.message ?? 'no reading'}` });
    const warnW = BigInt(Math.round(warnUsd * 100)) * 10n ** BigInt(scale - 2), failW = BigInt(Math.round(failUsd * 100)) * 10n ** BigInt(scale - 2);
    const level = v < failW ? LEVEL.FAIL : v < warnW ? LEVEL.WARN : LEVEL.OK;
    out.push({ check, level, text: `${Number(formatUnits(v, scale)).toFixed(2)} ${unit} (warn < ${warnUsd}, fail < ${failUsd})`, balance: v });
  };
  side('float Arc hub (USDC available)', s.arcAvail18, 18, p.arcWarnUsd, p.arcFailUsd, 'USDC');
  side('float RH ReserveVault (free USDG)', s.rhFree6, 6, p.rhWarnUsd, p.rhFailUsd, 'USDG');
  for (const [check, on] of [['float Arc hub floatEnabled', s.hubFloatOn], ['float RH vault floatEnabled', s.rhFloatOn]]) {
    if (on instanceof Error || on == null) out.push({ check, level: LEVEL.FAIL, text: `unreadable: ${on?.message ?? 'no reading'}` });
    else out.push({ check, level: on ? LEVEL.OK : LEVEL.FAIL, text: on ? 'on' : 'OFF (2a needs it on: buys wait / refunds stall)' });
  }
  return out;
}

// ---------------------------------------------------------------- report + alert de-duplication across runs
export function summarize(results) {
  const level = worst(...results.map(r => r.level));
  const counts = { OK: 0, WARN: 0, FAIL: 0 };
  for (const r of results) counts[LEVEL_NAME[r.level]]++;
  return { level, status: LEVEL_NAME[level], exitCode: level, counts };
}

export const formatLine = r => `${LEVEL_NAME[r.level].padEnd(4)}  ${r.check}: ${r.text}`;

/// The check runs as a fresh process every few minutes, so the in-memory alerter's rate limit does not apply:
/// state persisted between runs decides. Alert a non-OK check when it is new, its level changed, or repeatMs passed;
/// send one "recovered" note when a previously alerted check is OK again. The caller drops a check from the returned state
/// when its delivery failed (forgetDelivery), so the next run retries instead of waiting out repeatMs.
export function dueAlerts(results, state = {}, nowMs, repeatMs = 3600_000) {
  const next = {};
  const send = [];
  for (const r of results) {
    const prev = state[r.check];
    if (r.level === LEVEL.OK) {
      if (prev) send.push({ key: `health-${r.check}`, check: r.check, text: `RECOVERED ${r.check}: ${r.text}` });
      continue;
    }
    const due = !prev || prev.level !== r.level || nowMs - prev.at >= repeatMs;
    next[r.check] = due ? { level: r.level, at: nowMs } : prev;
    if (due) send.push({ key: `health-${r.check}`, check: r.check, text: `${LEVEL_NAME[r.level]} ${r.check}: ${r.text}` });
  }
  return { send, state: next };
}

export function forgetDelivery(state, prevState, check) {
  if (prevState[check]) state[check] = prevState[check]; // failed RECOVERED note: keep the old entry, retry next run
  else delete state[check];
  return state;
}

export function loadState(file) {
  try { return JSON.parse(readFileSync(file, 'utf8')); } catch { return {}; }
}

export function saveState(file, state) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(`${file}.tmp`, JSON.stringify(state));
  renameSync(`${file}.tmp`, file);
}

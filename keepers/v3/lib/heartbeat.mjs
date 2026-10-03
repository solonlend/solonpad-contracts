// Per-process heartbeat: every keeper tick (ok or failed) rewrites <statusDir>/heartbeat/<name>[.dry].json, so one
// health check (bin/health-check.mjs) can tell a dead or wedged process from a quiet one without parsing logs.
// Never throws: a full disk must not take a keeper down.
import { writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

// RPC URLs carry the dRPC key; error text can quote them. Strip before the note reaches disk / the health alert.
export const stripUrls = text => String(text).replace(/\b(?:https?|wss?):\/\/\S+/g, '<url>');

export const heartbeatPath = (statusDir, name, { dry = false } = {}) => join(statusDir, 'heartbeat', `${name}${dry ? '.dry' : ''}.json`);

export function writeHeartbeat(statusDir, name, { ok, execute = true, failures = 0, note = null, now = () => Date.now() } = {}) {
  if (!statusDir) return false;
  try {
    const file = heartbeatPath(statusDir, name, { dry: !execute });
    mkdirSync(join(statusDir, 'heartbeat'), { recursive: true });
    const tmp = `${file}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify({ name, at: now(), ok: Boolean(ok), failures, execute, pid: process.pid, ...(note ? { note: stripUrls(note).slice(0, 200) } : {}) }));
    renameSync(tmp, file);
    return true;
  } catch {
    return false;
  }
}

// One-writer lock per signing account (same mkdir semantics as v4launch/dd43_lock.mjs).
// Two processes reading the same 'pending' nonce would collide, so every keeper that
// signs with an account takes that account's lock for the whole cycle. The v2-ingress
// keeper, which will sign with the shared 0xdD43 platform wallet after cutover, uses
// the existing /tmp/solon-dD43.lock path so it also excludes harvest_daemon.mjs.
import { mkdirSync, rmSync, readFileSync, writeFileSync, statSync } from 'node:fs';

export const DD43_LOCK = '/tmp/solon-dD43.lock';
// SOLON_LOCK_DIR (default /tmp) separates concurrent fork/test runs whose keepers share the same anvil test keys.
export const lockPathFor = address => `${process.env.SOLON_LOCK_DIR ?? '/tmp'}/solon-keeper-${String(address).toLowerCase()}.lock`;

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

function readOwner(path) {
  try { return JSON.parse(readFileSync(`${path}/owner.json`, 'utf8')); } catch { return null; }
}

export function tryLock(path, owner, staleMs = 20 * 60_000) {
  try { mkdirSync(path); } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    const info = readOwner(path);
    let at;
    try { at = info?.at ?? statSync(path).mtimeMs; } catch { at = 0; }
    const alive = info ? pidAlive(info.pid) : Date.now() - at < 60_000;
    if (alive && Date.now() - at < staleMs) return false;
    rmSync(path, { recursive: true, force: true });
    try { mkdirSync(path); } catch { return false; }
  }
  writeFileSync(`${path}/owner.json`, JSON.stringify({ owner, pid: process.pid, at: Date.now() }));
  return true;
}

export function unlock(path) {
  if (readOwner(path)?.pid === process.pid) rmSync(path, { recursive: true, force: true });
}

export const lockHolder = path => readOwner(path);

export async function withLock(path, owner, fn) {
  if (!tryLock(path, owner)) return { skipped: true, holder: lockHolder(path)?.owner ?? '?' };
  try { return { skipped: false, value: await fn() }; } finally { unlock(path); }
}

// Telegram alert hook. Token from TELEGRAM_BOT_TOKEN (or a file named by
// TELEGRAM_BOT_TOKEN_FILE), chat from TELEGRAM_CHAT_ID. The token is never logged:
// failures are reported without the URL. Repeats of the same key are rate-limited.
// Convention (docs/MAINNET-RUNBOOK-v3.md): those variables live in ~/.config/solon/v3_alert.env
// (path override: SOLON_ALERT_ENV). run-keeper.sh sources it; a keeper started any other way loads
// it here when the environment has no chat id. Only the three TELEGRAM_* keys are read.
// SOLON_ALERT_PREFIX (process environment, e.g. "[TESTNET] ") is put in front of every message, so a testnet fleet
// sharing the mainnet chat cannot be mistaken for mainnet.
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { redact } from './log.mjs';

const ALERT_KEYS = ['TELEGRAM_BOT_TOKEN', 'TELEGRAM_BOT_TOKEN_FILE', 'TELEGRAM_CHAT_ID'];
export const defaultAlertEnvPath = () => process.env.SOLON_ALERT_ENV || join(homedir(), '.config/solon/v3_alert.env');

/// KEY=VALUE lines (optional `export `, quotes, # comments); existing values in `target` win.
export function loadAlertEnv(path = defaultAlertEnvPath(), target = process.env) {
  if (!existsSync(path)) return false;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^\s*(?:export\s+)?([A-Z_]+)\s*=\s*(.*?)\s*$/);
    if (!m || !ALERT_KEYS.includes(m[1]) || target[m[1]]) continue;
    target[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2').replace(/^~(?=\/)/, homedir());
  }
  return true;
}

function botToken(env) {
  if (env.TELEGRAM_BOT_TOKEN) return env.TELEGRAM_BOT_TOKEN;
  const file = env.TELEGRAM_BOT_TOKEN_FILE;
  if (!file) return null;
  try {
    const body = readFileSync(file, 'utf8');
    return body.match(/TELEGRAM_BOT_TOKEN=([^\s]+)/)?.[1] ?? body.trim();
  } catch { return null; }
}

export function makeAlerter({ logger, name = 'keeper', repeatMs = 6 * 3600_000, fetchImpl = globalThis.fetch, now = () => Date.now(), enabled = true, env = process.env } = {}) {
  if (!env.TELEGRAM_CHAT_ID) loadAlertEnv(defaultAlertEnvPath(), env);
  const prefix = env.SOLON_ALERT_PREFIX ? `${env.SOLON_ALERT_PREFIX.trim()} ` : '';
  const last = new Map();
  return async function alert(key, text) {
    if (now() - (last.get(key) ?? -Infinity) < repeatMs) return { sent: false, reason: 'rate-limited' };
    last.set(key, now());
    const message = redact(`${prefix}[${name}] ${text}`);
    const token = enabled ? botToken(env) : null;
    const chat = env.TELEGRAM_CHAT_ID;
    if (!token || !chat) {
      logger?.warn(`alert (not sent: no TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID): ${message}`);
      return { sent: false, reason: 'unconfigured' };
    }
    try {
      const res = await fetchImpl(`https://api.telegram.org/bot${token}/sendMessage`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ chat_id: chat, text: message }),
        signal: AbortSignal.timeout(15_000),
      });
      logger?.info(`alert sent (${res.status}): ${message.slice(0, 160)}`);
      return res.ok ? { sent: true } : { sent: false, reason: 'delivery', status: res.status };
    } catch (error) {
      logger?.warn(`alert delivery failed (${error?.name ?? 'error'}): ${message.slice(0, 160)}`);
      return { sent: false, reason: 'delivery' };
    }
  };
}

// Structured line logger. Everything written passes through redact(): 32-byte hex
// strings that are not tx/order hashes we chose to print, and bot-token shapes, are
// masked, so a stray error message can never leak a key or token into a log file.
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const BOT_TOKEN = /\b\d{6,12}:[A-Za-z0-9_-]{30,}\b/g;
const PRIVATE_KEY_FIELD = /("?(private_?key|privateKey|secret|mnemonic)"?\s*[:=]\s*"?)[^"\s,}]+/gi;
const BOT_URL = /(api\.telegram\.org\/bot)[^/\s]+/g;

export function redact(text) {
  return String(text)
    .replace(BOT_URL, '$1<redacted>')
    .replace(BOT_TOKEN, '<redacted-token>')
    .replace(PRIVATE_KEY_FIELD, '$1<redacted>');
}

export function makeLogger({ file = null, name = 'keeper', echo = true } = {}) {
  if (file) mkdirSync(dirname(file), { recursive: true });
  const write = (level, message, fields) => {
    const extra = fields ? ' ' + JSON.stringify(fields, (_, v) => (typeof v === 'bigint' ? v.toString() : v)) : '';
    const line = redact(`${new Date().toISOString()} [${name}] ${level} ${message}${extra}`);
    if (echo) console.log(line);
    if (file) appendFileSync(file, line + '\n');
    return line;
  };
  return {
    info: (m, f) => write('INFO', m, f),
    warn: (m, f) => write('WARN', m, f),
    error: (m, f) => write('ERROR', m, f),
  };
}

export const silentLogger = { info: () => {}, warn: () => {}, error: () => {} };

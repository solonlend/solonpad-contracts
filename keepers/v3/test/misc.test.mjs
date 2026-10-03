import test from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { inspect } from 'node:util';
import { redact, makeLogger } from '../lib/log.mjs';
import { loadSigner } from '../lib/signer.mjs';
import { makeAlerter } from '../lib/alert.mjs';
import { tryLock, unlock } from '../lib/lock.mjs';
import { parseArgs } from '../lib/cli.mjs';
import { tmp } from './helpers.mjs';

const KEY = '0x' + '5a'.repeat(32);

test('signer: key from env path, never visible via JSON/inspect; ~/.config/solon refused', () => {
  const dir = tmp();
  const path = join(dir, 'k.json');
  writeFileSync(path, JSON.stringify({ private_key: KEY.slice(2) }));
  chmodSync(path, 0o600);
  process.env.TEST_KEY_PATH = path;
  const w = loadSigner('TEST_KEY_PATH', null);
  assert.ok(!JSON.stringify(w).includes('5a5a5a'));
  assert.ok(!inspect(w).includes('5a5a5a'));
  process.env.TEST_KEY_PATH = `${process.env.HOME}/.config/solon/arclaunch_deployer.json`;
  assert.throws(() => loadSigner('TEST_KEY_PATH', null), /config\/solon/);
  delete process.env.TEST_KEY_PATH;
  assert.throws(() => loadSigner('TEST_KEY_PATH', null), /not set/);
});

test('redact masks bot tokens, telegram URLs and private-key fields', () => {
  const token = '123456789:AAHfakefakefakefakefakefakefakefake12';
  const out = redact(`POST https://api.telegram.org/bot${token}/sendMessage private_key=${KEY} {"privateKey":"${KEY}"}`);
  assert.ok(!out.includes(token));
  assert.ok(!out.includes(KEY));
});

test('alert: token from env, never logged; unconfigured just logs; rate-limited', async () => {
  const lines = [];
  const logger = { info: m => lines.push(m), warn: m => lines.push(m), error: m => lines.push(m) };
  const token = '123456789:AAHsecretsecretsecretsecretsecret99';
  process.env.TELEGRAM_BOT_TOKEN = token;
  process.env.TELEGRAM_CHAT_ID = '42';
  const calls = [];
  const alert = makeAlerter({ logger, fetchImpl: async (url, init) => { calls.push({ url, init }); return { ok: true, status: 200 }; } });
  assert.equal((await alert('k', `leak? ${token}`)).sent, true);
  assert.equal((await alert('k', 'again')).reason, 'rate-limited');
  assert.ok(calls[0].url.includes(token), 'token used for the request');
  assert.ok(!calls[0].init.body.includes(token), 'but never in the message body');
  assert.ok(lines.every(l => !l.includes(token)), 'and never in logs');
  delete process.env.TELEGRAM_BOT_TOKEN;
  const quiet = makeAlerter({ logger, fetchImpl: async () => { throw new Error('should not fetch'); } });
  assert.equal((await quiet('x', 'hi')).reason, 'unconfigured');
});

test('alert: SOLON_ALERT_PREFIX tags every message (testnet fleet on the mainnet chat)', async () => {
  const bodies = [];
  const fetchImpl = async (url, init) => { bodies.push(JSON.parse(init.body).text); return { ok: true, status: 200 }; };
  const env = { TELEGRAM_BOT_TOKEN: '1:x', TELEGRAM_CHAT_ID: '7', SOLON_ALERT_PREFIX: '[TESTNET]' };
  await makeAlerter({ name: 'health-check', fetchImpl, env })('k', 'oracle FAIL');
  await makeAlerter({ name: 'health-check', fetchImpl, env: { TELEGRAM_BOT_TOKEN: '1:x', TELEGRAM_CHAT_ID: '7' } })('k', 'oracle FAIL');
  assert.deepEqual(bodies, ['[TESTNET] [health-check] oracle FAIL', '[health-check] oracle FAIL']);
});

test('signer lock is exclusive per path and released by its owner', () => {
  const path = join(tmp(), 'lock');
  assert.equal(tryLock(path, 'a'), true);
  assert.equal(tryLock(path, 'b'), false);
  unlock(path);
  assert.equal(tryLock(path, 'b'), true);
  unlock(path);
});

test('cli: dry-run default, --execute opt-in, loop interval floor', () => {
  assert.equal(parseArgs([]).execute, false);
  assert.equal(parseArgs(['--execute']).execute, true);
  assert.deepEqual([parseArgs(['--loop=30']).loop, parseArgs(['--loop=30']).interval], [true, 30]);
  assert.throws(() => parseArgs(['--loop=1']));
  assert.throws(() => parseArgs(['stray']));
});

test('logger writes redacted lines to file', async () => {
  const file = join(tmp(), 'x.log');
  const log = makeLogger({ file, echo: false });
  log.info(`key ${'privateKey'}=${KEY}`);
  const { readFileSync } = await import('node:fs');
  assert.ok(!readFileSync(file, 'utf8').includes(KEY));
});

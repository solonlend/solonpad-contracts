import test from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { writeFileSync } from 'node:fs';
import { evaluateBalances, BalanceWatcher, parseTargets } from '../lib/balances.mjs';
import { makeAlerter, loadAlertEnv } from '../lib/alert.mjs';
import { tmp, quietLogger } from './helpers.mjs';

const E18 = 10n ** 18n;
const RV = '0x' + 'a1'.repeat(20);
const KA = '0x' + 'b2'.repeat(20);
const targets = parseTargets([
  { label: 'RH ReserveVault (LZ result fees)', chain: 'rh', address: RV, min: '0.02', unit: 'ETH' },
  { label: 'Arc round-keeper', chain: 'arc', address: KA, min: '20', unit: 'USDC' },
]);

test('F8: targets parse decimal minimums (18 dp: RH ETH, Arc native USDC); bad entries are refused', () => {
  assert.equal(targets[0].minWei, 2n * 10n ** 16n);
  assert.equal(targets[1].minWei, 20n * E18);
  assert.throws(() => parseTargets([{ label: 'x', chain: 'rh', address: '0x12', min: '1' }]), /address/);
  assert.throws(() => parseTargets([{ label: 'x', chain: 'rh', address: RV, min: '-1' }]), /min/);
});

test('F8: below-threshold balances are flagged with a readable amount', () => {
  const r = evaluateBalances(targets, { [RV]: 15n * 10n ** 15n, [KA]: 25n * E18 });
  assert.equal(r[0].low, true);
  assert.match(r[0].text, /RH ReserveVault .* 0\.015 ETH < 0\.02 ETH/);
  assert.equal(r[1].low, false);
});

test('F8: watcher alerts once per low target (keyed), keeps checking the others when one RPC fails', async () => {
  const alerts = [];
  const w = new BalanceWatcher({
    targets, logger: quietLogger, alert: async (k, t) => alerts.push({ k, t }),
    readers: { rh: async () => 1n, arc: async () => { throw new Error('rpc down'); } },
  });
  const out = await w.tick();
  assert.equal(out.results.length, 2);
  assert.equal(alerts.length, 2);
  assert.equal(alerts[0].k, `balance-rh-${RV.toLowerCase()}`);
  assert.match(alerts[1].t, /could not read/);
});

test('F8: alert config from ~/.config/solon/v3_alert.env format; the bot token never reaches logs or the message', async () => {
  const dir = tmp();
  const tokenFile = join(dir, 'bot.token');
  writeFileSync(tokenFile, 'TELEGRAM_BOT_TOKEN=123456:SECRETSECRETSECRETSECRETSECRET\n');
  const envFile = join(dir, 'v3_alert.env');
  writeFileSync(envFile, `# comment\nTELEGRAM_BOT_TOKEN_FILE=${tokenFile}\nTELEGRAM_CHAT_ID=-1001\nOTHER=ignored\n`);
  const env = {};
  loadAlertEnv(envFile, env);
  assert.deepEqual(Object.keys(env).sort(), ['TELEGRAM_BOT_TOKEN_FILE', 'TELEGRAM_CHAT_ID']);
  const calls = [];
  const lines = [];
  const logger = { info: m => lines.push(m), warn: m => lines.push(m) };
  const alert = makeAlerter({ logger, name: 'balance-watch', env, fetchImpl: async (url, init) => { calls.push({ url, body: init.body }); return { ok: true, status: 200 }; } });
  await alert('k', 'RH ReserveVault low');
  assert.equal(calls.length, 1);
  assert.match(calls[0].url, /SECRETSECRET/);
  assert.equal(JSON.parse(calls[0].body).chat_id, '-1001');
  assert.ok(!lines.join('\n').includes('SECRET'));
  assert.ok(!calls[0].body.includes('SECRET'));
});

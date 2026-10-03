import test from 'node:test';
import assert from 'node:assert/strict';
import { collectDecision, stockHalf, expectedRouting, lotNextAction, buybackChunk, buybackMinOut, deskPlan, evidenceFromCollect, SourceKind, IngressLot, RouterLot, E18, ZERO } from '../ingress/decide.mjs';

const SOLON = '0xd36687146385F7Dc84A18FEA3D00319d39D6d1a0';

test('collect only at/above threshold and when cost is small vs fees', () => {
  assert.equal(collectDecision({ feesUsd18: 99n * E18, thresholdUsd18: 100n * E18 }).collect, false);
  assert.equal(collectDecision({ feesUsd18: 100n * E18, thresholdUsd18: 100n * E18 }).collect, true);
  assert.equal(collectDecision({ feesUsd18: 100n * E18, thresholdUsd18: 1n, execCostUsd18: 2n * E18 }).collect, false);
});

test('stockHalf carries the odd unit across lots exactly like V2PlatformRouter', () => {
  let rem = 0; let stock = 0n; let total = 0n;
  for (const a of [3n, 5n, 7n, 1n]) { const r = stockHalf(a, rem); stock += r.stock; rem = r.remainder; total += a; }
  assert.equal(stock, 8n, '16 units -> exactly 8 to stock across lots');
  assert.equal(rem, 0);
  assert.deepEqual(stockHalf(3n, 0), { stock: 1n, remainder: 1 });
  assert.deepEqual(stockHalf(3n, 1), { stock: 2n, remainder: 0 });
});

test('§9.4 routing: SOLON pool 50/50 stock/buyback (USDC) or burn/convert (SOLON); others 100% -> ProtocolDesk', () => {
  const s = expectedRouting({ kind: SourceKind.SOLON_V2, token: ZERO, amount: 100n * E18 });
  assert.deepEqual([s.stockUSDC18, s.buybackUSDC18, s.protocolDesk], [50n * E18, 50n * E18, false]);
  const t = expectedRouting({ kind: SourceKind.SOLON_V2, token: SOLON, amount: 1000n });
  assert.deepEqual([t.burnRaw, t.convertRaw], [500n, 500n]);
  const o = expectedRouting({ kind: SourceKind.OTHER_V2, token: ZERO, amount: 100n * E18 });
  assert.deepEqual([o.buybackUSDC18, o.protocolDesk, o.stockUSDC18], [100n * E18, true, 0n]);
  const m = expectedRouting({ kind: SourceKind.OTHER_V2, token: '0x' + '12'.repeat(20), amount: 9n });
  assert.deepEqual([m.convertRaw, m.protocolDesk, m.burnRaw], [9n, true, 0n]);
  assert.throws(() => expectedRouting({ kind: 3, token: ZERO, amount: 1n }));
});

test('lot state machine: audit -> record -> fund -> route -> convert -> done; unadmitted quarantines', () => {
  const n = o => lotNextAction({ ingressState: IngressLot.None, admitted: false, routerState: 0, native: true, hasSignatures: true, ...o }).action;
  assert.equal(n({ hasSignatures: false }), 'awaitAudit');
  assert.equal(n({}), 'record');
  assert.equal(n({ ingressState: IngressLot.Observed, admitted: true }), 'fund');
  assert.equal(n({ ingressState: IngressLot.Observed, admitted: false }), 'quarantine');
  assert.equal(n({ ingressState: IngressLot.Funded, routerState: RouterLot.Done }), 'done');
  assert.equal(n({ ingressState: IngressLot.Funded, native: false, routerState: RouterLot.RawFunded }), 'route');
  assert.equal(n({ ingressState: IngressLot.Funded, native: false, routerState: RouterLot.Routed }), 'convert');
  assert.equal(n({ ingressState: IngressLot.Funded, native: false, routerState: RouterLot.Done }), 'done');
});

test('buyback chunks are <= $1000 and never exceed the remaining budget', () => {
  assert.deepEqual(buybackChunk({ budget: 2500n * E18, spent: 0n, executed: false }), { buy: true, amount: 1000n * E18 });
  assert.deepEqual(buybackChunk({ budget: 2500n * E18, spent: 2000n * E18, executed: false }), { buy: true, amount: 500n * E18 });
  assert.equal(buybackChunk({ budget: 1n, spent: 0n, executed: false }).buy, false);
  assert.equal(buybackChunk({ budget: 5n * E18, spent: 5n * E18, executed: true }).buy, false);
  assert.equal(buybackMinOut({ budget18: 25n * E18, solonPerUsdc18: 4000n * E18, slippageBps: 300n }), 97_000n * E18);
});

test('protocol desk: mint full cards (<=20/tx) until 1000/5000 caps, then sweep overflow to BurnSink', () => {
  const base = { perDesk: 100_000n * E18, protocolMinted: 0n, totalSupply: 10n, maxSupply: 5000n };
  assert.deepEqual(deskPlan({ ...base, pendingSolon: 99_999n * E18 }).action, 'none');
  assert.deepEqual(deskPlan({ ...base, pendingSolon: 250_000n * E18 }), { action: 'mint', cards: 2n });
  assert.deepEqual(deskPlan({ ...base, pendingSolon: 10_000_000n * E18 }), { action: 'mint', cards: 20n });
  assert.equal(deskPlan({ ...base, protocolMinted: 1000n, pendingSolon: 5n }).action, 'sweep');
  assert.equal(deskPlan({ ...base, totalSupply: 5000n, pendingSolon: 5n }).action, 'sweep');
  assert.equal(deskPlan({ ...base, pendingSolon: 250_000n * E18, opsSurchargeAvailable: false }).action, 'none');
});

test('evidence per token from a collect receipt: only transfers to the platform recipient', () => {
  const me = '0x' + 'dd'.repeat(20);
  const ev = evidenceFromCollect({
    sourceKey: '0x' + '01'.repeat(32), collectTx: '0x' + '02'.repeat(32), collectBlock: 100, platformRecipient: me,
    tokens: [ZERO, SOLON], nativeDelta: 7n * 10n ** 12n + 3n, policyVersion: 1,
    transfers: [
      { token: SOLON, to: me, value: 5n, logIndex: 4 }, { token: SOLON, to: '0x' + 'ee'.repeat(20), value: 5n, logIndex: 5 },
      { token: '0x3600000000000000000000000000000000000000', to: me, value: 7n, logIndex: 2 },
    ],
  });
  assert.deepEqual(ev.map(e => [e.token, e.actualPlatformAmount, e.logIndex, e.mismatch]), [[ZERO, 7n * 10n ** 12n + 3n, 2, undefined], [SOLON, 5n, 4, undefined]]);
});

// decimals M4 (AGENTS.md §4.6): the native platform fee is one amount seen two ways — the 18-dp native balance delta and
// Arc's 0x3600 ERC-20-view Transfer (6 dp). They must agree to within one 6-dp unit, or the lot is not funded.
const VIEW = '0x3600000000000000000000000000000000000000';
const me = '0x' + 'dd'.repeat(20);
const evArgs = (nativeDelta, transfers) => ({ sourceKey: '0x' + '01'.repeat(32), collectTx: '0x' + '02'.repeat(32), collectBlock: 100, platformRecipient: me, tokens: [ZERO], nativeDelta, policyVersion: 1, transfers });

test('decimals M4: native delta 1.000000000000000001 USDC agrees with a 1.000000 view Transfer', () => {
  const [e] = evidenceFromCollect(evArgs(10n ** 18n + 1n, [{ token: VIEW, to: me, value: 1_000_000n, logIndex: 3 }]));
  assert.equal(e.actualPlatformAmount, 10n ** 18n + 1n);
  assert.equal(e.mismatch, undefined);
});

test('decimals M4: an unrelated native inflow in the window (delta >> view x 1e12) is flagged, never funded as fee', () => {
  const [e] = evidenceFromCollect(evArgs(12n * 10n ** 18n + 1n, [{ token: VIEW, to: me, value: 7_000_000n, logIndex: 3 }]));
  assert.match(e.mismatch, /native delta .* 0x3600/);
});

test('decimals M4: a native delta with no 0x3600 Transfer to the recipient is flagged', () => {
  const [e] = evidenceFromCollect(evArgs(5n * 10n ** 18n, [{ token: VIEW, to: '0x' + 'ee'.repeat(20), value: 5_000_000n, logIndex: 1 }]));
  assert.match(e.mismatch, /no 0x3600 Transfer/);
});

test('decimals M4: view Transfers to the recipient are summed (one unit of slack per 6-dp step only)', () => {
  const t = [{ token: VIEW, to: me, value: 2_000_000n, logIndex: 3 }, { token: VIEW, to: me, value: 1_500_000n, logIndex: 6 }];
  assert.equal(evidenceFromCollect(evArgs(35n * 10n ** 17n + 999_999_999_999n, t))[0].mismatch, undefined);
  assert.match(evidenceFromCollect(evArgs(35n * 10n ** 17n + 10n ** 12n, t))[0].mismatch, /native delta/);
});

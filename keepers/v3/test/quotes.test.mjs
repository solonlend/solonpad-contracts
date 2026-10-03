import test from 'node:test';
import assert from 'node:assert/strict';
import { Wallet, recoverAddress } from 'ethers';
import { stockQuoteDigest, buybackQuoteDigest, conversionQuoteDigest, conversionMinFloor, signChecked, DigestMismatch, START_FUNDING_SELECTOR } from '../lib/quotes.mjs';
import { digestSigner } from '../lib/signer.mjs';

const A = n => '0x' + String(n).repeat(40).slice(0, 40);
const config = { asset: A(1), underlying: A(2), hub: A(3), path: '0x' + '44'.repeat(32), destinationChain: 4663n, vault: A(5), opsVault: A(6) };
const q = { orderId: '0x' + '77'.repeat(32), budget18: 10n, minRawOut: 1n, deadline: 5n, nonce: 9n, fees18: 0n, fixedCost18: 0n };

test('startFunding selector matches the adapter function', () => {
  assert.equal(START_FUNDING_SELECTOR, '0xcd96ab86');
});

test('stock quote digest binds adapter, chain and every economic field', () => {
  const d = stockQuoteDigest({ chainId: 5042, adapter: A(8), config, q });
  assert.notEqual(d, stockQuoteDigest({ chainId: 4663, adapter: A(8), config, q }));
  assert.notEqual(d, stockQuoteDigest({ chainId: 5042, adapter: A(9), config, q }));
  assert.notEqual(d, stockQuoteDigest({ chainId: 5042, adapter: A(8), config, q: { ...q, minRawOut: 0n } }));
  assert.notEqual(d, stockQuoteDigest({ chainId: 5042, adapter: A(8), config: { ...config, vault: A(1) }, q }));
});

test('signChecked signs only when local digest == on-chain digest and signer matches', async () => {
  const w = Wallet.createRandom();
  const s = digestSigner(w);
  const d = stockQuoteDigest({ chainId: 5042, adapter: A(8), config, q });
  const sig = await signChecked({ local: d, onchain: async () => d, quoteSigner: s, expectedSigner: w.address });
  assert.equal(recoverAddress(d, sig), w.address, 'raw-digest signature (SignatureChecker/ECDSA)');
  await assert.rejects(signChecked({ local: d, onchain: async () => '0x' + '00'.repeat(32), quoteSigner: s }), DigestMismatch);
  await assert.rejects(signChecked({ local: d, onchain: async () => d, quoteSigner: s, expectedSigner: A(1) }), DigestMismatch);
});

test('buyback and conversion digests differ per recipient / binding', () => {
  const bq = { lotId: '0x' + '12'.repeat(32), budget: 1n, minOut: 1n, pricePolicyVersion: 1n, quotedAt: 1n, deadline: 2n, nonce: 3n };
  const bc = { solon: A(1), router: A(2), path: '0x' + '99'.repeat(32) };
  assert.notEqual(buybackQuoteDigest({ chainId: 5042, executor: A(3), config: bc, recipient: A(4), q: bq }),
    buybackQuoteDigest({ chainId: 5042, executor: A(3), config: bc, recipient: A(5), q: bq }));
  const binding = { router: A(1), sellRoute: A(2), path: '0x' + '99'.repeat(32), version: 1, ops: A(4), lpFeePpm: 10000 };
  const cq = { lotId: '0x' + '12'.repeat(32), asset: A(5), raw: 1n, minUSDC18: 1n, value18: 1n, issuedAt: 1n, deadline: 2n, nonce: 3n, fees18: 0n };
  assert.notEqual(conversionQuoteDigest({ chainId: 5042, converter: A(6), binding, q: cq }),
    conversionQuoteDigest({ chainId: 5042, converter: A(6), binding: { ...binding, lpFeePpm: 3000 }, q: cq }));
});

test('conversion min floor = ceil(value * (1e6 - fee) * 9900 / 1e10) like V2FeeConverter', () => {
  assert.equal(conversionMinFloor(100n * 10n ** 18n, 10_000), 98_010_000_000_000_000_000n);
  assert.equal(conversionMinFloor(3n, 0), 3n, 'ceil');
});

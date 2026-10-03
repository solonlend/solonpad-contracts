// v2 fee-ingress keeper — the planned replacement of v4launch/buyback_daemon.mjs at cutover.
// Per cycle (under the shared 0xdD43 lock, since fundLot must come from the platform recipient):
//   1. collect (only when enabled and fees >= threshold) and derive per-token evidence
//   2. evidence -> 2-of-3 auditor signatures -> recordLot -> fundLot (exact amount)
//   3. raw lots: routeLot (SOLON: half burnt in kind) -> convertLot (signed conversion quote)
//   4. BuybackBurnExecutor.execute for funded buyback lots (<= $1000 chunks, signed quote)
//   5. BuybackVault.burnPending, ProtocolDeskVault.mintAvailable / sweepOverflowToBurn
// Each lot is journaled from Observed onward; every tx key is lot-scoped, and chain state
// (lotInfo, router.state, executor.lots) is re-read before each step.
import { Contract, Interface, keccak256, AbiCoder, recoverAddress } from 'ethers';
import {
  V2IngressAbi, V2RouterAbi, V2ConverterAbi, BuybackExecutorAbi, BuybackVaultAbi, ProtocolDeskVaultAbi, DeskNftAbi,
  Erc20Abi, SplitterAbi,
} from '../lib/abis.mjs';
import { taskKey } from '../lib/journal.mjs';
import { buybackQuoteDigest, conversionQuoteDigest, encodeConversionQuoteData, conversionMinFloor, signChecked, newNonce } from '../lib/quotes.mjs';
import { collectDecision, lotNextAction, buybackChunk, buybackMinOut, deskPlan, evidenceFromCollect, ZERO, E18 } from './decide.mjs';

const coder = AbiCoder.defaultAbiCoder();
const erc20 = new Interface(Erc20Abi);

export class AuditorSeam extends Error {
  constructor() { super('phase-5/ops seam: auditor signing service not configured'); this.seam = 'auditor signatures'; }
}

// Auditor client: returns two signatures over ingress.evidenceDigest(e). Each signature is
// recovered and matched to the on-chain auditor set before use.
export function localAuditors(wallets) {
  return {
    async sign(digest) {
      return wallets.slice(0, 2).map((w, i) => ({ auditor: w.index ?? i, signature: w.signer.signDigest(digest) }));
    },
  };
}

export class IngressKeeper {
  constructor({ cfg, provider, tx, journal, logger, alert, chainId, auditors = null, quoteSigner = null, priceSource = null, now = null }) {
    Object.assign(this, { cfg, provider, tx, journal, logger, alert, chainId, auditors, quoteSigner, priceSource });
    this.clock = now; // quotes need chain time: issuedAt <= block.timestamp
    this.nowSec = 0;
    const c = cfg.contracts;
    this.ingress = new Contract(c.v2Ingress, V2IngressAbi, provider);
    this.router = new Contract(c.v2Router, V2RouterAbi, provider);
    this.executor = new Contract(c.buybackExecutor, BuybackExecutorAbi, provider);
    this.deskVault = c.protocolDeskVault ? new Contract(c.protocolDeskVault, ProtocolDeskVaultAbi, provider) : null;
    this.p = { thresholdUsd18: 100n * E18, minBuy18: E18, buybackSlippageBps: 300n, conversionTtl: 50, collectEnabled: false, ...(cfg.ingress?.params ?? {}) };
    for (const k of ['thresholdUsd18', 'minBuy18', 'buybackSlippageBps']) this.p[k] = BigInt(this.p[k]);
  }

  now() { return this.clock ? this.clock() : this.nowSec; }

  key(contract, op) { return taskKey({ chainId: this.chainId, contract, op }); }

  async tick() {
    this.summary = { actions: [], seams: [], quarantined: [] };
    if (!this.clock) this.nowSec = (await this.provider.getBlock('latest')).timestamp;
    await this.tx.reconcileAll();
    for (const source of this.cfg.ingress?.sources ?? []) {
      if (this.p.collectEnabled && source.collect) await this.maybeCollect(source);
    }
    for (const lot of this.journal.records('lots')) await this.advanceLot(lot);
    await this.runBuybacks();
    await this.runBurnAndDesk();
    return this.summary;
  }

  // ------------------------------------------------------------ 1. collect
  async maybeCollect(source) {
    const est = await (this.priceSource?.platformFeesUsd18?.(source) ?? Promise.resolve(0n));
    const d = collectDecision({ feesUsd18: est, thresholdUsd18: this.p.thresholdUsd18 });
    if (!d.collect) { this.summary.actions.push({ kind: 'collect', source: source.name, status: 'skip', reason: d.reason }); return; }
    const recipient = this.tx.from;
    if (!recipient) { this.summary.actions.push({ kind: 'collect', source: source.name, status: 'dry-run', reason: 'fees over threshold; no signer loaded' }); return; }
    const splitter = new Contract(source.collect.splitter, SplitterAbi, this.provider);
    const tag = `${source.name}:${Math.floor(this.now() / 300)}`;
    const res = await this.tx.call(this.key(splitter.target, `collect:${tag}`), splitter, 'collectFees', [[BigInt(source.collect.positionId)]], { label: `collect ${source.name} #${source.collect.positionId}` });
    this.summary.actions.push({ kind: 'collect', source: source.name, status: res.status });
    if (res.status !== 'confirmed') return;
    const r = res.receipt;
    // Decimals M4: measure across the collect's own block (not a 'latest' read taken before sending); any other inflow
    // still inside that block is caught by the 0x3600 cross-check in evidenceFromCollect.
    const before = await this.provider.getBalance(recipient, r.blockNumber - 1);
    const after = await this.provider.getBalance(recipient, r.blockNumber);
    const nativeDelta = after - before + r.gasUsed * (r.gasPrice ?? 0n);
    const transfers = [];
    for (const log of r.logs) {
      try {
        const p = erc20.parseLog(log);
        if (p?.name === 'Transfer') transfers.push({ token: log.address, to: p.args.to, value: p.args.value, logIndex: log.index });
      } catch { /* not a Transfer */ }
    }
    const evidences = evidenceFromCollect({
      sourceKey: source.key, collectTx: r.hash, collectBlock: r.blockNumber, platformRecipient: recipient,
      tokens: source.tokens, transfers, nativeDelta, policyVersion: source.policyVersion,
    });
    for (const e of evidences) {
      const receiptKey = keccak256(coder.encode(['bytes32', 'bytes32', 'uint32', 'address'], [e.source, e.collectTx, e.logIndex, e.token]));
      if (e.mismatch) {
        const { mismatch, ...evidence } = e;
        this.journal.setRecord('lots', receiptKey, { evidence, kind: source.kind, name: source.name, observedAt: this.now(), quarantined: true, reason: mismatch });
        this.summary.quarantined.push(receiptKey);
        await this.alert(`collect-${receiptKey}`, `v2 collect ${r.hash} (${source.name}) native fee not funded: ${mismatch}; check the recipient's inflows and fund manually if correct`);
        continue;
      }
      this.journal.setRecord('lots', receiptKey, { evidence: e, kind: source.kind, name: source.name, observedAt: this.now() });
    }
  }

  // ------------------------------------------------------------ 2/3. record, fund, route, convert
  async advanceLot(lot) {
    if (lot.done || lot.quarantined) return;
    const e = lot.evidence;
    const evidenceTuple = [e.source, e.collectTx, e.collectBlock, e.logIndex, e.token, e.actualPlatformAmount, e.policyVersion];
    const digest = await this.ingress.evidenceDigest(evidenceTuple);
    const lotId = keccak256(coder.encode(['bytes32'], [digest]));
    const info = await this.ingress.lotInfo(lotId);
    const routerState = Number(await this.router.state(lotId));
    const native = e.token === ZERO;
    const d = lotNextAction({ ingressState: Number(info.state), admitted: info.admitted, routerState, native, hasSignatures: Boolean(this.auditors) });
    const rid = keccak256(coder.encode(['bytes32', 'bytes32', 'uint32', 'address'], [e.source, e.collectTx, e.logIndex, e.token]));
    switch (d.action) {
      case 'awaitAudit':
        this.summary.seams.push('auditor signatures');
        return;
      case 'record': {
        const sigs = await this.auditors.sign(digest);
        for (const s of sigs) {
          const expected = await this.ingress.auditors(s.auditor).catch(() => null);
          if (!expected || recoverAddress(digest, s.signature).toLowerCase() !== expected.toLowerCase()) throw new Error(`auditor ${s.auditor} signature does not match on-chain auditor`);
        }
        const res = await this.tx.call(this.key(this.ingress.target, `record:${rid}`), this.ingress, 'recordLot', [evidenceTuple, sigs.map(s => [s.auditor, s.signature])], { label: `recordLot ${lot.name} ${e.token === ZERO ? 'USDC' : e.token.slice(0, 8)}` });
        this.summary.actions.push({ kind: 'recordLot', lotId, status: res.status });
        if (res.status === 'confirmed') this.journal.setRecord('lots', rid, { lotId });
        return;
      }
      case 'quarantine':
        this.journal.setRecord('lots', rid, { quarantined: true, lotId, reason: d.reason });
        this.summary.quarantined.push(lotId);
        await this.alert(`lot-${lotId}`, `v2 lot ${lotId} quarantined: ${d.reason}; platform funds stay with the recipient, not spent`);
        return;
      case 'fund': {
        if (!native) {
          const token = new Contract(e.token, Erc20Abi, this.provider);
          if ((await token.allowance(this.tx.from, this.ingress.target)) < e.actualPlatformAmount) {
            const ar = await this.tx.call(this.key(e.token, `approve:${lotId}`), token, 'approve', [this.ingress.target, e.actualPlatformAmount], { label: 'approve exact lot amount' });
            if (ar.status !== 'confirmed') return;
          }
        }
        const res = await this.tx.call(this.key(this.ingress.target, `fund:${lotId}`), this.ingress, 'fundLot', [lotId], { value: native ? e.actualPlatformAmount : 0n, label: `fundLot ${lotId.slice(0, 10)}` });
        this.summary.actions.push({ kind: 'fundLot', lotId, status: res.status });
        if (res.status === 'confirmed') this.journal.setRecord('lots', rid, { fundedAt: this.now(), buybackLots: native ? [lotId] : [] });
        return;
      }
      case 'route': {
        const res = await this.tx.call(this.key(this.router.target, `route:${lotId}`), this.router, 'routeLot', [lotId], { label: `routeLot ${lotId.slice(0, 10)}` });
        this.summary.actions.push({ kind: 'routeLot', lotId, status: res.status });
        return;
      }
      case 'convert':
        await this.convert(lotId, rid);
        return;
      case 'done':
        this.journal.setRecord('lots', rid, { done: true });
        return;
      default:
        return;
    }
  }

  async convert(lotId, rid) {
    const pending = await this.router.pending(lotId);
    const selected = (await this.router.assetConverter(pending.token)) !== ZERO ? await this.router.assetConverter(pending.token) : await this.router.converter();
    if (selected === ZERO) { this.summary.seams.push('V2FeeConverter for asset'); return; }
    const conv = new Contract(selected, V2ConverterAbi, this.provider);
    const slice = await this.router.nextConversionId(lotId);
    if (!this.quoteSigner || !this.priceSource?.usdValue18) { this.summary.seams.push('conversion quote signer/price'); return; }
    const binding = { router: await conv.router(), sellRoute: await conv.sellRoute(), path: await conv.path(), version: await conv.version(), ops: await conv.ops(), lpFeePpm: await conv.lpFeePpm() };
    const raw = pending.raw;
    const value18 = await this.priceSource.usdValue18(pending.token, raw);
    if (value18 === 0n || value18 > 1000n * E18) { this.summary.actions.push({ kind: 'convert', lotId, status: 'skip', reason: 'value outside (0,$1000]; split needed' }); return; }
    const issuedAt = this.now();
    const q = { lotId: slice, asset: pending.token, raw, minUSDC18: conversionMinFloor(value18, binding.lpFeePpm), value18, issuedAt, deadline: issuedAt + this.p.conversionTtl, nonce: newNonce(), fees18: 0n };
    const signature = await signChecked({
      local: conversionQuoteDigest({ chainId: this.chainId, converter: selected, binding, q }),
      onchain: () => conv.quoteDigest([q.lotId, q.asset, q.raw, q.minUSDC18, q.value18, q.issuedAt, q.deadline, q.nonce, q.fees18]),
      quoteSigner: this.quoteSigner, expectedSigner: await conv.signer(),
    });
    const res = await this.tx.call(this.key(this.router.target, `convert:${slice}`), this.router, 'convertLot(bytes32,bytes)', [lotId, encodeConversionQuoteData(q, signature)], { label: `convertLot ${lotId.slice(0, 10)}` });
    this.summary.actions.push({ kind: 'convertLot', lotId, slice, status: res.status });
    // kind 1 (SOLON_V2) conversions become staking stock budget; only kind 2 slices are buyback lots.
    if (res.status === 'confirmed' && Number(pending.kind) === 2) {
      const lot = this.journal.record('lots', rid);
      this.journal.setRecord('lots', rid, { buybackLots: [...(lot.buybackLots ?? []), slice] });
    }
  }

  // ------------------------------------------------------------ 4. buybacks
  async runBuybacks() {
    const ids = new Set(this.journal.records('lots').flatMap(l => l.buybackLots ?? []));
    for (const id of ids) {
      const lot = await this.executor.lots(id);
      const chunk = buybackChunk({ budget: lot.budget, spent: lot.spent, executed: lot.executed, minBuy18: this.p.minBuy18 });
      if (!chunk.buy) continue;
      if (!this.quoteSigner || !this.priceSource?.solonPerUsdc18) { this.summary.seams.push('buyback quote signer/price'); continue; }
      const config = await this.executor.config();
      const quotedAt = this.now();
      const q = {
        lotId: id, budget: chunk.amount, minOut: buybackMinOut({ budget18: chunk.amount, solonPerUsdc18: await this.priceSource.solonPerUsdc18(), slippageBps: this.p.buybackSlippageBps }),
        pricePolicyVersion: await this.executor.pricePolicyVersion(), quotedAt, deadline: quotedAt + 50, nonce: newNonce(),
      };
      const recipient = lot.protocolDesk ? config.protocolDesk : await this.executor.vault();
      const signature = await signChecked({
        local: buybackQuoteDigest({ chainId: this.chainId, executor: this.executor.target, config, recipient, q }),
        onchain: () => this.executor.quoteDigest([q.lotId, q.budget, q.minOut, q.pricePolicyVersion, q.quotedAt, q.deadline, q.nonce]),
        quoteSigner: this.quoteSigner, expectedSigner: config.signer,
      });
      const res = await this.tx.call(this.key(this.executor.target, `buy:${id}:${lot.spent}`), this.executor, 'execute', [[q.lotId, q.budget, q.minOut, q.pricePolicyVersion, q.quotedAt, q.deadline, q.nonce], signature], { label: `buyback ${id.slice(0, 10)} $${chunk.amount / E18}` });
      this.summary.actions.push({ kind: 'buyback', lotId: id, amount: chunk.amount, protocolDesk: lot.protocolDesk, status: res.status });
      if (res.status === 'confirmed') {
        for (const log of res.receipt.logs) {
          try {
            const p = this.executor.interface.parseLog(log);
            if (p?.name === 'Bought' && !lot.protocolDesk) this.journal.setRecord('burns', p.args.lotId, { amount: p.args.received });
          } catch { /* other */ }
        }
      }
    }
  }

  // ------------------------------------------------------------ 5. burn + protocol desk
  async runBurnAndDesk() {
    const bv = new Contract(await this.executor.vault(), BuybackVaultAbi, this.provider);
    for (const [id, rec] of Object.entries(this.journal.state.records.burns ?? {})) {
      if (rec.burned) continue;
      const l = await bv.lots(id);
      if (Number(l.state) !== 1) { if (Number(l.state) === 2) this.journal.setRecord('burns', id, { burned: true }); continue; }
      const res = await this.tx.call(this.key(bv.target, `burn:${id}`), bv, 'burnPending', [id], { label: `burnPending ${id.slice(0, 10)}` });
      this.summary.actions.push({ kind: 'burnPending', lotId: id, status: res.status });
    }
    if (!this.deskVault) return;
    const nft = new Contract(await this.deskVault.nft(), DeskNftAbi, this.provider);
    const [pendingSolon, perDesk, protocolMinted, totalSupply, maxSupply] = await Promise.all([
      this.deskVault.pendingSolon(), nft.SOLON_PER_DESK(), nft.protocolMinted(), nft.totalSupply(), nft.MAX_SUPPLY(),
    ]);
    const plan = deskPlan({ pendingSolon, perDesk, protocolMinted, totalSupply, maxSupply });
    if (plan.action === 'mint') {
      const res = await this.tx.call(this.key(this.deskVault.target, `mint:${protocolMinted}`), this.deskVault, 'mintAvailable', [plan.cards], { label: `protocol desk mint ${plan.cards}` });
      this.summary.actions.push({ kind: 'deskMint', cards: plan.cards, status: res.status });
    } else if (plan.action === 'sweep') {
      const res = await this.tx.call(this.key(this.deskVault.target, `sweep:${pendingSolon}`), this.deskVault, 'sweepOverflowToBurn', [], { label: 'protocol desk overflow -> BurnSink' });
      this.summary.actions.push({ kind: 'deskSweep', amount: pendingSolon, status: res.status });
    }
  }
}

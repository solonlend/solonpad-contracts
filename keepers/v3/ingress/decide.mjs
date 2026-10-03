// Pure logic for the v2 fee-ingress keeper (DESIGN §9.4; V2FeeIngress / V2PlatformRouter /
// BuybackBurnExecutor / ProtocolDeskVault at 5f73eaf).
//   SOLON_V2 (kind 1): platform share 50% stock budget (SolonStakingV2) / 50% SOLON buyback -> BurnSink
//                      (SOLON-side raw fee: 50% burnt in kind, 50% converted to USDC for stock)
//   OTHER_V2 (kind 2): platform share 100% -> SOLON buyback -> ProtocolDeskVault (<=1000 cards, overflow burn)
export const E18 = 10n ** 18n;
export const SourceKind = Object.freeze({ SOLON_V2: 1, OTHER_V2: 2 });
export const IngressLot = Object.freeze({ None: 0, Observed: 1, Funded: 2 });
export const RouterLot = Object.freeze({ None: 0, RawFunded: 1, Routed: 2, Converting: 3, Done: 4 });
export const MAX_BUYBACK = 1000n * E18;
export const ZERO = '0x0000000000000000000000000000000000000000';

// Collect only when the estimated platform share covers execution cost with margin (§9.4 end).
export function collectDecision({ feesUsd18, thresholdUsd18, execCostUsd18 = 0n, maxCostBps = 100n }) {
  if (feesUsd18 < thresholdUsd18) return { collect: false, reason: `fees ${feesUsd18} < threshold ${thresholdUsd18}` };
  if (execCostUsd18 * 10_000n > feesUsd18 * maxCostBps) return { collect: false, reason: 'execution cost too high vs fees' };
  return { collect: true };
}

// Mirror of V2PlatformRouter._stockHalf (per-asset odd-unit remainder carried across lots).
export function stockHalf(amount, remainder = 0) {
  const fraction = (amount % 2n) + BigInt(remainder);
  return { stock: amount / 2n + fraction / 2n, remainder: Number(fraction % 2n) };
}

// What the router will do with a funded lot; used to verify post-state and for the report.
export function expectedRouting({ kind, token, amount, remainder = 0 }) {
  if (kind === SourceKind.SOLON_V2) {
    const { stock, remainder: r } = stockHalf(amount, remainder);
    if (token === ZERO) return { stockUSDC18: stock, buybackUSDC18: amount - stock, protocolDesk: false, burnRaw: 0n, convertRaw: 0n, remainder: r };
    return { stockUSDC18: 0n, buybackUSDC18: 0n, protocolDesk: false, burnRaw: amount - stock, convertRaw: stock, remainder: r };
  }
  if (kind === SourceKind.OTHER_V2) {
    if (token === ZERO) return { stockUSDC18: 0n, buybackUSDC18: amount, protocolDesk: true, burnRaw: 0n, convertRaw: 0n, remainder };
    return { stockUSDC18: 0n, buybackUSDC18: 0n, protocolDesk: true, burnRaw: 0n, convertRaw: amount, remainder };
  }
  throw new Error(`unknown source kind ${kind}`);
}

// Next action for one lot. ingress: {state, admitted}; routerState: RouterLot; native: token === 0.
export function lotNextAction({ ingressState, admitted, routerState, native, hasSignatures }) {
  if (ingressState === IngressLot.None) return hasSignatures ? { action: 'record' } : { action: 'awaitAudit' };
  if (ingressState === IngressLot.Observed) return admitted ? { action: 'fund' } : { action: 'quarantine', reason: 'lot not admitted (source/cutover/policy mismatch)' };
  if (native) return routerState === RouterLot.Done ? { action: 'done' } : { action: 'wait', reason: `router state ${routerState}` };
  switch (routerState) {
    case RouterLot.RawFunded: return { action: 'route' };
    case RouterLot.Routed: return { action: 'convert' };
    case RouterLot.Done: return { action: 'done' };
    default: return { action: 'wait', reason: `router state ${routerState}` };
  }
}

// Buyback chunk for BuybackBurnExecutor.execute (<= $1000 per quote, never more than remaining).
export function buybackChunk({ budget, spent, executed, minBuy18 = E18 }) {
  if (executed || budget === 0n) return { buy: false, reason: executed ? 'executed' : 'unfunded' };
  const remaining = budget - spent;
  if (remaining < minBuy18) return { buy: false, reason: 'below minimum buy' };
  return { buy: true, amount: remaining > MAX_BUYBACK ? MAX_BUYBACK : remaining };
}

// minOut for a SOLON buyback from a price (SOLON wei per 1 USDC18) and tolerance.
export function buybackMinOut({ budget18, solonPerUsdc18, slippageBps = 300n }) {
  if (solonPerUsdc18 <= 0n) throw new Error('no SOLON price');
  const out = (budget18 * solonPerUsdc18) / E18;
  const min = (out * (10_000n - BigInt(slippageBps))) / 10_000n;
  if (min === 0n) throw new Error('minOut rounds to zero');
  return min;
}

// ProtocolDeskVault: mint when a full card is pending and caps allow; sweep once capped.
export function deskPlan({ pendingSolon, perDesk, protocolMinted, protocolMax = 1000n, totalSupply, maxSupply, opsSurchargeAvailable = true }) {
  const capped = protocolMinted >= protocolMax || totalSupply >= maxSupply;
  if (capped) return pendingSolon > 0n ? { action: 'sweep' } : { action: 'none' };
  const cards = pendingSolon / perDesk;
  if (cards === 0n) return { action: 'none', reason: 'below one card' };
  if (!opsSurchargeAvailable) return { action: 'none', reason: 'OpsShortfall (surcharge)' };
  const n = cards > 20n ? 20n : cards;
  return { action: 'mint', cards: n };
}

// Evidence candidates from a collect receipt. transfers: [{token, to, value, logIndex}] (ERC20 Transfer
// logs already parsed), nativeDelta: platform-recipient native delta incl. gas. For native USDC the
// logIndex of Arc's 0x3600 ERC20-view Transfer is used (auditors verify independently).
// Decimals (AGENTS.md §4.6): native (18 dp) and the 0x3600 view (6 dp) are the same money, so the native delta must
// equal the view Transfers to the recipient x 1e12 within one 6-dp unit. Otherwise (other inflow in the window, or no
// view log) the evidence carries `mismatch` and must not be funded.
export function evidenceFromCollect({ sourceKey, collectTx, collectBlock, platformRecipient, tokens, transfers, nativeDelta, nativeViewToken = '0x3600000000000000000000000000000000000000', policyVersion }) {
  const out = [];
  const rcpt = platformRecipient.toLowerCase();
  for (const token of tokens) {
    if (token === ZERO) {
      if (nativeDelta <= 0n) continue;
      const logs = transfers.filter(t => t.token.toLowerCase() === nativeViewToken.toLowerCase() && t.to.toLowerCase() === rcpt);
      const view18 = logs.reduce((s, t) => s + BigInt(t.value), 0n) * 10n ** 12n;
      const diff = nativeDelta > view18 ? nativeDelta - view18 : view18 - nativeDelta;
      const mismatch = logs.length === 0
        ? `no 0x3600 Transfer to the recipient for native delta ${nativeDelta}`
        : diff >= 10n ** 12n ? `native delta ${nativeDelta} != 0x3600 view ${view18 / 10n ** 12n} x 1e12` : undefined;
      const e = { source: sourceKey, collectTx, collectBlock, logIndex: logs[0]?.logIndex ?? 0, token: ZERO, actualPlatformAmount: nativeDelta, policyVersion };
      out.push(mismatch ? { ...e, mismatch } : e);
    } else {
      const logs = transfers.filter(t => t.token.toLowerCase() === token.toLowerCase() && t.to.toLowerCase() === rcpt);
      const amount = logs.reduce((s, t) => s + t.value, 0n);
      if (amount === 0n) continue;
      out.push({ source: sourceKey, collectTx, collectBlock, logIndex: logs[0].logIndex, token, actualPlatformAmount: amount, policyVersion });
    }
  }
  return out;
}

// Pure decisions of the Desk payout keeper (desk/keeper.mjs). Contract facts (src/v3, frozen):
//   DeskRewards stream key = keccak(source, UTC day, asset, kind); credits only land on the current day, so a stream is
//   final once its day is over. counter = credit27 of a first-generation card (cards minted later in the day get less).
//   kind 1 (stock-quoted pool, stock royalties): claimable = credit27 / 1e27 of the stream's own stock.
//   kind 0 (USDC-quoted pool, surcharge, native royalty): claimable = credit27 x purchasedRaw / totalCredit27 of the stock
//   the round bought for the stream's DeskRewardEntry (RewardRoundManager entry, synced by syncPurchased).
//   DeskNFT.batchDistributeDesk(queueId, maxCards <= 32): runs only at >= 00:10 UTC and >= nextScanAt; before each card it
//   needs gasleft >= 500k x streams + 100k (else it returns without progress); a card is paid only when the sum of its
//   claimable over the queue's streams x priceUSD18 >= RewardDistributor.minimumUSD18 (>= $2) with a price younger than
//   oracleMaxAge; a finished pass sets nextScanAt to the next day 00:10, a partial one to now + 15 min.
export const DAY = 86_400;
export const SCAN_OFFSET = 600; // 00:10 UTC
export const P27 = 10n ** 27n;
export const E18 = 10n ** 18n;
export const USDC_GRID = 10n ** 12n; // round budgets are 6-dp aligned: < 1e12 of an entry may stay in `available` for good
export const MAX_CARDS = 32;
export const MAX_KEYS = 20; // DeskNFT._openDeskQueue

export const DESK_DEFAULTS = Object.freeze({
  maxKeysPerQueue: 8, // reserve per card = 500k x keys + 100k
  marginBps: 1000, // a group opens when a first-generation card is worth >= minimumUSD18 x 1.1 (price moves, later cards)
  maxTxGas: 15_000_000, // Arc block gas limit 30M (mainnet read 10-02)
  fixedGas: 150_000,
  perCardGas: 40_000, // per card outside the stream loop (ownerOf, try/catch, cursor, events)
  perKeyCardGas: 60_000, // per card per stream (claimable view + pay incl. ERC20 transfer)
  maxPasses: 3, // full passes of a queue while some card's push reverts (DeskPushBlocked), then alert and stop
  priceMarginSec: 900, // the batch must land with >= 15 min of oracleMaxAge left
  demandRefreshSec: 600,
  scanMarginSec: 30, // chain time of the next block >= our read of `now`
  deliverAlertSec: 2 * DAY, // sealed entry the round manager calls Ready / CostLimit / Pending, unbought this long -> alert
  // (BelowMinimum = its asset group has < minimumBudget queued: normal while volume is low, entries accumulate; no alert)
  priceAlertSec: 4 * DAY, // queue unable to run for an old price this long (> a weekend) -> alert
  lookbackDays: 45, // streams older than this are not chased (manual claim keeps working)
  discoveryAlertAfter: 5,
  market: {}, // lib/market.mjs gate for push demands (closed market: the oracle keeper would not push)
});

export const utcDay = nowSec => Math.floor(nowSec / DAY);
export const epochOver = (nowSec, epoch) => nowSec >= (Number(epoch) + 1) * DAY;

/// Raw stock a first-generation card can claim from one stream.
export function perCardRaw({ kind, counter, totalCredit27, purchasedRaw }) {
  if (Number(kind) === 1) return BigInt(counter) / P27;
  if (BigInt(totalCredit27) === 0n) return 0n;
  return (BigInt(counter) * BigInt(purchasedRaw)) / BigInt(totalCredit27);
}

export const usdOf = (raw, price18) => (BigInt(raw) * BigInt(price18)) / E18;

/// USDC-quoted (kind 0) stream progress from chain views.
export function kind0Stage({ now, epoch, budget, sealed, entrySource, entryId, delivered, purchasedRaw, available, pending, sealedFor = null, unbuyableAfterSec = 2 * DAY }) {
  if (!epochOver(now, epoch)) return { stage: 'wait-epoch' };
  if (!sealed) {
    // 0: sealDesk would revert "empty budget". < 1e12 (< $0.000001): not worth a seal; it stays in DeskRewards. Final after the day.
    if (BigInt(budget) < USDC_GRID) return { stage: 'empty' };
    return { stage: entrySource ? 'seal' : 'create-entry' };
  }
  if (entryId == null) return { stage: 'find-entry' };
  if (BigInt(delivered) > BigInt(purchasedRaw)) return { stage: 'sync' };
  const bought = BigInt(pending) === 0n && BigInt(available) < USDC_GRID;
  if (bought && BigInt(purchasedRaw) > 0n) return { stage: 'ready' };
  // Nothing bought and only grid dust left: no round will ever take it (the batch total must be 6-dp aligned).
  if (bought && BigInt(delivered) === 0n && sealedFor != null && sealedFor > unbuyableAfterSec) return { stage: 'unbuyable' };
  return { stage: 'await-round' };
}

/// Group ready streams per asset into queues. ready: [{ key, asset, perCard, readyAt }] (perCard = raw of a
/// first-generation card). A group opens once sum(perCard) x price >= minimum x (1 + margin); a full group still below
/// that gives up its oldest stream (dust: holders claim it manually) so newer streams can still group.
export function planGroups({ ready, prices, minimumUSD18, maxKeys = DESK_DEFAULTS.maxKeysPerQueue, marginBps = DESK_DEFAULTS.marginBps }) {
  const need = (BigInt(minimumUSD18) * (10_000n + BigInt(marginBps))) / 10_000n;
  const byAsset = new Map();
  for (const r of ready) {
    const a = String(r.asset).toLowerCase();
    if (!byAsset.has(a)) byAsset.set(a, []);
    byAsset.get(a).push(r);
  }
  const open = [], hold = [], dust = [];
  const priceOf = asset => {
    for (const [k, v] of prices) if (String(k).toLowerCase() === asset) return BigInt(v ?? 0n);
    return 0n;
  };
  const cap = Math.min(Math.max(1, maxKeys), MAX_KEYS);
  for (const [asset, list] of byAsset) {
    const price = priceOf(asset);
    // oldest first (then larger first) so nothing starves
    let rest = [...list].sort((x, y) => (x.readyAt - y.readyAt) || (BigInt(y.perCard) > BigInt(x.perCard) ? 1 : -1));
    if (price === 0n) { hold.push(...rest.map(r => r.key)); continue; }
    // Streams already worth the minimum each are packed greedily; anything smaller rides along.
    for (;;) {
      const group = rest.slice(0, cap);
      if (!group.length) break;
      const value = usdOf(group.reduce((t, r) => t + BigInt(r.perCard), 0n), price);
      if (value >= need) {
        open.push({ asset: group[0].asset, keys: group.map(r => r.key), valueUSD18: value });
        rest = rest.slice(group.length);
        continue;
      }
      if (group.length === cap) {
        dust.push({ key: group[0].key, valueUSD18: usdOf(group[0].perCard, price) });
        rest = rest.slice(1);
        continue;
      }
      hold.push(...group.map(r => r.key));
      break;
    }
  }
  return { open, hold, dust };
}

/// Gas for one batchDistributeDesk call: an explicit limit (estimateGas would find the early-return path and progress
/// nothing). cards fit under maxTxGas, at least 1, at most 32.
export function deskGasPlan({ keys, maxTxGas = DESK_DEFAULTS.maxTxGas, fixedGas = DESK_DEFAULTS.fixedGas, perCardGas = DESK_DEFAULTS.perCardGas, perKeyCardGas = DESK_DEFAULTS.perKeyCardGas, wanted = MAX_CARDS }) {
  const reserve = 500_000 * keys + 100_000;
  const perCard = perCardGas + perKeyCardGas * keys;
  const room = maxTxGas - fixedGas - reserve;
  const fit = perCard > 0 ? Math.floor(room / perCard) : wanted;
  const cards = Math.max(1, Math.min(wanted, MAX_CARDS, fit));
  return { cards, gasLimit: fixedGas + reserve + cards * perCard, reserve };
}

/// Pass bookkeeping after a confirmed batch. start = cursor the call scanned from (0 when it wrapped), after = cursor
/// read back. Returns { moved, complete, patch, alert }.
export function passUpdate(rec = {}, { start, after, upperBound, paid = 0, failed = 0, maxPasses = DESK_DEFAULTS.maxPasses }) {
  const moved = after !== start;
  if (!moved) return { moved, complete: false, patch: {}, alert: false };
  const passPaid = (rec.passPaid ?? 0) + paid;
  const passFailed = (rec.passFailed ?? 0) + failed;
  const complete = after === upperBound;
  if (!complete) return { moved, complete, patch: { ...rec, cursor: after, passPaid, passFailed }, alert: false };
  const passes = (rec.passes ?? 0) + 1;
  const done = passFailed === 0 || passes >= maxPasses;
  const patch = { ...rec, cursor: after, passes, passPaid: 0, passFailed: 0, lastPass: { paid: passPaid, failed: passFailed } };
  if (done) patch.done = true;
  return { moved, complete, patch, alert: passFailed > 0 && passes >= maxPasses };
}

// Float watch (r13, path 2a): the two acceleration floats are the launch's working capital — RH USDG in the
// ReserveVault (buys execute from it inside lzReceive; Relay's plain transfers refill it) and Arc USDC in the hub
// (sell payouts and failed-buy refunds are advanced from it; returns refill it). Money only moves between them by
// Relay, so every leg shows up as a two-chain difference. This process reads both chains, alerts on the thresholds
// below and once a day posts the balance + a rebalance suggestion (rebalancing is a manual Ops step via Relay).
// No transactions.
import { Contract, formatUnits } from 'ethers';
import { StockHubAbi, ReserveVaultAbi, HubStatus } from '../lib/abis.mjs';

const E18 = 10n ** 18n, E6 = 10n ** 6n;
export const FLOAT_DEFAULTS = Object.freeze({
  targetRh6: 3_000n * E6, // RH USDG float (3 x L_run)
  targetArc18: 2_000n * E18, // Arc USDC float
  lRun18: 1_000n * E18,
  band18: 250n * E18, // imbalance below this is noise
  driftAlert18: 100n * E18, // total float below target by more than this -> alert (fees eaten, money stuck)
  dailyHourUtc: 1, // daily summary at 01:00 UTC (10:00 JST)
  vaultEthLowWei: 3n * 10n ** 15n, // ReserveVault ETH pays every LZ result message (~0.0001 ETH each): ~30 left -> refill
});

const usd18 = v => Number(formatUnits(v, 18)).toFixed(2);

// Pure: snapshot -> { alerts: [{key, level, text}], suggestion, totals }.
export function decideFloat(s, p = FLOAT_DEFAULTS) {
  const rh18 = s.rhFree6 * 10n ** 12n;
  const total = rh18 + s.arcAvail18;
  const target = p.targetRh6 * 10n ** 12n + p.targetArc18;
  const alerts = [];
  if (!s.rhFloatOn) alerts.push({ key: 'rh-off', level: 'critical', text: 'RH ReserveVault floatEnabled = false: every buy waits for its own funding (2a needs it on)' });
  if (!s.hubFloatOn) alerts.push({ key: 'arc-off', level: 'critical', text: 'hub floatEnabled = false: sells/failed buys cannot be advanced from the float' });
  if (rh18 < p.lRun18) alerts.push({ key: 'rh-low', level: 'warn', text: `RH float ${usd18(rh18)} USDG < one order ($${usd18(p.lRun18)}): buys will wait (OrderWaitingFunds) — move USDC Arc -> RH` });
  if (s.arcAvail18 < p.lRun18) alerts.push({ key: 'arc-low', level: 'warn', text: `Arc float ${usd18(s.arcAvail18)} USDC < one order: sell advances / refunds stall — move USDG RH -> Arc` });
  if (target > total && target - total > p.driftAlert18) alerts.push({ key: 'drift', level: 'warn', text: `two-chain float ${usd18(total)} vs target ${usd18(target)} (-${usd18(target - total)}): Relay fees/short fills or money in flight; check stuck orders` });
  if (s.returning > 0 || s.proceeds > 0) alerts.push({ key: 'stuck', level: 'info', text: `open: ${s.returning} failed buy(s) Returning, ${s.proceeds} sell(s) Proceeds (refund keeper credits them)` });
  if (s.vaultEthWei != null && s.vaultEthWei < p.vaultEthLowWei) alerts.push({ key: 'vault-eth-low', level: 'warn', text: `RH ReserveVault ${Number(formatUnits(s.vaultEthWei, 18)).toFixed(4)} ETH < ${Number(formatUnits(p.vaultEthLowWei, 18)).toFixed(4)}: LZ result messages will fail (NotEnoughNative, orders stuck Dispatched) — send ETH to the vault` });
  if (s.rhWaiting > 0) alerts.push({ key: 'rh-waiting', level: 'warn', text: `${s.rhWaiting} RH buy(s) waiting for funds` });
  // Rebalance: move the excess of one side to the other, whole dollars, only beyond the band.
  const rhExcess = rh18 - p.targetRh6 * 10n ** 12n;
  const arcExcess = s.arcAvail18 - p.targetArc18;
  let suggestion = null;
  if (rhExcess > p.band18 && arcExcess < 0n) {
    const amt = (rhExcess < -arcExcess ? rhExcess : -arcExcess) / E18;
    suggestion = { dir: 'RH->Arc', usd: Number(amt), steps: [`RH: ReserveVault.withdrawFloat(USDG, RH_FLOAT_A, ${amt}e6) [Safe]`, `Relay: ${amt} USDG RH -> Arc USDC, recipient = hub ${s.hub} (plain transfer = hub float)`] };
  } else if (arcExcess > p.band18 && rhExcess < 0n) {
    const amt = (arcExcess < -rhExcess ? arcExcess : -rhExcess) / E18;
    suggestion = { dir: 'Arc->RH', usd: Number(amt), steps: [`Arc: hub.withdrawFloat(HUB_FLOAT_A, ${amt}e18) [Safe]`, `Relay: ${amt} USDC Arc -> RH USDG, recipient = ReserveVault ${s.vault} (plain transfer = RH float)`] };
  }
  return { alerts, suggestion, totals: { rh18, arc18: s.arcAvail18, total, target } };
}

export class FloatWatch {
  constructor({ cfg, provider, rhProvider, logger, alert, now = null }) {
    Object.assign(this, { cfg, provider, rhProvider, logger, alert });
    const c = cfg.contracts ?? {};
    this.hub = new Contract(c.stockHub, StockHubAbi, provider);
    this.vault = new Contract(c.reserveVault, ReserveVaultAbi, rhProvider);
    const q = cfg.float?.params ?? {};
    this.p = { ...FLOAT_DEFAULTS, ...Object.fromEntries(Object.entries(q).map(([k, v]) => [k, typeof FLOAT_DEFAULTS[k] === 'bigint' ? BigInt(v) : v])) };
    this.clock = now;
  }

  // Chain time of the latest block (refreshed each tick): quote deadlines and ages follow the chain, also on forks.
  now() { return this.clock ? this.clock() : this.nowSec ?? Math.floor(Date.now() / 1000); }
  async refreshClock() { if (!this.clock) this.nowSec = (await this.provider.getBlock('latest')).timestamp; }

  async snapshot() {
    const [arcAvail18, hubFloatOn, payAllowance18, escrowed18, rhFree6, rhLiab6, rhFloatOn, open, vaultEthWei] = await Promise.all([
      this.hub.available(), this.hub.floatEnabled(), this.hub.payAllowance(), this.hub.escrowed(),
      this.vault.freeSettlement(), this.vault.settlementLiabilities(), this.vault.floatEnabled(), this.hub.openOrders(),
      this.rhProvider.getBalance(this.vault.target)]);
    let returning = 0, proceeds = 0, dispatched = 0;
    for (const id of open) {
      const st = Number((await this.hub.getOrder(id)).status);
      if (st === HubStatus.Returning) returning++;
      else if (st === HubStatus.Proceeds) proceeds++;
      else if (st === HubStatus.Dispatched || st === HubStatus.Funded) dispatched++;
    }
    const rhWaiting = Number(this.cfg.float?.rhWaiting ?? 0);
    return { hub: this.hub.target, vault: this.vault.target, arcAvail18, hubFloatOn, payAllowance18, escrowed18, rhFree6, rhLiab6, rhFloatOn, returning, proceeds, dispatched, rhWaiting, vaultEthWei, at: this.now() };
  }

  async tick() {
    await this.refreshClock();
    const s = await this.snapshot();
    const d = decideFloat(s, this.p);
    for (const a of d.alerts) if (a.level !== 'info') await this.alert(`float-${a.key}`, a.text);
    const hour = new Date(this.now() * 1000).getUTCHours();
    const day = Math.floor(this.now() / 86_400);
    if (hour === this.p.dailyHourUtc || this.cfg.float?.forceDaily) {
      const text = [`daily float: RH ${usd18(d.totals.rh18)} USDG (target ${usd18(this.p.targetRh6 * 10n ** 12n)}), Arc ${usd18(d.totals.arc18)} USDC (target ${usd18(this.p.targetArc18)}), total ${usd18(d.totals.total)} / ${usd18(d.totals.target)}`,
        `RH liabilities ${Number(s.rhLiab6) / 1e6} USDG; vault ETH ${Number(formatUnits(s.vaultEthWei, 18)).toFixed(4)}; hub escrow ${usd18(s.escrowed18)}; pay allowance ${usd18(s.payAllowance18)}; open: ${s.dispatched} in flight, ${s.returning} Returning, ${s.proceeds} Proceeds`,
        d.suggestion ? `rebalance ${d.suggestion.dir} $${d.suggestion.usd}: ${d.suggestion.steps.join(' ; ')}` : 'rebalance: none needed'].join(' | ');
      await this.alert(`float-daily-${day}`, text);
    }
    return { snapshot: s, ...d };
  }
}

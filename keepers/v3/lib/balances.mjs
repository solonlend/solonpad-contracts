// Native-balance watch (fork F8). The RH ReserveVault pays the LayerZero fee of every result message (fills,
// refunds, sells) from its OWN ETH (ReserveVault._payNative reverts NotEnoughNative below the fee), so an empty
// vault silently stops settlement; the keeper wallets pay their own gas (Arc: native USDC, also the round keeper's
// Ops-fee deposits; RH: ETH, also the oracle keeper's LZ fee per push). Each target below its minimum alerts
// (alert key per chain+address, rate-limited by the alerter). Addresses only — no key material is touched.
import { getAddress, isAddress, parseUnits, formatUnits } from 'ethers';

/// [{ label, chain, address, min ("0.02"), unit ("ETH" | "USDC"), decimals? (18) }] -> normalized targets.
export function parseTargets(list = []) {
  return list.map((t, i) => {
    if (!t?.label || !t.chain) throw new Error(`balances.targets[${i}]: label and chain required`);
    if (!isAddress(t.address ?? '')) throw new Error(`balances.targets[${i}] ${t.label}: bad address`);
    const decimals = Number(t.decimals ?? 18); // RH ETH and Arc native USDC are both 18 dp
    let minWei;
    try { minWei = parseUnits(String(t.min), decimals); } catch { minWei = -1n; }
    if (minWei < 0n) throw new Error(`balances.targets[${i}] ${t.label}: min must be a non-negative decimal`);
    return { label: t.label, chain: t.chain, address: getAddress(t.address.toLowerCase()), minWei, unit: t.unit ?? 'ETH', decimals };
  });
}

const fmt = (wei, t) => `${formatUnits(wei, t.decimals).replace(/\.0$/, '')} ${t.unit}`;

/// balances: { [address]: bigint | Error }
export function evaluateBalances(targets, balances) {
  return targets.map(t => {
    const b = balances[t.address] ?? balances[t.address.toLowerCase()];
    if (b instanceof Error || b == null) {
      return { ...t, balance: null, low: true, text: `${t.label} (${t.chain} ${t.address}): could not read balance (${b?.message ?? 'no reading'})` };
    }
    const low = b < t.minWei;
    return { ...t, balance: b, low, text: `${t.label} (${t.chain} ${t.address}): ${fmt(b, t)}${low ? ` < ${fmt(t.minWei, t)}: top up` : ` (min ${fmt(t.minWei, t)})`}` };
  });
}

export class BalanceWatcher {
  /// readers: { [chain]: async address => bigint }
  constructor({ targets, readers, alert, logger }) {
    Object.assign(this, { targets, readers, alert, logger });
  }

  async tick() {
    const balances = {};
    await Promise.all(this.targets.map(async t => {
      const read = this.readers[t.chain];
      try {
        if (!read) throw new Error(`no RPC for chain ${t.chain}`);
        balances[t.address] = BigInt(await read(t.address));
      } catch (error) {
        balances[t.address] = new Error(String(error?.shortMessage ?? error?.message ?? error).slice(0, 80));
      }
    }));
    const results = evaluateBalances(this.targets, balances);
    for (const r of results) {
      if (r.low) await this.alert(`balance-${r.chain}-${r.address.toLowerCase()}`, r.text);
      else this.logger?.info(r.text);
    }
    return { results: results.map(r => ({ label: r.label, chain: r.chain, address: r.address, balance: r.balance, min: r.minWei, low: r.low })) };
  }
}

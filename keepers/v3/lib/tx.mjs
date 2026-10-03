// TxSender: simulate -> (dry-run stop) -> sign -> journal hash+raw -> broadcast -> receipt.
// Restart safety: a task left in Sent is reconciled from chain (receipt / nonce) before
// anything else happens for that key. Nothing is re-signed for a key whose earlier tx
// might still land, and a failed/replaced tx never advances keeper records.
import { keccak256 } from 'ethers';
import { TaskState, taskGate } from './journal.mjs';

const REJECTED = /nonce too low|already known|replacement transaction underpriced|insufficient funds|intrinsic gas|exceeds block gas limit|invalid sender/i;

export class TxSender {
  constructor({ provider, wallet = null, journal, logger, chainId, execute = false, gasMultiplierBps = 13_000n, confirmTimeoutMs = 120_000, giveUpMs = 15 * 60_000, maxFeePerGasCap = null, now = () => Date.now() }) {
    Object.assign(this, { provider, wallet, journal, logger, chainId, execute, gasMultiplierBps, confirmTimeoutMs, giveUpMs, maxFeePerGasCap, now });
    this.from = wallet?.address ?? null;
    if (execute && !wallet) throw new Error('--execute needs a signer');
  }

  async reconcile(task) {
    const receipt = await this.provider.getTransactionReceipt(task.hash);
    if (receipt) {
      if (receipt.status === 1) {
        this.journal.markConfirmed(task.key, { hash: task.hash, blockNumber: receipt.blockNumber });
        this.logger.info(`reconciled ${task.key}: confirmed ${task.hash}`);
        return { state: TaskState.Confirmed, receipt };
      }
      this.journal.markFailure(task.key, `reverted on chain ${task.hash}`);
      return { state: TaskState.Retryable, receipt };
    }
    const latest = await this.provider.getTransactionCount(task.from, 'latest');
    if (latest > task.nonce) {
      // Our nonce was used by some other tx: ours can never land. Caller re-reads chain state.
      this.journal.markFailure(task.key, `nonce ${task.nonce} consumed without our receipt (${task.hash})`);
      return { state: TaskState.Retryable };
    }
    if (this.now() - (task.sentAt ?? 0) > this.giveUpMs) {
      this.journal.markFailure(task.key, `not mined after ${this.giveUpMs / 60_000} min (${task.hash})`);
      return { state: TaskState.Retryable };
    }
    if (task.raw) {
      try { await this.provider.broadcastTransaction(task.raw); } catch (error) {
        if (!/already known|nonce too low/i.test(String(error?.message))) this.logger.warn(`rebroadcast ${task.key}: ${String(error?.message).slice(0, 120)}`);
      }
    }
    return { state: TaskState.Sent };
  }

  async reconcileAll() {
    const out = [];
    for (const task of this.journal.inflight()) out.push({ key: task.key, ...(await this.reconcile(task)) });
    return out;
  }

  // request: { key, to, data, value?, gasLimit?, label }
  async send(request) {
    const { key, to, data, value = 0n, gasLimit = null, label = key } = request;
    let task = this.journal.task(key);
    let gate = taskGate(task, this.now());
    if (gate.reconcile) {
      const result = await this.reconcile(task);
      if (result.state === TaskState.Confirmed) return { status: 'confirmed', receipt: result.receipt, reconciled: true };
      if (result.state === TaskState.Sent) return { status: 'inflight' };
      return { status: 'retry-later', reason: 'previous tx failed; chain state must be re-read' };
    }
    if (gate.reason === 'confirmed') {
      // Confirmed earlier (often by reconcileAll at tick start after a wait timeout): callers resuming the step read
      // receipt.hash / logs, so hand the receipt back; if the node cannot serve it yet, the caller retries next tick.
      const receipt = await this.provider.getTransactionReceipt(task.hash);
      if (receipt?.status === 1) return { status: 'confirmed', receipt, reconciled: true };
      this.logger.warn(`receipt of confirmed ${key} (${task.hash}) not available; retry next tick`);
      return { status: 'inflight', hash: task.hash };
    }
    if (!gate.go) return { status: gate.reason };

    const from = this.from ?? request.from ?? undefined;
    try {
      await this.provider.call({ to, data, value, from });
    } catch (error) {
      // Dry-run never writes the journal; only a live keeper counts failed attempts.
      if (this.execute) this.journal.markFailure(key, `simulation: ${error?.shortMessage ?? error?.message ?? error}`);
      this.logger.warn(`simulation failed ${label}: ${String(error?.shortMessage ?? error?.message).slice(0, 160)}`);
      return { status: 'simulation-failed', error };
    }
    if (!this.execute) {
      this.logger.info(`DRY-RUN would send ${label}`, { to, value, key });
      return { status: 'dry-run' };
    }

    const fee = await this.provider.getFeeData();
    if (this.maxFeePerGasCap && (fee.maxFeePerGas ?? fee.gasPrice) > this.maxFeePerGasCap) {
      this.logger.warn(`gas price above cap, deferring ${label}`);
      return { status: 'gas-cap' };
    }
    let limit = gasLimit;
    if (!limit) limit = ((await this.provider.estimateGas({ to, data, value, from })) * this.gasMultiplierBps) / 10_000n;
    const nonce = await this.provider.getTransactionCount(from, 'pending');
    const tx = { to, data, value, nonce, chainId: this.chainId, gasLimit: limit };
    if (fee.maxFeePerGas != null) Object.assign(tx, { type: 2, maxFeePerGas: fee.maxFeePerGas, maxPriorityFeePerGas: fee.maxPriorityFeePerGas ?? 0n });
    else Object.assign(tx, { type: 0, gasPrice: fee.gasPrice });
    const raw = await this.wallet.signTransaction(tx);
    const hash = keccak256(raw);
    this.journal.markSent(key, { hash, nonce, raw, from, meta: { label, to } });
    this.logger.info(`sent ${label} nonce=${nonce} ${hash}`);
    try {
      await this.provider.broadcastTransaction(raw);
    } catch (error) {
      if (REJECTED.test(String(error?.message))) {
        this.journal.markFailure(key, `broadcast rejected: ${error?.message}`);
        return { status: 'rejected', error };
      }
      this.logger.warn(`broadcast ambiguous for ${label}; leaving Sent for reconciliation`);
      return { status: 'inflight' };
    }
    let receipt = null;
    try {
      receipt = await this.provider.waitForTransaction(hash, 1, this.confirmTimeoutMs);
    } catch (error) {
      // ethers v6 rejects with TIMEOUT instead of resolving null, and can miss a tx mined before its block subscription
      // when no later block arrives: read the receipt once more, else leave the task Sent for reconciliation.
      if (error?.code !== 'TIMEOUT' && !/timeout/i.test(String(error?.message))) throw error;
      receipt = await this.provider.getTransactionReceipt(hash);
    }
    if (!receipt) return { status: 'inflight', hash };
    if (receipt.status !== 1) {
      this.journal.markFailure(key, `reverted ${hash}`);
      return { status: 'reverted', receipt };
    }
    this.journal.markConfirmed(key, { hash, blockNumber: receipt.blockNumber });
    return { status: 'confirmed', receipt };
  }

  // Convenience for ethers Contract calls.
  async call(key, contract, method, args = [], { value = 0n, gasLimit = null, label } = {}) {
    const data = contract.interface.encodeFunctionData(method, args);
    return this.send({ key, to: contract.target, data, value, gasLimit, label: label ?? `${method}` });
  }
}

export const ok = result => result.status === 'confirmed';
export const progressed = result => result.status === 'confirmed' || result.status === 'dry-run';

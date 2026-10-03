// Local-anvil integration: real phase 1-4 contracts (RewardRoundManager, RewardBatcher, RewardVault,
// RewardPayoutVault, RewardDistributor, StockAdapterRegistry, SolonStockAdapter, V3FeeLedger,
// V3RewardToken, EligibilityController) + fixture stand-ins for the phase-5 hub/capacity/oracle.
// Runs one full round through the keepers: fee credit -> seal -> enqueue -> fee plan + signed quote
// -> executeAndStart -> mocked Relay arrival -> poke -> submit -> mocked RH fill -> finalize ->
// participant index -> openQueue -> batchDistribute -> holder receives stock. Then restarts both
// keepers from their journals and checks that nothing is re-sent.
//
// Prereq (one-off, ~3 min via-IR):  see docs/KEEPERS-v3.md "Tests" for the forge build line.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { readFileSync, existsSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { JsonRpcProvider, HDNodeWallet, Wallet, ContractFactory, Contract, encodeBytes32String, parseEther } from 'ethers';
import { Journal } from '../../lib/journal.mjs';
import { TxSender } from '../../lib/tx.mjs';
import { digestSigner } from '../../lib/signer.mjs';
import { RoundKeeper } from '../../round/keeper.mjs';
import { MockFundingLane } from '../../round/funding.mjs';
import { PushKeeper } from '../../push/keeper.mjs';
import { Status } from '../../round/decide.mjs';

const OUT = new URL('../../.anvil-out/', import.meta.url).pathname;
const ANVIL = `${process.env.HOME}/.foundry/bin/anvil`;
const DAY = 86_400;
const E = 20_000; // reward epoch (UTC day) used by the fixture
const PORT = 18_500 + Math.floor(Math.random() * 400);
const RPC = `http://127.0.0.1:${PORT}`;
const MNEMONIC = 'test test test test test test test test test test test junk';
const log = { info() {}, warn(m) { if (process.env.KEEPER_TEST_VERBOSE) console.log(m); }, error(m) { console.error(m); } };

const artifact = (file, name) => {
  const j = JSON.parse(readFileSync(join(OUT, file, `${name}.json`), 'utf8'));
  return { abi: j.abi, bytecode: j.bytecode.object };
};

const haveArtifacts = existsSync(join(OUT, 'V3RewardToken.sol/V3RewardToken.json')) && existsSync(join(OUT, 'KeeperMocks.sol/KeeperMockFundingHub.json'));

test('anvil: one full reward round through round-keeper and push-keeper', { skip: !haveArtifacts && 'forge artifacts missing (.anvil-out)', timeout: 240_000 }, async () => {
  const anvil = spawn('nohup', [ANVIL, '--port', String(PORT), '--timestamp', String(E * DAY + 3600), '--disable-code-size-limit', '--silent'], { stdio: 'ignore', detached: true });
  const killer = setTimeout(() => { try { process.kill(anvil.pid, 'SIGKILL'); } catch {} }, 230_000);
  killer.unref();
  try {
    const provider = new JsonRpcProvider(RPC, 31337, { staticNetwork: true, cacheTimeout: -1, pollingInterval: 50 });
    for (let i = 0; ; i++) {
      try { await provider.getBlockNumber(); break; } catch { if (i > 100) throw new Error('anvil did not start'); await new Promise(r => setTimeout(r, 100)); }
    }
    const acct = i => HDNodeWallet.fromPhrase(MNEMONIC, undefined, `m/44'/60'/0'/0/${i}`).connect(provider);
    const [deployer, alice, quoteKey, keeperKey, bridge, treasury, ops] = [0, 1, 2, 3, 4, 5, 6].map(acct);
    const send = async p => (await p).wait();
    const deploy = async (file, name, ...args) => {
      const { abi, bytecode } = artifact(file, name);
      const c = await new ContractFactory(abi, bytecode, deployer).deploy(...args);
      await c.waitForDeployment();
      return c;
    };
    const setTime = async ts => { await provider.send('evm_setNextBlockTimestamp', [ts]); await provider.send('evm_mine', []); };

    // ---------------- deploy phase 1-4 contracts + phase-5 fixtures
    const stock = await deploy('KeeperMocks.sol', 'KeeperMockStock');
    const controller = await deploy('EligibilityController.sol', 'EligibilityController', deployer.address);
    const payout = await deploy('RewardPayoutVault.sol', 'RewardPayoutVault', [], controller.target);
    const factory = await deploy('KeeperMocks.sol', 'KeeperMockFactory');
    await send(payout.configureFactory(factory.target));
    const registry = await deploy('StockAdapterRegistry.sol', 'StockAdapterRegistry', deployer.address);
    const manager = await deploy('RewardRoundManager.sol', 'RewardRoundManager', deployer.address, registry.target, payout.target, treasury.address);
    const vaultAddr = await manager.vault();
    await send(factory.registerPayoutSource(payout.target, vaultAddr));
    const capacity = await deploy('KeeperMocks.sol', 'KeeperMockCapacity');
    const batcher = await deploy('RewardBatcher.sol', 'RewardBatcher', manager.target);
    await send(manager.configureExecution(batcher.target, capacity.target));
    const hub = await deploy('KeeperMocks.sol', 'KeeperMockFundingHub', stock.target, bridge.address);
    const path = encodeBytes32String('Relay');
    const oracle = await deploy('KeeperMocks.sol', 'KeeperMockOracle');
    await send(oracle.setPrice(stock.target, parseEther('180')));
    const adapter = await deploy('SolonStockAdapter.sol', 'SolonStockAdapter', [manager.target, vaultAddr, stock.target, stock.target, hub.target, quoteKey.address, path, 4663, ops.address, oracle.target]);
    const assetId = encodeBytes32String('NVDA');
    await send(registry.register(assetId, 1, [stock.target, stock.target, hub.target, adapter.target, path, 4663, true, 0]));
    const ledger = await deploy('V3FeeLedger.sol', 'V3FeeLedger', deployer.address, '0x0000000000000000000000000000000000000000');
    const token = await deploy('V3RewardToken.sol', 'V3RewardToken', 'Reward', 'RWD', deployer.address, ledger.target, []);
    const pool = encodeBytes32String('pool');
    await send(token.setDefaultRewardAsset(stock.target));
    await send(token.configurePool(pool, '0x0000000000000000000000000000000000000000', 0));
    await send(token.configureRounds(manager.target, assetId, 1, encodeBytes32String('price')));
    await send(manager.registerSource(token.target, pool));
    const buckets = [];
    for (let i = 0; i < 5; i++) buckets.push((await deploy('KeeperMocks.sol', 'KeeperMockBucket')).target);
    await send(ledger.registerPool(pool, '0x0000000000000000000000000000000000000000', 0, deployer.address, [token.target, ...buckets]));
    const distributor = await deploy('RewardDistributor.sol', 'RewardDistributor', payout.target, oracle.target);
    await send(payout.configureDistributor(distributor.target));

    // ---------------- epoch E: alice holds (earns on receipt, no activation), $400 fee credited (holder bucket 57.5% = $230)
    await send(token.transfer(alice.address, parseEther('100')));
    assert.equal(await token.eligible(alice.address), parseEther('100'));
    await setTime(E * DAY + 4 * 3600);
    await send(ledger.creditNative(pool, { value: parseEther('400') }));
    assert.equal(await token.epochBudget(E), parseEther('230'));

    // ---------------- day E+1, 00:15 UTC: keepers run
    await setTime((E + 1) * DAY + 15 * 60);
    const dir = mkdtempSync(join(tmpdir(), 'keeper-anvil-'));
    const cfg = {
      contracts: { roundManager: manager.target, batcher: batcher.target, stockRegistry: registry.target, rewardPriceOracle: oracle.target, payoutVault: payout.target, distributor: distributor.target },
      // market: false — the fixture clock is epoch 20000 (2024), outside the built-in NYSE calendar (M1 gate).
      round: { sources: [{ address: token.target, kind: 'token', firstEpoch: E - 2 }], params: { market: false } },
      push: {},
    };
    const chainNow = async () => (await provider.getBlock('latest')).timestamp;
    let nowSec = await chainNow();
    const now = () => nowSec;
    const lane = new MockFundingLane({ feeBps: 10n, arrive: async ({ orderId, amount18 }) => (await hub.connect(bridge).mockArrive(orderId, amount18)).wait() });
    const makeRound = () => {
      const journal = new Journal(join(dir, 'round-keeper.json'));
      const tx = new TxSender({ provider, wallet: keeperKey, journal, logger: log, chainId: 31337, execute: true });
      return new RoundKeeper({ cfg, provider, tx, journal, logger: log, alert: async () => {}, lane, quoteSigner: digestSigner(new Wallet(quoteKey.privateKey)), chainId: 31337, now });
    };

    // CLI smoke first: dry-run through bin/round-keeper.mjs must simulate and send nothing.
    const cfgPath = join(dir, 'cfg.json');
    // r13: bin/round-keeper.mjs funds through the launcher's scheduler lane, which needs the stock-layer addresses
    // (never called in this dry-run seal tick; the mock hub stands in for all three).
    const cliCfg = { ...cfg, contracts: { ...cfg.contracts, stockHub: hub.target, scheduler: hub.target, reserveVault: hub.target } };
    writeFileSync(cfgPath, JSON.stringify({ chains: { arc: { chainId: 31337, rpcUrl: RPC } }, statusDir: join(dir, 'cli'), relay: {}, ...cliCfg }));
    const nonceBefore = await provider.getTransactionCount(keeperKey.address);
    const cliOut = execFileSync('node', [new URL('../../bin/round-keeper.mjs', import.meta.url).pathname, `--config=${cfgPath}`], { encoding: 'utf8', timeout: 60_000, env: { ...process.env, KEEPER_KEY_PATH: '' } });
    assert.match(cliOut, /"kind": "seal"[\s\S]*"status": "dry-run"/);
    assert.equal(await provider.getTransactionCount(keeperKey.address), nonceBefore);

    // Tick 1: seal + enqueue + fee deposit + signed-quote executeAndStart + mocked Relay dispatch.
    const rk = makeRound();
    let s = await rk.tick();
    const kinds = s.actions.map(a => `${a.kind}:${a.status}`);
    assert.ok(kinds.includes('seal:confirmed'), kinds.join());
    assert.ok(kinds.includes('enqueue:confirmed'));
    assert.ok(kinds.includes('depositFees:confirmed'));
    assert.ok(kinds.includes('executeAndStart:confirmed'), JSON.stringify(s, (_, v) => (typeof v === 'bigint' ? v.toString() : v)));
    assert.ok(kinds.includes('dispatchFunding:sent'));
    let r = await manager.round(1);
    assert.equal(Number(r.status), Status.Funding);
    assert.equal(r.budget18, parseEther('230'));
    assert.equal(await hub.fundingReceived(r.orderId), parseEther('230'));
    const hubOrder = await hub.orders(r.orderId);
    assert.ok(hubOrder.value > parseEther('230'), 'Ops fees ride on top of the principal');

    // Tick 2: funded -> poke -> submit.
    nowSec = await chainNow();
    s = await rk.tick();
    r = await manager.round(1);
    assert.equal(Number(r.status), Status.Submitted, JSON.stringify(s.actions));
    // No verified result yet: even past the quarantine window the keeper only alerts (finalize with an
    // empty proof is a no-op since 03d87c2), so no tx is sent and the round stays Submitted.
    const nq = await provider.getTransactionCount(keeperKey.address);
    nowSec = Number(r.submittedAt) + 7 * 3600;
    s = await rk.tick();
    assert.equal(await provider.getTransactionCount(keeperKey.address), nq, JSON.stringify(s.actions));
    assert.ok(s.actions.some(a => a.kind === 'alert' && a.reason === 'result unknown'), JSON.stringify(s.actions));
    assert.equal(Number((await manager.round(1)).status), Status.Submitted);

    // RH fill (fixture): 230 / 180 = 1.2777 shares, >= minRaw (1% slippage).
    const raw = parseEther('1.2777');
    assert.ok(raw >= r.minRawOut);
    await send(hub.connect(bridge).mockSettle(r.orderId, 1, raw));

    // Tick 3: result -> finalize -> Settled; delivery recorded on the allocation.
    nowSec = await chainNow();
    s = await rk.tick();
    r = await manager.round(1);
    assert.equal(Number(r.status), Status.Settled, JSON.stringify(s.actions));
    assert.equal(r.delivered, raw);
    assert.equal(await stock.balanceOf(vaultAddr), raw);
    assert.equal(await capacity.finalized(r.orderId), true, 'capacity released on Settled (03d87c2)');
    assert.equal(await capacity.reserved(r.orderId), 0n);

    // Restart: a fresh keeper from the same journal sends nothing.
    const n1 = await provider.getTransactionCount(keeperKey.address);
    nowSec = await chainNow();
    const again = await makeRound().tick();
    assert.equal(await provider.getTransactionCount(keeperKey.address), n1, JSON.stringify(again.actions));

    // ---------------- push keeper: participant index -> openQueue -> batchDistribute
    const makePush = () => {
      const journal = new Journal(join(dir, 'push-keeper.json'));
      const tx = new TxSender({ provider, wallet: keeperKey, journal, logger: log, chainId: 31337, execute: true });
      return new PushKeeper({ cfg, provider, tx, journal, logger: log, alert: async () => {}, chainId: 31337, now });
    };
    nowSec = await chainNow();
    const p = await makePush().tick();
    const pk = p.actions.map(a => `${a.kind}:${a.status}`);
    assert.ok(pk.includes('registerParticipants:confirmed'), pk.join());
    assert.ok(pk.includes('sealIndex:confirmed'));
    assert.ok(pk.includes('openQueue:confirmed'));
    const paidAlice = await stock.balanceOf(alice.address);
    assert.ok(paidAlice > 0n && paidAlice <= raw && raw - paidAlice <= 1n, `alice got ${paidAlice} of ${raw}`);
    assert.equal(await payout.paidTotal(alice.address, stock.target), paidAlice);
    const batch = p.actions.find(a => a.kind === 'batchDistribute');
    assert.equal(batch.complete, true);

    // Same day again: cycle complete -> no tx; restart-safe.
    const n2 = await provider.getTransactionCount(keeperKey.address);
    nowSec = await chainNow();
    const p2 = await makePush().tick();
    assert.equal(await provider.getTransactionCount(keeperKey.address), n2, JSON.stringify(p2));
    assert.ok(p2.skipped.some(x => /cycle complete today|empty/.test(x.reason)));
    console.log(`anvil round: budget $230, fees ${hubOrder.value - parseEther('230')} wei, delivered ${raw}, alice paid ${paidAlice}; keeper txs ${n2 - nonceBefore}`);
  } finally {
    clearTimeout(killer);
    try { process.kill(anvil.pid, 'SIGKILL'); } catch {}
  }
});

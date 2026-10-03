// Shared process harness for all v3 keepers: config, provider, signer(s), journal, lock,
// alerts, dry-run/--execute, one-shot (launchd) or --loop mode.
import { JsonRpcProvider } from 'ethers';
import { parseArgs } from './cli.mjs';
import { loadConfig } from './config.mjs';
import { loadSigner, digestSigner } from './signer.mjs';
import { Journal } from './journal.mjs';
import { makeLogger } from './log.mjs';
import { makeAlerter } from './alert.mjs';
import { TxSender } from './tx.mjs';
import { withLock, lockPathFor } from './lock.mjs';
import { writeHeartbeat } from './heartbeat.mjs';

const replacer = (_, v) => (typeof v === 'bigint' ? v.toString() : v);

// r13: `chain` picks the signing chain (arc | rh | eth); `withRh` / `withEth` / `withArc` add a read/sign context for
// Robinhood Chain / Ethereum / Arc (same key, own journal file: <name>-<chain>.json).
export async function buildContext(name, argv = process.argv.slice(2), { chain: chainName = 'arc', withRh = false, withEth = false, withArc = false, keyless = false } = {}) {
  const args = parseArgs(argv);
  const cfg = loadConfig(args.config);
  const chain = cfg.chains?.[chainName];
  if (!chain?.rpcUrl) throw new Error(`config chains.${chainName}.rpcUrl (or its rpcEnv) is required`);
  const provider = new JsonRpcProvider(chain.rpcUrl, chain.chainId, { staticNetwork: true, cacheTimeout: -1 });
  const logger = makeLogger({ file: `${cfg.statusDir}/${name}.log`, name });
  const keyEnv = cfg.keys?.[name] ?? 'KEEPER_KEY_PATH';
  // keyless (r13 float watch): read-only process; --execute only enables alerts.
  const wallet = !keyless && (args.execute || process.env[keyEnv]) ? loadSigner(keyEnv, provider, { allowSolonConfigDir: cfg.keys?.allowSolonConfigDir === true }) : null;
  const quoteSigner = process.env.QUOTE_SIGNER_KEY_PATH ? digestSigner(loadSigner('QUOTE_SIGNER_KEY_PATH', null, { allowSolonConfigDir: cfg.keys?.allowSolonConfigDir === true })) : null;
  const journal = new Journal(`${cfg.statusDir}/${name}${args.execute ? '' : '.dry'}.json`);
  const alert = makeAlerter({ logger, name, enabled: args.execute });
  const tx = new TxSender({ provider, wallet, journal, logger, chainId: chain.chainId, execute: args.execute && !keyless, maxFeePerGasCap: chain.maxFeePerGasCap ? BigInt(chain.maxFeePerGasCap) : null });
  logger.info(`start ${args.execute ? 'EXECUTE' : 'dry-run'} chain ${chain.chainId}${wallet ? ` signer ${wallet.address}` : ''}${quoteSigner ? ` quoteSigner ${quoteSigner.address}` : ''}`);
  const ctx = { args, cfg, provider, logger, wallet, quoteSigner, journal, alert, tx, chainId: chain.chainId };
  const side = key => {
    const c = cfg.chains?.[key];
    if (!c?.rpcUrl) throw new Error(`config chains.${key}.rpcUrl (or its rpcEnv) is required`);
    const p = new JsonRpcProvider(c.rpcUrl, c.chainId, { staticNetwork: true, cacheTimeout: -1 });
    const w = wallet ? wallet.connect(p) : null;
    const j = new Journal(`${cfg.statusDir}/${name}-${key}${args.execute ? '' : '.dry'}.json`);
    return { provider: p, wallet: w, journal: j, chainId: c.chainId,
      tx: new TxSender({ provider: p, wallet: w, journal: j, logger, chainId: c.chainId, execute: args.execute && !keyless, maxFeePerGasCap: c.maxFeePerGasCap ? BigInt(c.maxFeePerGasCap) : null }) };
  };
  if (withRh) ctx.rh = side('rh');
  if (withEth) ctx.eth = side('eth');
  if (withArc) ctx.arc = side('arc');
  return ctx;
}

export async function runLoop(ctx, keeper, { name, lockPath = null } = {}) {
  const { args, logger, alert, wallet, cfg } = ctx;
  const path = lockPath ?? (wallet ? lockPathFor(wallet.address) : null);
  let failures = 0;
  for (;;) {
    try {
      const run = async () => keeper.tick();
      const out = args.execute && path ? await withLock(path, name, run) : { skipped: false, value: await run() };
      if (out.skipped) logger.warn(`signer lock held by ${out.holder}; skipping this tick`);
      else console.log(JSON.stringify(out.value, replacer, 2));
      failures = 0;
      writeHeartbeat(cfg?.statusDir, name, { ok: true, execute: args.execute, note: out.skipped ? `lock held by ${out.holder}` : null });
    } catch (error) {
      failures++;
      writeHeartbeat(cfg?.statusDir, name, { ok: false, execute: args.execute, failures, note: error?.shortMessage ?? error?.message });
      logger.error(`tick failed (${failures} in a row): ${String(error?.shortMessage ?? error?.message ?? error).slice(0, 300)}`);
      if (failures >= 5) await alert(`${name}-tick`, `${failures} consecutive tick failures: ${String(error?.message).slice(0, 200)}`);
      if (!args.loop) process.exitCode = 1;
    }
    if (!args.loop) return;
    await new Promise(resolve => setTimeout(resolve, args.interval * 1000));
  }
}

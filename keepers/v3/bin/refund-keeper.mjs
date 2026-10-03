#!/usr/bin/env node
// Refund keeper (r13, path 2a): credits failed buys (Returning) and unpaid sells (Proceeds) from the hub float via the
// Relay router (withdrawFloat to HUB_FLOAT_B, then router.multicall -> route.receiveReturnFor).
//   KEEPER_CONFIG=... KEEPER_KEY_PATH=<hub keeper> [REFUND_KEY_PATH=<refund wallet = HUB_FLOAT_B>] \
//     node bin/refund-keeper.mjs [--execute] [--loop=30]
// With REFUND_KEY_PATH (mainnet): the hub keeper only signs withdrawFloat(refund wallet); the refund wallet signs the
// credit-back from its own journal. Without it, KEEPER_KEY_PATH must itself be HUB_FLOAT_B (fork / testnet).
import { buildContext, runLoop } from '../lib/runner.mjs';
import { loadSigner } from '../lib/signer.mjs';
import { Journal } from '../lib/journal.mjs';
import { TxSender } from '../lib/tx.mjs';
import { RefundKeeper } from '../refund/keeper.mjs';

const ctx = await buildContext('refund-keeper', process.argv.slice(2), { withRh: true });
let payer = null;
if (process.env.REFUND_KEY_PATH) {
  const { cfg, args, provider, logger, chainId } = ctx;
  const wallet = loadSigner('REFUND_KEY_PATH', provider, { allowSolonConfigDir: cfg.keys?.allowSolonConfigDir === true });
  const journal = new Journal(`${cfg.statusDir}/refund-keeper-payer${args.execute ? '' : '.dry'}.json`);
  const chain = cfg.chains.arc;
  payer = { wallet, tx: new TxSender({ provider, wallet, journal, logger, chainId, execute: args.execute, maxFeePerGasCap: chain?.maxFeePerGasCap ? BigInt(chain.maxFeePerGasCap) : null }) };
  logger.info(`refund wallet ${wallet.address} (credit-back signer)`);
}
const keeper = new RefundKeeper({ ...ctx, payer, rhProvider: ctx.rh.provider });
await runLoop(ctx, keeper, { name: 'refund-keeper' });

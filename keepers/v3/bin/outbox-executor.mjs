#!/usr/bin/env node
// Outbox executor (canonical lane RH -> Ethereum): executes every confirmed ReserveVault checkpoint L2->L1 message on the
// RH rollup Outbox (Arbitrum SDK method: confirmed send root -> NodeInterface.constructOutboxProof -> executeTransaction),
// then forwards any accepted-but-unforwarded checkpoint on the EthereumBridger. Signs on Ethereum; reads RH.
//   KEEPER_CONFIG=... KEEPER_KEY_PATH=... node bin/outbox-executor.mjs [--execute] [--loop=300]
import { buildContext, runLoop } from '../lib/runner.mjs';
import { OutboxExecutor } from '../canonical/outbox-executor.mjs';

const ctx = await buildContext('outbox-executor', process.argv.slice(2), { chain: 'eth', withRh: true });
const keeper = new OutboxExecutor({ ...ctx, eth: { provider: ctx.provider, tx: ctx.tx, chainId: ctx.chainId, wallet: ctx.wallet, journal: ctx.journal }, rh: ctx.rh });
await runLoop(ctx, keeper, { name: 'outbox-executor' });

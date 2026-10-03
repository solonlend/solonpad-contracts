#!/usr/bin/env node
// Launcher (r13, path 2a): funds the OrderScheduler heads (public buys, reward rounds, pool-A restock) through Relay.
//   KEEPER_CONFIG=config/arc.json KEEPER_KEY_PATH=... QUOTE_SIGNER_KEY_PATH=... node bin/launcher.mjs [--execute] [--loop=15]
import { buildContext, runLoop } from '../lib/runner.mjs';
import { Launcher } from '../launcher/keeper.mjs';
import { relayClientFor } from '../lib/relay-mock.mjs';

const ctx = await buildContext('launcher');
const keeper = new Launcher({ ...ctx, relayClient: await relayClientFor(ctx.cfg, ctx.chainId, ctx.cfg.launcher?.rhChainId ?? 4663) });
await runLoop(ctx, keeper, { name: 'launcher' });

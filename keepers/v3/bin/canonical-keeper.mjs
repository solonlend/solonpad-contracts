#!/usr/bin/env node
// Canonical keeper (r13, N6): RH checkpoint() hourly, Arc hub.reconcile for every gate checkpoint, and the 8-day
// RECONCILE_WINDOW watch (warn 5 d / critical 7 d / halted). Signs on both chains with the same keeper key.
//   KEEPER_CONFIG=... KEEPER_KEY_PATH=... node bin/canonical-keeper.mjs [--execute] [--loop=300]
import { buildContext, runLoop } from '../lib/runner.mjs';
import { CanonicalKeeper } from '../canonical/keeper.mjs';

const ctx = await buildContext('canonical-keeper', process.argv.slice(2), { withRh: true });
const keeper = new CanonicalKeeper({ ...ctx, arc: { provider: ctx.provider, tx: ctx.tx, chainId: ctx.chainId }, rh: ctx.rh });
await runLoop(ctx, keeper, { name: 'canonical-keeper' });

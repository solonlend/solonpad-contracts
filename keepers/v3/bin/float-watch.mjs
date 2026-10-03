#!/usr/bin/env node
// Float watch (r13, path 2a): RH USDG + Arc USDC float balances, two-chain drift, stuck orders, daily rebalance hint.
// Read-only (no key needed); alerts through ~/.config/solon/v3_alert.env.
//   KEEPER_CONFIG=... node bin/float-watch.mjs [--execute (= send alerts)] [--loop=300]
import { buildContext, runLoop } from '../lib/runner.mjs';
import { FloatWatch } from '../float/watch.mjs';

const ctx = await buildContext('float-watch', process.argv.slice(2), { withRh: true, keyless: true });
const keeper = new FloatWatch({ ...ctx, rhProvider: ctx.rh.provider });
await runLoop(ctx, keeper, { name: 'float-watch' });

#!/usr/bin/env node
// Round keeper. Dry-run by default; --execute to act; --loop[=15] for a resident process.
//   KEEPER_CONFIG=config/arc.json KEEPER_KEY_PATH=... QUOTE_SIGNER_KEY_PATH=... node bin/round-keeper.mjs [--execute] [--loop=15]
// r13 (path 2a): the funding lane is the launcher's scheduler lane (no phase-5 seam): the reward buy waits in
// OrderScheduler and is funded through Relay by the same code as public buys (bin/launcher.mjs runs it too).
import { Contract } from 'ethers';
import { buildContext, runLoop } from '../lib/runner.mjs';
import { RoundKeeper } from '../round/keeper.mjs';
import { Launcher, SchedulerFundingLane } from '../launcher/keeper.mjs';
import { relayClientFor } from '../lib/relay-mock.mjs';
import { StockHubAbi } from '../lib/abis.mjs';

const ctx = await buildContext('round-keeper');
const launcher = new Launcher({ ...ctx, relayClient: await relayClientFor(ctx.cfg, ctx.chainId, ctx.cfg.launcher?.rhChainId ?? 4663) });
const lane = new SchedulerFundingLane({ launcher, hub: new Contract(ctx.cfg.contracts.stockHub, StockHubAbi, ctx.provider) });
const keeper = new RoundKeeper({ ...ctx, lane });
await runLoop(ctx, keeper, { name: 'round-keeper' });

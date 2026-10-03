#!/usr/bin/env node
// v2 fee-ingress keeper (buyback_daemon.mjs replacement; see docs/KEEPERS-v3.md "Cutover").
// Signs with the platform recipient (0xdD43 after cutover) => takes the shared DD43 lock.
import { buildContext, runLoop } from '../lib/runner.mjs';
import { IngressKeeper } from '../ingress/keeper.mjs';
import { DD43_LOCK } from '../lib/lock.mjs';

const ctx = await buildContext('v2-ingress-keeper');
const keeper = new IngressKeeper({ ...ctx, auditors: null /* ops seam: 2-of-3 auditor service */, priceSource: null /* seam */ });
await runLoop(ctx, keeper, { name: 'v2-ingress-keeper', lockPath: ctx.cfg.ingress?.sharedDd43Lock === false ? null : DD43_LOCK });

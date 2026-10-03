#!/usr/bin/env node
// Daily push keeper (00:10 UTC cycle, 15-minute continuations). launchd: StartInterval 900 + --execute.
import { buildContext, runLoop } from '../lib/runner.mjs';
import { PushKeeper } from '../push/keeper.mjs';

const ctx = await buildContext('push-keeper');
await runLoop(ctx, new PushKeeper(ctx), { name: 'push-keeper' });

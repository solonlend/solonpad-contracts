#!/usr/bin/env node
// Desk 10% payout keeper (DeskRewards / DeskNFT chain, not RewardDistributor). Dry-run by default; --execute to act.
//   KEEPER_CONFIG=config/mainnet-stock.json KEEPER_KEY_PATH=... node bin/desk-keeper.mjs [--execute] [--loop=300]
// USDC-quoted streams are sealed into RewardRoundManager here; the round keeper + launcher buy the stock (same lane and
// on-demand oracle push as holder rounds). launchd: xyz.solonlend.v3-desk, --loop=300 --execute.
import { buildContext, runLoop } from '../lib/runner.mjs';
import { DeskKeeper } from '../desk/keeper.mjs';

const ctx = await buildContext('desk-keeper');
await runLoop(ctx, new DeskKeeper(ctx), { name: 'desk-keeper' });

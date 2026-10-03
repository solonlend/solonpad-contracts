#!/usr/bin/env node
// RH vault worker (r13, path 2a): executeFunded for buys that waited for the float; returnFunds of settled
// liabilities (sell proceeds) to the hub through Relay. Signs on Robinhood Chain.
//   KEEPER_CONFIG=... KEEPER_KEY_PATH=... QUOTE_SIGNER_KEY_PATH=... node bin/vault-worker.mjs [--execute] [--loop=15]
import { buildContext, runLoop } from '../lib/runner.mjs';
import { VaultWorker } from '../vault/keeper.mjs';
import { relayClientFor } from '../lib/relay-mock.mjs';

const ctx = await buildContext('vault-worker', process.argv.slice(2), { chain: 'rh' });
const keeper = new VaultWorker({ ...ctx, relayClient: await relayClientFor(ctx.cfg, ctx.chainId, ctx.cfg.vault?.arcChainId ?? 5042) });
await runLoop(ctx, keeper, { name: 'vault-worker' });

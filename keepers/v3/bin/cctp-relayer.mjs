#!/usr/bin/env node
// CCTP v2 relayer (canonical lane): Iris v2 attestations -> Arc CanonicalGate.relay (checkpoints from the Ethereum
// bridger) and Ethereum EthereumBridger.relay (deliveries from the Arc gate, pays the RH retryable ticket).
// Signs on Arc and Ethereum with the same key; reads RH gas price for the ticket.
//   KEEPER_CONFIG=... KEEPER_KEY_PATH=... node bin/cctp-relayer.mjs [--execute] [--loop=60]
import { buildContext, runLoop } from '../lib/runner.mjs';
import { CctpRelayer } from '../canonical/cctp-relayer.mjs';

const ctx = await buildContext('cctp-relayer', process.argv.slice(2), { chain: 'arc', withEth: true, withRh: true });
const keeper = new CctpRelayer({ ...ctx, arc: { provider: ctx.provider, tx: ctx.tx, chainId: ctx.chainId, wallet: ctx.wallet, journal: ctx.journal }, eth: ctx.eth, rh: ctx.rh });
await runLoop(ctx, keeper, { name: 'cctp-relayer' });

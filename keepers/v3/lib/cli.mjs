// Shared CLI: dry-run by default; --execute to broadcast; --loop[=seconds] for a
// long-running process, otherwise one tick (launchd StartInterval friendly).
export function parseArgs(argv = process.argv.slice(2)) {
  const args = { execute: false, loop: false, interval: 60, config: process.env.KEEPER_CONFIG ?? null, extra: {} };
  for (const a of argv) {
    if (a === '--execute') args.execute = true;
    else if (a === '--dry-run') args.execute = false;
    else if (a === '--once') args.loop = false;
    else if (a === '--loop') args.loop = true;
    else if (a.startsWith('--loop=')) { args.loop = true; args.interval = Number(a.slice(7)); }
    else if (a.startsWith('--interval=')) args.interval = Number(a.slice(11));
    else if (a.startsWith('--config=')) args.config = a.slice(9);
    else if (a.startsWith('--')) { const [k, v = 'true'] = a.slice(2).split('='); args.extra[k] = v; }
    else throw new Error(`unknown argument ${a}`);
  }
  if (!Number.isFinite(args.interval) || args.interval < 5) throw new Error('--interval must be >= 5 seconds');
  return args;
}

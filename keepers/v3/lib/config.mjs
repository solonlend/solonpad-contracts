// Per-deployment config: one JSON file (path via --config or KEEPER_CONFIG) with a
// chains map and contract addresses. RPC URLs come from env vars named in the file so
// keyed endpoints never land in git. Unset phase-5 addresses stay null and the
// keepers treat the dependent step as an integration seam (skip + report).
import { readFileSync } from 'node:fs';
import { isAddress, getAddress } from 'ethers';

export const DEFAULTS = Object.freeze({
  arcChainId: 5042,
  rhChainId: 4663,
  relayApi: 'https://api.relay.link',
  arcNativeUsdc: '0x0000000000000000000000000000000000000000',
  rhUsdg: '0x5fc5360d0400a0fd4f2af552add042d716f1d168',
  relayRouter: '0xb92fe925dc43a0ecde6c8b1a2709c170ec4fff4f',
  relayDepository: '0x4cd00e387622c35bddb9b4c962c136462338bc31',
});

function normalizeAddresses(obj, path = '') {
  if (obj === null || typeof obj !== 'object') return obj;
  if (Array.isArray(obj)) return obj.map((v, i) => normalizeAddresses(v, `${path}[${i}]`));
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v === 'string' && /^0x[0-9a-fA-F]{40}$/.test(v)) {
      if (!isAddress(v)) throw new Error(`config ${path}${k}: bad address`);
      out[k] = getAddress(v.toLowerCase());
    } else out[k] = normalizeAddresses(v, `${path}${k}.`);
  }
  return out;
}

export function loadConfig(path = process.env.KEEPER_CONFIG) {
  if (!path) throw new Error('no config: pass --config=<file> or set KEEPER_CONFIG');
  const cfg = normalizeAddresses(JSON.parse(readFileSync(path, 'utf8')));
  for (const [name, chain] of Object.entries(cfg.chains ?? {})) {
    if (!Number.isInteger(chain.chainId)) throw new Error(`chain ${name}: chainId required`);
    chain.rpcUrl = (chain.rpcEnv && process.env[chain.rpcEnv]) || chain.rpcUrl || null;
  }
  cfg.relay = { ...DEFAULTS, ...(cfg.relay ?? {}) };
  cfg.statusDir ??= new URL('../state/', import.meta.url).pathname;
  return cfg;
}

export function requireAddress(cfg, dotted) {
  const value = dotted.split('.').reduce((o, k) => o?.[k], cfg);
  if (!value || !isAddress(value)) throw new Error(`config: ${dotted} is required`);
  return value;
}

export const optionalAddress = (cfg, dotted) => {
  const value = dotted.split('.').reduce((o, k) => o?.[k], cfg);
  return value && isAddress(value) ? value : null;
};

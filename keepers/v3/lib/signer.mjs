// Signer abstraction. The key is read from a file path given by an env var (never
// from argv, never from the config JSON), accepted as raw hex or {"private_key": ..}.
// Only the derived address is ever exposed/logged. Dry-run needs no key at all.
import { readFileSync, statSync } from 'node:fs';
import { Wallet, SigningKey, getBytes } from 'ethers';

function parseKeyFile(path) {
  const body = readFileSync(path, 'utf8').trim();
  let key = body;
  if (body.startsWith('{')) {
    const json = JSON.parse(body);
    key = json.private_key ?? json.privateKey ?? json.key;
  }
  if (typeof key !== 'string') throw new Error(`key file ${path}: no private_key field`);
  key = key.startsWith('0x') ? key : `0x${key}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error(`key file ${path}: not a 32-byte hex key`);
  return key;
}

// Refuse the live treasury/deployer wallets unless the operator explicitly opts in:
// the keepers must run from their own Ops-funded hot wallet.
const FORBIDDEN_DIRS = [`${process.env.HOME}/.config/solon/`];

export function loadSigner(envVar, provider, { allowSolonConfigDir = false } = {}) {
  const path = process.env[envVar];
  if (!path) throw new Error(`${envVar} is not set (path to the keeper key file)`);
  if (!allowSolonConfigDir && FORBIDDEN_DIRS.some(dir => path.startsWith(dir))) {
    throw new Error(`${envVar} points into ~/.config/solon; keepers use a dedicated hot wallet`);
  }
  const mode = statSync(path).mode & 0o077;
  if (mode !== 0) console.warn(`warning: key file ${envVar} is group/world readable`);
  const wallet = new Wallet(parseKeyFile(path), provider);
  // Do not let util.inspect / JSON.stringify print the key.
  Object.defineProperty(wallet, 'toJSON', { value: () => ({ address: wallet.address }) });
  Object.defineProperty(wallet, Symbol.for('nodejs.util.inspect.custom'), { value: () => `Wallet(${wallet.address})` });
  return wallet;
}

// Signs a raw 32-byte digest (ECDSA over the digest itself; matches OpenZeppelin
// SignatureChecker/ECDSA.recover on an EIP-712 or custom digest). Never eth_sign-prefixed.
export function digestSigner(wallet) {
  const key = new SigningKey(wallet.privateKey);
  return {
    address: wallet.address,
    signDigest: digest => key.sign(getBytes(digest)).serialized,
  };
}

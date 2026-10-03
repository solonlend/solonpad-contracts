// Quote digests for the three signed-quote contracts. Digests are rebuilt locally from
// on-chain immutable config and compared with the contract's own quoteDigest view before
// any signature is produced — a lying RPC or misconfigured address cannot get us to sign
// an unrelated digest. Signers sign the raw digest (OpenZeppelin SignatureChecker).
import { AbiCoder, TypedDataEncoder, keccak256, toUtf8Bytes, id as idHash, randomBytes, toBigInt } from 'ethers';

const coder = AbiCoder.defaultAbiCoder();
export const START_FUNDING_SELECTOR = idHash('startFunding(bytes32,uint256,uint256,uint256,address,bytes)').slice(0, 10);

export const newNonce = () => toBigInt(randomBytes(16));

export const STOCK_BUY_TYPES = {
  StockBuy: [
    { name: 'orderId', type: 'bytes32' }, { name: 'asset', type: 'address' }, { name: 'underlying', type: 'address' },
    { name: 'hub', type: 'address' }, { name: 'path', type: 'bytes32' }, { name: 'destinationChain', type: 'uint256' },
    { name: 'vault', type: 'address' }, { name: 'refundVault', type: 'address' }, { name: 'selector', type: 'bytes4' },
    { name: 'budget18', type: 'uint256' }, { name: 'minRawOut', type: 'uint256' }, { name: 'deadline', type: 'uint256' },
    { name: 'nonce', type: 'uint256' }, { name: 'fees18', type: 'uint256' }, { name: 'fixedCost18', type: 'uint256' },
    { name: 'opsVault', type: 'address' },
  ],
};

export function stockQuoteDigest({ chainId, adapter, config, q }) {
  const domain = { name: 'SolonStockAdapter', version: '3', chainId, verifyingContract: adapter };
  return TypedDataEncoder.hash(domain, STOCK_BUY_TYPES, {
    orderId: q.orderId, asset: config.asset, underlying: config.underlying, hub: config.hub, path: config.path,
    destinationChain: config.destinationChain, vault: config.vault, refundVault: config.vault, selector: START_FUNDING_SELECTOR,
    budget18: q.budget18, minRawOut: q.minRawOut, deadline: q.deadline, nonce: q.nonce, fees18: q.fees18,
    fixedCost18: q.fixedCost18, opsVault: config.opsVault,
  });
}

export const encodeStockQuoteData = (q, signature) => coder.encode(
  ['tuple(bytes32 orderId,uint256 budget18,uint256 minRawOut,uint256 deadline,uint256 nonce,uint256 fees18,uint256 fixedCost18)', 'bytes'],
  [[q.orderId, q.budget18, q.minRawOut, q.deadline, q.nonce, q.fees18, q.fixedCost18], signature],
);

export const BUYBACK_TYPES = {
  Buyback: [
    { name: 'lotId', type: 'bytes32' }, { name: 'budget', type: 'uint256' }, { name: 'minOut', type: 'uint256' },
    { name: 'pricePolicyVersion', type: 'uint256' }, { name: 'quotedAt', type: 'uint256' }, { name: 'deadline', type: 'uint256' },
    { name: 'nonce', type: 'uint256' }, { name: 'solon', type: 'address' }, { name: 'router', type: 'address' },
    { name: 'path', type: 'bytes32' }, { name: 'recipient', type: 'address' },
  ],
};

export function buybackQuoteDigest({ chainId, executor, config, recipient, q }) {
  const domain = { name: 'SolonBuyback', version: '3', chainId, verifyingContract: executor };
  return TypedDataEncoder.hash(domain, BUYBACK_TYPES, { ...q, solon: config.solon, router: config.router, path: config.path, recipient });
}

const CONVERSION_TUPLE = 'tuple(bytes32 lotId,address asset,uint256 raw,uint256 minUSDC18,uint256 value18,uint256 issuedAt,uint256 deadline,uint256 nonce,uint256 fees18)';

export function conversionQuoteDigest({ chainId, converter, binding, q }) {
  return keccak256(coder.encode(
    ['bytes32', CONVERSION_TUPLE, 'uint256', 'address', 'address', 'address', 'bytes32', 'uint32', 'address', 'uint24'],
    [keccak256(toUtf8Bytes('V2FeeConversionV1')), [q.lotId, q.asset, q.raw, q.minUSDC18, q.value18, q.issuedAt, q.deadline, q.nonce, q.fees18],
      chainId, converter, binding.router, binding.sellRoute, binding.path, binding.version, binding.ops, binding.lpFeePpm],
  ));
}

export const encodeConversionQuoteData = (q, signature) => coder.encode([CONVERSION_TUPLE, 'bytes'],
  [[q.lotId, q.asset, q.raw, q.minUSDC18, q.value18, q.issuedAt, q.deadline, q.nonce, q.fees18], signature]);

// Minimum the V2FeeConverter enforces: ceil(value18 * (1e6 - lpFeePpm) * 9900 / 1e10).
export function conversionMinFloor(value18, lpFeePpm) {
  const num = value18 * (1_000_000n - BigInt(lpFeePpm)) * 9900n;
  const den = 10_000_000_000n;
  return (num + den - 1n) / den;
}

export class DigestMismatch extends Error {}

// Compare local vs on-chain digest, then sign. quoteSigner: { address, signDigest(digest) }.
export async function signChecked({ local, onchain, quoteSigner, expectedSigner }) {
  const remote = await onchain();
  if (remote.toLowerCase() !== local.toLowerCase()) throw new DigestMismatch(`digest mismatch local ${local} chain ${remote}`);
  if (expectedSigner && expectedSigner.toLowerCase() !== quoteSigner.address.toLowerCase()) {
    throw new DigestMismatch(`contract signer ${expectedSigner} is not our quote signer ${quoteSigner.address}`);
  }
  return quoteSigner.signDigest(local);
}

import { SigningKey } from 'ethers';
export { stockQuoteDigest } from '../lib/quotes.mjs';
export const digestSignerFor = wallet => ({ address: wallet.address, signDigest: async d => new SigningKey(wallet.privateKey).sign(d).serialized });

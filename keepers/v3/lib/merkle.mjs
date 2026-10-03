// Checkpoint Merkle tree exactly as ReserveVault.merkleRoot builds it (sorted pairs, odd node carried up) and
// Messages.leaf (double-hashed abi.encode(Result)), so hub.reconcile proofs can be built off-chain.
import { AbiCoder, keccak256, concat } from 'ethers';

const coder = AbiCoder.defaultAbiCoder();
const RESULT = 'tuple(bytes32 ref,address underlying,uint8 outcome,uint128 amountIn,uint128 amountOut,uint64 seq)';

export function leafOf(r) {
  return keccak256(keccak256(coder.encode([RESULT], [[r.ref, r.underlying, r.outcome, r.amountIn, r.amountOut, r.seq]])));
}
const pair = (a, b) => (BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a])));

export function rootOf(leaves) {
  let lv = [...leaves];
  while (lv.length > 1) {
    const next = [];
    for (let i = 0; i < lv.length; i += 2) next.push(i + 1 < lv.length ? pair(lv[i], lv[i + 1]) : lv[i]);
    lv = next;
  }
  return lv[0];
}

export function proofFor(leaves, index) {
  const proof = [];
  let lv = [...leaves], i = index;
  while (lv.length > 1) {
    const sib = i ^ 1;
    if (sib < lv.length) proof.push(lv[sib]);
    const next = [];
    for (let k = 0; k < lv.length; k += 2) next.push(k + 1 < lv.length ? pair(lv[k], lv[k + 1]) : lv[k]);
    lv = next;
    i = Math.floor(i / 2);
  }
  return proof;
}

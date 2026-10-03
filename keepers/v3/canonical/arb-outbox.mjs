// Arbitrum Nitro L2->L1 (child->parent) messages, the way Offchain Labs' own SDK executes them
// (arbitrum-sdk ChildToParentMessageNitro: status() / getOutboxProof() / execute()):
//   1. the L2 message is an ArbSys `L2ToL1Tx` event (position = leaf index in the send accumulator);
//   2. it is executable once the rollup has CONFIRMED an assertion whose L2 block has sendCount > position
//      (confirmation calls Outbox.updateSendRoot(sendRoot, l2BlockHash) -> event SendRootUpdated);
//   3. proof = NodeInterface(0xc8).constructOutboxProof(sendCount, position) via eth_call on an L2 node;
//   4. Outbox.executeTransaction(proof, position, caller, destination, arbBlockNum, ethBlockNum, timestamp, callvalue, data).
// Sources (read 2026-10-01): https://docs.arbitrum.io/how-arbitrum-works/deep-dives/l2-to-l1-messaging ,
// nitro-contracts src/bridge/AbsOutbox.sol + src/libraries/MerkleLib.sol + src/node-interface/NodeInterface.sol,
// nitro-precompile-interfaces ArbSys.sol, arbitrum-sdk packages/sdk/src/lib/message/ChildToParentMessageNitro.ts.
// The SDK finds the confirmed L2 block from the rollup's latestConfirmed assertion; this module reads the same block hash
// from the Outbox's SendRootUpdated event (emitted by that very confirmation), which works for BoLD and legacy rollups alike.
import { Contract, Interface, keccak256, solidityPacked, concat, getAddress, toBeHex } from 'ethers';

export const ARBSYS = '0x0000000000000000000000000000000000000064';
export const NODE_INTERFACE = '0x00000000000000000000000000000000000000C8';
export const L2_TO_L1_TX = 'event L2ToL1Tx(address caller, address indexed destination, uint256 indexed hash, uint256 indexed position, uint256 arbBlockNum, uint256 ethBlockNum, uint256 timestamp, uint256 callvalue, bytes data)';
export const OUTBOX_ABI = [
  'event SendRootUpdated(bytes32 indexed outputRoot, bytes32 indexed l2BlockHash)',
  'function roots(bytes32) view returns (bytes32)',
  'function isSpent(uint256 index) view returns (bool)',
  'function rollup() view returns (address)',
  'function executeTransaction(bytes32[] proof, uint256 index, address l2Sender, address to, uint256 l2Block, uint256 l1Block, uint256 l2Timestamp, uint256 value, bytes data)',
];
export const NODE_INTERFACE_ABI = ['function constructOutboxProof(uint64 size, uint64 leaf) view returns (bytes32 send, bytes32 root, bytes32[] proof)'];
export const arbSysIface = new Interface([L2_TO_L1_TX]);

/// Outbox.calculateItemHash: keccak256(abi.encodePacked(l2Sender, to, l2Block, l1Block, l2Timestamp, value, data)).
export function itemHash(s) {
  return keccak256(solidityPacked(['address', 'address', 'uint256', 'uint256', 'uint256', 'uint256', 'bytes'],
    [s.caller, s.destination, s.arbBlockNum, s.ethBlockNum, s.timestamp, s.callvalue, s.data]));
}

/// Outbox.calculateMerkleRoot = MerkleLib.calculateRoot(proof, path, keccak256(item)).
export function merkleRootFrom(proof, path, item) {
  let h = keccak256(item);
  const route = BigInt(path);
  proof.forEach((node, i) => { h = (route >> BigInt(i)) & 1n ? keccak256(concat([node, h])) : keccak256(concat([h, node])); });
  return h;
}

export function parseL2ToL1(log) {
  const e = arbSysIface.parseLog(log).args;
  return { caller: getAddress(e.caller), destination: getAddress(e.destination), hash: toBeHex(e.hash, 32), position: e.position, arbBlockNum: e.arbBlockNum,
    ethBlockNum: e.ethBlockNum, timestamp: e.timestamp, callvalue: e.callvalue, data: e.data, l2Tx: log.transactionHash, l2LogBlock: log.blockNumber };
}

/// Confirmed send state + proofs. l1 = Ethereum provider, l2 = RH provider (must serve Arbitrum block fields and NodeInterface).
export class ArbOutboxSource {
  constructor({ l1, l2, outbox, chunk = 10_000, lookbackBlocks = 100_000 }) {
    Object.assign(this, { l1, l2, chunk, lookbackBlocks });
    this.outbox = new Contract(outbox, OUTBOX_ABI, l1);
    this.node = new Contract(NODE_INTERFACE, NODE_INTERFACE_ABI, l2);
    this.topic = this.outbox.interface.getEvent('SendRootUpdated').topicHash;
    this.last = null; // { sendRoot, l2BlockHash, sendCount, l1Block }
  }

  async logs(fromBlock, toBlock) {
    return this.l1.getLogs({ address: this.outbox.target, fromBlock, toBlock, topics: [this.topic] });
  }

  // Newest confirmed send root: forward from the cached one, else backward from the head (bounded).
  async latestConfirmed() {
    const head = await this.l1.getBlockNumber();
    let found = null;
    if (this.last) {
      for (let from = this.last.l1Block + 1; from <= head; from += this.chunk) {
        const l = await this.logs(from, Math.min(head, from + this.chunk - 1));
        if (l.length) found = l[l.length - 1];
      }
      if (!found) return this.last;
    } else {
      for (let to = head; to >= Math.max(0, head - this.lookbackBlocks) && !found; to -= this.chunk) {
        const l = await this.logs(Math.max(0, to - this.chunk + 1), to);
        if (l.length) found = l[l.length - 1];
      }
      if (!found) return null;
    }
    const sendRoot = found.topics[1], l2BlockHash = found.topics[2];
    const block = await this.l2.send('eth_getBlockByHash', [l2BlockHash, false]);
    if (!block) throw new Error(`L2 block ${l2BlockHash} of confirmed send root not found on the RH node`);
    if (block.sendCount == null || block.sendRoot == null) throw new Error('RH node did not return Arbitrum block fields (sendCount/sendRoot)');
    if (block.sendRoot.toLowerCase() !== sendRoot.toLowerCase()) throw new Error(`L2 block sendRoot ${block.sendRoot} != Outbox SendRootUpdated ${sendRoot}`);
    this.last = { sendRoot, l2BlockHash, sendCount: BigInt(block.sendCount), l1Block: found.blockNumber };
    return this.last;
  }

  async proof(size, leaf) {
    const r = await this.node.constructOutboxProof(size, leaf);
    return { send: r.send, root: r.root, proof: [...r.proof] };
  }

  async isSpent(position) { return this.outbox.isSpent(position); }
  async rootKnown(root) { return (await this.outbox.roots(root)) !== '0x' + '00'.repeat(32); }
}

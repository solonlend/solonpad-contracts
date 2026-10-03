// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice V3Carry arithmetic with an explicit historical checkpoint timestamp.
/// @dev Callers must process authenticated checkpoints monotonically.
/// @dev A 32-level sparse prefix tree stores principal and principal * endpoint.
///      Fractions remain in the locked numerator; rounding never unlocks early.
library StakingCarry {
    uint256 internal constant DURATION = 7 days;

    struct Node {
        uint256 principal;
        uint256 weightedEnd;
    }

    struct Stream {
        mapping(uint256 => Node) nodes;
        uint256 deposited; // Principal already represented in the tree.
        uint256 pendingDeposit; // Coalesced principal waiting at the current effective clock.
        uint256 weightedEnd;
        uint256 released;
        uint256 clock;
        uint256 last;
    }
    error ClockOverflow();

    function checkpoint(Stream storage s, bool running, uint256 timestamp) internal returns (uint256 amount) {
        if (s.last == 0) {
            s.last = timestamp;
            return 0;
        }
        if (!running) {
            s.last = timestamp;
            return 0;
        }
        // All paused deposits share this effective-time endpoint. Insert once, before
        // advancing, so the first running interval already earns its release.
        uint256 pending = s.pendingDeposit;
        if (pending != 0) {
            s.pendingDeposit = 0;
            _insert(s, pending);
        }
        s.clock += timestamp - s.last;
        if (s.clock > type(uint32).max) revert ClockOverflow();
        s.last = timestamp;
        (uint256 ended, uint256 weighted) = _prefix(s, uint32(s.clock));
        uint256 numerator = s.weightedEnd - weighted - s.clock * (s.deposited - ended);
        uint256 unlocked = s.deposited - Math.ceilDiv(numerator, DURATION);
        amount = unlocked - s.released;
        s.released = unlocked;
    }

    function deposit(Stream storage s, uint256 amount) internal {
        s.pendingDeposit += amount;
    }

    function _insert(Stream storage s, uint256 amount) private {
        uint256 end = s.clock + DURATION;
        if (end > type(uint32).max) revert ClockOverflow();
        s.deposited += amount;
        s.weightedEnd += amount * end;
        for (uint256 depth = 1; depth <= 32; ++depth) {
            uint256 key = (uint256(1) << depth) | (end >> (32 - depth));
            Node storage n = s.nodes[key];
            n.principal += amount;
            n.weightedEnd += amount * end;
        }
    }

    function _prefix(Stream storage s, uint32 value) private view returns (uint256 principal, uint256 weighted) {
        uint256 key = 1;
        for (uint256 depth; depth < 32; ++depth) {
            key <<= 1;
            if ((uint256(value) & (uint256(1) << (31 - depth))) != 0) {
                Node storage n = s.nodes[key];
                principal += n.principal;
                weighted += n.weightedEnd;
                key |= 1;
            }
        }
        Node storage leaf = s.nodes[key];
        principal += leaf.principal;
        weighted += leaf.weightedEnd;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Sparse uint32 seconds tree. Every update/read visits exactly 32 branches.
library ExpirySumTree {
    struct Tree {
        mapping(uint256 => uint256) sums;
    }

    function add(Tree storage self, uint32 expiry, uint256 amount) internal {
        for (uint256 depth = 1; depth <= 32; ++depth) {
            self.sums[(uint256(1) << depth) | (uint256(expiry) >> (32 - depth))] += amount;
        }
    }

    function sub(Tree storage self, uint32 expiry, uint256 amount) internal {
        for (uint256 depth = 1; depth <= 32; ++depth) {
            self.sums[(uint256(1) << depth) | (uint256(expiry) >> (32 - depth))] -= amount;
        }
    }

    function suffixSum(Tree storage self, uint256 time) internal view returns (uint256 sum) {
        if (time >= type(uint32).max) return 0;
        uint256 key = 1;
        for (uint256 depth; depth < 32; ++depth) {
            key <<= 1;
            if ((time & (uint256(1) << (31 - depth))) == 0) sum += self.sums[key | 1];
            else key |= 1;
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StakingCarry} from "../../../../src/v3/libraries/StakingCarry.sol";
import {V3Carry} from "../../../../src/v3/libraries/V3Carry.sol";
import {ExpirySumTree} from "../../../../src/v3/libraries/ExpirySumTree.sol";

contract CovBStakingCarryHarness {
    using StakingCarry for StakingCarry.Stream;
    StakingCarry.Stream s;

    function checkpoint(bool running, uint256 t) external returns (uint256) {
        return s.checkpoint(running, t);
    }

    function deposit(uint256 a) external {
        s.deposit(a);
    }

    function clock() external view returns (uint256) {
        return s.clock;
    }
}

contract CovBV3CarryHarness {
    using V3Carry for V3Carry.Stream;
    V3Carry.Stream s;

    function checkpoint(bool running) external returns (uint256) {
        return s.checkpoint(running);
    }

    function deposit(uint256 a) external {
        s.deposit(a);
    }

    function clock() external view returns (uint256) {
        return s.clock;
    }
}

contract CovBExpiryTreeHarness {
    using ExpirySumTree for ExpirySumTree.Tree;
    ExpirySumTree.Tree t;

    function add(uint32 e, uint256 a) external {
        t.add(e, a);
    }

    function suffixSum(uint256 time) external view returns (uint256) {
        return t.suffixSum(time);
    }
}

/// @notice The uint32 effective-clock bound (~136 years of running time) and the tree's max-time read.
contract CovBCarryLibrariesTest is Test {
    uint256 constant MAX32 = type(uint32).max;

    /// StakingCarry line 45: the effective clock may not pass uint32.
    function testStakingCarryClockOverflow() public {
        CovBStakingCarryHarness h = new CovBStakingCarryHarness();
        h.checkpoint(true, 1); // initialise `last`
        h.checkpoint(true, MAX32 + 1); // clock == MAX32: still fine
        assertEq(h.clock(), MAX32);
        vm.expectRevert(StakingCarry.ClockOverflow.selector);
        h.checkpoint(true, MAX32 + 2);
    }

    /// StakingCarry line 60: a deposit whose 7-day endpoint passes uint32 is rejected.
    function testStakingCarryInsertOverflow() public {
        CovBStakingCarryHarness h = new CovBStakingCarryHarness();
        h.checkpoint(true, 1);
        uint256 t = 1 + MAX32 - 7 days; // clock = MAX32 - 7 days: endpoint == MAX32 still fits
        h.checkpoint(true, t);
        h.deposit(1);
        h.checkpoint(true, t); // insert at endpoint MAX32: ok
        h.checkpoint(true, t + 1); // clock = MAX32 - 7 days + 1
        h.deposit(1);
        vm.expectRevert(StakingCarry.ClockOverflow.selector);
        h.checkpoint(true, t + 1);
    }

    /// V3Carry line 44.
    function testV3CarryClockOverflow() public {
        CovBV3CarryHarness h = new CovBV3CarryHarness();
        vm.warp(1);
        h.checkpoint(true);
        vm.warp(MAX32 + 1);
        h.checkpoint(true);
        assertEq(h.clock(), MAX32);
        vm.warp(MAX32 + 2);
        vm.expectRevert(V3Carry.ClockOverflow.selector);
        h.checkpoint(true);
    }

    /// V3Carry line 59.
    function testV3CarryInsertOverflow() public {
        CovBV3CarryHarness h = new CovBV3CarryHarness();
        vm.warp(1);
        h.checkpoint(true);
        vm.warp(1 + MAX32 - 7 days + 1);
        h.checkpoint(true);
        h.deposit(1);
        vm.expectRevert(V3Carry.ClockOverflow.selector);
        h.checkpoint(true);
    }

    /// ExpirySumTree line 23: at or beyond the uint32 horizon nothing is live.
    function testExpiryTreeMaxTimeIsEmpty() public {
        CovBExpiryTreeHarness h = new CovBExpiryTreeHarness();
        h.add(uint32(MAX32), 5);
        h.add(100, 7);
        assertEq(h.suffixSum(0), 12);
        assertEq(h.suffixSum(MAX32 - 1), 5);
        assertEq(h.suffixSum(MAX32), 0);
        assertEq(h.suffixSum(MAX32 + 10), 0);
    }
}

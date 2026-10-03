// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";

/// @dev With no maturity bucket, dust can only add weight to its recipient; it can
/// never block, delay or reset anyone's existing earning balance.
contract DustTest is Test {
    V3RewardToken token;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    function setUp() public {
        vm.warp(10 days);
        token = new V3RewardToken("R", "R", address(this), address(this), new address[](0));
    }

    function testOneWeiDustJoinsRecipientWeightImmediately() public {
        token.transfer(alice, 1_000_000 ether);
        token.transfer(bob, 1 ether);
        vm.prank(bob);
        token.transfer(alice, 1);
        assertEq(token.eligible(alice), 1_000_000 ether + 1);
        assertEq(token.eligible(bob), 1 ether - 1);
        assertEq(token.totalEligible(), 1_000_001 ether);
    }

    function testRepeatedDustAndPartialSalesKeepWeightEqualBalance() public {
        token.transfer(alice, 100 ether);
        token.transfer(bob, 100);
        for (uint256 i; i < 10; ++i) {
            vm.prank(bob);
            token.transfer(alice, 1);
            vm.prank(alice);
            token.transfer(address(this), 1 ether);
            assertEq(token.eligible(alice), token.balanceOf(alice));
            assertEq(token.eligible(bob), token.balanceOf(bob));
        }
        assertEq(token.eligible(alice), 90 ether + 10);
        assertEq(token.totalEligible(), 90 ether + 100);
    }

    function testFuzzDustSequenceKeepsTotalsExact(uint96 principal, uint8 rounds) public {
        uint256 p = bound(principal, 1, 1e24);
        token.transfer(alice, p);
        token.transfer(bob, 1_000);
        uint256 n = bound(rounds, 1, 40);
        for (uint256 i; i < n; ++i) {
            vm.prank(bob);
            token.transfer(alice, 1);
            if (i % 5 == 0) vm.warp(vm.getBlockTimestamp() + 1);
        }
        assertEq(token.eligible(alice), p + n);
        assertEq(token.totalEligible(), p + 1_000);
    }
}

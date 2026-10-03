// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RewardVault} from "../../../../src/v3/RewardVault.sol";
import {RoundSource} from "../../RewardRounds.t.sol";
import {CovBTaxToken} from "./CovBHelpers.sol";

/// @notice RewardVault deployed directly: this test contract is its `manager` (deployer).
contract CovBRewardVaultTest is Test {
    RewardVault vault;
    CovBTaxToken stock;
    RoundSource source;
    address payout = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    bool rejectEth;

    receive() external payable {
        require(!rejectEth, "manager rejects");
    }

    function setUp() public {
        vault = new RewardVault(payout);
        stock = new CovBTaxToken();
        source = new RoundSource();
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    /// lines 27, 33, 63, 72: every mutating manager hook rejects other callers.
    function testManagerOnlyHooks() public {
        vm.deal(address(vault), 1 ether);
        vm.startPrank(address(0xBAD));
        vm.expectRevert();
        vault.returnRefund(1 ether);
        vm.expectRevert();
        vault.sendOrphan(address(stock), address(0xBAD), 0);
        vm.expectRevert();
        vault.registerAllocation(1, address(source), 7, 0, address(stock), 100);
        vm.expectRevert();
        vault.recordDelivery(1, 0);
        vm.stopPrank();
        assertEq(address(vault).balance, 1 ether);
        (address src,,,,,,) = vault.allocations(1);
        assertEq(src, address(0));
    }

    /// line 29: refund goes to the manager; a rejecting manager reverts the whole call (no silent loss).
    function testReturnRefundToManager() public {
        vm.deal(address(vault), 5 ether);
        uint256 before = address(this).balance;
        vault.returnRefund(2 ether);
        assertEq(address(this).balance, before + 2 ether);
        rejectEth = true;
        vm.expectRevert();
        vault.returnRefund(3 ether);
        assertEq(address(vault).balance, 3 ether);
    }

    /// line 37: orphan transfer must move exactly `raw` (fee-on-transfer token rejected).
    function testSendOrphanExactDelta() public {
        stock.mint(address(vault), 10);
        stock.setTaxTo(address(0xFEE), true);
        vm.expectRevert(bytes("orphan delta"));
        vault.sendOrphan(address(stock), address(0xFEE), 4);
        assertEq(stock.balanceOf(address(vault)), 10);
        stock.setTaxTo(address(0xFEE), false);
        vault.sendOrphan(address(stock), address(0xFEE), 4);
        assertEq(stock.balanceOf(address(0xFEE)), 4);
        assertEq(stock.balanceOf(address(vault)), 6);
    }

    /// lines 74, 78: delivery must target a registered allocation and be backed by vault stock.
    function testRecordDeliveryRequiresAllocationAndCoverage() public {
        vm.expectRevert();
        vault.recordDelivery(1, 10);
        vault.registerAllocation(1, address(source), 7, 0, address(stock), 100);
        vm.expectRevert(bytes("stock coverage"));
        vault.recordDelivery(1, 10);
        stock.mint(address(vault), 10);
        vault.recordDelivery(1, 10);
        (,,,,, uint256 cumulative, uint256 revision) = vault.allocations(1);
        assertEq(cumulative, 10);
        assertEq(revision, 1);
        assertEq(vault.totalDelivered(address(stock)), 10);
    }

    function _deliver(uint256 id, uint256 raw) internal {
        vault.registerAllocation(id, address(source), 7, 0, address(stock), 100);
        stock.mint(address(vault), raw);
        vault.recordDelivery(id, raw);
    }

    /// lines 88, 91, 92: payout-only, page <= 20, unknown allocation reverts, other-asset allocation is skipped.
    function testStageCreditGuards() public {
        source.setCredit(alice, 50);
        _deliver(1, 10);
        vm.expectRevert();
        vault.stageCredit(alice, _ids(1), address(stock)); // not payout
        vm.startPrank(payout);
        vm.expectRevert();
        vault.stageCredit(alice, new uint256[](21), address(stock));
        vm.expectRevert();
        vault.stageCredit(alice, _ids(2), address(stock)); // unregistered allocation
        assertEq(vault.stageCredit(alice, _ids(1), address(0x1234)), 0); // asset mismatch: skipped
        assertEq(vault.creditedToPayout(1, alice), 0);
        assertEq(vault.stageCredit(alice, _ids(1), address(stock)), 5);
        vm.stopPrank();
        assertEq(stock.balanceOf(payout), 5);
        assertEq(vault.totalStaged(address(stock)), 5);
    }

    /// line 94: a source reporting a credit above the sealed total cannot over-stage.
    function testStageCreditRejectsCreditAboveTotal() public {
        source.setCredit(alice, 101);
        _deliver(1, 10);
        vm.prank(payout);
        vm.expectRevert();
        vault.stageCredit(alice, _ids(1), address(stock));
        assertEq(stock.balanceOf(address(vault)), 10);
    }

    /// line 98: a source whose credits sum above the total cannot drain other allocations' stock.
    function testAllocationCoverageCapsOverReportingSource() public {
        source.setCredit(alice, 100);
        source.setCredit(bob, 100);
        _deliver(1, 10);
        stock.mint(address(vault), 1000); // unrelated stock in custody
        vm.startPrank(payout);
        assertEq(vault.stageCredit(alice, _ids(1), address(stock)), 10);
        vm.expectRevert(bytes("allocation coverage"));
        vault.stageCredit(bob, _ids(1), address(stock));
        vm.stopPrank();
        assertEq(stock.balanceOf(address(vault)), 1000);
        assertEq(vault.allocationStaged(1), 10);
    }

    /// line 108: staging transfer must move exactly the staged amount.
    function testStageCreditExactDelta() public {
        source.setCredit(alice, 50);
        _deliver(1, 10);
        stock.setTaxTo(payout, true);
        vm.prank(payout);
        vm.expectRevert(bytes("stage delta"));
        vault.stageCredit(alice, _ids(1), address(stock));
        assertEq(vault.creditedToPayout(1, alice), 0);
        assertEq(stock.balanceOf(address(vault)), 10);
    }

    /// line 144 + never-called participantCount: queue snapshot only after the participant index is sealed.
    function testQueueSnapshotRequiresSealedIndex() public {
        source.setCredit(alice, 60);
        source.setCredit(bob, 40);
        vault.registerAllocation(1, address(source), 7, 0, address(stock), 100);
        vm.expectRevert(bytes("source enumeration incomplete"));
        vault.queueSnapshot(1);
        vm.expectRevert();
        vault.sealParticipantIndex(1); // enumeration incomplete
        vault.registerParticipants(address(source), 1);
        assertEq(vault.participantCount(address(source)), 1);
        vault.registerParticipants(address(source), 64);
        assertEq(vault.participantCount(address(source)), 2);
        vault.sealParticipantIndex(1);
        vault.sealParticipantIndex(1); // idempotent
        (uint256 upper, uint256 revision) = vault.queueSnapshot(1);
        assertEq(upper, 2);
        assertEq(revision, 0);
        assertEq(vault.participantAt(1, 1), bob);
        vm.expectRevert(bytes("participant bound"));
        vault.participantAt(1, 2);
    }
}

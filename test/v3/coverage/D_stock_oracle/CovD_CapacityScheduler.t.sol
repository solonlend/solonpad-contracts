// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CapacityController} from "../../../../src/v3/stock/CapacityController.sol";
import {OrderScheduler} from "../../../../src/v3/stock/OrderScheduler.sol";
import {SchedHub} from "../../Capacity.t.sol";

contract CovDCapacityTest is Test {
    CapacityController cap;
    address owner = address(0xA11CE);
    address guardian = address(0x6A);
    address hub = address(0x4B);
    address rewards = address(0x4E);
    address constant NVDA = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);

    function setUp() public {
        cap = new CapacityController(owner, guardian);
        vm.prank(owner);
        cap.bind(hub, rewards);
    }

    function k(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("covd", i));
    }

    function testCovD_ConstructorRejectsZeroRoles() public {
        vm.expectRevert();
        new CapacityController(address(0), guardian);
        vm.expectRevert();
        new CapacityController(owner, address(0));
    }

    /// L152 onlyHub, L158 bind owner-only, L159 bind once, L160 non-zero wiring.
    function testCovD_BindOnceByOwnerOnlyAndHubGate() public {
        vm.expectRevert(CapacityController.NotHub.selector);
        cap.reservePublicFor(k(1), NVDA, 100e18);
        vm.expectRevert(CapacityController.NotHub.selector);
        cap.markReviewed(k(1));

        CapacityController c2 = new CapacityController(owner, guardian);
        vm.prank(hub);
        vm.expectRevert(CapacityController.NotOwner.selector);
        c2.bind(hub, rewards);
        vm.startPrank(owner);
        vm.expectRevert();
        c2.bind(address(0), rewards);
        vm.expectRevert();
        c2.bind(hub, address(0));
        assertEq(c2.hub(), address(0));
        c2.bind(hub, rewards);
        vm.expectRevert(CapacityController.AlreadyBound.selector);
        c2.bind(address(0xEE), rewards);
        vm.stopPrank();
        assertEq(c2.hub(), hub);
        assertEq(c2.rewardManager(), rewards);
    }

    /// L172: only guardian/owner lower; owner lowering with no pending proposal (L174 false arm).
    function testCovD_LowerLimitsAuthAndNoPending() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.lowerLimits(1e18, 1e18, 1e18);
        vm.prank(owner);
        vm.expectRevert(CapacityController.OnlyLower.selector);
        cap.lowerLimits(10_001e18, 1_000_000e18, 1_000_000e18);
        vm.prank(owner);
        cap.lowerLimits(5_000e18, 500_000e18, 600_000e18);
        assertEq(cap.lRun(), 5_000e18);
        assertEq(cap.uRun(), 500_000e18);
        assertEq(cap.totalCap(), 600_000e18);
        (,,, uint64 eta) = cap.pendingLimits();
        assertEq(eta, 0);
    }

    function testCovD_LimitProposalAuthAndMinOrderBound() public {
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.proposeLimits(1e18, 1e18, 1e18);
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.executeLimits();
        vm.prank(owner);
        vm.expectRevert(CapacityController.Timelocked.selector);
        cap.executeLimits();
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.setMinOrder(1e18);
        vm.prank(owner);
        vm.expectRevert(CapacityController.BadLimits.selector);
        cap.setMinOrder(10_000e18 + 1);
        vm.prank(owner);
        cap.setMinOrder(10_000e18); // boundary: equal to lRun is allowed
        assertEq(cap.minOrderUsd(), 10_000e18);
        vm.expectRevert(CapacityController.BelowMinOrder.selector);
        cap.checkRun(10_000e18 - 1);
        cap.checkRun(10_000e18);
    }

    /// L231-233: first asset cap owner-only, non-zero asset, once.
    function testCovD_SetAssetCapOwnerOnceNonZero() public {
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.setAssetCap(NVDA, 1e18);
        vm.prank(owner);
        vm.expectRevert();
        cap.setAssetCap(address(0), 1e18);
        assertEq(cap.cappedAssets().length, 0);
        vm.prank(owner);
        cap.setAssetCap(NVDA, 400_000e18);
        vm.prank(owner);
        vm.expectRevert(CapacityController.Timelocked.selector);
        cap.setAssetCap(NVDA, 500_000e18);
        assertEq(cap.cappedAssets().length, 1);
        (uint256 c, bool set) = cap.assetCap(NVDA);
        assertEq(c, 400_000e18);
        assertTrue(set);
        assertEq(cap.assetRoomUsd(address(0x1234)), type(uint256).max, "uncapped asset");
        assertEq(cap.assetRoomUsd(NVDA), 400_000e18);
    }

    /// L240/L242 lower; L248/L249 propose; L256/L258 execute.
    function testCovD_AssetCapGovernanceGuards() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.lowerAssetCap(NVDA, 0);
        vm.prank(guardian);
        vm.expectRevert(CapacityController.OnlyLower.selector);
        cap.lowerAssetCap(NVDA, 0); // not set yet
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.proposeAssetCap(NVDA, 1);
        vm.prank(owner);
        vm.expectRevert(CapacityController.NotReserved.selector);
        cap.proposeAssetCap(NVDA, 1); // not set yet
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.executeAssetCap(NVDA);
        vm.prank(owner);
        vm.expectRevert(CapacityController.Timelocked.selector);
        cap.executeAssetCap(NVDA); // nothing proposed

        vm.prank(owner);
        cap.setAssetCap(NVDA, 100e18);
        vm.prank(guardian);
        vm.expectRevert(CapacityController.OnlyLower.selector);
        cap.lowerAssetCap(NVDA, 100e18 + 1);
        vm.prank(guardian);
        cap.lowerAssetCap(NVDA, 50e18);
        (uint256 c,) = cap.assetCap(NVDA);
        assertEq(c, 50e18);
        // exposure at/over the cap: zero room
        vm.prank(hub);
        cap.reservePublicFor(k(1), NVDA, 50e18);
        assertEq(cap.assetRoomUsd(NVDA), 0);
        assertFalse(cap.canReserveFor(0, NVDA, 1));
    }

    /// L314: the reward lane with an asset is reward-manager only.
    function testCovD_ReserveForRewardManagerOnly() public {
        vm.prank(hub);
        vm.expectRevert(CapacityController.NotRewardManager.selector);
        cap.reserveFor(k(1), NVDA, 100e18);
        vm.prank(rewards);
        cap.reserveFor(k(1), NVDA, 100e18);
        assertEq(cap.inflightUsdOf(NVDA), 100e18);
        assertEq(cap.unreviewedRewardUsd(), 100e18);
        CapacityController.Ticket memory t = cap.ticket(k(1));
        assertEq(t.lane, 1);
        assertEq(t.asset, NVDA);
    }

    /// L339: a zero reservation is refused (view and write).
    function testCovD_ZeroUsdIsRefused() public {
        assertFalse(cap.canReserve(0, 0));
        assertFalse(cap.canReserve(1, 0));
        vm.prank(hub);
        vm.expectRevert(CapacityController.ZeroAmount.selector);
        cap.reservePublicFor(k(1), NVDA, 0);
        assertEq(cap.inflightUsd(), 0);
    }

    /// L359: a live ticket cannot be reserved again; L360: a closed *sent* one neither (a closed unsent
    /// one may be reused).
    function testCovD_ReserveReuseRules() public {
        vm.startPrank(hub);
        cap.reservePublicFor(k(1), NVDA, 100e18);
        vm.expectRevert(CapacityController.AlreadyReserved.selector);
        cap.reservePublicFor(k(1), NVDA, 100e18);
        // closed after the principal left -> never again
        cap.markSent(k(1));
        cap.release(k(1));
        assertEq(uint8(cap.ticket(k(1)).state), uint8(CapacityController.State.Closed));
        vm.expectRevert(CapacityController.AlreadySent.selector);
        cap.reservePublicFor(k(1), NVDA, 100e18);
        // closed without being sent -> reusable
        cap.reservePublicFor(k(2), NVDA, 100e18);
        cap.release(k(2));
        assertEq(uint8(cap.ticket(k(2)).state), uint8(CapacityController.State.Closed));
        cap.reservePublicFor(k(2), NVDA, 70e18);
        vm.stopPrank();
        assertEq(cap.inflightUsd(), 70e18);
        assertEq(uint8(cap.ticket(k(2)).state), uint8(CapacityController.State.Reserved));
    }

    /// L378 markSent needs a Reserved ticket; L386/L388 releaseUnsent caller and state; L397 release no-op.
    function testCovD_SentAndReleaseGuards() public {
        vm.prank(hub);
        vm.expectRevert(CapacityController.NotReserved.selector);
        cap.markSent(k(9));
        vm.prank(address(0xBAD));
        vm.expectRevert(CapacityController.NotRewardManager.selector);
        cap.releaseUnsent(k(9));
        vm.prank(hub);
        vm.expectRevert(CapacityController.NotReserved.selector);
        cap.releaseUnsent(k(9));
        // the hub may release an unsent public reservation (refunded queued order)
        vm.startPrank(hub);
        cap.reservePublicFor(k(3), NVDA, 100e18);
        cap.releaseUnsent(k(3));
        assertEq(uint8(cap.ticket(k(3)).state), uint8(CapacityController.State.None));
        assertEq(cap.inflightUsd(), 0);
        assertEq(cap.unreviewedUsd(), 0);
        // release of an unknown / non-reserved ticket changes nothing
        cap.release(k(4));
        assertEq(uint8(cap.ticket(k(4)).state), uint8(CapacityController.State.None));
        cap.reservePublicFor(k(5), NVDA, 100e18);
        cap.finalizeBuy(k(5), NVDA, 1e18);
        cap.release(k(5)); // Issued: not released
        vm.stopPrank();
        assertEq(uint8(cap.ticket(k(5)).state), uint8(CapacityController.State.Issued));
        assertEq(cap.issuedUsd(), 100e18);
    }

    /// L446: a redemption key must be fresh.
    function testCovD_BeginRedeemNeedsAFreshKey() public {
        vm.startPrank(hub);
        cap.reservePublicFor(k(1), NVDA, 100e18);
        cap.finalizeBuy(k(1), NVDA, 1e18);
        vm.expectRevert(CapacityController.AlreadyReserved.selector);
        cap.beginRedeem(k(1), NVDA, 1e18);
        // fresh key, raw above the issued total: clamps to the whole basis (L449 true arm)
        uint256 usd = cap.beginRedeem(k(2), NVDA, 5e18);
        vm.stopPrank();
        assertEq(usd, 100e18);
        assertEq(cap.issuedRaw(NVDA), 0);
        assertEq(cap.redeemingUsdOf(NVDA), 100e18);
    }

    /// Supports the L454 justification: the rounded-up basis of a partial redemption never exceeds the basis.
    function testCovDFuzz_PartialRedeemUsdNeverExceedsBasis(uint256 usd, uint256 raw, uint256 part) public {
        usd = bound(usd, 1, 10_000e18);
        raw = bound(raw, 2, 1e30);
        part = bound(part, 1, raw - 1);
        vm.startPrank(hub);
        cap.reservePublicFor(k(1), NVDA, usd);
        cap.finalizeBuy(k(1), NVDA, raw);
        uint256 out = cap.beginRedeem(k(2), NVDA, part);
        vm.stopPrank();
        assertLe(out, usd);
        assertEq(cap.issuedUsdOf(NVDA) + cap.redeemingUsdOf(NVDA), usd);
    }

    /// L468/L482: finalize/revert of a ticket that is not Redeeming are no-ops (results always apply).
    function testCovD_FinalizeAndRevertRedeemAreNoOpsOffState() public {
        vm.startPrank(hub);
        cap.finalizeRedeem(k(7), false);
        cap.revertRedeem(k(7));
        assertEq(uint8(cap.ticket(k(7)).state), uint8(CapacityController.State.None));
        assertEq(cap.unreviewedUsd(), 0);
        cap.reservePublicFor(k(1), NVDA, 100e18);
        cap.finalizeBuy(k(1), NVDA, 1e18);
        cap.beginRedeem(k(2), NVDA, 1e18);
        cap.finalizeRedeem(k(2), true);
        // already Closed: a second finalize / a revert change nothing
        cap.finalizeRedeem(k(2), false);
        cap.revertRedeem(k(2));
        vm.stopPrank();
        assertEq(cap.redeemingUsd(), 0);
        assertEq(cap.issuedUsd(), 0);
        assertEq(cap.issuedRaw(NVDA), 0);
        assertEq(cap.unreviewedUsd(), 100e18, "only the buy's unreviewed stays; the reviewed redeem added none");
    }
}

contract CovDSchedulerTest is Test {
    CapacityController cap;
    SchedHub hub;
    OrderScheduler sched;
    address owner = address(0xA11CE);

    function setUp() public {
        cap = new CapacityController(owner, address(0x6A));
        hub = new SchedHub(cap);
        sched = new OrderScheduler(address(hub), cap);
        hub.setScheduler(sched);
        vm.prank(owner);
        cap.bind(address(hub), address(hub));
    }

    function testCovD_ConstructorRejectsZero() public {
        vm.expectRevert();
        new OrderScheduler(address(0), cap);
        vm.expectRevert();
        new OrderScheduler(address(hub), CapacityController(address(0)));
    }

    /// L47 only the hub enqueues; L48 only lanes 0/1.
    function testCovD_EnqueueGuards() public {
        vm.expectRevert(OrderScheduler.NotHub.selector);
        sched.enqueue(0, 1);
        vm.prank(address(hub));
        vm.expectRevert(OrderScheduler.BadLane.selector);
        sched.enqueue(2, 1);
        (uint256 total,) = sched.queueLength(0);
        assertEq(total, 0);
    }

    /// L80-89: skipClosed drops closed heads, stops at the first pending entry and respects `max`.
    function testCovD_SkipClosedBothLanes() public {
        uint256 a = hub.place(0, 100e18);
        uint256 b = hub.place(0, 100e18);
        uint256 c = hub.place(0, 100e18);
        hub.cancel(a);
        hub.cancel(b);
        sched.skipClosed(0, 1); // bounded by max
        assertEq(sched.head0(), 1);
        sched.skipClosed(0, 10); // stops at the pending c
        assertEq(sched.head0(), 2);
        (uint256 total, uint256 waiting) = sched.queueLength(0);
        assertEq(total, 3);
        assertEq(waiting, 1);
        assertEq(sched.queued(0, 2), c);

        uint256 r = hub.place(1, 100e18);
        hub.cancel(r);
        sched.skipClosed(1, 10); // runs to the end of the queue
        assertEq(sched.head1(), 1);
        assertEq(sched.head0(), 2, "lane 0 untouched");
        assertEq(sched.queued(1, 0), r);
        (total, waiting) = sched.queueLength(1);
        assertEq(total, 1);
        assertEq(waiting, 0);
        (bool found, uint8 lane, uint256 id) = sched.nextLaunch();
        assertTrue(found);
        assertEq(lane, 0);
        assertEq(id, c);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CanonicalBase} from "./Canonical.t.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";

/// @notice Re-review of the stock layer (after 818223d): N1/N2 (acceleration float), L1 (fee on the
///         canonical proceeds exit), L2 (held money in refunds), L3 (minimum order size), L4 (cap
///         governance). The first two started as PoCs (otc-research/ReReviewPoC.t.sol) and are kept here
///         with the fixed expectations.
contract StockReReviewTest is CanonicalBase {
    address attacker = address(0xA77);
    uint256 constant FEE = 2.5e18;
    uint256 constant SELL_FEE = 2.49375e18; // 25 bps of 997.5

    function setUp() public override {
        super.setUp();
        vm.deal(attacker, 100 ether);
        vm.deal(address(this), 100_000 ether);
    }

    function _floatOn() internal {
        vm.prank(owner);
        hub.setFloatEnabled(true);
        hub.fundFloat{value: 5_000 ether}();
    }

    function _returnAll(uint256 id, uint256 arrives) internal {
        vault.returnFunds(bytes32(id), 0, "ok");
        returnRoute.complete{value: arrives}(returnRoute.sentCount() - 1, payable(address(route)), arrives);
    }

    uint256 before;

    /// Buys 1,000 USDC of stock, then sells all of it (sold on RH, result in flight). `before` is the
    /// user's balance right before the sell.
    function _soldAwaitingProceeds() internal returns (uint256 id) {
        _boughtOrder(1_000e18);
        before = user.balance;
        vm.prank(user);
        id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 0);
        _deliverLatestOrder();
    }

    // ---------------------------------------------------------------- N1

    /// PoC: float on; the user cancels (float refund) while the vault waits for funds; the Relay intent
    /// then expires and refills the float. The vault's order must still be closable and the reservation
    /// released exactly once.
    function testN1_FloatCancelledBuyIsVoidedAndItsReservationReleasedOnce() public {
        _floatOn();
        uint256 start = user.balance;
        uint256 id = _buy(1_000e18, 1);
        _deliverLatestOrder(); // vault waits for funding
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id); // float refunds now
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        assertEq(user.balance, start - 0.51 ether, "principal + fee + unused reserve back from the float");
        uint256 floatMid = hub.available();
        route.refund(0, 997.2e18); // Relay intent expired: refills the float
        assertEq(hub.available(), floatMid + 997.2e18);
        vm.prank(user);
        vm.expectRevert(); // the canonical door stays shut: its delivery would pay the float's money on RH
        hub.escalateFunds{value: 1 ether}(id, user);
        vm.prank(attacker);
        hub.voidOrder{value: 0.01 ether}(id); // anyone, at the caller's cost (the reserve went to the user)
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled), "a void never reopens");
        _deliverLatestOrder();
        assertTrue(vault.settled(bytes32(id)));
        assertEq(vault.waitingOrder(bytes32(id)).underlying, address(0), "the vault order is closed");
        _deliverLatestResult(); // Failed
        assertEq(hub.getOrder(id).outcome, 3);
        assertEq(capacity.inflightUsd(), 0, "reservation released");
        assertEq(capacity.unreviewedUsd(), 0, "unreviewed released");
        vm.prank(attacker);
        vm.expectRevert(); // once
        hub.voidOrder{value: 0.01 ether}(id);
        assertEq(user.balance, start - 0.51 ether, "paid exactly once");
        assertEq(hub.escrowed(), 0);
    }

    /// Variant: the funding reached the vault after the float refund but the order was never executed.
    /// The void makes it returnable and the return refills the float, never the user again.
    function testN1_FloatCancelledBuyWithFundingOnTheVaultReturnsItToTheFloat() public {
        _floatOn();
        uint256 start = user.balance;
        uint256 id = _buy(1_000e18, 1);
        _deliverLatestOrder();
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        route.fill(0, 997_500_000); // money arrives, the waiting order is not executed yet
        uint256 floatMid = hub.available();
        hub.voidOrder{value: 0.01 ether}(id);
        _deliverLatestOrder();
        _deliverLatestResult();
        assertEq(capacity.inflightUsd(), 0);
        _returnAll(id, 997.2e18);
        assertEq(hub.available(), floatMid + 997.2e18, "the return refills the float");
        assertEq(user.balance, start - 0.51 ether, "the user is not paid twice");
        assertEq(vault.settlementLiabilities(), 0);
    }

    /// Found by the extended invariant suite: a float-refunded buy the vault still bought, proven
    /// canonically before its LayerZero Bought lands, orphans to the treasury — and must also clear its
    /// unreviewed exposure (the late LayerZero copy is ignored, so nothing else ever would).
    function testN1_CanonicalOrphanOfAFloatRefundedBuyIsReviewed() public {
        _floatOn();
        uint256 id = _buy(1_000e18, 1);
        _deliverLatestOrder();
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        route.fill(0, 997_500_000);
        vault.executeFunded(bytes32(id)); // the vault buys; the LayerZero Bought is stuck
        uint256 stuck = rhEp.packetCount() - 1;
        uint256 index = _checkpointToArc();
        _reconcile(vault.resultCount() - 1, index);
        assertEq(token.balanceOf(treasury), 9.975e18, "orphaned to the treasury");
        assertEq(capacity.inflightUsd(), 0);
        assertEq(capacity.unreviewedUsd(), 0, "proven canonically: reviewed");
        rhEp.deliver(stuck); // the late LayerZero copy changes nothing
        assertEq(token.balanceOf(treasury), 9.975e18);
        assertEq(token.totalSupply(), vault.entitledOf(address(stock)));
    }

    // ---------------------------------------------------------------- N2

    /// PoC: float on; a sell's proceeds come back below half of net before the Sold result. The float
    /// pays net once and keeps the held part as its own replenishment.
    function testN2_FloatSoldAfterSmallReturnPaysNetOnceAndTheHeldPartRefillsTheFloat() public {
        _floatOn();
        uint256 id = _soldAwaitingProceeds();
        uint256 floatBefore = hub.available();
        _returnAll(id, 400e18); // costly return leg: < 50% of net, before Sold
        assertEq(hub.getOrder(id).held, 400e18);
        _deliverLatestResult(); // Sold
        uint256 net = 997.5e18 - SELL_FEE;
        assertEq(hub.getOrder(id).amountOut, net);
        assertEq(user.balance, before - 0.01 ether + net, "net, exactly once");
        // The float advances gross (net to the user, the fee to the treasury); the held part is its first refill.
        assertEq(hub.available(), floatBefore - 997.5e18 + 400e18, "held money replenishes the float");
        assertEq(hub.escrowed(), 0);
        assertEq(hub.accruedFees(), FEE + SELL_FEE);
    }

    // ---------------------------------------------------------------- L1

    function testL1_EscalatedProceedsPayTheLockedSellFee() public {
        uint256 id = _soldAwaitingProceeds();
        _deliverLatestResult(); // Sold, proceeds stuck on RH
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Proceeds));
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user);
        vm.expectRevert(); // the hook alone no longer covers it: the locked 25 bps is due too
        hub.escalateFunds{value: 1 ether}(id, rhUser);
        vm.prank(user);
        hub.escalateFunds{value: 1 ether + SELL_FEE}(id, rhUser);
        assertEq(hub.accruedFees(), FEE + SELL_FEE, "the locked fee is charged");
        _deliverToReserve();
        assertEq(usdg.balanceOf(rhUser), 997_500_000, "gross delivered on the reserve chain");
        assertEq(user.balance, before - 0.01 ether - 1 ether - SELL_FEE);
        assertEq(hub.escrowed(), 0);
    }

    /// The proceeds were already on their way back when the seller escalated: RH hands over nothing and
    /// the late Arc return is paid to the seller, who already paid the fee (net overall, not gross).
    function testL1_LateArcReturnAfterEscalationIsNetOfTheFee() public {
        uint256 id = _soldAwaitingProceeds();
        _deliverLatestResult();
        vault.returnFunds(bytes32(id), 0, "ok"); // in flight (the suite is the vault keeper)
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user);
        hub.escalateFunds{value: 1 ether + SELL_FEE}(id, rhUser);
        _deliverToReserve();
        assertEq(usdg.balanceOf(rhUser), 0, "nothing left on RH");
        returnRoute.complete{value: 997.2e18}(returnRoute.sentCount() - 1, payable(address(route)), 997.2e18);
        assertEq(user.balance, before - 0.01 ether - 1 ether + 997.2e18 - SELL_FEE, "gross less the fee, once");
        assertEq(hub.accruedFees(), FEE + SELL_FEE);
        assertEq(hub.escrowed(), 0);
    }

    /// A partial return held for the order pays the fee first; the rest of the held money goes back.
    function testL1_HeldPartialReturnPaysTheFeeOnEscalation() public {
        uint256 id = _soldAwaitingProceeds();
        _returnAll(id, 400e18); // below half of net: held
        _deliverLatestResult(); // Sold, still waiting (float off)
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Proceeds));
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user);
        hub.escalateFunds{value: 1 ether}(id, rhUser);
        assertEq(user.balance, before - 0.01 ether - 1 ether + 400e18 - SELL_FEE);
        assertEq(hub.accruedFees(), FEE + SELL_FEE);
        assertEq(hub.escrowed(), 0);
    }

    // ---------------------------------------------------------------- L2

    function testL2_RefundOfAQueuedBuyIncludesMoneyHeldForIt() public {
        uint256 start = user.balance;
        vm.prank(user);
        uint256 id = hub.requestBuy{value: 1_001 ether}(address(stock), 1_000e18, 1); // queued, never launched
        route.deliverReturnFor{value: 1e12}(bytes32(id)); // a stray credit for the ref
        assertEq(hub.getOrder(id).held, 1e12);
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        assertEq(user.balance, start + 1e12, "everything back, held included");
        assertEq(hub.getOrder(id).held, 0);
        assertEq(hub.escrowed(), 0, "nothing stranded");
    }

    // ---------------------------------------------------------------- L3

    function testL3_PublicBuysBelowTheMinimumOrderAreRefused() public {
        assertEq(capacity.minOrderUsd(), 20e18, "default $20");
        vm.prank(user);
        vm.expectRevert(CapacityController.BelowMinOrder.selector);
        hub.requestBuy{value: 20e18}(address(stock), 20e18, 1); // principal 19.95
        vm.prank(user);
        hub.requestBuy{value: 20.1e18}(address(stock), 20.1e18, 1); // principal 20.04975 -> 20.049749
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        capacity.setMinOrder(0);
        vm.prank(owner);
        vm.expectRevert(CapacityController.BadLimits.selector);
        capacity.setMinOrder(10_001e18); // above the single-order limit
        vm.prank(owner);
        capacity.setMinOrder(50e18);
        vm.prank(user);
        vm.expectRevert(CapacityController.BelowMinOrder.selector);
        hub.requestBuy{value: 40e18}(address(stock), 40e18, 1);
    }

    // ---------------------------------------------------------------- L4

    function testL4_GuardianLoweringCancelsAPendingRaise() public {
        vm.prank(owner);
        capacity.proposeLimits(10_000e18, 1_000_000e18, 1_000_000e18);
        vm.prank(guardian);
        capacity.lowerLimits(1_000e18, 100_000e18, 100_000e18);
        (,,, uint64 eta) = capacity.pendingLimits();
        assertEq(eta, 0, "the pending raise is gone");
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        vm.expectRevert(CapacityController.Timelocked.selector);
        capacity.executeLimits();
        assertEq(capacity.lRun(), 1_000e18);
    }

    function testL4_ProposalsAreSanityChecked() public {
        vm.startPrank(owner);
        vm.expectRevert(CapacityController.BadLimits.selector);
        capacity.proposeLimits(0, 1_000_000e18, 1_000_000e18); // no single order could ever fit
        vm.expectRevert(CapacityController.BadLimits.selector);
        capacity.proposeLimits(20_000e18, 10_000e18, 1_000_000e18); // per order > unreviewed
        vm.expectRevert(CapacityController.BadLimits.selector);
        capacity.proposeLimits(10_000e18, 2_000_000e18, 1_000_000e18); // unreviewed > total
        vm.expectRevert(CapacityController.BadLimits.selector);
        capacity.proposeLimits(10e18, 1_000_000e18, 1_000_000e18); // per order below the minimum order
        capacity.proposeLimits(20_000e18, 2_000_000e18, 2_000_000e18);
        vm.stopPrank();
    }
}

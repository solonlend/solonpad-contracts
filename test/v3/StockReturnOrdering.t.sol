// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CanonicalBase} from "./Canonical.t.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";
import {Messages} from "../../src/v3/stock/libs/Messages.sol";

/// @notice Review p5 #2/#3/#8 and the float lows: money that comes back through a funding route before
///         the vault's LayerZero result must never decide the order. Real hub + real reserve vault over
///         mock LayerZero endpoints and mock money routes, delivered in adversarial orders.
contract StockReturnOrderingTest is CanonicalBase {
    address attacker = address(0xA77);
    uint256 constant PRINCIPAL = 997.5e18;
    uint256 constant FEE = 2.5e18;

    function setUp() public override {
        super.setUp();
        vm.deal(attacker, 100 ether);
        vm.deal(address(this), 100_000 ether);
    }

    // ---------------------------------------------------------------- helpers

    /// A buy of 1,000 USDC with 1 USDC reserve: route fee 0.5, LZ fee 0.01 -> 0.49 unused extra.
    function _dispatchedBuy() internal returns (uint256 id) {
        id = _buy(1_000e18, 1);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Dispatched));
    }

    /// Anyone can pay USDG into any ref and, once the ref is settled on the vault, bounce it to Arc
    /// (together with whatever else the ref still has there).
    function _dustReturn(uint256 id) internal {
        usdg.mint(attacker, 1);
        vm.startPrank(attacker);
        usdg.approve(address(vault), 1);
        vault.fund(bytes32(id), 1);
        vm.stopPrank();
        _returnOwed(id);
    }

    /// Return everything the vault holds for `id`, arriving on Arc 1:1.
    function _returnOwed(uint256 id) internal {
        uint256 owed = vault.funding(bytes32(id)) + vault.proceeds(bytes32(id));
        _returnAll(id, owed * 1e12);
    }

    function _returnAll(uint256 id, uint256 arrives) internal {
        vault.returnFunds(bytes32(id), 0, "ok");
        returnRoute.complete{value: arrives}(returnRoute.sentCount() - 1, payable(address(route)), arrives);
    }

    function _pendingPackets(bool arc) internal view returns (uint256[] memory list) {
        uint256 n = arc ? arcEp.packetCount() : rhEp.packetCount();
        list = new uint256[](n);
        uint256 m;
        for (uint256 i; i < n; ++i) {
            (,,,,, bool delivered) = arc ? arcEp.packets(i) : rhEp.packets(i);
            if (!delivered) list[m++] = i;
        }
        assembly ("memory-safe") {
            mstore(list, m)
        }
    }

    function _deliverAll() internal {
        for (uint256 round; round < 4; ++round) {
            uint256[] memory a = _pendingPackets(true);
            for (uint256 i; i < a.length; ++i) {
                arcEp.deliver(a[i]);
            }
            uint256[] memory r = _pendingPackets(false);
            for (uint256 i; i < r.length; ++i) {
                rhEp.deliver(r[i]);
            }
        }
    }

    // ---------------------------------------------------------------- #2 (a)

    function testCancelDustReturnThenLateBoughtGivesTheUserTheStockNotTheTreasury() public {
        uint256 before = user.balance;
        uint256 id = _dispatchedBuy();
        route.fill(0, 997_500_000);
        _deliverLatestOrder(); // the vault buys; the Bought result is still in flight
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        _dustReturn(id); // arrives on Arc before the result
        HubSettlement.Order memory o = hub.getOrder(id);
        assertEq(uint8(o.status), uint8(HubSettlement.Status.Dispatched), "a return before the result is only held");
        assertEq(o.held, 1e12);
        assertEq(capacity.inflightUsd(), PRINCIPAL, "no release without the vault's answer");
        _deliverLatestResult();
        assertEq(token.balanceOf(user), 9.975e18, "the user gets the stock");
        assertEq(token.balanceOf(treasury), 0, "never the treasury");
        assertEq(user.balance, before - 1_001 ether + 0.49 ether + 1e12, "unused reserve and the held dust");
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
        assertEq(hub.escrowed(), 0);
        assertEq(hub.accruedFees(), FEE);
    }

    // ---------------------------------------------------------------- #2 (b)

    function testSellProceedsBeforeSoldAreFeeChargedAndTheOrderResolves() public {
        _boughtOrder(1_000e18);
        uint256 before = user.balance;
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 990e18);
        _deliverLatestOrder(); // sold on RH; the Sold result is in flight
        _returnAll(id, 997.2e18); // proceeds are back first
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Dispatched));
        assertEq(user.balance, before - 0.01 ether, "nothing paid before the result");
        _deliverLatestResult();
        uint256 fee = 2.49375e18;
        assertEq(user.balance, before - 0.01 ether + 997.2e18 - fee, "gross less the locked 25 bps");
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
        assertEq(hub.accruedFees(), FEE + fee);
        assertEq(hub.escrowed(), 0);
        assertEq(capacity.exposureUsd(), 0);
    }

    // ---------------------------------------------------------------- #2 (c)

    function testFloatNeverPaysASellTwiceWhenProceedsBeatTheResult() public {
        vm.prank(owner);
        hub.setFloatEnabled(true);
        hub.fundFloat{value: 5_000 ether}();
        _boughtOrder(1_000e18);
        uint256 before = user.balance;
        uint256 floatBefore = hub.available();
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 990e18);
        _deliverLatestOrder();
        _returnAll(id, 997.2e18);
        _deliverLatestResult();
        uint256 fee = 2.49375e18;
        assertEq(user.balance, before - 0.01 ether + 997.2e18 - fee, "paid exactly once, from the held proceeds");
        assertEq(hub.available(), floatBefore, "the float is untouched");
        vm.expectRevert(); // nothing left to return, and a replayed return route credit changes nothing
        vault.returnFunds(bytes32(id), 0, "ok");
    }

    function testFloatAdvanceThenReturnReplenishesExactlyOnce() public {
        vm.prank(owner);
        hub.setFloatEnabled(true);
        hub.fundFloat{value: 5_000 ether}();
        _boughtOrder(1_000e18);
        uint256 before = user.balance;
        uint256 floatBefore = hub.available();
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 990e18);
        _deliverLatestOrder();
        _deliverLatestResult(); // float pays the net at once
        uint256 net = 997.5e18 - 2.49375e18;
        assertEq(user.balance, before - 0.01 ether + net);
        _returnAll(id, 997.5e18);
        assertEq(user.balance, before - 0.01 ether + net, "the return refills the float, never the user again");
        assertEq(hub.available(), floatBefore);
    }

    // ---------------------------------------------------------------- #3

    function testRelayRefundWithoutCancelIsHeldThenVoidedAndReleased() public {
        uint256 before = user.balance;
        uint256 id = _dispatchedBuy();
        _deliverLatestOrder(); // the order waits on the vault for money that never comes
        route.refund(0, 997.2e18); // the intent expired: the source-side refund lands on Arc
        HubSettlement.Order memory o = hub.getOrder(id);
        assertEq(uint8(o.status), uint8(HubSettlement.Status.Dispatched));
        assertEq(o.held, 997.2e18);
        assertEq(capacity.inflightUsd(), PRINCIPAL, "still reserved: nothing proves the vault will not buy");
        vm.prank(attacker);
        hub.voidOrder{value: 0.01 ether}(id); // anyone: the money is provably back on Arc
        _deliverLatestOrder(); // the void closes the ref on the vault: it can never execute now
        assertTrue(vault.settled(bytes32(id)));
        assertEq(vault.waitingOrder(bytes32(id)).underlying, address(0));
        _deliverLatestResult(); // Failed
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        assertEq(user.balance, before - 1_001 ether + 997.2e18 + FEE + 0.49 ether, "held + fee + unused reserve");
        assertEq(capacity.inflightUsd(), 0);
        assertEq(capacity.unreviewedUsd(), 0);
        assertEq(hub.escrowed(), 0);
    }

    function testTenRelayRefundsCannotFillTheUnreviewedCap() public {
        vm.prank(owner);
        capacity.lowerLimits(1_000e18, 10_000e18, 1_000_000e18); // the review's $10k scenario
        for (uint256 i; i < 10; ++i) {
            uint256 id = _buy(1_000e18, 1);
            route.refund(route.sentCount() - 1, 997.2e18);
            hub.voidOrder{value: 0.01 ether}(id);
            _deliverLatestOrder();
            _deliverLatestResult();
        }
        assertEq(capacity.unreviewedUsd(), 0);
        assertTrue(capacity.canReserve(0, 997.5e18), "the public lane still has room");
        assertTrue(capacity.canReserve(1, 997.5e18), "and so does the reward lane");
    }

    function testVoidIsRefusedWhileTheOrderMayStillExecute() public {
        uint256 id = _dispatchedBuy();
        vm.expectRevert();
        hub.voidOrder{value: 0.01 ether}(id); // no cancel request, nothing came back
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        _deliverLatestResult();
        vm.expectRevert();
        hub.voidOrder{value: 0.01 ether}(id); // settled
    }

    function testVoidAfterTheVaultAlreadyBoughtChangesNothing() public {
        uint256 id = _dispatchedBuy();
        route.fill(0, 997_500_000);
        _deliverLatestOrder(); // bought on RH, result in flight
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        hub.voidOrder{value: 0.01 ether}(id);
        _deliverAll();
        assertEq(token.balanceOf(user), 9.975e18, "the fill stands");
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
        assertEq(capacity.inflightUsd(), 0);
    }

    function testEscalateFundsCoversARefundedOrderWhenLayerZeroIsDown() public {
        uint256 before = user.balance;
        uint256 id = _dispatchedBuy();
        route.refund(0, 997.2e18);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user);
        hub.escalateFunds{value: 1 ether}(id, rhUser);
        _deliverToReserve(); // the canonical delivery closes the ref on the vault
        assertTrue(vault.settled(bytes32(id)));
        uint256 index = _checkpointToArc();
        uint256 seq = vault.resultCount() - 1;
        assertEq(vault.resultAt(seq).ref, bytes32(id));
        assertEq(uint8(vault.resultAt(seq).outcome), uint8(Messages.Outcome.Failed));
        _reconcile(seq, index);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        assertEq(user.balance, before - 1_001 ether - 1 ether + 997.2e18 + FEE + 0.49 ether);
        assertEq(capacity.inflightUsd(), 0);
        assertEq(capacity.unreviewedUsd(), 0);
        uint256 results = rhEp.packetCount();
        _deliverLatestOrder(); // the original order message finally lands: ignored
        assertEq(rhEp.packetCount(), results);
    }

    // ---------------------------------------------------------------- #8

    function testPausedHubStillRefundsAFundedUndispatchedBuy() public {
        uint256 before = user.balance;
        vm.prank(user);
        uint256 id = hub.requestBuy{value: 1_000e18 + 0.5 ether}(address(stock), 1_000e18, 1); // no LZ fee left
        scheduler.launchNext(id, abi.encode(uint256(0.5 ether), bytes("ok")));
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Funded));
        route.fill(0, 997_500_000);
        vm.startPrank(owner);
        hub.pause();
        vault.pause();
        vm.stopPrank();
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        vm.prank(user);
        hub.voidOrder{value: 0.01 ether}(id);
        _deliverLatestOrder();
        _deliverLatestResult();
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Returning));
        _returnAll(id, 997.1e18);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        assertEq(user.balance, before - 1_000.5 ether - 0.01 ether + 997.1e18 + FEE);
        assertEq(capacity.inflightUsd(), 0);
    }

    // ---------------------------------------------------------------- float lows

    function testFloatCancelThenFailedReleasesTheReservation() public {
        vm.prank(owner);
        hub.setFloatEnabled(true);
        hub.fundFloat{value: 5_000 ether}();
        uint256 id = _dispatchedBuy();
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id); // the float refunds now
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        venue.setFail(true);
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        _deliverLatestResult(); // Failed
        assertEq(capacity.inflightUsd(), 0, "the Failed result releases the reservation");
        assertEq(capacity.unreviewedUsd(), 0);
        uint256 floatBefore = hub.available();
        _returnAll(id, 997.5e18);
        assertEq(hub.available(), floatBefore + 997.5e18, "the returned principal refills the float");
    }

    // ---------------------------------------------------------------- second review (post-fix)

    /// H1: with the vault's optional float on, the vault may buy for a ref whose Relay funding was
    /// refunded to Arc. The principal then belongs to the reserve that advanced it, never to the user too.
    function testVaultFloatAdvanceAfterRelayRefundNeverPaysTheUserTwice() public {
        vm.prank(owner);
        vault.setFloatEnabled(true);
        usdg.mint(address(vault), 2_000e6); // free settlement float on the reserve chain
        uint256 before = user.balance;
        uint256 treasuryBefore = treasury.balance;
        uint256 id = _dispatchedBuy();
        route.refund(0, 997.2e18); // the Relay intent expired
        _deliverLatestOrder(); // the vault advances from its float and buys
        _deliverLatestResult();
        assertEq(token.balanceOf(user), 9.975e18, "the user has the stock");
        assertEq(user.balance, before - 1_001 ether + 0.49 ether, "and not the principal as well");
        assertEq(treasury.balance, treasuryBefore + 997.2e18, "the principal goes to the reserve's owner");
        assertEq(hub.escrowed(), 0);
    }

    /// M1: a small credit ahead of a Failed result is not the principal; the order keeps waiting and
    /// keeps its exits.
    function testDustBeforeFailedDoesNotCloseTheBuy() public {
        uint256 before = user.balance;
        venue.setFail(true);
        uint256 id = _dispatchedBuy();
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        route.deliverReturnFor{value: 1e12}(bytes32(id)); // e.g. a Relay surplus credit
        _deliverLatestResult(); // Failed
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Returning), "still waiting");
        vm.prank(attacker);
        vm.expectRevert(); // dust never lets a third party void a live order
        hub.voidOrder{value: 0.01 ether}(id);
        _returnAll(id, 997.1e18);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        assertEq(user.balance, before - 1_001 ether + 997.1e18 + 1e12 + FEE + 0.49 ether);
        assertEq(hub.escrowed(), 0);
    }

    function testDustBeforeSoldStillChargesTheFeeOnTheRealProceeds() public {
        _boughtOrder(1_000e18);
        uint256 before = user.balance;
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 990e18);
        _deliverLatestOrder();
        route.deliverReturnFor{value: 1e12}(bytes32(id));
        _deliverLatestResult(); // Sold
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Proceeds), "dust is not the proceeds");
        _returnAll(id, 997.2e18);
        uint256 fee = 2.49375e18;
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
        assertEq(user.balance, before - 0.01 ether + 997.2e18 + 1e12 - fee);
        assertEq(hub.accruedFees(), FEE + fee, "the full locked fee");
    }

    /// M2: one void per order is paid from its own reserve; repeats cost the caller, never the user.
    function testRepeatedVoidsCannotDrainTheOrderReserve() public {
        uint256 id = _dispatchedBuy();
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        uint256 extra = hub.getOrder(id).extra;
        vm.prank(attacker);
        hub.voidOrder(id); // fee from the order's reserve, once
        assertEq(hub.getOrder(id).extra, extra - 0.01 ether);
        vm.prank(attacker);
        vm.expectRevert();
        hub.voidOrder(id);
        vm.prank(attacker);
        hub.voidOrder{value: 0.01 ether}(id); // allowed only at the caller's cost
        assertEq(hub.getOrder(id).extra, extra - 0.01 ether);
    }

    /// M3: a Sold result the canonical lane already applied cannot be applied again by the stuck
    /// LayerZero copy after the proceeds were escalated.
    function testStuckLayerZeroSoldAfterCanonicalSettlementAndEscalationIsIgnored() public {
        vm.prank(owner);
        hub.setFloatEnabled(true); // on, but empty until after the escalation
        _boughtOrder(1_000e18);
        uint256 before = user.balance;
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 990e18);
        _deliverLatestOrder(); // sold; the LayerZero Sold is stuck
        uint256 stuck = rhEp.packetCount() - 1;
        uint256 index = _checkpointToArc();
        _reconcile(vault.resultCount() - 1, index); // canonical Sold applied: waiting for proceeds
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Proceeds));
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user);
        hub.escalateFunds{value: 1 ether + 2.49375e18}(id, rhUser); // hook + the locked sell fee (re-review L1)
        _deliverToReserve();
        assertEq(usdg.balanceOf(rhUser), 997_500_000, "proceeds delivered on the reserve chain");
        hub.fundFloat{value: 5_000 ether}();
        uint256 floatMid = hub.available();
        rhEp.deliver(stuck); // the stuck LayerZero copy of the same Sold
        assertEq(user.balance, before - 0.01 ether - 1 ether - 2.49375e18, "no second payout on Arc");
        assertEq(hub.available(), floatMid, "no float advance");
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Escalated));
    }

    // ---------------------------------------------------------------- fuzzed orderings

    /// Buy: money leg (fill or relay refund), order message, result, cancel request, dust bounce and
    /// principal return, in any order the seed picks; then everything outstanding is drained.
    function testFuzz_BuyReturnOrderingsNeverMisassign(uint256 seed, bool refundLeg, bool venueFails) public {
        venue.setFail(venueFails);
        uint256 before = user.balance;
        uint256 id = _dispatchedBuy();
        bool moneyDone;
        bool cancelled;
        uint256 dust;
        for (uint256 step; step < 8; ++step) {
            uint256 a = uint256(keccak256(abi.encode(seed, step))) % 6;
            if (a == 0 && !moneyDone) {
                moneyDone = true;
                if (refundLeg) route.refund(0, 997.2e18);
                else route.fill(0, 997_500_000);
            } else if (a == 1) {
                uint256[] memory p = _pendingPackets(true);
                if (p.length > 0) arcEp.deliver(p[0]);
            } else if (a == 2) {
                uint256[] memory p = _pendingPackets(false);
                if (p.length > 0) rhEp.deliver(p[0]);
            } else if (a == 3 && !cancelled) {
                cancelled = true;
                vm.warp(block.timestamp + 31 minutes);
                vm.prank(user);
                try hub.cancel(id) {} catch {}
            } else if (a == 4 && vault.settled(bytes32(id))) {
                _dustReturn(id);
                dust += 1e12;
            } else if (a == 5 && vault.settled(bytes32(id)) && vault.funding(bytes32(id)) > 0) {
                _returnOwed(id);
            }
        }
        _drainBuy(id, moneyDone, refundLeg);
        _assertBuyResolved(id, before, dust);
    }

    function _drainBuy(uint256 id, bool moneyDone, bool refundLeg) internal {
        if (!moneyDone) {
            if (refundLeg) route.refund(0, 997.2e18);
            else route.fill(0, 997_500_000);
        }
        _deliverAll();
        if (!vault.settled(bytes32(id)) || hub.getOrder(id).outcome == 0) {
            // Stuck: no money on the vault (refunded) or the order never reached it. Void and finish.
            HubSettlement.Order memory o = hub.getOrder(id);
            if (!o.cancelRequested && o.held == 0) {
                vm.warp(block.timestamp + 31 minutes);
                vm.prank(user);
                hub.cancel(id);
            }
            hub.voidOrder{value: 0.01 ether}(id);
            _deliverAll();
        }
        if (vault.funding(bytes32(id)) > 0) _returnOwed(id);
    }

    function _assertBuyResolved(uint256 id, uint256 before, uint256 dust) internal view {
        HubSettlement.Order memory o = hub.getOrder(id);
        assertEq(token.balanceOf(treasury), 0, "the treasury never takes a user's fill");
        assertEq(hub.escrowed(), 0, "nothing left in escrow");
        assertEq(hub.claimableTotal(), 0);
        assertEq(capacity.inflightUsd(), 0, "reservation finalized or released");
        assertEq(vault.settlementLiabilities(), 0, "the vault owes nothing");
        if (o.outcome == 1) {
            assertEq(uint8(o.status), uint8(HubSettlement.Status.Filled));
            assertEq(token.balanceOf(user), 9.975e18, "the user's stock");
            assertEq(hub.accruedFees(), FEE);
            assertLe(user.balance, before - 1_000 ether + dust, "stock, never also the principal");
        } else {
            assertEq(o.outcome, 3);
            assertEq(uint8(o.status), uint8(HubSettlement.Status.Cancelled));
            assertEq(token.balanceOf(user), 0);
            assertEq(hub.accruedFees(), 0, "no fee on an order that bought nothing");
            assertGe(user.balance, before - 2 ether, "principal back less route costs");
            assertLe(user.balance, before + dust, "never more than was paid in (plus donated dust)");
        }
    }

    /// Sell: order message, result and proceeds return in any order, with or without the float.
    function testFuzz_SellReturnOrderingsPayExactlyOnce(uint256 seed, bool float_) public {
        if (float_) {
            vm.prank(owner);
            hub.setFloatEnabled(true);
            hub.fundFloat{value: 5_000 ether}();
        }
        _boughtOrder(1_000e18);
        uint256 floatBefore = hub.available();
        uint256 before = user.balance;
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 990e18);
        uint256 dust;
        for (uint256 step; step < 6; ++step) {
            uint256 a = uint256(keccak256(abi.encode(seed, step))) % 4;
            if (a == 0) {
                uint256[] memory p = _pendingPackets(true);
                if (p.length > 0) arcEp.deliver(p[0]);
            } else if (a == 1) {
                uint256[] memory p = _pendingPackets(false);
                if (p.length > 0) rhEp.deliver(p[0]);
            } else if (a == 2 && vault.proceeds(bytes32(id)) > 0) {
                _returnOwed(id);
            } else if (a == 3 && vault.settled(bytes32(id))) {
                _dustReturn(id);
                dust += 1e12;
            }
        }
        _deliverAll();
        if (vault.proceeds(bytes32(id)) > 0) _returnOwed(id);
        HubSettlement.Order memory o = hub.getOrder(id);
        assertEq(uint8(o.status), uint8(HubSettlement.Status.Filled));
        uint256 fee = 2.49375e18;
        uint256 paid = user.balance + 0.01 ether - before;
        assertGe(paid, 997.5e18 - fee, "net proceeds, once");
        assertLe(paid, 997.5e18 - fee + dust, "never twice (at most the donated dust on top)");
        assertEq(hub.accruedFees(), FEE + fee);
        assertEq(hub.escrowed(), 0);
        assertGe(hub.available(), floatBefore, "any float advance is replenished");
        assertLe(hub.available(), floatBefore + dust, "(plus donated dust at most)");
        assertEq(capacity.exposureUsd(), 0);
    }
}

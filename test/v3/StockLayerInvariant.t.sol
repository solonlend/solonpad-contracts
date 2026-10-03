// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CanonicalBase} from "./Canonical.t.sol";
import {Messages} from "../../src/v3/stock/libs/Messages.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";

/// @notice Random walks over the whole two-chain stock layer (hub, capacity, scheduler, both money routes,
///         LayerZero both ways, reserve vault, canonical lane): buys, failed buys, sells, canonical
///         redemptions, donations and canonical reviews, each settled end to end — and (review p5 #2/#3)
///         the adversarial orders: relay refunds before any result, proceeds before Sold, a cancel plus a
///         dust bounce before a late Bought.
contract StockLayerHandler is Test {
    StockLayerInvariantTest internal suite;
    uint256 public calls;

    constructor(StockLayerInvariantTest s) {
        suite = s;
    }

    function buy(uint256 seed) external {
        ++calls;
        suite.actBuy(seed, false);
    }

    function failBuy(uint256 seed) external {
        ++calls;
        suite.actBuy(seed, true);
    }

    function sell(uint256 seed) external {
        ++calls;
        suite.actSell(seed);
    }

    function redeem(uint256 seed) external {
        ++calls;
        suite.actRedeem(seed);
    }

    function donate(uint256 seed) external {
        ++calls;
        suite.actDonate(seed);
    }

    function review() external {
        ++calls;
        suite.actReview();
    }

    function relayRefund(uint256 seed) external {
        ++calls;
        suite.actRelayRefundThenVoid(seed);
    }

    function proceedsFirst(uint256 seed) external {
        ++calls;
        suite.actSellProceedsBeforeResult(seed);
    }

    function cancelDustThenBought(uint256 seed) external {
        ++calls;
        suite.actCancelDustThenBought(seed);
    }
}

contract StockLayerInvariantTest is CanonicalBase {
    StockLayerHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new StockLayerHandler(this);
        vm.deal(user, 1e30);
        vm.deal(address(this), 1e30);
        arcUsdc.mint(address(gate), 1_000_000e6);
        ethUsdc.mint(address(bridger), 1_000_000e6);
        targetContract(address(handler));
    }

    // ------------------------------------------------------------ actions (called by the handler)

    function actBuy(uint256 seed, bool fail) external {
        uint256 usdcIn = bound(seed, 100e18, 1_000e18);
        uint256 principal = (usdcIn - usdcIn * 25 / 10_000) / 1e12 * 1e12;
        if (!capacity.canReserve(0, principal)) actReview();
        if (!capacity.canReserve(0, principal)) return;
        vm.prank(user);
        uint256 id = hub.requestBuy{value: usdcIn + 1 ether}(address(stock), usdcIn, 1);
        (bool found,, uint256 next) = scheduler.nextLaunch();
        if (!found || next != id) return;
        scheduler.launchNext(id, abi.encode(uint256(0.5 ether), bytes("ok")));
        venue.setFail(fail);
        route.fill(route.sentCount() - 1, principal / 1e12);
        _deliverLatestOrder();
        _deliverLatestResult();
        venue.setFail(false);
        if (fail) {
            vault.returnFunds(bytes32(id), 1, "ok");
            returnRoute.complete{value: principal - 0.2e18}(
                returnRoute.sentCount() - 1, payable(address(route)), principal - 0.2e18
            );
            assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        }
    }

    function actSell(uint256 seed) external {
        uint256 bal = token.balanceOf(user);
        if (bal == 0) return;
        uint256 shares = bound(seed, 1, bal);
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), shares, 0);
        _deliverLatestOrder();
        _deliverLatestResult();
        HubSettlement.Order memory o = hub.getOrder(id);
        if (o.status != HubSettlement.Status.Proceeds) return; // e.g. a zero-proceeds dust sale
        vault.returnFunds(bytes32(id), 1, "ok");
        uint256 owed = uint256(o.rawOut) * 1e12;
        returnRoute.complete{value: owed}(returnRoute.sentCount() - 1, payable(address(route)), owed);
    }

    function actRedeem(uint256 seed) external {
        uint256 bal = token.balanceOf(user);
        if (bal == 0) return;
        uint256 shares = bound(seed, 1, bal);
        vm.prank(user);
        hub.canonicalRedeem{value: 1 ether}(address(stock), shares, rhUser, Messages.DeliverMode(seed % 2));
        _deliverToReserve();
    }

    function _launchPublic(uint256 seed) internal returns (uint256 id, uint256 principal, bool ok) {
        uint256 usdcIn = bound(seed, 100e18, 1_000e18);
        principal = (usdcIn - usdcIn * 25 / 10_000) / 1e12 * 1e12;
        if (!capacity.canReserve(0, principal)) actReview();
        if (!capacity.canReserve(0, principal)) return (0, 0, false);
        vm.prank(user);
        id = hub.requestBuy{value: usdcIn + 1 ether}(address(stock), usdcIn, 1);
        (bool found,, uint256 next) = scheduler.nextLaunch();
        if (!found || next != id) return (id, principal, false);
        scheduler.launchNext(id, abi.encode(uint256(0.5 ether), bytes("ok")));
        ok = true;
    }

    function actRelayRefundThenVoid(uint256 seed) external {
        (uint256 id, uint256 principal, bool ok) = _launchPublic(seed);
        if (!ok) return;
        if (seed % 2 == 0) _deliverLatestOrder(); // the order may already wait on the vault
        route.refund(route.sentCount() - 1, principal - 0.3e18);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Dispatched), "held, not closed");
        hub.voidOrder{value: 0.01 ether}(id);
        _deliverLatestOrder();
        if (seed % 2 == 1) _deliverOrder(id); // the late original order is ignored
        _deliverLatestResult();
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
    }

    function _deliverOrder(uint256 id) internal {
        for (uint256 i; i < arcEp.packetCount(); ++i) {
            (,,,,, bool delivered) = arcEp.packets(i);
            if (!delivered && Messages.decodeOrder(arcEp.packetMessage(i)).ref == bytes32(id)) arcEp.deliver(i);
        }
    }

    function actSellProceedsBeforeResult(uint256 seed) external {
        uint256 bal = token.balanceOf(user);
        if (bal == 0) return;
        uint256 shares = bound(seed, 1, bal);
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), shares, 0);
        _deliverLatestOrder();
        uint256 owed = vault.proceeds(bytes32(id));
        if (owed > 0) {
            vault.returnFunds(bytes32(id), 1, "ok");
            returnRoute.complete{value: owed * 1e12}(returnRoute.sentCount() - 1, payable(address(route)), owed * 1e12);
        }
        _deliverLatestResult();
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
    }

    function actCancelDustThenBought(uint256 seed) external {
        (uint256 id, uint256 principal, bool ok) = _launchPublic(seed);
        if (!ok) return;
        route.fill(route.sentCount() - 1, principal / 1e12);
        _deliverLatestOrder();
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        usdg.mint(address(this), 1);
        usdg.approve(address(vault), 1);
        vault.fund(bytes32(id), 1);
        vault.returnFunds(bytes32(id), 0, "ok");
        returnRoute.complete{value: 1e12}(returnRoute.sentCount() - 1, payable(address(route)), 1e12);
        uint256 before = token.balanceOf(user);
        _deliverLatestResult();
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled), "the late fill stands");
        assertGt(token.balanceOf(user), before, "and goes to the user");
    }

    function actDonate(uint256 seed) external {
        stock.mint(address(vault), bound(seed, 0, 1e18));
    }

    function actReview() public {
        if (vault.resultCount() == vault.checkpointedThrough()) return;
        uint256 index = _checkpointToArc();
        Messages.Checkpoint memory c = gate.checkpointAt(index);
        for (uint256 seq = c.fromSeq; seq <= c.toSeq; ++seq) {
            Messages.Result memory r = vault.resultAt(seq);
            if (hub.reconciled(r.ref)) continue;
            try hub.reconcile(r, index, _proof(c.fromSeq, c.toSeq, seq)) {} catch {}
        }
    }

    // ------------------------------------------------------------ invariants

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    /// forge-config: deep.invariant.runs = 1000
    /// forge-config: deep.invariant.depth = 500
    /// forge-config: default.invariant.show-metrics = true
    function invariant_reserveCoversEntitledPlusClaimableRaw() public view {
        assertGe(
            vault.reserveOf(address(stock)),
            vault.entitledOf(address(stock)) + vault.claimableTotal(address(stock)),
            "R >= E + C"
        );
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    /// forge-config: deep.invariant.runs = 1000
    /// forge-config: deep.invariant.depth = 500
    function invariant_arcSupplyEqualsReserveEntitlementAndIssuedRaw() public view {
        assertEq(token.totalSupply(), vault.entitledOf(address(stock)), "1:1 raw, no unbacked mint");
        assertEq(capacity.issuedRaw(address(stock)), token.totalSupply(), "capacity tracks the same raw");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    /// forge-config: deep.invariant.runs = 1000
    /// forge-config: deep.invariant.depth = 500
    function invariant_moneyCoversEveryLiability() public view {
        assertGe(address(hub).balance, hub.escrowed() + hub.accruedFees() + hub.claimableTotal(), "hub");
        assertGe(usdg.balanceOf(address(vault)), vault.settlementLiabilities(), "vault USDG");
        assertEq(hub.escrowed(), 0, "every handler action settles end to end: nothing held");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    /// forge-config: deep.invariant.runs = 1000
    /// forge-config: deep.invariant.depth = 500
    function invariant_exposureWithinTheTotalCap() public view {
        assertLe(capacity.exposureUsd(), capacity.totalCap());
        assertEq(capacity.inflightUsd(), 0, "every handler action settles end to end");
    }
}

/// @notice Re-review: the asynchronous action set. Unlike `StockLayerHandler`, no action settles end to end:
///         orders, money legs, LayerZero packets in both directions and returns are left in flight and
///         delivered later in any order. Adds float on/off, pause/unpause, cancels, Relay refunds, voids,
///         `escalateFunds`, the reward lane (begin/submit/cancelReward/claim) and multiplier changes. After
///         every call: 1:1 backing and solvency on both chains, and the user's total wealth never grows
///         (no double pay). After every run: everything is drained through the public doors and every
///         capacity reservation must be released.
contract StockChaosHandler is Test {
    StockChaosInvariantTest internal suite;
    mapping(bytes4 => uint256) public hits;

    constructor(StockChaosInvariantTest s) {
        suite = s;
    }

    function buy(uint256 seed) external {
        ++hits[msg.sig];
        suite.cBuy(seed);
    }

    function launchNext() external {
        ++hits[msg.sig];
        suite.cLaunchNext();
    }

    function fill(uint256 seed) external {
        ++hits[msg.sig];
        suite.cFill(seed);
    }

    function relayRefund(uint256 seed) external {
        ++hits[msg.sig];
        suite.cRelayRefund(seed);
    }

    function deliverOrder(uint256 seed) external {
        ++hits[msg.sig];
        suite.cDeliver(true, seed);
    }

    function deliverResult(uint256 seed) external {
        ++hits[msg.sig];
        suite.cDeliver(false, seed);
    }

    function executeFunded(uint256 seed) external {
        ++hits[msg.sig];
        suite.cExecuteFunded(seed);
    }

    function returnFunds(uint256 seed) external {
        ++hits[msg.sig];
        suite.cReturnFunds(seed);
    }

    function completeReturn(uint256 seed, uint8 cut) external {
        ++hits[msg.sig];
        suite.cCompleteReturn(seed, cut);
    }

    function cancel(uint256 seed) external {
        ++hits[msg.sig];
        suite.cCancel(seed);
    }

    function voidOrder(uint256 seed) external {
        ++hits[msg.sig];
        suite.cVoid(seed);
    }

    function escalateFunds(uint256 seed) external {
        ++hits[msg.sig];
        suite.cEscalateFunds(seed);
    }

    function sell(uint256 seed) external {
        ++hits[msg.sig];
        suite.cSell(seed);
    }

    function redeem(uint256 seed) external {
        ++hits[msg.sig];
        suite.cRedeem(seed);
    }

    function setFloat(uint256 seed) external {
        ++hits[msg.sig];
        suite.cFloat(seed);
    }

    function setPaused(bool p) external {
        ++hits[msg.sig];
        suite.cPause(p);
    }

    function review() external {
        ++hits[msg.sig];
        suite.cReview();
    }

    function rewardBegin(uint256 seed) external {
        ++hits[msg.sig];
        suite.cRewardBegin(seed);
    }

    function rewardSubmit(uint256 seed) external {
        ++hits[msg.sig];
        suite.cRewardSubmit(seed);
    }

    function cancelReward(uint256 seed) external {
        ++hits[msg.sig];
        suite.cCancelReward(seed);
    }

    function rewardClaim(uint256 seed) external {
        ++hits[msg.sig];
        suite.cRewardClaim(seed);
    }

    function multiplier(uint256 seed) external {
        ++hits[msg.sig];
        suite.cMultiplier(seed);
    }

    function sellRace(uint256 seed, uint8 cut) external {
        ++hits[msg.sig];
        suite.cSellRace(seed, cut);
    }

    function cancelRace(uint256 seed) external {
        ++hits[msg.sig];
        suite.cCancelRace(seed);
    }
}

contract StockChaosInvariantTest is CanonicalBase {
    StockChaosHandler handler;
    uint256 wealth0;
    uint256 rewardNonce;
    bytes32[] rewardIds;
    mapping(bytes32 => uint256) rewardBudget;
    mapping(bytes32 => bool) rewardDone;
    uint256 public maxOrdersSeen;

    function setUp() public override {
        super.setUp();
        handler = new StockChaosHandler(this);
        vm.deal(user, 1e30);
        vm.deal(address(this), 1e30);
        arcUsdc.mint(address(gate), 1_000_000e6);
        ethUsdc.mint(address(bridger), 1_000_000e6);
        vm.startPrank(owner);
        hub.setRewardAdapter(address(this), true); // the suite plays the reward adapter
        hub.setGuardian(guardian);
        vm.stopPrank();
        vm.deal(owner, 1_000 ether); // the operator pays reward-lane voids it sends
        wealth0 = _wealth();
        targetContract(address(handler));
    }

    receive() external payable {}

    // ------------------------------------------------------------ helpers

    /// The user's total wealth at the venue's fixed $100 per share: Arc native + RH USDG + stock on both
    /// chains. Fees, route costs and LayerZero fees only ever lower it; a double payment would raise it.
    function _wealth() internal view returns (uint256) {
        return user.balance + usdg.balanceOf(rhUser) * 1e12 + (token.balanceOf(user) + stock.balanceOf(rhUser)) * 100;
    }

    /// Mostly an order that can still move (open, or refunded by the float and not yet answered).
    function _pick(uint256 seed) internal view returns (bool ok, uint256 id) {
        uint256 n = hub.orderCount();
        if (n == 0) return (false, 0);
        if (seed % 4 == 0) return (true, seed % n);
        for (uint256 k; k < n; ++k) {
            id = (seed % n + k) % n;
            HubSettlement.Order memory o = hub.getOrder(id);
            if (_open(o) || (o.advanced && o.status == HubSettlement.Status.Cancelled && o.outcome == 0)) {
                return (true, id);
            }
        }
        return (true, seed % n);
    }

    function _routeData() internal pure returns (bytes memory) {
        return abi.encode(uint256(0.5 ether), bytes("ok"));
    }

    function _open(HubSettlement.Order memory o) internal pure returns (bool) {
        return o.status == HubSettlement.Status.Pending || o.status == HubSettlement.Status.Funded
            || o.status == HubSettlement.Status.Dispatched || o.status == HubSettlement.Status.Returning
            || o.status == HubSettlement.Status.Proceeds;
    }

    // ------------------------------------------------------------ actions

    function cBuy(uint256 seed) external {
        uint256 usdcIn = bound(seed, 21e18, 2_000e18);
        vm.prank(user);
        try hub.requestBuy{value: usdcIn + 1 ether}(address(stock), usdcIn, 1) {} catch {}
        this.cLaunchNext();
    }

    function cLaunchNext() external {
        (bool found,, uint256 next) = scheduler.nextLaunch();
        if (found) {
            try scheduler.launchNext(next, _routeData()) {} catch {}
        }
    }

    function _undone(bool arcRoute, uint256 seed) internal view returns (bool ok, uint256 i) {
        uint256 n = arcRoute ? route.sentCount() : returnRoute.sentCount();
        for (uint256 k; k < n; ++k) {
            i = (seed % n + k) % n;
            bool done;
            if (arcRoute) (,,,, done) = route.sent(i);
            else (,,, done) = returnRoute.sent(i);
            if (!done) return (true, i);
        }
    }

    function cFill(uint256 seed) external {
        (bool ok, uint256 i) = _undone(true, seed);
        if (!ok) return;
        (, uint256 amountIn,,,) = route.sent(i);
        route.fill(i, amountIn / 1e12);
    }

    function cRelayRefund(uint256 seed) external {
        (bool ok, uint256 i) = _undone(true, seed);
        if (!ok) return;
        (, uint256 amountIn,,,) = route.sent(i);
        route.refund(i, amountIn - 0.3e18); // the intent expired; the refund costs a little
    }

    function cDeliver(bool toVault, uint256 seed) public {
        MockLzEndpointLike ep = MockLzEndpointLike(toVault ? address(arcEp) : address(rhEp));
        uint256 n = ep.packetCount();
        for (uint256 k; k < n; ++k) {
            uint256 i = (seed % n + k) % n;
            (,,,,, bool delivered) = ep.packets(i);
            if (delivered) continue;
            try ep.deliver(i) {}
            catch {
                // e.g. minting halted by a stale reconciliation: prove what we can and resume.
                this.cReview();
                vm.prank(owner);
                hub.resumeMints();
            }
            return;
        }
    }

    function cExecuteFunded(uint256 seed) external {
        (bool ok, uint256 id) = _pick(seed);
        if (ok) {
            try vault.executeFunded(bytes32(id)) {} catch {}
        }
    }

    function cReturnFunds(uint256 seed) external {
        (bool ok, uint256 id) = _pick(seed);
        if (ok) {
            try vault.returnFunds(bytes32(id), 0, "ok") {} catch {}
        }
    }

    /// cut 0: in full; 1: less a small cost; 2: a costly leg below half (held, never decisive).
    function cCompleteReturn(uint256 seed, uint8 cut) external {
        (bool ok, uint256 i) = _undone(false, seed);
        if (!ok) return;
        (, uint256 amount6,,) = returnRoute.sent(i);
        uint256 arrives = amount6 * 1e12;
        if (cut % 3 == 1) arrives -= arrives / 1_000;
        else if (cut % 3 == 2) arrives = arrives * 2 / 5;
        returnRoute.complete{value: arrives}(i, payable(address(route)), arrives);
    }

    function cCancel(uint256 seed) external {
        (bool ok, uint256 id) = _pick(seed);
        if (!ok) return;
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        try hub.cancel(id) {} catch {}
    }

    function cVoid(uint256 seed) external {
        (bool ok, uint256 id) = _pick(seed);
        if (!ok) return;
        uint256 fee = hub.quoteDispatch(id);
        try hub.voidOrder{value: fee}(id) {} catch {}
    }

    function cEscalateFunds(uint256 seed) public {
        (bool ok, uint256 id) = _pick(seed);
        if (!ok) return;
        _escalateFunds(id);
    }

    function _escalateFunds(uint256 id) internal returns (bool sent) {
        vm.warp(block.timestamp + 6 hours + 1);
        HubSettlement.Order memory o = hub.getOrder(id);
        uint256 fee = o.kind == HubSettlement.Kind.Sell && o.status == HubSettlement.Status.Proceeds ? o.fee : 0;
        vm.prank(user);
        try hub.escalateFunds{value: 1 ether + fee}(id, rhUser) {
            _deliverToReserve();
            sent = true;
        } catch {}
    }

    function cSell(uint256 seed) external {
        uint256 bal = token.balanceOf(user);
        if (bal == 0) return;
        uint256 shares = bound(seed, 1, bal);
        vm.prank(user);
        hub.requestSell{value: 0.01 ether}(address(stock), shares, 0);
    }

    function cRedeem(uint256 seed) external {
        uint256 bal = token.balanceOf(user);
        if (bal == 0) return;
        uint256 shares = bound(seed, 1, bal);
        vm.prank(user);
        try hub.canonicalRedeem{value: 1 ether}(address(stock), shares, rhUser, Messages.DeliverMode(seed % 2)) {
            _deliverToReserve();
        } catch {}
    }

    function cFloat(uint256 seed) external {
        bool on = seed % 3 != 0;
        vm.prank(owner);
        hub.setFloatEnabled(on);
        if (on && hub.available() < 3_000e18) hub.fundFloat{value: 5_000e18}();
    }

    /// A sell whose proceeds come back (in full, less a cost, or below half) before or after its result.
    function cSellRace(uint256 seed, uint8 cut) external {
        uint256 before = hub.orderCount();
        this.cSell(seed);
        if (hub.orderCount() == before) return;
        uint256 id = before;
        if (hub.getOrder(id).kind != HubSettlement.Kind.Sell) return;
        cDeliver(true, arcEp.packetCount() - 1);
        uint256 result = rhEp.packetCount() - 1; // the Sold (or Failed) result, now in flight
        uint256 order = seed % 3; // 0: result first; 1: money first, then the result; 2: money only
        if (order == 0) cDeliver(false, result);
        try vault.returnFunds(bytes32(id), 0, "ok") {
            this.cCompleteReturn(returnRoute.sentCount() - 1, cut);
        } catch {}
        if (order == 1) cDeliver(false, result);
    }

    /// A buy waiting on the vault whose owner cancels (the float refunds it when on) and whose Relay
    /// intent then expires or fills.
    function cCancelRace(uint256 seed) external {
        uint256 before = hub.orderCount();
        this.cBuy(seed);
        if (hub.orderCount() == before) return;
        uint256 id = before;
        HubSettlement.Order memory o = hub.getOrder(id);
        if (o.kind != HubSettlement.Kind.Buy || o.status != HubSettlement.Status.Dispatched) return;
        cDeliver(true, arcEp.packetCount() - 1);
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        try hub.cancel(id) {} catch {}
        uint256 i = route.sentCount() - 1; // launched, so this order's intent is the latest
        (bytes32 ref, uint256 amountIn,,, bool done) = route.sent(i);
        if (done || ref != bytes32(id)) return;
        if (seed % 2 == 0) route.refund(i, amountIn - 0.3e18);
        else route.fill(i, amountIn / 1e12);
    }

    function cPause(bool p) external {
        bool now_ = hub.paused();
        if (p == now_) return;
        vm.prank(p ? guardian : owner); // the guardian pauses, only the owner resumes
        if (p) hub.pause();
        else hub.unpause();
    }

    function cReview() public {
        if (vault.resultCount() == vault.checkpointedThrough()) return;
        uint256 index = _checkpointToArc();
        Messages.Checkpoint memory c = gate.checkpointAt(index);
        for (uint256 seq = c.fromSeq; seq <= c.toSeq; ++seq) {
            Messages.Result memory r = vault.resultAt(seq);
            if (hub.reconciled(r.ref)) continue;
            try hub.reconcile(r, index, _proof(c.fromSeq, c.toSeq, seq)) {} catch {}
        }
    }

    function cRewardBegin(uint256 seed) external {
        uint256 budget = bound(seed, 20e18, 1_000e18) / 1e12 * 1e12;
        if (!capacity.canReserve(1, budget)) return;
        bytes32 orderId = keccak256(abi.encode("reward", ++rewardNonce));
        vm.prank(_rewardManager());
        capacity.reserveFor(orderId, address(stock), budget);
        uint256 fees = budget * 25 / 10_000 + 1 ether; // service fee + Ops reserve for route and LayerZero
        try hub.beginFunding{value: budget + fees}(orderId, address(stock), budget, 1, address(this), RELAY) {
            rewardIds.push(orderId);
            rewardBudget[orderId] = budget;
        } catch {
            vm.prank(_rewardManager());
            capacity.releaseUnsent(orderId); // the RoundManager's cancelUnsent
        }
    }

    function _rewardAt(uint256 seed) internal view returns (bool ok, bytes32 orderId) {
        if (rewardIds.length == 0) return (false, 0);
        return (true, rewardIds[seed % rewardIds.length]);
    }

    function cRewardSubmit(uint256 seed) external {
        (bool ok, bytes32 orderId) = _rewardAt(seed);
        if (ok) {
            try hub.submitFundedBuy(orderId) {} catch {}
        }
    }

    function cCancelReward(uint256 seed) external {
        (bool ok, bytes32 orderId) = _rewardAt(seed);
        if (!ok) return;
        uint256 id = hub.orderCount(); // find the hub id: scan (reward ids are few)
        for (uint256 i; i < hub.orderCount(); ++i) {
            if (hub.getOrder(i).capKey == orderId) id = i;
        }
        vm.prank(owner);
        try hub.cancelReward(id) {} catch {}
    }

    function cRewardClaim(uint256 seed) public {
        (bool ok, bytes32 orderId) = _rewardAt(seed);
        if (ok) _claimReward(orderId);
    }

    function _claimReward(bytes32 orderId) internal {
        (uint8 st, uint256 raw, uint256 refund) = hub.claimResult(orderId, "");
        if (st == 0) return;
        assertFalse(rewardDone[orderId], "a reward order is handed over once");
        rewardDone[orderId] = true;
        if (st == 1) assertGt(raw, 0, "shares");
        else assertEq(refund, rewardBudget[orderId], "a reward refund is the exact budget");
    }

    function cMultiplier(uint256 seed) external {
        stock.setMultiplier(bound(seed, 0.5e18, 4e18)); // a corporate action: display only, raw never changes
    }

    // ------------------------------------------------------------ invariants

    function _backing() internal view {
        uint256 supply = token.totalSupply();
        uint256 entitled = vault.entitledOf(address(stock));
        uint256 free = vault.reserveOf(address(stock)) - vault.claimableTotal(address(stock));
        assertLe(supply, entitled, "Arc supply <= RH entitlement");
        assertLe(entitled, free, "RH entitlement <= RH holdings not owed elsewhere");
        uint256 m = stock.uiMultiplier();
        assertLe(supply * m / 1e18, free * m / 1e18, "same in display units under the multiplier");
        assertEq(capacity.issuedRaw(address(stock)), supply, "capacity tracks the same raw");
    }

    function _solvency() internal view {
        assertGe(address(hub).balance, hub.escrowed() + hub.accruedFees() + hub.claimableTotal(), "hub");
        assertGe(usdg.balanceOf(address(vault)), vault.settlementLiabilities(), "vault USDG");
        assertLe(capacity.exposureUsd(), capacity.totalCap(), "total cap");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: deep.invariant.runs = 1000
    /// forge-config: deep.invariant.depth = 150
    /// forge-config: default.invariant.show-metrics = true
    function invariant_chaosBackingSolvencyNoDoublePay() public view {
        _backing();
        _solvency();
        assertLe(_wealth(), wealth0, "the user is never paid twice");
    }

    /// End of every run: drain through the public doors only. Every reservation must be releasable.
    function afterInvariant() public {
        vm.startPrank(owner);
        if (hub.paused()) hub.unpause();
        if (hub.mintsHalted()) hub.resumeMints();
        vm.stopPrank();
        for (uint256 round; round < 6; ++round) {
            _drainRound();
        }
        uint256 n = hub.orderCount();
        for (uint256 id; id < n; ++id) {
            HubSettlement.Order memory o = hub.getOrder(id);
            assertFalse(_open(o), "every order reached a final state");
        }
        for (uint256 i; i < rewardIds.length; ++i) {
            _claimReward(rewardIds[i]);
        }
        cReview();
        assertEq(capacity.inflightUsd(), 0, "every reservation released or issued");
        assertEq(capacity.redeemingUsd(), 0, "every redemption settled");
        assertEq(capacity.unreviewedUsd(), 0, "everything proven canonically");
        assertEq(hub.escrowed(), 0, "nothing stranded in escrow");
        assertEq(hub.claimableTotal(), 0);
        assertEq(vault.settlementLiabilities(), 0, "the vault owes nothing");
        _backing();
        _solvency();
        assertLe(_wealth(), wealth0, "no double pay after the drain");
        if (n > maxOrdersSeen) maxOrdersSeen = n;
    }

    function _drainRound() internal {
        // Launch everything queued; a public head that cannot launch is cancelled by its owner.
        for (uint256 k; k < 64; ++k) {
            (bool found,, uint256 next) = scheduler.nextLaunch();
            if (!found) break;
            try scheduler.launchNext(next, _routeData()) {}
            catch {
                break;
            }
        }
        uint256 n = hub.orderCount();
        vm.warp(block.timestamp + 31 minutes);
        for (uint256 id; id < n; ++id) {
            HubSettlement.Order memory o = hub.getOrder(id);
            if (o.status == HubSettlement.Status.Pending && o.kind == HubSettlement.Kind.Buy) {
                vm.prank(o.lane == 0 ? user : owner);
                if (o.lane == 0) {
                    try hub.cancel(id) {} catch {}
                } else {
                    try hub.cancelReward(id) {} catch {}
                }
            }
        }
        // Money legs still in flight land (solver fills); every LayerZero packet is delivered.
        for (uint256 i; i < route.sentCount(); ++i) {
            (, uint256 amountIn,,, bool done) = route.sent(i);
            if (!done) route.fill(i, amountIn / 1e12);
        }
        _deliverEverything();
        for (uint256 id; id < n; ++id) {
            HubSettlement.Order memory o = hub.getOrder(id);
            if (o.lane == 1 && o.status == HubSettlement.Status.Funded) {
                try hub.submitFundedBuy(o.capKey) {} catch {}
            } else if (o.kind == HubSettlement.Kind.Sell && o.status == HubSettlement.Status.Pending) {
                try hub.dispatch{value: 0.01 ether}(id) {} catch {}
            }
            try vault.executeFunded(bytes32(id)) {} catch {}
        }
        _deliverEverything();
        // Unanswered buys: cancel and void (the operator for the reward lane).
        vm.warp(block.timestamp + 31 minutes);
        for (uint256 id; id < n; ++id) {
            HubSettlement.Order memory o = hub.getOrder(id);
            bool floatRefunded = o.advanced && o.status == HubSettlement.Status.Cancelled;
            bool unanswered = o.status == HubSettlement.Status.Funded || o.status == HubSettlement.Status.Dispatched;
            if (o.kind != HubSettlement.Kind.Buy || o.outcome != 0 || !(unanswered || floatRefunded)) continue;
            if (o.lane == 0 && !o.cancelRequested) {
                vm.prank(user);
                try hub.cancel(id) {} catch {}
            }
            uint256 fee = hub.quoteDispatch(id);
            vm.prank(o.lane == 1 ? owner : address(this));
            try hub.voidOrder{value: fee}(id) {} catch {}
        }
        _deliverEverything();
        // Everything owed on RH comes back in full.
        for (uint256 id; id < n; ++id) {
            try vault.returnFunds(bytes32(id), 0, "ok") {} catch {}
        }
        for (uint256 i; i < returnRoute.sentCount(); ++i) {
            (, uint256 amount6,, bool done) = returnRoute.sent(i);
            if (!done) returnRoute.complete{value: amount6 * 1e12}(i, payable(address(route)), amount6 * 1e12);
        }
        // What only came back in part waits for its canonical door; reward shortfalls are subsidized.
        for (uint256 id; id < n; ++id) {
            HubSettlement.Order memory o = hub.getOrder(id);
            if (o.status != HubSettlement.Status.Returning && o.status != HubSettlement.Status.Proceeds) continue;
            if (o.lane == 1) {
                hub.subsidize{value: o.amountIn}(id);
            } else {
                _escalateFunds(id);
            }
        }
        cReview();
    }

    function _deliverEverything() internal {
        for (uint256 pass; pass < 4; ++pass) {
            for (uint256 i; i < arcEp.packetCount(); ++i) {
                (,,,,, bool d) = arcEp.packets(i);
                if (!d) {
                    try arcEp.deliver(i) {} catch {}
                }
            }
            for (uint256 i; i < rhEp.packetCount(); ++i) {
                (,,,,, bool d) = rhEp.packets(i);
                if (d) continue;
                try rhEp.deliver(i) {}
                catch {
                    cReview();
                    vm.prank(owner);
                    hub.resumeMints();
                    try rhEp.deliver(i) {} catch {}
                }
            }
        }
    }
}

interface MockLzEndpointLike {
    function packetCount() external view returns (uint256);
    function packets(uint256) external view returns (uint32, bytes32, address, bytes memory, uint64, bool);
    function deliver(uint256) external;
}

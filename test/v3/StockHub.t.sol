// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FloorOracleStub, FLOOR_ORACLE} from "./helpers/OracleMocks.sol";

import {Test} from "forge-std/Test.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {SolonStockToken} from "../../src/v3/stock/SolonStockToken.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";
import {OrderScheduler} from "../../src/v3/stock/OrderScheduler.sol";
import {Messages} from "../../src/v3/stock/libs/Messages.sol";
import {SolonStockAdapter} from "../../src/v3/adapters/SolonStockAdapter.sol";
import {MockLzEndpoint, MockNativeRoute, MockUSDG} from "./helpers/StockMocks.sol";

contract RejectNative {
    receive() external payable {
        revert("no");
    }
}

abstract contract StockHubBase is Test {
    uint32 constant ARC_EID = 30417;
    uint32 constant RH_EID = 30416;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    bytes32 constant RELAY = keccak256("RELAY");

    MockLzEndpoint arcEp;
    SolonStockHub hub;
    CapacityController capacity;
    OrderScheduler scheduler;
    MockNativeRoute route;
    MockUSDG usdg;
    SolonStockToken token;

    address owner = address(0xA11CE);
    address guardian = address(0x6A2D);
    address treasury = address(0x7EA5);
    address ops = address(0x0B5);
    address floatA = address(0xF1);
    address floatB = address(0xF2);
    address rewardManager = address(0x4E3);
    address vaultPeer = address(0x7A017);
    address user = address(0xB0B);

    function setUp() public virtual {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        arcEp = new MockLzEndpoint(ARC_EID);
        hub = new SolonStockHub(address(arcEp), treasury, 25, owner, ops, [floatA, floatB]);
        capacity = new CapacityController(owner, guardian);
        scheduler = new OrderScheduler(address(hub), capacity);
        usdg = new MockUSDG();
        route = new MockNativeRoute(address(hub), vaultPeer, usdg);
        vm.startPrank(owner);
        capacity.bind(address(hub), rewardManager);
        hub.setCapacity(capacity, scheduler);
        hub.setPeer(RH_EID, bytes32(uint256(uint160(vaultPeer))));
        token = hub.listStock(NVDA, "NVDA", RH_EID, 4663, 1_000_000e18, address(route), RELAY);
        hub.setGuardian(guardian);
        vm.stopPrank();
        vm.deal(user, 100_000 ether);
    }

    function _routeData(uint256 fee) internal pure returns (bytes memory) {
        return abi.encode(fee, bytes("ok"));
    }

    function _result(uint256 id, Messages.Outcome outcome, uint128 amountIn, uint128 amountOut) internal {
        Messages.Result memory r = Messages.Result(bytes32(id), NVDA, outcome, amountIn, amountOut, 0);
        arcEp.inject(RH_EID, vaultPeer, address(hub), Messages.encode(r));
    }

    function _buy(uint256 usdcIn, uint256 minShares, uint256 extra) internal returns (uint256 id) {
        vm.prank(user);
        id = hub.requestBuy{value: usdcIn + extra}(NVDA, usdcIn, minShares);
    }

    function _launch(uint256 id, uint256 routeFee) internal {
        scheduler.launchNext(id, _routeData(routeFee));
    }

    function _filledBuy(uint256 shares) internal returns (uint256 id) {
        id = _buy(1_000e18, 1, 1 ether);
        _launch(id, 0.5 ether);
        _result(id, Messages.Outcome.Bought, 997_500_000, uint128(shares));
    }
}

contract StockHubTest is StockHubBase {
    /// @dev r7 per-asset cap on the hub's public path: NVDA at its cap is refunded at launch (the queue does not
    ///      stall behind it), while the asset exposure tracks the reservation.
    function testPublicBuyOverItsAssetCapIsRefundedAtLaunch() public {
        vm.prank(owner);
        capacity.setAssetCap(NVDA, 1_500e18);
        uint256 a = _buy(1_000e18, 1, 1 ether);
        _launch(a, 0.5 ether);
        assertEq(capacity.assetExposureUsd(NVDA), 997.5e18, "reserved against NVDA");
        uint256 b = _buy(1_000e18, 1, 1 ether);
        uint256 before = user.balance;
        _launch(b, 0.5 ether);
        HubSettlement.Order memory o = hub.getOrder(b);
        assertEq(uint8(o.status), uint8(HubSettlement.Status.Cancelled));
        assertEq(user.balance, before + 1_001e18, "principal, fee and reserve back");
        assertEq(capacity.assetExposureUsd(NVDA), 997.5e18);
        _result(a, Messages.Outcome.Bought, 997_500_000, 5e18);
        assertEq(capacity.issuedUsdOf(NVDA), 997.5e18);
        assertEq(capacity.inflightUsdOf(NVDA), 0);
    }

    function testTokenIsSolonNamedAndMintsRawOneToOne() public {
        assertEq(token.name(), "Solon NVDA");
        assertEq(token.symbol(), "NVDA.sol");
        assertEq(token.decimals(), 18);
        assertEq(token.underlying(), NVDA);
        assertEq(token.reserveChainId(), 4663);
        assertEq(token.hub(), address(hub));
        _filledBuy(9.975e18 + 3);
        assertEq(token.balanceOf(user), 9.975e18 + 3, "raw result is minted unit for unit");
        assertEq(token.totalSupply(), 9.975e18 + 3);
        vm.expectRevert(SolonStockToken.NotHub.selector);
        token.mint(user, 1);
    }

    function testFuzz_BuySplitsIntoWholeMicroPrincipalAndLockedFee(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, 20.1e18, 1_002e18); // at least the $20 minimum principal (re-review L3)
        vm.prank(user);
        uint256 id = hub.requestBuy{value: usdcIn}(NVDA, usdcIn, 1);
        HubSettlement.Order memory o = hub.getOrder(id);
        assertEq(o.amountIn + o.fee, usdcIn, "nothing created or lost");
        assertEq(o.amountIn % 1e12, 0, "principal is a whole 6-dp USDG amount");
        assertGe(o.fee, usdcIn * 25 / 10_000, "at least 25 bps");
        assertLt(o.fee, usdcIn * 25 / 10_000 + 1e12, "dust below one micro-dollar only");
        assertEq(hub.escrowed(), usdcIn);
    }

    function testBuyFeeIsTwentyFiveBpsAndLockedOnTheOrder() public {
        uint256 a = _buy(1_000e18, 1, 1 ether);
        HubSettlement.Order memory o = hub.getOrder(a);
        assertEq(o.fee, 2.5e18);
        assertEq(o.amountIn, 997.5e18);
        assertEq(o.feeBps, 25);
        vm.prank(owner);
        vm.expectRevert(SolonStockHub.FeeTooHigh.selector);
        hub.lowerFees(30, 25); // raising is a new version, never an in-place change
        vm.prank(owner);
        hub.lowerFees(10, 10);
        uint256 b = _buy(1_000e18, 1, 1 ether);
        assertEq(hub.getOrder(b).fee, 1e18);
        _launch(a, 0.5 ether);
        _result(a, Messages.Outcome.Bought, 997_500_000, 9e18);
        assertEq(hub.accruedFees(), 2.5e18, "old order keeps the fee it was placed with");
    }

    function testSellFeeLockedAtRequestNotAtSettlement() public {
        _filledBuy(10e18);
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(NVDA, 10e18, 990e18);
        vm.prank(owner);
        hub.lowerFees(0, 0);
        _result(id, Messages.Outcome.Sold, 10e18, 1_000e6);
        HubSettlement.Order memory o = hub.getOrder(id);
        assertEq(o.fee, 2.5e18, "25 bps of the 1,000 USDC gross");
        assertEq(o.amountOut, 997.5e18);
    }

    function testSequentialLaunchSendsPrincipalThenTheOriginalOrderMessage() public {
        uint256 id = _buy(1_000e18, 9e18, 1 ether);
        assertEq(route.sentCount(), 0, "nothing leaves before the scheduler launches it");
        assertEq(arcEp.packetCount(), 0);
        assertEq(capacity.inflightUsd(), 0);
        _launch(id, 0.5 ether);
        (bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut,) = route.sent(0);
        assertEq(ref, bytes32(id));
        assertEq(amountIn, 997.5e18);
        assertEq(fee, 0.5 ether);
        assertEq(minOut, 997_500_000, "the whole principal must arrive as USDG");
        assertEq(address(route).balance, 997.5e18 + 0.5 ether);
        assertEq(capacity.inflightUsd(), 997.5e18);
        assertEq(arcEp.packetCount(), 1);
        Messages.Order memory m = Messages.decodeOrder(arcEp.packetMessage(0));
        assertEq(m.ref, bytes32(id));
        assertEq(m.underlying, NVDA);
        assertEq(uint8(m.side), uint8(Messages.Side.Buy));
        assertEq(m.amountIn, 997_500_000);
        assertEq(m.minOut, 9e18);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Dispatched));
    }

    function testBoughtSettlesFeesAndReturnsUnusedExtra() public {
        uint256 before = user.balance;
        uint256 id = _filledBuy(9e18);
        assertEq(hub.accruedFees(), 2.5e18);
        // 1 ether extra - 0.5 route - 0.01 LayerZero comes back.
        assertEq(user.balance, before - 1_000e18 - 1 ether + 0.49 ether);
        assertEq(hub.escrowed(), 0);
        assertEq(capacity.issuedRaw(NVDA), 9e18);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
    }

    function testZeroFloatSellWaitsForProceedsThenPaysOnlyThatOrder() public {
        _filledBuy(10e18);
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(NVDA, 10e18, 990e18);
        assertEq(token.balanceOf(user), 0);
        uint256 before = user.balance;
        _result(id, Messages.Outcome.Sold, 10e18, 1_000e6);
        assertEq(user.balance, before, "zero float: nothing is paid before the proceeds return");
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Proceeds));
        // Proceeds bridge back net of the route cost (0.4 USDC).
        vm.deal(address(this), 1_000 ether);
        route.deliverReturnFor{value: 999.6e18}(bytes32(id));
        assertEq(user.balance, before + 999.6e18 - 2.5e18);
        assertEq(hub.accruedFees(), 2.5e18 + 2.5e18);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
        assertEq(capacity.exposureUsd(), 0, "final redemption releases the exposure");
    }

    function testReturnsAreOnlyAcceptedFromTheOrdersRoute() public {
        uint256 id = _buy(1_000e18, 1, 1 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(SolonStockHub.NotRoute.selector);
        hub.receiveReturn{value: 1 ether}(bytes32(id));
    }

    function testQueuedCancelNeedsThirtyMinutesThenRefundsEverything() public {
        uint256 before = user.balance;
        uint256 id = _buy(1_000e18, 1, 1 ether);
        vm.warp(block.timestamp + 30 minutes - 1);
        vm.prank(user);
        vm.expectRevert();
        hub.cancel(id);
        vm.warp(block.timestamp + 1);
        vm.prank(user);
        hub.cancel(id);
        assertEq(user.balance, before);
        assertEq(hub.escrowed(), 0);
        (bool found,,) = scheduler.nextLaunch();
        assertFalse(found, "cancelled entries are skipped");
    }

    function testDispatchedCancelOnlyRequestsUntilPrincipalActuallyReturns() public {
        uint256 before = user.balance;
        uint256 id = _buy(1_000e18, 1, 1 ether);
        _launch(id, 0.5 ether);
        vm.warp(block.timestamp + 29 minutes);
        vm.prank(user);
        vm.expectRevert();
        hub.cancel(id);
        vm.warp(block.timestamp + 1 minutes);
        vm.prank(user);
        hub.cancel(id);
        HubSettlement.Order memory o = hub.getOrder(id);
        assertTrue(o.cancelRequested);
        assertEq(uint8(o.status), uint8(HubSettlement.Status.Dispatched));
        assertEq(user.balance, before - 1_001 ether, "no Arc float pays a refund before the money is back");
        assertEq(capacity.inflightUsd(), 997.5e18, "unknown RH outcome keeps the reservation");
        // The intent expired: the source-side refund arrives net of 0.3 USDC. It is only held: nothing
        // yet proves the vault will not buy (review #2/#3).
        route.refund(0, 997.2e18);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Dispatched));
        assertEq(hub.getOrder(id).held, 997.2e18);
        assertEq(capacity.inflightUsd(), 997.5e18);
        // A void closes the ref on the vault; its Failed answer releases and refunds.
        hub.voidOrder{value: 0.01 ether}(id);
        Messages.Order memory v = Messages.decodeOrder(arcEp.packetMessage(arcEp.packetCount() - 1));
        assertEq(v.amountIn, 0, "the void is a zero-amount order for the same ref");
        assertEq(v.ref, bytes32(id));
        _result(id, Messages.Outcome.Failed, 0, 0);
        assertEq(user.balance, before - 0.5 ether - 0.01 ether - 0.3 ether);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        assertEq(capacity.inflightUsd(), 0);
        assertEq(hub.escrowed(), 0);
    }

    function testLateFillAfterUnrefundedCancelRequestStillBelongsToTheOrder() public {
        uint256 id = _buy(1_000e18, 1, 1 ether);
        _launch(id, 0.5 ether);
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        _result(id, Messages.Outcome.Bought, 997_500_000, 9e18);
        assertEq(token.balanceOf(user), 9e18);
        assertEq(token.balanceOf(treasury), 0);
    }

    function testAccelerationFloatRefundsNowAndOrphansTheLateFillToTreasury() public {
        vm.prank(owner);
        hub.setFloatEnabled(true);
        hub.fundFloat{value: 2_000 ether}();
        uint256 before = user.balance;
        uint256 id = _buy(1_000e18, 1, 1 ether);
        _launch(id, 0.5 ether);
        vm.warp(block.timestamp + 31 minutes);
        vm.prank(user);
        hub.cancel(id);
        assertEq(user.balance, before - 0.51 ether, "float advances the principal");
        _result(id, Messages.Outcome.Bought, 997_500_000, 9e18);
        assertEq(token.balanceOf(treasury), 9e18, "the user was already refunded");
        assertEq(token.balanceOf(user), 0);
        assertEq(capacity.issuedRaw(NVDA), 9e18);
    }

    function testFloatNeverAdvancesAnUndispatchedBuy() public {
        vm.prank(owner);
        hub.setFloatEnabled(true);
        hub.fundFloat{value: 2_000 ether}();
        uint256 id = _buy(1_000e18, 1, 0.5 ether); // reserve covers the route only: funded, not dispatched
        _launch(id, 0.5 ether);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Funded));
        vm.warp(block.timestamp + 31 minutes);
        uint256 before = user.balance;
        vm.prank(user);
        hub.cancel(id);
        assertEq(user.balance, before, "an order the vault never received cannot be orphaned later");
        assertTrue(hub.getOrder(id).cancelRequested);
        hub.dispatch{value: 0.01 ether}(id); // anyone may still send it; its fill belongs to the user
        _result(id, Messages.Outcome.Bought, 997_500_000, 9e18);
        assertEq(token.balanceOf(user), 9e18);
    }

    function testPauseStopsLaunchesAndBuyDispatchButNeverSells() public {
        _filledBuy(10e18);
        uint256 a = _buy(1_000e18, 1, 0.5 ether);
        vm.prank(guardian);
        hub.pause();
        vm.expectRevert();
        scheduler.launchNext(a, _routeData(0.5 ether));
        vm.prank(owner);
        hub.unpause();
        _launch(a, 0.5 ether); // funded, not dispatched
        vm.prank(guardian);
        hub.pause();
        vm.expectRevert();
        hub.dispatch{value: 0.01 ether}(a);
        vm.prank(user);
        uint256 s = hub.requestSell(NVDA, 1e18, 1);
        hub.dispatch{value: 0.01 ether}(s); // exits are never paused
        assertEq(uint8(hub.getOrder(s).status), uint8(HubSettlement.Status.Dispatched));
    }

    function testDuplicateAndForgedResultsMintNothing() public {
        uint256 id = _filledBuy(9e18);
        _result(id, Messages.Outcome.Bought, 997_500_000, 9e18);
        assertEq(token.totalSupply(), 9e18, "a replayed result is ignored");
        Messages.Result memory r = Messages.Result(bytes32(id), NVDA, Messages.Outcome.Bought, 1, 5e18, 0);
        vm.expectRevert();
        arcEp.inject(RH_EID, address(0xBAD), address(hub), Messages.encode(r));
        vm.expectRevert();
        arcEp.inject(ARC_EID, vaultPeer, address(hub), Messages.encode(r));
        assertEq(token.totalSupply(), 9e18);
    }

    function testOldOrderKeepsItsRouteAndLimitAcrossConfigChanges() public {
        uint256 id = _buy(1_000e18, 9e18, 1 ether);
        MockNativeRoute other = new MockNativeRoute(address(hub), vaultPeer, usdg);
        vm.prank(owner);
        hub.proposeRoute(NVDA, address(other));
        vm.prank(owner);
        vm.expectRevert();
        hub.executeRoute(NVDA);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        hub.executeRoute(NVDA);
        _launch(id, 0.5 ether);
        assertEq(route.sentCount(), 1, "placed under the old route, launched on it");
        assertEq(other.sentCount(), 0);
        assertEq(Messages.decodeOrder(arcEp.packetMessage(0)).minOut, 9e18);
        uint256 b = _buy(1_000e18, 1, 1 ether);
        _launch(b, 0.5 ether);
        assertEq(other.sentCount(), 1, "new orders use the new route");
    }

    function testLaunchWithoutEnoughFeeReserveRefundsInsteadOfBlockingTheQueue() public {
        uint256 before = user.balance;
        uint256 a = _buy(1_000e18, 1, 0.1 ether);
        uint256 b = _buy(1_000e18, 1, 1 ether);
        _launch(a, 0.5 ether);
        assertEq(uint8(hub.getOrder(a).status), uint8(HubSettlement.Status.Cancelled));
        assertEq(route.sentCount(), 0);
        _launch(b, 0.5 ether);
        assertEq(route.sentCount(), 1);
        assertEq(user.balance, before - 1_001 ether);
    }

    function testPublicOrderAboveSingleOrderLimitIsRejected() public {
        vm.prank(user);
        vm.expectRevert(CapacityController.RunLimit.selector);
        hub.requestBuy{value: 10_040 ether}(NVDA, 10_030e18, 1); // principal 10,004.925 > $10,000
    }

    function testSellFailedRemintsAndRestoresExposure() public {
        _filledBuy(10e18);
        uint256 exposure = capacity.exposureUsd();
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(NVDA, 4e18, 1);
        _result(id, Messages.Outcome.Failed, 4e18, 0);
        assertEq(token.balanceOf(user), 10e18);
        assertEq(capacity.exposureUsd(), exposure);
    }

    function testBuyFailedWaitsForPrincipalThenRefundsAndReleases() public {
        uint256 before = user.balance;
        uint256 id = _buy(1_000e18, 1, 1 ether);
        _launch(id, 0.5 ether);
        _result(id, Messages.Outcome.Failed, 997_500_000, 0);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Returning));
        assertEq(capacity.inflightUsd(), 0, "a verified Failed proves RH owes no stock");
        vm.deal(address(this), 1_000 ether);
        route.deliverReturnFor{value: 997e18}(bytes32(id));
        assertEq(user.balance, before - 1_001 ether + 997e18 + 2.5e18 + 0.49 ether);
    }

    function testOwedStaysPerOrderAndCannotBeVoidedWithoutDispute() public {
        RejectNative rejecter = new RejectNative();
        vm.deal(address(rejecter), 2_000 ether);
        vm.prank(address(rejecter));
        uint256 id = hub.requestBuy{value: 1_001 ether}(NVDA, 1_000e18, 1);
        _launch(id, 0.5 ether);
        _result(id, Messages.Outcome.Bought, 997_500_000, 9e18);
        uint256 owed = hub.getOrder(id).owed;
        assertEq(owed, 0.49 ether, "the unused extra waits per order");
        // Not disputed: even the timelock cannot strike it (the disputed path is in Canonical.t.sol).
        vm.prank(owner);
        vm.expectRevert();
        hub.voidClaimable(id, owed, keccak256("evidence"));
        vm.prank(address(rejecter));
        vm.expectRevert();
        hub.claim(id); // still rejects native
        assertEq(hub.getOrder(id).owed, owed);
    }

    function testFloatWithdrawalsOnlyToFixedDestinations() public {
        hub.fundFloat{value: 10 ether}();
        vm.prank(owner);
        vm.expectRevert(SolonStockHub.NotFloatRecipient.selector);
        hub.withdrawFloat(address(0xEE), 1 ether);
        vm.prank(owner);
        hub.withdrawFloat(floatA, 1 ether);
        assertEq(floatA.balance, 1 ether);
        uint256 id = _buy(1_000e18, 1, 1 ether);
        id;
        vm.prank(owner);
        vm.expectRevert();
        hub.withdrawFloat(floatB, 10 ether); // escrow is never float
    }

    function testGuardianPausesNewBuysAndTradingButNotExits() public {
        _filledBuy(10e18);
        vm.prank(guardian);
        hub.pause();
        vm.prank(user);
        vm.expectRevert();
        hub.requestBuy{value: 1_001 ether}(NVDA, 1_000e18, 1);
        vm.prank(user);
        hub.requestSell{value: 0.01 ether}(NVDA, 1e18, 1);
        vm.prank(guardian);
        hub.setTradingPaused(NVDA, true);
        (bool open, bool transferable, uint256 version) = hub.stockState(address(token));
        assertFalse(open);
        assertFalse(transferable);
        assertEq(version, 1);
        vm.prank(guardian);
        vm.expectRevert();
        hub.setTradingPaused(NVDA, false); // only the owner (timelock) restores
        vm.prank(guardian);
        vm.expectRevert();
        hub.unpause();
    }

    function testRouteAndPeerChangesNeedFortyEightHours() public {
        vm.prank(owner);
        vm.expectRevert(SolonStockHub.Timelocked.selector);
        hub.setPeer(RH_EID, bytes32(uint256(1)));
        vm.prank(owner);
        hub.proposePeer(RH_EID, bytes32(uint256(1)));
        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(owner);
        vm.expectRevert(SolonStockHub.Timelocked.selector);
        hub.executePeer(RH_EID);
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        hub.executePeer(RH_EID);
        assertEq(hub.peers(RH_EID), bytes32(uint256(1)));
    }
}

contract StockHubRewardLaneTest is StockHubBase {
    SolonStockAdapter adapter;
    uint256 key = 0xA11;
    address rewardVault = address(0x5A7E);
    bytes32 orderId = keccak256("round-1");

    function setUp() public override {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        super.setUp();
        adapter = new SolonStockAdapter(
            SolonStockAdapter.Config(
                address(this), rewardVault, address(token), NVDA, address(hub), vm.addr(key), RELAY, 4663, ops,
                FLOOR_ORACLE
            )
        );
        vm.prank(owner);
        hub.setRewardAdapter(address(adapter), true);
        vm.deal(address(this), 10_000 ether);
    }

    function _quote(uint256 budget) internal view returns (bytes memory) {
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(orderId, budget, 1e18, block.timestamp + 60, 1, (budget * 25) / 10_000 + 0.4 ether, 0.4 ether); // r12: hub 25 bps + external
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, adapter.quoteDigest(q));
        return abi.encode(q, abi.encodePacked(r, s, v));
    }

    function _start(uint256 budget) internal returns (uint256 id) {
        vm.prank(rewardManager);
        capacity.reserveFor(orderId, NVDA, budget);
        adapter.depositFees{value: (budget * 25) / 10_000 + 0.4 ether}(orderId); // r12: exactly the signed fees18
        adapter.startFunding{value: budget}(orderId, budget, 1e18, block.timestamp + 60, rewardVault, _quote(budget));
        id = hub.orderCount() - 1;
    }

    function testRewardOrderFlowsThroughTheRewardQueueAndHandsSharesToTheAdapter() public {
        uint256 id = _start(200 ether);
        HubSettlement.Order memory o = hub.getOrder(id);
        assertEq(o.lane, 1);
        assertEq(o.amountIn, 200 ether, "the whole budget buys stock");
        assertEq(o.fee, 0.5 ether, "same 25 bps, paid from the Ops fee deposit");
        assertFalse(adapter.funded(orderId));
        (bool found, uint8 lane, uint256 next) = scheduler.nextLaunch();
        assertTrue(found);
        assertEq(lane, 1);
        assertEq(next, id);
        _launch(id, 0.3 ether);
        assertTrue(adapter.funded(orderId));
        adapter.submit(orderId);
        assertEq(arcEp.packetCount(), 1);
        _result(id, Messages.Outcome.Bought, 200_000_000, 2e18);
        assertEq(token.balanceOf(address(hub)), 2e18, "held for the adapter, not minted to a user");
        (uint8 status, uint256 raw,) = adapter.consumeResult(orderId, "");
        assertEq(status, 1);
        assertEq(raw, 2e18);
        assertEq(token.balanceOf(rewardVault), 2e18);
        assertEq(ops.balance, 0.9 ether - 0.5 ether - 0.3 ether - 0.01 ether, "unused Ops fees go back to Ops");
    }

    function testRewardLaneRejectsUnreservedOrUnknownCallers() public {
        vm.expectRevert(SolonStockHub.NotRewardAdapter.selector);
        hub.beginFunding{value: 101 ether}(orderId, NVDA, 100 ether, 1, address(this), RELAY);
        // Adapter without a capacity reservation from the RoundManager is refused.
        adapter.depositFees{value: 2 ether}(orderId);
        bytes memory q = _quote(200 ether);
        vm.expectRevert(SolonStockHub.BadRewardOrder.selector);
        adapter.startFunding{value: 200 ether}(orderId, 200 ether, 1e18, block.timestamp + 60, rewardVault, q);
    }

    function testRewardRefundIsExactBudgetToppedUpFromOpsFees() public {
        uint256 id = _start(200 ether);
        _launch(id, 0.3 ether);
        adapter.submit(orderId);
        _result(id, Messages.Outcome.Failed, 200_000_000, 0);
        (uint8 status,,) = adapter.consumeResult(orderId, "");
        assertEq(status, 0, "nothing to hand over until the principal is back");
        vm.deal(address(this), 1_000 ether);
        route.deliverReturnFor{value: 199.6 ether}(bytes32(id));
        uint256 vaultBefore = rewardVault.balance;
        (uint8 st, uint256 raw, uint256 refund) = adapter.consumeResult(orderId, "");
        assertEq(st, 2);
        assertEq(raw, 0);
        assertEq(refund, 200 ether, "reward principal never shrinks by bridge costs");
        assertEq(rewardVault.balance, vaultBefore + 200 ether);
        assertEq(ops.balance, 0.9 ether - 0.3 ether - 0.01 ether - 0.4 ether, "Ops paid the 0.4 shortfall; fee refunded");
    }

    function testRewardShortfallWaitsForOpsSubsidy() public {
        vm.prank(rewardManager);
        capacity.reserveFor(orderId, NVDA, 200 ether);
        SolonStockAdapter.SignedQuote memory q =
            SolonStockAdapter.SignedQuote(orderId, 200 ether, 1e18, block.timestamp + 60, 1, 0.6 ether, 0.4 ether);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, adapter.quoteDigest(q));
        adapter.depositFees{value: 0.6 ether}(orderId);
        adapter.startFunding{value: 200 ether}(
            orderId, 200 ether, 1e18, block.timestamp + 60, rewardVault, abi.encode(q, abi.encodePacked(r, s, v))
        );
        uint256 id = hub.orderCount() - 1;
        _launch(id, 0.05 ether);
        adapter.submit(orderId);
        _result(id, Messages.Outcome.Failed, 200_000_000, 0);
        route.deliverReturnFor{value: 199 ether}(bytes32(id));
        (uint8 st,,) = adapter.consumeResult(orderId, "");
        assertEq(st, 0, "0.5 fee + 0.04 left < 1 USDC shortfall");
        hub.subsidize{value: 0.46 ether}(id);
        (st,,) = adapter.consumeResult(orderId, "");
        assertEq(st, 2);
    }

    /// Review #5: a reward head whose fixed route can no longer validate (retired route, rotated signer)
    /// blocked every launch once the reward slot came up; the operator can now refund it exactly.
    function testStuckRewardHeadCanBeCancelledAndUnblocksPublicLaunches() public {
        uint256 id = _start(200 ether);
        // Three public launches make it the reward's turn.
        for (uint256 i; i < 3; ++i) {
            uint256 p = _buy(100e18, 1, 1 ether);
            _launch(p, 0.5 ether);
        }
        route.setReject(true); // the reward order's fixed route stops validating
        uint256 blocked = _buy(100e18, 1, 1 ether);
        vm.expectRevert();
        _launch(id, 0.3 ether);
        vm.expectRevert(OrderScheduler.NotNext.selector);
        _launch(blocked, 0.5 ether);
        vm.prank(user);
        vm.expectRevert(SolonStockHub.NotKeeper.selector);
        hub.cancelReward(id);
        vm.prank(owner);
        hub.cancelReward(id);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        assertEq(uint8(capacity.ticket(orderId).state), uint8(CapacityController.State.None), "released unsent");
        (uint8 st, uint256 raw, uint256 refund) = adapter.consumeResult(orderId, "");
        assertEq(st, 2);
        assertEq(raw, 0);
        assertEq(refund, 200 ether, "exact budget back to the reward vault");
        (bool found, uint8 lane, uint256 next) = scheduler.nextLaunch();
        assertTrue(found);
        assertEq(lane, 0);
        assertEq(next, blocked, "the public queue moves again");
        vm.prank(owner);
        vm.expectRevert();
        hub.cancelReward(id); // once
    }

    /// Re-review L2: money credited to a queued reward order before it is cancelled is not stranded in
    /// escrow: the budget goes back exactly, everything else (fees, reserve, the held credit) to Ops.
    function testCancelRewardIncludesMoneyHeldForTheOrder() public {
        uint256 id = _start(200 ether);
        route.deliverReturnFor{value: 1e12}(bytes32(id));
        assertEq(hub.getOrder(id).held, 1e12);
        uint256 opsBefore = ops.balance;
        vm.prank(owner);
        hub.cancelReward(id);
        (uint8 st,, uint256 refund) = adapter.consumeResult(orderId, "");
        assertEq(st, 2);
        assertEq(refund, 200 ether, "exact budget");
        assertEq(ops.balance, opsBefore + 0.9 ether + 1e12, "Ops fees and the held credit back to Ops");
        assertEq(hub.getOrder(id).held, 0);
        assertEq(hub.escrowed(), 0, "nothing stranded");
    }

    /// Review #8: a funded reward order the pause keeps from dispatching is voided by the operator and
    /// refunded exactly while the hub stays paused.
    function testPausedFundedRewardOrderIsVoidedAndRefunded() public {
        uint256 id = _start(200 ether);
        _launch(id, 0.3 ether);
        vm.prank(guardian);
        hub.pause();
        vm.expectRevert();
        adapter.submit(orderId);
        vm.prank(user);
        vm.expectRevert(); // not the operator, no cancel request, nothing came back
        hub.voidOrder(id);
        vm.prank(owner);
        hub.voidOrder(id); // LayerZero fee from the order's Ops reserve
        Messages.Order memory v = Messages.decodeOrder(arcEp.packetMessage(arcEp.packetCount() - 1));
        assertEq(v.amountIn, 0);
        _result(id, Messages.Outcome.Failed, 0, 0);
        route.deliverReturnFor{value: 199.8 ether}(bytes32(id));
        (uint8 st,, uint256 refund) = adapter.consumeResult(orderId, "");
        assertEq(st, 2);
        assertEq(refund, 200 ether);
        assertEq(capacity.inflightUsd(), 0);
    }
}

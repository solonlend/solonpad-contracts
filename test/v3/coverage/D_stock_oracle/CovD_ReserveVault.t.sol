// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StockSystemBase} from "../../ReserveVault.t.sol";
import {ReserveVault} from "../../../../src/v3/stock/robinhood/ReserveVault.sol";
import {IExecutionVenue} from "../../../../src/v3/stock/interfaces/IExecutionVenue.sol";
import {Messages} from "../../../../src/v3/stock/libs/Messages.sol";
import {AddressAlias} from "../../../../src/v3/stock/libs/Arbitrum.sol";
import {
    MockUSDG,
    MockRHStock,
    MockVenue,
    MockTokenRoute,
    MockNativeRoute
} from "../../helpers/StockMocks.sol";

/// @notice Venue that reports more settlement on a sale than it actually delivers (lying venue).
contract CovDLyingSellVenue is IExecutionVenue {
    MockUSDG public immutable usdg;
    MockRHStock public immutable stock;
    uint256 public sellShortBy;

    constructor(MockUSDG usdg_, MockRHStock stock_) {
        usdg = usdg_;
        stock = stock_;
    }

    function setSellShortBy(uint256 s) external {
        sellShortBy = s;
    }

    function buy(address, uint256 settlementIn, uint256 minSharesOut, address recipient)
        external
        returns (uint256 sharesOut)
    {
        usdg.transferFrom(msg.sender, address(this), settlementIn);
        sharesOut = settlementIn * 1e18 / 100e6;
        require(sharesOut >= minSharesOut, "min");
        stock.mint(recipient, sharesOut);
    }

    function sell(address, uint256 sharesIn, uint256 minSettlementOut, address recipient)
        external
        returns (uint256 settlementOut)
    {
        stock.transferFrom(msg.sender, address(this), sharesIn);
        settlementOut = sharesIn * 100e6 / 1e18;
        require(settlementOut >= minSettlementOut, "min"); // checks its own (inflated) claim
        usdg.mint(recipient, settlementOut - sellShortBy);
    }

    function settlementToken() external view returns (address) {
        return address(usdg);
    }

    function isSupported(address s) external view returns (bool) {
        return s == address(stock);
    }
}

/// @notice A float recipient that refuses native transfers.
contract CovDRejectNative {
    receive() external payable {
        revert("no native");
    }
}

contract CovDReserveVaultTest is StockSystemBase {
    address stranger = address(0x5757);

    // ---------------------------------------------------------------- helpers

    function _order(bytes32 ref, address u, Messages.Side side, uint128 amountIn, uint128 minOut)
        internal
        pure
        returns (Messages.Order memory)
    {
        return Messages.Order({ref: ref, underlying: u, side: side, amountIn: amountIn, minOut: minOut});
    }

    /// Inject an order as if the hub peer sent it from the hub eid.
    function _inject(Messages.Order memory o) internal {
        rhEp.inject(ARC_EID, address(hub), address(vault), Messages.encode(o));
    }

    function _fund(bytes32 ref, uint256 amount) internal {
        usdg.mint(address(this), amount);
        usdg.approve(address(vault), amount);
        vault.fund(ref, amount);
    }

    function _expectExecuted(
        bytes32 ref,
        address u,
        Messages.Outcome outcome,
        uint128 amountIn,
        uint128 amountOut,
        string memory reason
    ) internal {
        uint64 seq = uint64(vault.resultCount());
        vm.expectEmit(true, true, false, true, address(vault));
        emit ReserveVault.OrderExecuted(ref, u, outcome, amountIn, amountOut, seq, reason);
    }

    function _deploy(
        address settlement_,
        address venue_,
        address arbSys_,
        address bridger_,
        address treasury_,
        address fr0,
        address fr1
    ) internal returns (ReserveVault) {
        return new ReserveVault(
            address(rhEp), ARC_EID, settlement_, venue_, arbSys_, bridger_, owner, treasury_, [fr0, fr1]
        );
    }

    function _alias() internal view returns (address) {
        return AddressAlias.applyL1ToL2Alias(bridgerL1);
    }

    // ---------------------------------------------------------------- constructor (190, 191, 194, 589)

    function testCovD_constructorRejectsEveryZeroAddress() public {
        address s = address(usdg);
        address v = address(venue);
        address a = address(arbSys);
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        _deploy(address(0), v, a, bridgerL1, rhTreasury, address(0xF3), address(0xF4));
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        _deploy(s, address(0), a, bridgerL1, rhTreasury, address(0xF3), address(0xF4));
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        _deploy(s, v, address(0), bridgerL1, rhTreasury, address(0xF3), address(0xF4));
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        _deploy(s, v, a, bridgerL1, address(0), address(0xF3), address(0xF4));
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        _deploy(s, v, a, bridgerL1, rhTreasury, address(0), address(0xF4));
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        _deploy(s, v, a, bridgerL1, rhTreasury, address(0xF3), address(0));
    }

    function testCovD_constructorRejectsVenueWithOtherSettlement() public {
        MockVenue other = new MockVenue(IERC20(address(new MockUSDG())), stock);
        vm.expectRevert(ReserveVault.SettlementMismatch.selector);
        _deploy(address(usdg), address(other), address(arbSys), bridgerL1, rhTreasury, address(0xF3), address(0xF4));
    }

    function testCovD_bridgerUnsetAtDeployIsSetOnceImmediatelyThenTimelocked() public {
        ReserveVault v =
            _deploy(address(usdg), address(venue), address(arbSys), address(0), rhTreasury, address(0xF3), address(0xF4));
        assertEq(v.bridger(), address(0));
        assertEq(v.treasury(), rhTreasury);
        assertEq(v.floatRecipientA(), address(0xF3));
        assertEq(v.floatRecipientB(), address(0xF4));
        vm.startPrank(owner);
        v.setBridger(address(0xB1));
        assertEq(v.bridger(), address(0xB1), "first bridger takes effect immediately");
        v.setBridger(address(0xB2));
        assertEq(v.bridger(), address(0xB1), "a change only proposes");
        (address pv, uint64 eta) = v.pendingBridger();
        assertEq(pv, address(0xB2));
        assertEq(eta, uint64(block.timestamp) + 48 hours);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- _lzReceive (218, 232, 765)

    function testCovD_orderFromAnotherPeeredEidIsRejected() public {
        vm.prank(owner);
        vault.setPeer(999, bytes32(uint256(uint160(address(0xE1)))));
        bytes32 ref = bytes32(uint256(5));
        _fund(ref, 100e6);
        bytes memory m = Messages.encode(_order(ref, address(stock), Messages.Side.Buy, 100e6, 1));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0)));
        rhEp.inject(999, address(0xE1), address(vault), m);
        assertFalse(vault.settled(ref));
        assertEq(vault.funding(ref), 100e6);
        assertEq(vault.resultCount(), 0);
    }

    function testCovD_duplicateWaitingOrderIsIgnored() public {
        uint256 id = _buy(1_000e18, 1);
        _deliverLatestOrder(); // no money yet: waits
        assertEq(vault.waitingOrder(bytes32(id)).amountIn, 997_500_000);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ReserveVault.OrderIgnored(bytes32(id), "already waiting");
        arcEp.redeliver(0);
        assertEq(rhEp.packetCount(), 0, "no result for the duplicate");
        assertEq(vault.waitingOrder(bytes32(id)).amountIn, 997_500_000, "the original still waits");
        assertFalse(vault.settled(bytes32(id)));
    }

    function testCovD_resultFeeLargerThanGasBalanceRevertsAndRollsBack() public {
        vm.deal(address(vault), 0);
        bytes32 ref = bytes32(uint256(6));
        _fund(ref, 100e6);
        vm.expectRevert(abi.encodeWithSignature("NotEnoughNative(uint256)", uint256(0)));
        _inject(_order(ref, address(stock), Messages.Side.Buy, 100e6, 1));
        assertFalse(vault.settled(ref), "the whole receive rolled back");
        assertEq(vault.funding(ref), 100e6);
        assertEq(stock.balanceOf(address(vault)), 0);
        // once gas is topped up (via receive()), the same order executes
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        _inject(_order(ref, address(stock), Messages.Side.Buy, 100e6, 1));
        assertTrue(vault.settled(ref));
        assertEq(vault.entitledOf(address(stock)), 1e18);
        assertEq(address(vault).balance, 1 ether - 0.01 ether);
    }

    // ---------------------------------------------------------------- fund (247)

    function testCovD_fundZeroReverts() public {
        vm.expectRevert(ReserveVault.ZeroAmount.selector);
        vault.fund(bytes32(uint256(1)), 0);
        assertEq(vault.fundingTotal(), 0);
    }

    // ---------------------------------------------------------------- _execute (306, 310, 311, 315, 332)

    function testCovD_unlistedBuyAndSellFailAndBuyMoneyStaysReturnable() public {
        address unlisted = address(0xDEAD);
        bytes32 b = bytes32(uint256(10));
        bytes32 s = bytes32(uint256(11));
        _fund(b, 100e6);
        _expectExecuted(b, unlisted, Messages.Outcome.Failed, 100e6, 0, "not listed");
        _inject(_order(b, unlisted, Messages.Side.Buy, 100e6, 1));
        _expectExecuted(s, unlisted, Messages.Outcome.Failed, 1e18, 0, "not listed");
        _inject(_order(s, unlisted, Messages.Side.Sell, 1e18, 1));
        assertTrue(vault.settled(b) && vault.settled(s));
        assertEq(vault.funding(b), 100e6, "unspent: still this ref's");
        vault.returnFunds(b, 1, "ok");
        assertEq(usdg.balanceOf(address(returnRoute)), 100e6);
        assertEq(vault.settlementLiabilities(), 0);
    }

    function testCovD_pausedBlocksBuysButNeverSells() public {
        _boughtOrder(1_000e18); // entitlement 9.975e18
        vm.prank(owner);
        vault.pause();
        bytes32 b = bytes32(uint256(20));
        _fund(b, 100e6);
        _expectExecuted(b, address(stock), Messages.Outcome.Failed, 100e6, 0, "paused");
        _inject(_order(b, address(stock), Messages.Side.Buy, 100e6, 1));
        assertEq(vault.funding(b), 100e6, "paused buy spent nothing");
        assertEq(vault.entitledOf(address(stock)), 9.975e18);
        // the outflow side keeps working while paused
        bytes32 s = bytes32(uint256(21));
        _expectExecuted(s, address(stock), Messages.Outcome.Sold, 1e18, 100e6, "");
        _inject(_order(s, address(stock), Messages.Side.Sell, 1e18, 1));
        assertEq(vault.proceeds(s), 100e6);
        assertEq(vault.entitledOf(address(stock)), 8.975e18);
        // unpausing does not resurrect the settled-failed buy
        vm.prank(owner);
        vault.unpause();
        vm.expectEmit(true, false, false, true, address(vault));
        emit ReserveVault.OrderIgnored(b, "already settled");
        _inject(_order(b, address(stock), Messages.Side.Buy, 100e6, 1));
        assertEq(vault.funding(b), 100e6);
    }

    function testCovD_disabledStockFailsBuysAndReEnablingRestores() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.NotListed.selector, address(0xDEAD)));
        vault.setEnabled(address(0xDEAD), false);

        vm.prank(owner);
        vault.setEnabled(address(stock), false);
        assertFalse(vault.getListing(address(stock)).enabled);
        bytes32 b = bytes32(uint256(30));
        _fund(b, 100e6);
        _expectExecuted(b, address(stock), Messages.Outcome.Failed, 100e6, 0, "disabled");
        _inject(_order(b, address(stock), Messages.Side.Buy, 100e6, 1));
        assertEq(vault.funding(b), 100e6);

        vm.prank(owner);
        vault.setEnabled(address(stock), true);
        bytes32 b2 = bytes32(uint256(31));
        _fund(b2, 100e6);
        _expectExecuted(b2, address(stock), Messages.Outcome.Bought, 100e6, 1e18, "");
        _inject(_order(b2, address(stock), Messages.Side.Buy, 100e6, 1));
        assertEq(vault.funding(b2), 0);
        assertEq(vault.entitledOf(address(stock)), 1e18);
    }

    /// Line 315 true arm: `_fundable` (line 282) already required `floatEnabled && free >= amountIn` for
    /// any advance, and no state changes between the two reads, so with a standard ERC20 this arm is
    /// unreachable. It is exercised here by making the settlement balance read differ between the two
    /// calls (mockCalls), proving the defensive guard fails the order without touching state.
    function testCovD_fundingGuardFailsBuyIfFloatShrinksBetweenChecks() public {
        vm.prank(owner);
        vault.setFloatEnabled(true);
        usdg.mint(address(vault), 2_000e6);
        bytes32 ref = bytes32(uint256(40));
        bytes[] memory rets = new bytes[](2);
        rets[0] = abi.encode(uint256(2_000e6)); // _fundable sees the float
        rets[1] = abi.encode(uint256(0)); // _execute sees none
        vm.mockCalls(address(usdg), abi.encodeCall(IERC20.balanceOf, (address(vault))), rets);
        _expectExecuted(ref, address(stock), Messages.Outcome.Failed, 1_000e6, 0, "funding");
        _inject(_order(ref, address(stock), Messages.Side.Buy, 1_000e6, 1));
        vm.clearMockedCalls();
        assertEq(vault.advanced(ref), 0);
        assertEq(vault.funding(ref), 0);
        assertEq(vault.entitledOf(address(stock)), 0);
        assertEq(usdg.balanceOf(address(vault)), 2_000e6);
    }

    function testCovD_sellAboveEntitlementFails() public {
        bytes32 s = bytes32(uint256(50));
        stock.mint(address(vault), 5e18); // a donation is not entitlement
        _expectExecuted(s, address(stock), Messages.Outcome.Failed, 1e18, 0, "entitlement");
        _inject(_order(s, address(stock), Messages.Side.Sell, 1e18, 1));
        assertEq(vault.proceeds(s), 0);
        assertEq(stock.balanceOf(address(vault)), 5e18);
    }

    // ---------------------------------------------------------------- venueBuy/venueSell (170, 366, 367)

    function testCovD_venueEntrypointsAreSelfOnly() public {
        vm.expectRevert(ReserveVault.OnlySelf.selector);
        vault.venueBuy(address(stock), 1, 0);
        vm.expectRevert(ReserveVault.OnlySelf.selector);
        vault.venueSell(address(stock), 1, 0);
    }

    function _swapToLyingVenue() internal returns (CovDLyingSellVenue lv) {
        lv = new CovDLyingSellVenue(usdg, stock);
        vm.startPrank(owner);
        vault.proposeVenue(address(lv));
        vm.warp(block.timestamp + 48 hours);
        vault.executeVenue();
        vm.stopPrank();
        assertEq(address(vault.venue()), address(lv));
    }

    function testCovD_saleCountsOnlyLandedSettlement() public {
        _boughtOrder(1_000e18);
        CovDLyingSellVenue lv = _swapToLyingVenue();
        lv.setSellShortBy(1);
        bytes32 s = bytes32(uint256(60));
        _expectExecuted(s, address(stock), Messages.Outcome.Sold, 1e18, 100e6 - 1, "");
        _inject(_order(s, address(stock), Messages.Side.Sell, 1e18, 1));
        assertEq(vault.proceeds(s), 100e6 - 1, "proceeds = what landed, not the venue's claim");
        assertEq(vault.proceedsTotal(), 100e6 - 1);
        assertEq(vault.entitledOf(address(stock)), 8.975e18);
    }

    function testCovD_saleBelowFloorAfterShortfallFailsAndKeepsStock() public {
        _boughtOrder(1_000e18);
        CovDLyingSellVenue lv = _swapToLyingVenue();
        lv.setSellShortBy(1);
        bytes32 s = bytes32(uint256(61));
        uint256 stockBefore = stock.balanceOf(address(vault));
        _expectExecuted(s, address(stock), Messages.Outcome.Failed, 1e18, 0, "venue sell");
        _inject(_order(s, address(stock), Messages.Side.Sell, 1e18, 100e6));
        assertEq(vault.proceeds(s), 0);
        assertEq(vault.entitledOf(address(stock)), 9.975e18, "entitlement untouched");
        assertEq(stock.balanceOf(address(vault)), stockBefore, "the reverted sale moved no stock");
        assertEq(usdg.balanceOf(address(vault)), 0);
    }

    // ---------------------------------------------------------------- checkpoint (377)

    function testCovD_checkpointWithNothingNewReverts() public {
        vm.expectRevert(ReserveVault.NothingToCheckpoint.selector);
        vault.checkpoint();
        _boughtOrder(1_000e18);
        (, uint64 fromSeq, uint64 toSeq) = vault.checkpoint();
        assertEq(fromSeq, 0);
        assertEq(toSeq, 0);
        assertEq(arbSys.callCount(), 1);
        vm.expectRevert(ReserveVault.NothingToCheckpoint.selector);
        vault.checkpoint();
        assertEq(vault.checkpointedThrough(), 1);
    }

    // ---------------------------------------------------------------- deliver (428, 430) + claim (456)

    function testCovD_deliverUnlistedOrAboveEntitlementReverts() public {
        address a = _alias();
        bytes32 ref = bytes32(uint256(70));
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.NotListed.selector, address(0xDEAD)));
        vault.deliver(Messages.Deliver(ref, address(0xDEAD), 1, user, Messages.DeliverMode.Stock));
        assertFalse(vault.settled(ref));

        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.ExceedsEntitlement.selector, uint256(1), uint256(0)));
        vault.deliver(Messages.Deliver(ref, address(stock), 1, user, Messages.DeliverMode.Stock));
        assertFalse(vault.settled(ref));
        assertEq(vault.resultCount(), 0);
    }

    function testCovD_claimPaysOnceAndOnlyWhatIsOwed() public {
        _boughtOrder(1_000e18);
        address rhUser = address(0xCAFE);
        vm.expectRevert(ReserveVault.ZeroAmount.selector);
        vm.prank(rhUser);
        vault.claim(address(stock));

        stock.setBlocked(rhUser, true);
        vm.prank(_alias());
        vault.deliver(Messages.Deliver(bytes32(uint256(71)), address(stock), 2e18, rhUser, Messages.DeliverMode.Stock));
        assertEq(vault.claimable(address(stock), rhUser), 2e18);
        assertEq(vault.claimableTotal(address(stock)), 2e18);
        (uint256 reserve, uint256 entitled) = vault.backingOf(address(stock));
        assertEq(reserve, 9.975e18);
        assertEq(entitled, 7.975e18);
        assertTrue(vault.isFullyBacked(address(stock)));

        vm.prank(stranger);
        vm.expectRevert(ReserveVault.ZeroAmount.selector);
        vault.claim(address(stock));

        stock.setBlocked(rhUser, false);
        vm.prank(rhUser);
        vault.claim(address(stock));
        assertEq(stock.balanceOf(rhUser), 2e18);
        assertEq(vault.claimable(address(stock), rhUser), 0);
        assertEq(vault.claimableTotal(address(stock)), 0);
        assertTrue(vault.isFullyBacked(address(stock)));

        vm.prank(rhUser);
        vm.expectRevert(ReserveVault.ZeroAmount.selector);
        vault.claim(address(stock));
    }

    // ---------------------------------------------------------------- merkleRoot (544)

    function testCovD_merkleRootOfEmptyAndSingle() public view {
        assertEq(vault.merkleRoot(new bytes32[](0)), bytes32(0));
        bytes32[] memory one = new bytes32[](1);
        one[0] = keccak256("x");
        assertEq(vault.merkleRoot(one), keccak256("x"));
    }

    // ---------------------------------------------------------------- listing admin (560, 561, 562)

    function testCovD_listStockGuards() public {
        vm.startPrank(owner);
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        vault.listStock(address(0), "X");
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.AlreadyListed.selector, address(stock)));
        vault.listStock(address(stock), "NVDA2");
        MockRHStock other = new MockRHStock();
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.VenueUnsupported.selector, address(other)));
        vault.listStock(address(other), "AAPL");
        vm.stopPrank();
        address[] memory us = vault.underlyings();
        assertEq(us.length, 1);
        assertEq(us[0], address(stock));
        ReserveVault.Listing memory l = vault.getListing(address(stock));
        assertEq(l.underlying, address(stock));
        assertEq(l.ticker, "NVDA");
        assertTrue(l.enabled);
        assertEq(vault.getListing(address(other)).underlying, address(0));
    }

    // ---------------------------------------------------------------- venue/bridger/route/peer timelocks

    function testCovD_proposeVenueGuards() public {
        vm.startPrank(owner);
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        vault.proposeVenue(address(0));
        MockVenue other = new MockVenue(IERC20(address(new MockUSDG())), stock);
        vm.expectRevert(ReserveVault.SettlementMismatch.selector);
        vault.proposeVenue(address(other));
        vm.stopPrank();
        (address pv,) = vault.pendingVenue();
        assertEq(pv, address(0));
        assertEq(address(vault.venue()), address(venue));
    }

    function testCovD_bridgerChangeWaitsAndMovesTheDeliverAuthority() public {
        address oldAlias = _alias();
        address newL1 = address(0xB42);
        vm.startPrank(owner);
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        vault.setBridger(address(0));
        vault.setBridger(newL1);
        assertEq(vault.bridger(), bridgerL1, "only proposed");
        vm.expectRevert(ReserveVault.Timelocked.selector);
        vault.executeBridger();
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(ReserveVault.Timelocked.selector);
        vault.executeBridger();
        vm.warp(block.timestamp + 1);
        vault.executeBridger();
        vm.stopPrank();
        assertEq(vault.bridger(), newL1);
        (address pv,) = vault.pendingBridger();
        assertEq(pv, address(0));
        vm.prank(owner);
        vm.expectRevert(ReserveVault.Timelocked.selector);
        vault.executeBridger(); // the pending slot was cleared

        vm.prank(oldAlias);
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.NotBridgerAlias.selector, oldAlias));
        vault.deliver(Messages.Deliver(bytes32(uint256(80)), address(stock), 0, user, Messages.DeliverMode.Settlement));
        vm.prank(AddressAlias.applyL1ToL2Alias(newL1));
        vault.deliver(Messages.Deliver(bytes32(uint256(80)), address(stock), 0, user, Messages.DeliverMode.Settlement));
        assertTrue(vault.settled(bytes32(uint256(80))));
    }

    function testCovD_returnRouteGuardsAndTimelock() public {
        vm.startPrank(owner);
        vm.expectRevert(ReserveVault.ZeroAddress.selector);
        vault.setReturnRoute(address(0));
        MockNativeRoute nativeRoute = new MockNativeRoute(address(hub), address(vault), usdg);
        vm.expectRevert(ReserveVault.SettlementMismatch.selector);
        vault.setReturnRoute(address(nativeRoute));
        MockTokenRoute r2 = new MockTokenRoute(address(hub), usdg);
        vault.setReturnRoute(address(r2));
        assertEq(address(vault.returnRoute()), address(returnRoute), "second route only proposed");
        vm.expectRevert(ReserveVault.Timelocked.selector);
        vault.executeReturnRoute();
        vm.warp(block.timestamp + 48 hours);
        vault.executeReturnRoute();
        vm.stopPrank();
        assertEq(address(vault.returnRoute()), address(r2));
        (address pv,) = vault.pendingReturnRoute();
        assertEq(pv, address(0));
    }

    function testCovD_peerChangeWaitsFortyEightHours() public {
        bytes32 newPeer = bytes32(uint256(uint160(address(0x4E1))));
        vm.startPrank(owner);
        vm.expectRevert(ReserveVault.Timelocked.selector);
        vault.executePeer(ARC_EID); // nothing proposed (eta == 0)
        vault.proposePeer(ARC_EID, newPeer);
        assertEq(vault.pendingPeer(ARC_EID), newPeer);
        vm.expectRevert(ReserveVault.Timelocked.selector);
        vault.executePeer(ARC_EID); // too early
        assertEq(vault.peers(ARC_EID), bytes32(uint256(uint160(address(hub)))));
        vm.warp(block.timestamp + 48 hours);
        vault.executePeer(ARC_EID);
        vm.stopPrank();
        assertEq(vault.peers(ARC_EID), newPeer);
        assertEq(vault.pendingPeer(ARC_EID), bytes32(0));
        assertEq(vault.pendingPeerEta(ARC_EID), 0);
        // the old hub peer is no longer accepted
        vm.expectRevert();
        _inject(_order(bytes32(uint256(81)), address(stock), Messages.Side.Sell, 1, 0));
    }

    // ---------------------------------------------------------------- withdrawFloat (175, 659, 661)

    function testCovD_withdrawFloatPermissionsAndNativeArms() public {
        uint256 gas0 = address(vault).balance; // 10 ether from setUp
        vm.prank(stranger);
        vm.expectRevert(ReserveVault.NotKeeper.selector);
        vault.withdrawFloat(address(0), address(0xF3), 1 ether);

        address k = address(0x4EE9);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setKeeper(k);
        vm.prank(owner);
        vault.setKeeper(k);
        assertEq(vault.keeper(), k);

        vm.prank(k);
        vault.withdrawFloat(address(0), address(0xF3), 1 ether);
        assertEq(address(0xF3).balance, 1 ether);
        vm.prank(owner);
        vault.withdrawFloat(address(0), address(0xF4), 2 ether);
        assertEq(address(0xF4).balance, 2 ether);
        assertEq(address(vault).balance, gas0 - 3 ether);

        // a non-listed, non-settlement token (stray airdrop) goes out without a liability check
        MockUSDG stray = new MockUSDG();
        stray.mint(address(vault), 7);
        vm.prank(k);
        vault.withdrawFloat(address(stray), address(0xF3), 7);
        assertEq(stray.balanceOf(address(0xF3)), 7);

        // a recipient that rejects native: the withdrawal reverts, nothing moves
        vm.etch(address(0xF3), address(new CovDRejectNative()).code);
        vm.prank(k);
        vm.expectRevert(ReserveVault.ZeroAmount.selector);
        vault.withdrawFloat(address(0), address(0xF3), 1 ether);
        assertEq(address(vault).balance, gas0 - 3 ether);
    }

    // ---------------------------------------------------------------- migration (684, 685, 686, 688)

    function testCovD_migrateInGuardsSuccessAndClose() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.NotListed.selector, address(0xDEAD)));
        vault.migrateIn(address(0xDEAD), 1e6, 0);
        vm.expectRevert(ReserveVault.ZeroAmount.selector);
        vault.migrateIn(address(stock), 0, 0);
        vm.stopPrank();

        // funding for a ref is a liability, never migration money
        _fund(bytes32(uint256(90)), 500e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.InsufficientFloat.selector, uint256(0), uint256(1e6)));
        vault.migrateIn(address(stock), 1e6, 0);

        usdg.mint(address(vault), 100e6); // free float
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.InsufficientFloat.selector, uint256(100e6), uint256(100e6 + 1)));
        vault.migrateIn(address(stock), 100e6 + 1, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.migrateIn(address(stock), 100e6, 1);

        vm.prank(owner);
        (bytes32 ref, uint256 shares) = vault.migrateIn(address(stock), 100e6, 1e18);
        assertEq(shares, 1e18);
        assertEq(ref, Messages.migrationRef(address(stock), 0));
        assertEq(vault.migrationNonce(address(stock)), 1);
        assertEq(vault.entitledOf(address(stock)), 1e18);
        assertEq(vault.funding(bytes32(uint256(90))), 500e6, "liability untouched");
        assertEq(usdg.balanceOf(address(vault)), 500e6);
        Messages.Result memory r = vault.resultAt(vault.resultCount() - 1);
        assertEq(r.ref, ref);
        assertEq(uint8(r.outcome), uint8(Messages.Outcome.Bought));
        assertEq(r.amountIn, 100e6);
        assertEq(r.amountOut, 1e18);

        vm.startPrank(owner);
        vault.closeMigration();
        assertFalse(vault.migrationOpen());
        vm.expectRevert(ReserveVault.MigrationIsClosed.selector);
        vault.migrateIn(address(stock), 1e6, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- skim (714)

    function testCovD_skimUnlistedReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.NotListed.selector, address(0xDEAD)));
        vault.skimExcess(address(0xDEAD));
    }

    // ---------------------------------------------------------------- misc admin

    function testCovD_resultOptionsAreUsedForResults() public {
        bytes memory opts = hex"00030100110100000000000000000000000000030d40";
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.setResultOptions(opts);
        vm.prank(owner);
        vault.setResultOptions(opts);
        assertEq(vault.resultOptions(), opts);
        bytes32 ref = bytes32(uint256(100));
        _fund(ref, 100e6);
        _inject(_order(ref, address(stock), Messages.Side.Buy, 100e6, 1));
        assertEq(rhEp.packetCount(), 1);
    }

    function testCovD_ownershipIsTwoStep() public {
        address n = address(0x0E2);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.transferOwnership(n);
        vm.prank(owner);
        vault.transferOwnership(n);
        assertEq(vault.owner(), owner, "nothing moves until accepted");
        assertEq(vault.pendingOwner(), n);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.acceptOwnership();
        vm.prank(n);
        vault.acceptOwnership();
        assertEq(vault.owner(), n);
        assertEq(vault.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setFloatEnabled(true);
    }

    function testCovD_everyAdminEntryIsOwnerOnly() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(err);
        vault.listStock(address(1), "X");
        vm.expectRevert(err);
        vault.setEnabled(address(stock), false);
        vm.expectRevert(err);
        vault.proposeVenue(address(venue));
        vm.expectRevert(err);
        vault.executeVenue();
        vm.expectRevert(err);
        vault.setBridger(address(1));
        vm.expectRevert(err);
        vault.executeBridger();
        vm.expectRevert(err);
        vault.setReturnRoute(address(returnRoute));
        vm.expectRevert(err);
        vault.executeReturnRoute();
        vm.expectRevert(err);
        vault.setPeer(1, bytes32(uint256(1)));
        vm.expectRevert(err);
        vault.proposePeer(ARC_EID, bytes32(uint256(1)));
        vm.expectRevert(err);
        vault.executePeer(ARC_EID);
        vm.expectRevert(err);
        vault.setFloatEnabled(true);
        vm.expectRevert(err);
        vault.closeMigration();
        vm.expectRevert(err);
        vault.skimExcess(address(stock));
        vm.stopPrank();
        assertTrue(vault.migrationOpen());
        assertTrue(vault.getListing(address(stock)).enabled);
    }
}

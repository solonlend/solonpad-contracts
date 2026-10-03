// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StockHubBase, RejectNative} from "../../StockHub.t.sol";
import {SolonStockHub} from "../../../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../../../src/v3/stock/HubSettlement.sol";
import {HubExits} from "../../../../src/v3/stock/HubExits.sol";
import {CapacityController} from "../../../../src/v3/stock/CapacityController.sol";
import {OrderScheduler} from "../../../../src/v3/stock/OrderScheduler.sol";
import {OAppSender} from "../../../../src/v3/stock/lz/OAppSender.sol";
import {Guarded} from "../../../../src/v3/stock/libs/Guarded.sol";
import {Messages} from "../../../../src/v3/stock/libs/Messages.sol";
import {MockNativeRoute} from "../../helpers/StockMocks.sol";

/// @dev Canonical gate double: accepts every proof (the real Merkle check is covered in Canonical.t.sol)
///      and records deliveries and the hook payment.
contract CovDGateStub {
    uint256 public delivers;
    bytes32 public lastRef;
    address public lastTo;
    uint128 public lastShares;

    function verify(Messages.Result calldata, uint256, bytes32[] calldata) external pure {}

    function sendDeliver(Messages.Deliver calldata d) external {
        ++delivers;
        lastRef = d.ref;
        lastTo = d.to;
        lastShares = d.shares;
    }

    receive() external payable {}
}

/// @dev A gate that refuses the native hook payment (misconfigured / malicious gate).
contract CovDRejectingGate {
    function verify(Messages.Result calldata, uint256, bytes32[] calldata) external pure {}

    function sendDeliver(Messages.Deliver calldata) external {}
}

/// @dev A caller that cannot take native back (fee refund target).
contract CovDRejectingCaller {
    function dispatch(SolonStockHub hub, uint256 id) external payable {
        hub.dispatch{value: msg.value}(id);
    }

    receive() external payable {
        revert("no");
    }
}

contract CovDHubTest is StockHubBase {
    CovDGateStub stub;
    address rhUser = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        stub = new CovDGateStub();
    }

    function _setStub() internal {
        vm.prank(owner);
        hub.setCanonicalGate(address(stub));
    }

    function _sell(uint256 shares, uint256 value) internal returns (uint256 id) {
        vm.prank(user);
        id = hub.requestSell{value: value}(NVDA, shares, 1);
    }

    // ------------------------------------------------------------------ constructor / admin

    /// Hub L179-181.
    function testCovD_ConstructorChecks() public {
        address[2] memory fr = [floatA, floatB];
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        new SolonStockHub(address(arcEp), address(0), 25, owner, ops, fr);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        new SolonStockHub(address(arcEp), treasury, 25, owner, address(0), fr);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        new SolonStockHub(address(arcEp), treasury, 25, owner, ops, [address(0), floatB]);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        new SolonStockHub(address(arcEp), treasury, 25, owner, ops, [floatA, address(0)]);
        vm.expectRevert(SolonStockHub.FeeTooHigh.selector);
        new SolonStockHub(address(arcEp), treasury, 101, owner, ops, fr);
        SolonStockHub h = new SolonStockHub(address(arcEp), treasury, 100, owner, ops, fr); // boundary
        (uint16 b, uint16 s_, uint16 m) = h.fees();
        assertEq(b, 100);
        assertEq(s_, 100);
        assertEq(m, 500);
    }

    /// Hub L586/587 gate once and non-zero; L594/595 capacity once, non-zero, scheduler bound to this hub.
    function testCovD_OneTimeWiring() public {
        vm.startPrank(owner);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        hub.setCanonicalGate(address(0));
        hub.setCanonicalGate(address(stub));
        vm.expectRevert(SolonStockHub.GateAlreadySet.selector);
        hub.setCanonicalGate(address(0x1234));
        assertEq(address(hub.gate()), address(stub));
        vm.expectRevert(SolonStockHub.GateAlreadySet.selector);
        hub.setCapacity(capacity, scheduler);
        vm.stopPrank();

        SolonStockHub h = new SolonStockHub(address(arcEp), treasury, 25, owner, ops, [floatA, floatB]);
        CapacityController c2 = new CapacityController(owner, guardian);
        vm.startPrank(owner);
        OrderScheduler s2 = new OrderScheduler(address(h), c2);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        h.setCapacity(CapacityController(address(0)), s2);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        h.setCapacity(c2, scheduler); // scheduler bound to another hub
        h.setCapacity(c2, s2);
        vm.stopPrank();
        assertEq(address(h.capacity()), address(c2));
        assertEq(address(h.scheduler()), address(s2));
    }

    /// Hub L610/611 listing checks; L833 NotListed; L838 StockDisabled; setEnabled.
    function testCovD_ListingGuards() public {
        vm.startPrank(owner);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        hub.listStock(address(0), "X", RH_EID, 4663, 1, address(route), RELAY);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        hub.listStock(address(0x1234), "X", RH_EID, 4663, 1, address(0), RELAY);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        hub.listStock(address(0x1234), "X", RH_EID, 4663, 1, address(route), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.AlreadyListed.selector, NVDA));
        hub.listStock(NVDA, "NVDA", RH_EID, 4663, 1, address(route), RELAY);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NotListed.selector, address(0x1234)));
        hub.setEnabled(address(0x1234), true);
        hub.setEnabled(NVDA, false);
        vm.stopPrank();
        assertEq(hub.underlyings().length, 1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.StockDisabled.selector, NVDA));
        hub.requestBuy{value: 1_000e18}(NVDA, 1_000e18, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NotListed.selector, address(0x1234)));
        hub.requestBuy{value: 1_000e18}(address(0x1234), 1_000e18, 1);
        (bool open, bool transferable,) = hub.stockState(address(token));
        assertFalse(open, "disabled: no new subscriptions");
        assertTrue(transferable, "issued stock still trades");
        assertEq(hub.orderCount(), 0);
        assertEq(hub.escrowed(), 0);
    }

    /// Hub L575: an unknown token has no stock state.
    function testCovD_StockStateUnknownToken() public view {
        (bool open, bool transferable, uint256 v) = hub.stockState(address(0xdead));
        assertFalse(open);
        assertFalse(transferable);
        assertEq(v, 0);
    }

    /// Never-called setters and views; L675 setTreasury zero; L704 proposeRoute zero/unlisted; executeRoute /
    /// executePeer with nothing proposed; owner-only rejections.
    function testCovD_AdminSettersAndViews() public {
        vm.startPrank(owner);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        hub.setTreasury(address(0));
        hub.setTreasury(address(0x7EA9));
        hub.setKeeper(address(0x4EE));
        hub.setOrderOptions(hex"00030100");
        hub.setMintLimitBps(1_000);
        hub.setPayLimit(1 ether, 100);
        hub.setMultiplierVersion(NVDA, 2);
        vm.expectRevert(SolonStockHub.ZeroAddress.selector);
        hub.proposeRoute(NVDA, address(0));
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NotListed.selector, address(0x1234)));
        hub.proposeRoute(address(0x1234), address(route));
        vm.expectRevert(SolonStockHub.Timelocked.selector);
        hub.executeRoute(NVDA);
        vm.expectRevert(SolonStockHub.Timelocked.selector);
        hub.executePeer(RH_EID);
        vm.stopPrank();
        assertEq(hub.treasury(), address(0x7EA9));
        assertEq(hub.keeper(), address(0x4EE));
        assertEq(keccak256(hub.orderOptions()), keccak256(hex"00030100"));
        (,, uint16 m) = hub.fees();
        assertEq(m, 1_000);
        assertEq(hub.payAllowance(), 1 ether, "floor dominates an empty float");
        assertFalse(hub.floatEnabled());
        HubSettlement.Listing memory l = hub.getListing(NVDA);
        assertEq(l.multiplierVersion, 2);
        assertEq(address(l.arc), address(token));
        assertEq(hub.supplyOf(NVDA), 0);
        assertEq(hub.mintAllowance(NVDA), 1_000_000e18, "mint floor while supply is zero");
        (,, uint256 v) = hub.stockState(address(token));
        assertEq(v, 2);

        address[6] memory who = [address(0xBAD), guardian, address(0x4EE), user, treasury, ops];
        for (uint256 i; i < who.length; ++i) {
            vm.startPrank(who[i]);
            bytes memory e = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]);
            vm.expectRevert(e);
            hub.setKeeper(who[i]);
            vm.expectRevert(e);
            hub.setTreasury(who[i]);
            vm.expectRevert(e);
            hub.setFloatEnabled(true);
            vm.expectRevert(e);
            hub.setMintLimitBps(0);
            vm.expectRevert(e);
            hub.lowerFees(0, 0);
            vm.expectRevert(e);
            hub.resumeMints();
            vm.expectRevert(e);
            hub.setRewardAdapter(who[i], true);
            vm.stopPrank();
        }
    }

    function testCovD_OwnershipIsTwoStep() public {
        vm.prank(owner);
        hub.transferOwnership(address(0x0E2));
        assertEq(hub.owner(), owner);
        assertEq(hub.pendingOwner(), address(0x0E2));
        vm.prank(address(0x0E2));
        hub.acceptOwnership();
        assertEq(hub.owner(), address(0x0E2));
    }

    /// Guarded L35/36/43/49.
    function testCovD_GuardedPauseRules() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(Guarded.NotGuardian.selector);
        hub.pause();
        vm.prank(owner);
        vm.expectRevert(Guarded.ExpectedPause.selector);
        hub.unpause();
        vm.prank(owner); // the owner may pause too
        hub.pause();
        vm.prank(guardian);
        vm.expectRevert(Guarded.EnforcedPause.selector);
        hub.pause();
        vm.prank(guardian);
        vm.expectRevert(Guarded.NotOwnerOfGuard.selector);
        hub.setGuardian(address(0xBAD));
        assertEq(hub.guardian(), guardian);
        assertTrue(hub.paused());
        vm.prank(owner);
        hub.unpause();
        assertFalse(hub.paused());
    }

    // ------------------------------------------------------------------ user entry points

    /// Hub L209/L210 (and the exact-value boundary: zero reserve is allowed).
    function testCovD_RequestBuyAmountChecks() public {
        vm.prank(user);
        vm.expectRevert(SolonStockHub.ZeroAmount.selector);
        hub.requestBuy(NVDA, 0, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.InsufficientValue.selector, 1_000e18 - 1, 1_000e18));
        hub.requestBuy{value: 1_000e18 - 1}(NVDA, 1_000e18, 1);
        assertEq(hub.orderCount(), 0);
        assertEq(hub.escrowed(), 0);
        vm.prank(user);
        uint256 id = hub.requestBuy{value: 1_000e18}(NVDA, 1_000e18, 1);
        assertEq(hub.getOrder(id).extra, 0);
        assertEq(hub.escrowed(), 1_000e18);
        assertEq(hub.ordersOf(user).length, 1);
        assertEq(hub.openOrders().length, 1);
    }

    /// Hub L229 zero sell; L794 value below the LayerZero fee; L799 excess fee refunded to the payer.
    function testCovD_RequestSellChecksAndFeeRefund() public {
        _filledBuy(10e18);
        vm.prank(user);
        vm.expectRevert(SolonStockHub.ZeroAmount.selector);
        hub.requestSell(NVDA, 0, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NotListed.selector, address(0x1234)));
        hub.requestSell(address(0x1234), 1e18, 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.InsufficientValue.selector, 0.005 ether, 0.01 ether));
        hub.requestSell{value: 0.005 ether}(NVDA, 1e18, 1);
        assertEq(token.balanceOf(user), 10e18, "burn undone with the revert");
        uint256 before = user.balance;
        uint256 id = _sell(1e18, 0.03 ether);
        assertEq(user.balance, before - 0.01 ether, "only the LayerZero fee is kept");
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Dispatched));
        assertEq(hub.getOrder(id).dispatchedAt, block.timestamp);
    }

    /// Hub L242 scheduler only; L244 defensive status/kind check (unreachable through the scheduler, which
    /// only launches `scheduleInfo().pending` buys — exercised by pranking the scheduler).
    function testCovD_LaunchGuards() public {
        uint256 f = _filledBuy(10e18); // Filled
        uint256 id = _buy(1_000e18, 1, 1 ether); // queued
        vm.expectRevert(SolonStockHub.NotScheduler.selector);
        hub.launch(id, _routeData(0.5 ether));
        vm.prank(address(scheduler));
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.WrongStatus.selector, f, HubSettlement.Status.Filled));
        hub.launch(f, _routeData(0.5 ether));
        uint256 s = _sell(1e18, 0); // Pending sell
        vm.prank(address(scheduler));
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.WrongStatus.selector, s, HubSettlement.Status.Pending));
        hub.launch(s, _routeData(0.5 ether));
        assertEq(route.sentCount(), 1, "only the filled buy was ever funded");
    }

    /// Hub L264: dispatch needs a Funded buy or a Pending sell; L817 fee refund to a caller that refuses it.
    function testCovD_DispatchGuardsAndRefusedRefund() public {
        uint256 f = _filledBuy(10e18);
        uint256 q = _buy(1_000e18, 1, 1 ether); // queued
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.WrongStatus.selector, q, HubSettlement.Status.Pending));
        hub.dispatch{value: 0.01 ether}(q);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.WrongStatus.selector, f, HubSettlement.Status.Filled));
        hub.dispatch{value: 0.01 ether}(f);
        uint256 s = _sell(1e18, 0.01 ether); // already dispatched
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.WrongStatus.selector, s, HubSettlement.Status.Dispatched));
        hub.dispatch{value: 0.01 ether}(s);

        uint256 a = _buy(1_000e18, 1, 0.5 ether);
        scheduler.launchNext(q, _routeData(0.5 ether)); // q funded + dispatched from its reserve
        _launch(a, 0.5 ether); // a funded only (reserve spent on the route)
        assertEq(uint8(hub.getOrder(a).status), uint8(HubSettlement.Status.Funded));
        CovDRejectingCaller c = new CovDRejectingCaller();
        vm.deal(address(c), 1 ether);
        vm.expectRevert(SolonStockHub.TransferFailed.selector);
        c.dispatch{value: 0.02 ether}(hub, a);
        assertEq(uint8(hub.getOrder(a).status), uint8(HubSettlement.Status.Funded));
        c.dispatch{value: 0.01 ether}(hub, a); // exact fee: nothing to refund
        assertEq(uint8(hub.getOrder(a).status), uint8(HubSettlement.Status.Dispatched));
    }

    /// Hub L821: unknown ids.
    function testCovD_UnknownOrderIds() public {
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NoSuchOrder.selector, 0));
        hub.cancel(0);
        _buy(1_000e18, 1, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NoSuchOrder.selector, 1));
        hub.dispatch(1);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NoSuchOrder.selector, 7));
        hub.claim(7);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NoSuchOrder.selector, 7));
        hub.quoteDispatch(7);
        vm.expectRevert(SolonStockHub.NotRoute.selector);
        hub.receiveReturn(bytes32(uint256(7)));
        assertEq(hub.quoteDispatch(0), 0.01 ether);
        assertEq(hub.quoteOrder(NVDA), 0.01 ether);
    }

    /// HubSettlement L731: nothing owed.
    function testCovD_ClaimWithNothingOwed() public {
        uint256 id = _filledBuy(10e18);
        vm.expectRevert(abi.encodeWithSelector(HubSettlement.NotClaimable.selector, id, 0));
        hub.claim(id);
    }

    /// Hub L661: voiding owed money needs evidence.
    function testCovD_VoidClaimableNeedsEvidence() public {
        uint256 id = _filledBuy(10e18);
        vm.prank(owner);
        vm.expectRevert(SolonStockHub.ZeroAmount.selector);
        hub.voidClaimable(id, 0, bytes32(0));
    }

    /// Hub L752 caller; L815 zero amount returns early; L817 treasury refusing native.
    function testCovD_ClaimFeesPaths() public {
        vm.prank(user);
        vm.expectRevert(SolonStockHub.NotKeeper.selector);
        hub.claimFees();
        vm.prank(treasury);
        hub.claimFees(); // nothing accrued: no transfer
        assertEq(treasury.balance, 0);
        _filledBuy(10e18);
        assertEq(hub.accruedFees(), 2.5e18);
        RejectNative rej = new RejectNative();
        vm.prank(owner);
        hub.setTreasury(address(rej));
        vm.prank(owner);
        vm.expectRevert(SolonStockHub.TransferFailed.selector);
        hub.claimFees();
        assertEq(hub.accruedFees(), 2.5e18, "fees stay accrued");
        vm.prank(owner);
        hub.setTreasury(treasury);
        vm.prank(owner); // the owner may trigger it; money only goes to the treasury
        hub.claimFees();
        assertEq(treasury.balance, 2.5e18);
        assertEq(hub.accruedFees(), 0);
    }

    function testCovD_WithdrawFloatZeroAndKeeper() public {
        hub.fundFloat{value: 3 ether}();
        vm.prank(owner);
        hub.setKeeper(address(0x4EE));
        vm.prank(address(0x4EE));
        hub.withdrawFloat(floatB, 0); // zero: no call
        vm.prank(address(0x4EE));
        hub.withdrawFloat(floatB, 3 ether);
        assertEq(floatB.balance, 3 ether);
        vm.prank(user);
        vm.expectRevert(SolonStockHub.NotKeeper.selector);
        hub.withdrawFloat(floatA, 0);
        // receive() accepts plain native
        (bool ok,) = address(hub).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(hub.available(), 1 ether);
    }

    // ------------------------------------------------------------------ LayerZero lane

    /// Hub L435 migration refs never settle over LayerZero; L437 unknown id; L438 wrong source eid.
    function testCovD_LzReceiveGuards() public {
        uint256 id = _buy(1_000e18, 1, 1 ether);
        _launch(id, 0.5 ether);
        bytes32 mref = Messages.migrationRef(NVDA, 1);
        Messages.Result memory r = Messages.Result(mref, NVDA, Messages.Outcome.Bought, 0, 5e18, 0);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NoSuchOrder.selector, uint256(mref)));
        arcEp.inject(RH_EID, vaultPeer, address(hub), Messages.encode(r));
        r.ref = bytes32(uint256(5));
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NoSuchOrder.selector, 5));
        arcEp.inject(RH_EID, vaultPeer, address(hub), Messages.encode(r));
        vm.prank(owner);
        hub.setPeer(777, bytes32(uint256(uint160(vaultPeer)))); // a trusted peer, but not this listing's vault
        r.ref = bytes32(id);
        vm.expectRevert(
            abi.encodeWithSelector(SolonStockHub.WrongSource.selector, uint32(777), bytes32(uint256(uint160(vaultPeer))))
        );
        arcEp.inject(777, vaultPeer, address(hub), Messages.encode(r));
        assertEq(token.totalSupply(), 0);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Dispatched));
    }

    /// HubSettlement L555 Bought for a sell / L601 Sold for a buy are ignored and change nothing.
    function testCovD_WrongKindResultsAreIgnored() public {
        _filledBuy(10e18);
        uint256 s = _sell(4e18, 0.01 ether);
        uint256 b = _buy(1_000e18, 1, 1 ether);
        _launch(b, 0.5 ether);
        uint256 supply = token.totalSupply();
        vm.expectEmit(true, false, false, true, address(hub));
        emit HubSettlement.ResultIgnored(s, HubSettlement.Reason.WrongKind);
        _result(s, Messages.Outcome.Bought, 4e18, 9e18);
        vm.expectEmit(true, false, false, true, address(hub));
        emit HubSettlement.ResultIgnored(b, HubSettlement.Reason.WrongKind);
        _result(b, Messages.Outcome.Sold, 997_500_000, 1_000e6);
        assertEq(token.totalSupply(), supply);
        assertEq(uint8(hub.getOrder(s).status), uint8(HubSettlement.Status.Dispatched));
        assertEq(uint8(hub.getOrder(b).status), uint8(HubSettlement.Status.Dispatched));
        assertEq(hub.getOrder(s).outcome, 0);
        assertEq(hub.getOrder(b).outcome, 0);
    }

    // ------------------------------------------------------------------ canonical lane (gate stub)

    /// Hub L455 + HubSettlement.migrationMint (L688-691); Hub L461 unknown id.
    function testCovD_ReconcileMigrationAndUnknownId() public {
        _setStub();
        bytes32[] memory p = new bytes32[](0);
        Messages.Result memory r = Messages.Result(bytes32(uint256(9)), NVDA, Messages.Outcome.Bought, 0, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NoSuchOrder.selector, 9));
        hub.reconcile(r, 0, p);

        bytes32 mref = Messages.migrationRef(NVDA, 1);
        assertEq(Messages.migrationUnderlying(mref), NVDA);
        r = Messages.Result(mref, NVDA, Messages.Outcome.Failed, 0, 5e18, 0);
        vm.expectRevert(abi.encodeWithSelector(HubSettlement.BadMigration.selector, mref));
        hub.reconcile(r, 0, p);
        r.outcome = Messages.Outcome.Bought;
        r.amountOut = 0;
        vm.expectRevert(abi.encodeWithSelector(HubSettlement.BadMigration.selector, mref));
        hub.reconcile(r, 0, p);
        r.amountOut = 5e18;
        r.underlying = address(0x1234); // ref names NVDA
        vm.expectRevert(abi.encodeWithSelector(HubSettlement.BadMigration.selector, mref));
        hub.reconcile(r, 0, p);
        bytes32 xref = Messages.migrationRef(address(0x1234), 1);
        Messages.Result memory x = Messages.Result(xref, address(0x1234), Messages.Outcome.Bought, 0, 5e18, 0);
        vm.expectRevert(abi.encodeWithSelector(HubSettlement.NotListedHere.selector, address(0x1234)));
        hub.reconcile(x, 0, p);
        assertFalse(hub.reconciled(mref));
        assertFalse(hub.reconciled(xref));

        r.underlying = NVDA;
        hub.reconcile(r, 0, p);
        assertTrue(hub.reconciled(mref));
        assertEq(token.balanceOf(treasury), 5e18, "migration mints to the treasury");
        assertEq(capacity.issuedRaw(NVDA), 5e18);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.AlreadyReconciled.selector, mref));
        hub.reconcile(r, 0, p);
        assertEq(token.totalSupply(), 5e18);
    }

    /// HubSettlement L714: a resume restarts the stale clock for what is still unproven (never forgives it);
    /// L747: a second halt is a no-op.
    function testCovD_StaleClockRestartsAtResumeAndHaltIsIdempotent() public {
        uint256 t0 = vm.getBlockTimestamp(); // cheatcode: via-IR may re-read TIMESTAMP for a local
        _filledBuy(9e18); // LayerZero settlement, unreconciled
        vm.warp(t0 + 5 days);
        vm.prank(owner);
        hub.resumeMints();
        vm.warp(t0 + 8 days + 1);
        hub.checkStale();
        assertFalse(hub.mintsHalted(), "the window counts from the resume");
        vm.warp(t0 + 13 days + 1);
        hub.checkStale();
        assertTrue(hub.mintsHalted(), "still unproven after a full window from the resume");
        vm.recordLogs();
        vm.prank(guardian);
        hub.haltMints();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "already halted: no second MintsHalted");
        assertTrue(hub.mintsHalted());
    }

    // ------------------------------------------------------------------ exits

    /// HubExits L56 buy; L205 own escalation to zero; L57 not open any more; happy path with the gate stub.
    function testCovD_EscalateGuardsAndHappyPath() public {
        _setStub();
        uint256 b = _filledBuy(10e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(HubExits.WrongKind.selector, b));
        hub.escalate{value: 1 ether}(b, rhUser);
        uint256 s = _sell(4e18, 0);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user);
        vm.expectRevert(HubExits.ZeroAddress.selector);
        hub.escalate{value: 1 ether}(s, address(0));
        vm.prank(user);
        hub.escalate{value: 1 ether}(s, rhUser);
        assertEq(uint8(hub.getOrder(s).status), uint8(HubSettlement.Status.Escalated));
        assertEq(address(stub).balance, 1 ether, "hook paid to the gate");
        assertEq(stub.delivers(), 1);
        assertEq(stub.lastRef(), bytes32(s));
        assertEq(stub.lastTo(), rhUser);
        assertEq(stub.lastShares(), 4e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(HubExits.WrongStatus.selector, s, HubSettlement.Status.Escalated));
        hub.escalate{value: 1 ether}(s, rhUser);
    }

    /// HubExits L220: no gate wired -> every canonical send refuses (gate is set once after deployment).
    function testCovD_CanonicalSendsNeedAGate() public {
        _filledBuy(10e18);
        uint256 s = _sell(4e18, 0);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user);
        vm.expectRevert(HubExits.ZeroAddress.selector);
        hub.escalate{value: 1 ether}(s, rhUser);
        vm.prank(user);
        vm.expectRevert(HubExits.ZeroAddress.selector);
        hub.canonicalRedeem{value: 1 ether}(NVDA, 1e18, rhUser, Messages.DeliverMode.Stock);
        assertEq(uint8(hub.getOrder(s).status), uint8(HubSettlement.Status.Pending));
        assertEq(token.balanceOf(user), 6e18);
    }

    /// HubExits L223: a gate that refuses the native hook payment.
    function testCovD_GateRefusingTheHookPayment() public {
        CovDRejectingGate g = new CovDRejectingGate();
        vm.prank(owner);
        hub.setCanonicalGate(address(g));
        _filledBuy(10e18);
        vm.prank(user);
        vm.expectRevert(HubExits.TransferFailed.selector);
        hub.canonicalRedeem{value: 1 ether}(NVDA, 1e18, rhUser, Messages.DeliverMode.Stock);
        assertEq(token.balanceOf(user), 10e18);
    }

    /// HubExits L79/L80; NotListed on an unknown underlying; happy path keeps the sell fee in shares.
    function testCovD_CanonicalRedeemChecks() public {
        _setStub();
        _filledBuy(10e18);
        vm.startPrank(user);
        vm.expectRevert(HubExits.ZeroAmount.selector);
        hub.canonicalRedeem{value: 1 ether}(NVDA, 0, rhUser, Messages.DeliverMode.Stock);
        vm.expectRevert(HubExits.ZeroAddress.selector);
        hub.canonicalRedeem{value: 1 ether}(NVDA, 1e18, address(0), Messages.DeliverMode.Stock);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NotListed.selector, address(0x1234)));
        hub.canonicalRedeem{value: 1 ether}(address(0x1234), 1e18, rhUser, Messages.DeliverMode.Stock);
        uint256 id = hub.canonicalRedeem{value: 1 ether}(NVDA, 1, rhUser, Messages.DeliverMode.Settlement);
        vm.stopPrank();
        assertEq(hub.getOrder(id).amountIn, 1, "1 raw: the 25 bps fee rounds to zero, net stays positive");
        assertEq(token.balanceOf(treasury), 0);
        assertEq(stub.lastShares(), 1);
    }

    /// HubExits L121: an unanswered buy whose owner cancelled may go canonical only 6h after its principal left.
    function testCovD_EscalateFundsUnansweredTooEarlyThenOk() public {
        _setStub();
        uint256 id = _buy(1_000e18, 1, 1 ether);
        _launch(id, 0.5 ether);
        uint64 at0 = uint64(vm.getBlockTimestamp()) + 6 hours;
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.prank(user);
        hub.cancel(id);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(HubExits.TooEarly.selector, id, at0));
        hub.escalateFunds{value: 1 ether}(id, rhUser);
        vm.warp(at0);
        vm.prank(user);
        hub.escalateFunds{value: 1 ether}(id, rhUser);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Escalated));
        assertEq(stub.lastShares(), 0, "a funds delivery carries no shares");
        assertEq(stub.lastRef(), bytes32(id));
    }
}

/// @dev Reward-lane coverage with this test contract registered as the adapter (the hub only requires
///      `rewardAdapter[msg.sender]` and `receiver == msg.sender`).
contract CovDHubRewardTest is StockHubBase {
    uint256 nonce;

    receive() external payable {}

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        hub.setRewardAdapter(address(this), true);
        vm.deal(address(this), 100_000 ether);
        vm.deal(owner, 10 ether);
    }

    function _begin(uint256 budget, uint256 fees) internal returns (bytes32 orderId, uint256 id) {
        orderId = keccak256(abi.encode("covd-reward", ++nonce));
        vm.prank(rewardManager);
        capacity.reserveFor(orderId, NVDA, budget);
        hub.beginFunding{value: budget + fees}(orderId, NVDA, budget, 1, address(this), RELAY);
        id = hub.orderCount() - 1;
    }

    /// Hub L371 receiver; pause; HubSettlement L305 Ops fees below the 25 bps fee.
    function testCovD_BeginFundingGuards() public {
        bytes32 orderId = keccak256("r");
        vm.prank(rewardManager);
        capacity.reserveFor(orderId, NVDA, 200e18);
        vm.expectRevert(SolonStockHub.NotRewardAdapter.selector);
        hub.beginFunding{value: 201e18}(orderId, NVDA, 200e18, 1, address(0xBEEF), RELAY);
        vm.expectRevert(abi.encodeWithSelector(HubSettlement.InsufficientValue.selector, 0.4e18, 0.5e18));
        hub.beginFunding{value: 200.4e18}(orderId, NVDA, 200e18, 1, address(this), RELAY);
        vm.prank(guardian);
        hub.pause();
        vm.expectRevert(Guarded.EnforcedPause.selector);
        hub.beginFunding{value: 201e18}(orderId, NVDA, 200e18, 1, address(this), RELAY);
        vm.prank(owner);
        hub.unpause();
        hub.beginFunding{value: 200.5e18}(orderId, NVDA, 200e18, 1, address(this), RELAY); // fee exactly covered
        assertEq(hub.getOrder(0).extra, 0);
        assertEq(hub.getOrder(0).fee, 0.5e18);
    }

    /// Hub L249 + HubSettlement L382: a reward order whose reserve cannot pay the route is re-queued, not
    /// refunded; after `subsidize` it launches.
    function testCovD_RewardShortOfRouteFeeIsRequeued() public {
        (bytes32 orderId, uint256 id) = _begin(200e18, 0.6e18); // extra 0.1
        assertEq(hub.fundingReceived(orderId), 0);
        vm.expectEmit(true, false, false, true, address(hub));
        emit HubSettlement.AwaitingReturn(id, HubSettlement.Status.Pending, 0.3e18);
        _launch(id, 0.3 ether);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Pending));
        assertEq(route.sentCount(), 0);
        (uint256 total, uint256 waiting) = scheduler.queueLength(1);
        assertEq(total, 2, "re-queued behind itself");
        assertEq(waiting, 1);
        hub.subsidize{value: 0.2 ether}(id);
        _launch(id, 0.3 ether);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Funded));
        assertEq(hub.getOrder(id).extra, 0);
        assertEq(hub.fundingReceived(orderId), 200e18);
    }

    /// Hub L384 owner check; L780 reserve below the LayerZero fee; then subsidized and dispatched.
    function testCovD_SubmitFundedBuyGuards() public {
        (bytes32 orderId, uint256 id) = _begin(200e18, 0.8e18); // extra 0.3
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.WrongStatus.selector, 0, HubSettlement.Status.Pending));
        hub.submitFundedBuy(orderId);
        _launch(id, 0.3 ether); // extra -> 0
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NotYours.selector, 0));
        hub.submitFundedBuy(orderId);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.InsufficientValue.selector, 0, 0.01 ether));
        hub.submitFundedBuy(orderId);
        assertEq(arcEp.packetCount(), 0);
        hub.subsidize{value: 0.01 ether}(id);
        hub.submitFundedBuy(orderId);
        assertEq(arcEp.packetCount(), 1);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Dispatched));
        assertEq(hub.escrowed(), 0.5e18, "principal sent, reserve spent; only the 25 bps fee stays escrowed until fill");
    }

    /// Hub L391-401 (requestCancel never called before): owner, status and once.
    function testCovD_RequestCancelRules() public {
        vm.expectRevert(SolonStockHub.BadRewardOrder.selector);
        hub.requestCancel(keccak256("nope"));
        (bytes32 a, uint256 ia) = _begin(200e18, 0.8e18);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.WrongStatus.selector, 0, HubSettlement.Status.Pending));
        hub.requestCancel(a);
        _launch(ia, 0.3 ether); // Funded
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.NotYours.selector, 0));
        hub.requestCancel(a);
        hub.requestCancel(a);
        assertTrue(hub.getOrder(ia).cancelRequested);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.WrongStatus.selector, 0, HubSettlement.Status.Funded));
        hub.requestCancel(a);
        (bytes32 b, uint256 ib) = _begin(200e18, 0.81e18);
        _launch(ib, 0.3 ether);
        hub.submitFundedBuy(b); // Dispatched
        hub.requestCancel(b);
        assertTrue(hub.getOrder(ib).cancelRequested);
        assertEq(uint8(hub.getOrder(ib).status), uint8(HubSettlement.Status.Dispatched), "no float: waits for money");
    }

    /// Hub L827 unknown reward id; HubSettlement L320/L322 claimResult unknown / not the adapter.
    function testCovD_RewardIdGuards() public {
        vm.expectRevert(SolonStockHub.BadRewardOrder.selector);
        hub.fundingReceived(keccak256("nope"));
        vm.expectRevert(HubSettlement.BadRewardOrder.selector);
        hub.claimResult(keccak256("nope"), "");
        (bytes32 orderId, uint256 id) = _begin(200e18, 0.8e18);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(HubSettlement.NotYours.selector, id));
        hub.claimResult(orderId, "");
        (uint8 st, uint256 raw, uint256 refund) = hub.claimResult(orderId, "");
        assertEq(st, 0);
        assertEq(raw, 0);
        assertEq(refund, 0);
        vm.prank(owner);
        hub.cancelReward(id);
        assertEq(hub.fundingReceived(orderId), 0, "cancelled reads as nothing funded");
    }

    /// HubExits L115: escalateFunds is public-lane only.
    function testCovD_EscalateFundsRefusesRewardLane() public {
        (, uint256 id) = _begin(200e18, 0.8e18);
        _launch(id, 0.3 ether);
        vm.expectRevert(abi.encodeWithSelector(HubExits.WrongStatus.selector, id, HubSettlement.Status.Funded));
        hub.escalateFunds{value: 1 ether}(id, address(this));
    }

    /// HubExits L186: the operator's void needs the order's reserve to cover the fee the caller did not pay.
    function testCovD_VoidReserveTooSmall() public {
        (, uint256 id) = _begin(200e18, 0.8e18);
        _launch(id, 0.3 ether); // extra 0
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HubExits.InsufficientValue.selector, 0, 0.01 ether));
        hub.voidOrder(id);
        assertFalse(hub.getOrder(id).voided);
        vm.prank(owner);
        hub.voidOrder{value: 0.01 ether}(id); // caller pays
        assertFalse(hub.getOrder(id).voided, "a caller-paid void does not use the reserve's one free void");
        assertEq(Messages.decodeOrder(arcEp.packetMessage(0)).amountIn, 0);
    }

    /// HubExits L183: the reserve pays for one void only; a repeat must be paid by its caller.
    function testCovD_SecondVoidNeedsTheCallersFee() public {
        (, uint256 id) = _begin(200e18, 0.82e18); // extra 0.32
        _launch(id, 0.3 ether); // extra 0.02
        vm.prank(owner);
        hub.voidOrder(id);
        assertTrue(hub.getOrder(id).voided);
        assertEq(hub.getOrder(id).extra, 0.01 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HubExits.InsufficientValue.selector, 0, 0.01 ether));
        hub.voidOrder(id);
        assertEq(hub.getOrder(id).extra, 0.01 ether, "the reserve is not touched again");
        vm.prank(owner);
        hub.voidOrder{value: 0.01 ether}(id);
        assertEq(arcEp.packetCount(), 2);
    }

    /// Hub L843 (`_payNative`): defensive; only reachable if the hub held less native than it escrows.
    ///      Forced here with vm.deal to show the guard fails closed.
    function testCovD_PayNativeFailsClosedOnInsolvency() public {
        (bytes32 orderId, uint256 id) = _begin(200e18, 0.81e18);
        _launch(id, 0.3 ether); // extra 0.01 = the LayerZero fee
        vm.deal(address(hub), 0);
        vm.expectRevert(abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, 0));
        hub.submitFundedBuy(orderId);
    }
}

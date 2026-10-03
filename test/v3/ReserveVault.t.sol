// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {SolonStockToken} from "../../src/v3/stock/SolonStockToken.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";
import {OrderScheduler} from "../../src/v3/stock/OrderScheduler.sol";
import {ReserveVault} from "../../src/v3/stock/robinhood/ReserveVault.sol";
import {RestrictedVenue} from "../../src/v3/stock/robinhood/RestrictedVenue.sol";
import {IV3SwapRouter} from "../../src/v3/stock/interfaces/IV3SwapRouter.sol";
import {Messages} from "../../src/v3/stock/libs/Messages.sol";
import {AddressAlias} from "../../src/v3/stock/libs/Arbitrum.sol";
import {
    MockLzEndpoint,
    MockNativeRoute,
    MockTokenRoute,
    MockUSDG,
    MockRHStock,
    MockVenue,
    MockArbSys
} from "./helpers/StockMocks.sol";

/// @notice Arc hub + RH vault wired through two LayerZero endpoint doubles and the two money routes.
abstract contract StockSystemBase is Test {
    uint32 constant ARC_EID = 30417;
    uint32 constant RH_EID = 30416;
    bytes32 constant RELAY = keccak256("RELAY");

    MockLzEndpoint arcEp;
    MockLzEndpoint rhEp;
    SolonStockHub hub;
    CapacityController capacity;
    OrderScheduler scheduler;
    MockNativeRoute route;
    MockTokenRoute returnRoute;
    MockUSDG usdg;
    MockRHStock stock;
    MockVenue venue;
    MockArbSys arbSys;
    ReserveVault vault;
    SolonStockToken token;

    address owner = address(0xA11CE);
    address guardian = address(0x6A2D);
    address treasury = address(0x7EA5);
    address rhTreasury = address(0x7EA6);
    address ops = address(0x0B5);
    address bridgerL1 = address(0xB41D);
    address user = address(0xB0B);

    function setUp() public virtual {
        arcEp = new MockLzEndpoint(ARC_EID);
        rhEp = new MockLzEndpoint(RH_EID);
        arcEp.connect(rhEp);
        rhEp.connect(arcEp);
        usdg = new MockUSDG();
        stock = new MockRHStock();
        venue = new MockVenue(usdg, stock);
        arbSys = new MockArbSys();
        hub = new SolonStockHub(address(arcEp), treasury, 25, owner, ops, [address(0xF1), address(0xF2)]);
        capacity = new CapacityController(owner, guardian);
        scheduler = new OrderScheduler(address(hub), capacity);
        vault = new ReserveVault(
            address(rhEp),
            ARC_EID,
            address(usdg),
            address(venue),
            address(arbSys),
            bridgerL1,
            owner,
            rhTreasury,
            [address(0xF3), address(0xF4)]
        );
        route = new MockNativeRoute(address(hub), address(vault), usdg);
        returnRoute = new MockTokenRoute(address(hub), usdg);
        returnRoute.setCaller(address(vault));
        vm.startPrank(owner);
        capacity.bind(address(hub), _rewardManager());
        hub.setCapacity(capacity, scheduler);
        hub.setPeer(RH_EID, bytes32(uint256(uint160(address(vault)))));
        token = hub.listStock(address(stock), "NVDA", RH_EID, 4663, 1_000_000e18, address(route), RELAY);
        vault.setPeer(ARC_EID, bytes32(uint256(uint160(address(hub)))));
        vault.listStock(address(stock), "NVDA");
        vault.setReturnRoute(address(returnRoute));
        vault.setKeeper(address(this)); // the suite plays the RH vault keeper (returnFunds is keeper/owner only)
        vm.stopPrank();
        vm.deal(user, 100_000 ether);
        vm.deal(address(vault), 10 ether); // LayerZero gas for results
    }

    function _rewardManager() internal view virtual returns (address) {
        return address(0x4E3);
    }

    function _buy(uint256 usdcIn, uint256 minShares) internal returns (uint256 id) {
        vm.prank(user);
        id = hub.requestBuy{value: usdcIn + 1 ether}(address(stock), usdcIn, minShares);
        scheduler.launchNext(id, abi.encode(uint256(0.5 ether), bytes("ok")));
    }

    function _deliverLatestOrder() internal {
        arcEp.deliver(arcEp.packetCount() - 1);
    }

    function _deliverLatestResult() internal {
        rhEp.deliver(rhEp.packetCount() - 1);
    }

    /// Full happy-path buy: money, message, result. Returns the order id.
    function _boughtOrder(uint256 usdcIn) internal returns (uint256 id) {
        id = _buy(usdcIn, 1);
        route.fill(route.sentCount() - 1, (usdcIn - usdcIn * 25 / 10_000) / 1e12);
        _deliverLatestOrder();
        _deliverLatestResult();
    }
}

contract ReserveVaultTest is StockSystemBase {
    function testMessageFirstWaitsForItsOwnMoneyThenExecutesExactlyOnce() public {
        uint256 a = _buy(1_000e18, 1);
        _deliverLatestOrder();
        assertEq(rhEp.packetCount(), 0, "no result before the money arrives");
        assertEq(vault.waitingOrder(bytes32(a)).amountIn, 997_500_000);
        // Another order's money must never fund this one.
        uint256 b = _buy(1_000e18, 1);
        route.fill(1, 997_500_000);
        assertEq(vault.funding(bytes32(b)), 997_500_000);
        vm.expectRevert(abi.encodeWithSelector(ReserveVault.NotWaiting.selector, bytes32(a)));
        vault.executeFunded(bytes32(a));
        route.fill(0, 997_500_000);
        vault.executeFunded(bytes32(a));
        _deliverLatestResult();
        assertEq(token.balanceOf(user), 9.975e18, "raw 1:1 with the RH purchase");
        assertEq(vault.entitledOf(address(stock)), 9.975e18);
        assertEq(vault.funding(bytes32(a)), 0);
        vm.expectRevert();
        vault.executeFunded(bytes32(a));
        uint256 results = rhEp.packetCount();
        arcEp.redeliver(0); // replayed order message
        assertEq(rhEp.packetCount(), results, "a settled ref is ignored");
        assertEq(stock.balanceOf(address(vault)), 9.975e18);
    }

    function testMoneyFirstThenMessageExecutesOnArrival() public {
        uint256 id = _buy(1_000e18, 1);
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        assertEq(rhEp.packetCount(), 1);
        _deliverLatestResult();
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
        assertEq(capacity.issuedRaw(address(stock)), 9.975e18);
    }

    function testBuyFailureKeepsItsFundingAndReturnsItToThatOrder() public {
        venue.setFail(true);
        uint256 before = user.balance;
        uint256 id = _buy(1_000e18, 1);
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        _deliverLatestResult();
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Returning));
        assertEq(vault.funding(bytes32(id)), 997_500_000, "unspent money is still this ref's");
        assertEq(vault.settlementLiabilities(), 997_500_000);
        assertEq(vault.freeSettlement(), 0);
        vault.returnFunds(bytes32(id), 997e18, "ok");
        assertEq(usdg.balanceOf(address(returnRoute)), 997_500_000);
        assertEq(vault.settlementLiabilities(), 0);
        vm.deal(address(this), 1_000 ether);
        returnRoute.complete{value: 997.1e18}(0, payable(address(route)), 997.1e18);
        // principal back net of both route legs; fee and unused reserve returned in full
        assertEq(user.balance, before - 1_001 ether + 997.1e18 + 2.5e18 + 0.49 ether);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Cancelled));
        vm.expectRevert();
        vault.returnFunds(bytes32(id), 1, "ok"); // nothing left to return twice
    }

    /// review finding #2: the return route checks the quote signature but not which Relay order (recipient) the
    /// opaque order id stands for, so a valid quote alone must not let anyone send a ref's money back.
    function testReturnFundsKeeperOrOwnerOnly() public {
        venue.setFail(true);
        uint256 id = _buy(1_000e18, 1);
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        _deliverLatestResult();
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(ReserveVault.NotKeeper.selector);
        vault.returnFunds(bytes32(id), 997e18, "ok"); // a valid ("ok") quote is not enough
        vm.prank(user);
        vm.expectRevert(ReserveVault.NotKeeper.selector);
        vault.returnFunds(bytes32(id), 997e18, "ok");
        assertEq(vault.funding(bytes32(id)), 997_500_000, "nothing moved");
        vault.returnFunds(bytes32(id), 997e18, "ok"); // the keeper
        assertEq(usdg.balanceOf(address(returnRoute)), 997_500_000);
        assertEq(vault.settlementLiabilities(), 0);
    }

    function testReturnFundsByOwner() public {
        _boughtOrder(1_000e18);
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 990e18);
        _deliverLatestOrder();
        _deliverLatestResult();
        vm.prank(owner);
        vault.returnFunds(bytes32(id), 997e18, "ok");
        assertEq(usdg.balanceOf(address(returnRoute)), 997_500_000);
    }

    function testSellProceedsAreALiabilityUntilReturned() public {
        _boughtOrder(1_000e18);
        uint256 before = user.balance;
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 990e18);
        _deliverLatestOrder();
        assertEq(vault.proceeds(bytes32(id)), 997_500_000);
        assertEq(vault.entitledOf(address(stock)), 0);
        vm.prank(owner);
        vm.expectRevert();
        vault.withdrawFloat(address(usdg), address(0xF3), 1);
        _deliverLatestResult();
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Proceeds));
        vault.returnFunds(bytes32(id), 997e18, "ok");
        vm.deal(address(this), 1_000 ether);
        returnRoute.complete{value: 997.2e18}(0, payable(address(route)), 997.2e18);
        assertEq(user.balance, before - 0.01 ether + 997.2e18 - 2.49375e18);
        assertEq(capacity.exposureUsd(), 0);
    }

    function testFloatWithdrawalsOnlyFreeOnlyWhitelistedNeverStock() public {
        _boughtOrder(1_000e18);
        usdg.mint(address(vault), 50e6); // an operator's independent top-up
        vm.startPrank(owner);
        vm.expectRevert(ReserveVault.NotFloatRecipient.selector);
        vault.withdrawFloat(address(usdg), address(0xEE), 1);
        vm.expectRevert();
        vault.withdrawFloat(address(usdg), address(0xF3), 50e6 + 1);
        vm.expectRevert();
        vault.withdrawFloat(address(stock), address(0xF3), 1);
        vault.withdrawFloat(address(usdg), address(0xF3), 50e6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(0xF3)), 50e6);
    }

    function testSkimTakesOnlyDonationsToTheFixedTreasury() public {
        _boughtOrder(1_000e18);
        vm.prank(owner);
        vm.expectRevert(ReserveVault.NothingToSkim.selector);
        vault.skimExcess(address(stock));
        stock.mint(address(vault), 1e18);
        vm.prank(owner);
        vault.skimExcess(address(stock));
        assertEq(stock.balanceOf(rhTreasury), 1e18);
        assertTrue(vault.isFullyBacked(address(stock)));
    }

    function testCanonicalDeliveryBothModesAndBlockedRecipientStaysOwed() public {
        _boughtOrder(1_000e18);
        address alias_ = AddressAlias.applyL1ToL2Alias(bridgerL1);
        address rhUser = address(0xCAFE);
        uint256 seq = vault.resultCount();
        vm.prank(alias_);
        vault.deliver(Messages.Deliver(bytes32(uint256(77)), address(stock), 2e18, rhUser, Messages.DeliverMode.Stock));
        assertEq(stock.balanceOf(rhUser), 2e18);
        assertEq(vault.entitledOf(address(stock)), 7.975e18);
        Messages.Result memory r = vault.resultAt(seq);
        assertEq(r.ref, bytes32(uint256(77)));
        assertEq(uint8(r.outcome), uint8(Messages.Outcome.Sold));
        assertEq(r.amountOut, 0, "Arc owes nothing for a canonical delivery");
        // Settlement mode sells with no floor and pays USDG here.
        vm.prank(alias_);
        vault.deliver(
            Messages.Deliver(bytes32(uint256(78)), address(stock), 1e18, rhUser, Messages.DeliverMode.Settlement)
        );
        assertEq(usdg.balanceOf(rhUser), 100e6);
        // Settlement fails -> falls back to the stock; a blocked recipient -> claimable, still backed.
        venue.setFail(true);
        stock.setBlocked(rhUser, true);
        vm.prank(alias_);
        vault.deliver(
            Messages.Deliver(bytes32(uint256(79)), address(stock), 1e18, rhUser, Messages.DeliverMode.Settlement)
        );
        assertEq(vault.claimable(address(stock), rhUser), 1e18);
        assertEq(vault.claimableTotal(address(stock)), 1e18);
        assertTrue(vault.isFullyBacked(address(stock)));
        stock.mint(address(vault), 0.5e18);
        vm.prank(owner);
        vault.skimExcess(address(stock));
        assertEq(stock.balanceOf(rhTreasury), 0.5e18, "skim never takes the claimable raw");
        vm.prank(address(0xBAD));
        vm.expectRevert();
        vault.deliver(Messages.Deliver(bytes32(uint256(80)), address(stock), 1e18, rhUser, Messages.DeliverMode.Stock));
        // replay of a settled ref is a no-op
        vm.prank(alias_);
        vault.deliver(Messages.Deliver(bytes32(uint256(77)), address(stock), 2e18, rhUser, Messages.DeliverMode.Stock));
        assertEq(vault.entitledOf(address(stock)), 5.975e18);
    }

    function testCanonicalDeliveryOfStuckFundsForASettledRef() public {
        venue.setFail(true);
        uint256 id = _buy(1_000e18, 1);
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        address alias_ = AddressAlias.applyL1ToL2Alias(bridgerL1);
        vm.prank(alias_);
        vault.deliver(
            Messages.Deliver(bytes32(id), address(stock), 0, address(0xCAFE), Messages.DeliverMode.Settlement)
        );
        assertEq(usdg.balanceOf(address(0xCAFE)), 997_500_000);
        assertEq(vault.settlementLiabilities(), 0);
    }

    function testLyingVenueCannotInflateRaw() public {
        venue.setShortBy(1);
        uint256 id = _buy(1_000e18, 1);
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        _deliverLatestResult();
        assertEq(token.balanceOf(user), 9.975e18 - 1, "only what landed in the reserve is minted");
        assertEq(vault.entitledOf(address(stock)), stock.balanceOf(address(vault)));
        uint256 id2 = _buy(1_000e18, 9.975e18);
        route.fill(1, 997_500_000);
        _deliverLatestOrder();
        _deliverLatestResult();
        assertEq(uint8(hub.getOrder(id2).status), uint8(HubSettlement.Status.Returning), "below the order floor fails");
        id;
    }

    function testMultiplierIsDisplayOnly() public {
        _boughtOrder(1_000e18);
        stock.setMultiplier(4e18); // 4:1 forward split
        (uint256 reserveRaw, uint256 entitledRaw,,,,,, uint256 m) = vault.porSnapshot(address(stock));
        assertEq(m, 4e18);
        assertEq(reserveRaw, 9.975e18);
        assertEq(entitledRaw, 9.975e18);
        assertEq(token.balanceOf(user), 9.975e18, "raw units never re-scaled");
    }

    function testAccelerationFloatAdvancesAndLateFundingRefillsIt() public {
        usdg.mint(address(vault), 2_000e6);
        vm.prank(owner);
        vault.setFloatEnabled(true);
        uint256 id = _buy(1_000e18, 1);
        _deliverLatestOrder();
        assertEq(rhEp.packetCount(), 1, "the float advanced the purchase");
        assertEq(vault.advanced(bytes32(id)), 997_500_000);
        assertEq(vault.freeSettlement(), 2_000e6 - 997_500_000);
        route.fill(0, 997_500_000);
        assertEq(vault.funding(bytes32(id)), 0);
        assertEq(vault.advanced(bytes32(id)), 0);
        assertEq(vault.freeSettlement(), 2_000e6, "late funding refilled the float");
    }

    function testVenueAndReturnRouteChangesWaitFortyEightHours() public {
        MockVenue other = new MockVenue(usdg, stock);
        vm.startPrank(owner);
        vault.proposeVenue(address(other));
        vm.expectRevert(ReserveVault.Timelocked.selector);
        vault.executeVenue();
        vm.warp(block.timestamp + 48 hours);
        vault.executeVenue();
        assertEq(address(vault.venue()), address(other));
        vm.expectRevert(ReserveVault.Timelocked.selector);
        vault.setPeer(ARC_EID, bytes32(uint256(1)));
        vm.stopPrank();
    }
}

contract MockV3Router is IV3SwapRouter {
    uint256 public lie;
    uint256 public price6 = 100e6;

    function setLie(uint256 l) external {
        lie = l;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        bool buying = IERC20(p.tokenIn).totalSupply() > 0 && _isUsd(p.tokenIn);
        amountOut = buying ? p.amountIn * 1e18 / price6 : p.amountIn * price6 / 1e18;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        if (buying) MockRHStock(p.tokenOut).mint(p.recipient, amountOut);
        else MockUSDG(p.tokenOut).mint(p.recipient, amountOut);
        amountOut += lie;
    }

    function _isUsd(address t) private view returns (bool) {
        return MockUSDG(t).decimals() == 6;
    }
}

contract RestrictedVenueTest is Test {
    MockUSDG usdg;
    MockRHStock stock;
    MockV3Router router;
    RestrictedVenue venue;
    address vault = address(0x7A);

    function setUp() public {
        usdg = new MockUSDG();
        stock = new MockRHStock();
        router = new MockV3Router();
        venue = new RestrictedVenue(address(router), address(usdg), address(usdg), address(0), address(this));
        venue.setVault(vault);
        venue.setPool(address(stock), 3000);
        usdg.mint(vault, 10_000e6);
        vm.prank(vault);
        usdg.approve(address(venue), type(uint256).max);
    }

    function testOnlyVaultTradesAndVaultBindsOnce() public {
        vm.expectRevert(RestrictedVenue.NotVault.selector);
        venue.buy(address(stock), 100e6, 1, address(this));
        vm.expectRevert(RestrictedVenue.AlreadySet.selector);
        venue.setVault(address(this));
    }

    function testBuyReportsLandedSharesNotTheRoutersClaim() public {
        router.setLie(5e18);
        vm.prank(vault);
        uint256 out = venue.buy(address(stock), 100e6, 1e18, vault);
        assertEq(out, 1e18);
        assertEq(stock.balanceOf(vault), 1e18);
    }

    function testOrderMinOutIsPassedThrough() public {
        vm.prank(vault);
        vm.expectRevert(bytes("Too little received"));
        venue.buy(address(stock), 100e6, 1e18 + 1, vault);
    }

    function testPoolChangesWaitFortyEightHours() public {
        venue.setPool(address(stock), 500);
        assertEq(venue.poolFee(address(stock)), 3000);
        vm.expectRevert(RestrictedVenue.Timelocked.selector);
        venue.executePool(address(stock));
        vm.warp(block.timestamp + 48 hours);
        venue.executePool(address(stock));
        assertEq(venue.poolFee(address(stock)), 500);
    }
}

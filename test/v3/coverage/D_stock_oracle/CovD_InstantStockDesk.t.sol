// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {InstantStockDesk} from "../../../../src/v3/stock/InstantStockDesk.sol";
import {SolonStockOracle} from "../../../../src/v3/oracle/SolonStockOracle.sol";
import {MockPriceSource, OracleTestLib} from "../../helpers/OracleMocks.sol";
import {DeskStockToken, DeskHubMock} from "../../InstantStockDesk.t.sol";

contract CovDDeskRejecter {
    receive() external payable {
        revert("no native");
    }
}

/// @notice InstantStockDesk is NOT deployed (PLAN r8 §0, rejected). Cheap branch coverage of its guards so the
///         artifact stays honest if it is ever revived; same fixture as InstantStockDeskTest.
contract CovDInstantStockDeskTest is Test {
    address constant OWNER = address(0x71);
    address constant GUARDIAN = address(0x6A);
    address constant RESTOCKER = address(0xB07);
    address constant TREASURY = address(0x7EA5);
    address constant RH_RECIPIENT = address(0x7EA6);
    address constant NVDA = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    address constant USER = address(0xA11CE);

    event Funded(address indexed from, uint256 amount);

    DeskStockToken stock;
    DeskHubMock hub;
    SolonStockOracle oracle;
    MockPriceSource source;
    InstantStockDesk desk;

    function setUp() public {
        vm.warp(1_760_000_000);
        stock = new DeskStockToken();
        hub = new DeskHubMock();
        hub.list(address(stock), NVDA);
        source = new MockPriceSource();
        oracle = new SolonStockOracle(OWNER, GUARDIAN);
        vm.prank(OWNER);
        oracle.configureAsset(NVDA, address(stock), source, OracleTestLib.params());
        source.set(NVDA, 200e18, 1); // $200
        oracle.poke(address(stock));
        desk = new InstantStockDesk(OWNER, GUARDIAN, address(hub), address(oracle), RESTOCKER, TREASURY, RH_RECIPIENT);
        vm.prank(OWNER);
        desk.setTerms(address(stock), 50, 100, 10_000e18, 20_000e18, true);
        stock.mint(address(desk), 100e18);
        vm.deal(address(desk), 10_000e18);
        vm.deal(USER, 100_000e18);
        stock.mint(USER, 100e18);
        vm.prank(USER);
        stock.approve(address(desk), type(uint256).max);
    }

    // L132 (buy + sell), L294 (stranger / owner arms)
    function test_pause_blocksBothSides_ownerMayPause() public {
        vm.prank(USER);
        vm.expectRevert(InstantStockDesk.NotGuardian.selector);
        desk.pause();
        vm.prank(OWNER);
        desk.pause();
        assertTrue(desk.paused());
        vm.startPrank(USER);
        vm.expectRevert(InstantStockDesk.IsPaused.selector);
        desk.buy{value: 1e18}(address(stock), 0, address(0));
        vm.expectRevert(InstantStockDesk.IsPaused.selector);
        desk.sell(address(stock), 1e18, 0, address(0));
        vm.stopPrank();
        (uint256 b, uint256 s) = desk.capacity(address(stock));
        assertEq(b + s, 0);
    }

    // L146 / L166
    function test_zeroAmounts_revert() public {
        vm.startPrank(USER);
        vm.expectRevert(InstantStockDesk.ZeroAmount.selector);
        desk.buy(address(stock), 0, address(0));
        vm.expectRevert(InstantStockDesk.ZeroAmount.selector);
        desk.sell(address(stock), 0, 0, address(0));
        vm.stopPrank();
    }

    // L173 / L174 / L177
    function test_sell_outOfUsdc_slippage_refusingRecipient() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.Slippage.selector, 396e18, 397e18));
        desk.sell(address(stock), 2e18, 397e18, address(0));
        CovDDeskRejecter rej = new CovDDeskRejecter();
        vm.prank(USER);
        vm.expectRevert(InstantStockDesk.TransferFailed.selector);
        desk.sell(address(stock), 2e18, 0, address(rej));
        assertEq(stock.balanceOf(USER), 100e18, "shares not taken");
        assertEq(address(desk).balance, 10_000e18);
        vm.prank(OWNER);
        desk.withdraw(address(0), 9_900e18);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.OutOfUsdc.selector, 396e18, 100e18));
        desk.sell(address(stock), 2e18, 0, address(0));
        (uint256 q, bool ok) = desk.quoteSell(address(stock), 2e18);
        assertEq(q, 396e18);
        assertFalse(ok, "quote agrees: not enough USDC");
    }

    // L191 (price 0: unlisted and stale-oracle arms), L367 (_peek unlisted)
    function test_quotes_noPrice() public {
        (uint256 q, bool ok) = desk.quoteSell(address(0xBEEF), 1e18);
        assertEq(q, 0);
        assertFalse(ok);
        (q, ok) = desk.quoteBuy(address(0xBEEF), 1e18);
        assertEq(q, 0);
        assertFalse(ok);
        (uint256 b, uint256 s) = desk.capacity(address(0xBEEF));
        assertEq(b + s, 0);
        vm.warp(block.timestamp + 16 minutes); // stale: execPrice reverts, caught
        (q, ok) = desk.quoteSell(address(stock), 1e18);
        assertEq(q, 0);
        assertFalse(ok);
    }

    // L222 / L234 / L354
    function test_restockUnstock_outOfUsdc_and_unlisted() public {
        vm.prank(OWNER);
        desk.withdraw(address(0), 9_500e18); // 500 left
        vm.startPrank(RESTOCKER);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.OutOfUsdc.selector, 1_000.05e18, 500e18));
        desk.restock(address(stock), 1_000e18, 4.9375e18);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.NotListed.selector, address(0xBEEF)));
        desk.restock(address(0xBEEF), 1e18, 1);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.NotListed.selector, address(0xBEEF)));
        desk.unstock(address(0xBEEF), 1e18, 1);
        vm.stopPrank();
        vm.prank(OWNER);
        desk.withdraw(address(0), 500e18); // empty
        vm.prank(RESTOCKER);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.OutOfUsdc.selector, 0.05e18, 0));
        desk.unstock(address(stock), 2e18, 395e18);
        assertEq(hub.callCount(), 0);
    }

    // L285
    function test_withdrawNative_treasuryRefuses_reverts() public {
        vm.etch(TREASURY, hex"60006000fd");
        vm.prank(OWNER);
        vm.expectRevert(InstantStockDesk.TransferFailed.selector);
        desk.withdraw(address(0), 1e18);
        assertEq(address(desk).balance, 10_000e18);
    }

    // L313 (stale hour reads as zero), receive(), terms()
    function test_flowResetsByHour_receive_terms() public {
        vm.prank(USER);
        desk.buy{value: 1_000e18}(address(stock), 0, address(0));
        (uint256 bought,) = desk.flowOf(address(stock));
        assertEq(bought, 1_000e18);
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours);
        (uint256 b2, uint256 s2) = desk.flowOf(address(stock));
        assertEq(b2 + s2, 0);
        vm.expectEmit(address(desk));
        emit Funded(USER, 5e18);
        vm.prank(USER);
        (bool ok,) = payable(address(desk)).call{value: 5e18}("");
        assertTrue(ok);
        InstantStockDesk.Terms memory t = desk.terms(address(stock));
        assertEq(t.underlying, NVDA);
        assertEq(t.spreadBps, 50);
        assertEq(t.sellSpreadBps, 100);
        assertEq(t.maxTradeUsd, 10_000e18);
        assertEq(t.flowCapUsd, 20_000e18);
        assertTrue(t.enabled);
    }
}

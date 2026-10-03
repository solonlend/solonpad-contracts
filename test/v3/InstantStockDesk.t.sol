// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {InstantStockDesk} from "../../src/v3/stock/InstantStockDesk.sol";
import {SolonStockOracle} from "../../src/v3/oracle/SolonStockOracle.sol";
import {MockPriceSource, OracleTestLib} from "./helpers/OracleMocks.sol";

contract DeskStockToken is ERC20("NVDA.sol", "NVDA.sol") {
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @notice The hub entry points the desk uses (listing lookup, order entry, exits).
contract DeskHubMock {
    mapping(address => address) public underlyingOfToken;
    mapping(address => bool) public paused;
    struct Call {
        uint8 kind; // 0 buy, 1 sell, 2 cancel, 3 claim, 4 escalate, 5 escalateFunds
        address underlying;
        uint256 amount;
        uint256 min;
        uint256 value;
        address to;
    }
    Call[] public calls;

    function list(address token, address underlying) external {
        underlyingOfToken[token] = underlying;
    }

    function setPaused(address token, bool p) external {
        paused[token] = p;
    }

    function stockState(address token) external view returns (bool, bool, uint256) {
        bool listed = underlyingOfToken[token] != address(0);
        return (listed && !paused[token], listed && !paused[token], 1);
    }

    function quoteOrder(address) external pure returns (uint256) {
        return 0.05 ether;
    }

    function requestBuy(address u, uint256 usdcIn, uint256 minOut) external payable returns (uint256) {
        calls.push(Call(0, u, usdcIn, minOut, msg.value, address(0)));
        return calls.length;
    }

    function requestSell(address u, uint256 sharesIn, uint256 minOut) external payable returns (uint256) {
        calls.push(Call(1, u, sharesIn, minOut, msg.value, address(0)));
        return calls.length;
    }

    function cancel(uint256 id) external {
        calls.push(Call(2, address(0), id, 0, 0, address(0)));
    }

    function claim(uint256 id) external {
        calls.push(Call(3, address(0), id, 0, 0, address(0)));
    }

    function escalate(uint256 id, address to) external payable {
        calls.push(Call(4, address(0), id, 0, msg.value, to));
    }

    function escalateFunds(uint256 id, address to) external payable {
        calls.push(Call(5, address(0), id, 0, msg.value, to));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }
}

contract InstantStockDeskTest is Test {
    address constant OWNER = address(0x71);
    address constant GUARDIAN = address(0x6A);
    address constant RESTOCKER = address(0xB07);
    address constant TREASURY = address(0x7EA5);
    address constant RH_RECIPIENT = address(0x7EA6);
    address constant NVDA = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    address constant USER = address(0xA11CE);

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
        source.set(NVDA, 200e18, 1); // $200 per NVDA.sol
        oracle.poke(address(stock));
        desk = new InstantStockDesk(OWNER, GUARDIAN, address(hub), address(oracle), RESTOCKER, TREASURY, RH_RECIPIENT);
        vm.prank(OWNER);
        desk.setTerms(address(stock), 50, 100, 10_000e18, 20_000e18, true); // 0.5% / 1%, $10k trade, $20k/h
        stock.mint(address(desk), 100e18);
        vm.deal(address(desk), 10_000e18);
        vm.deal(USER, 100_000e18);
        stock.mint(USER, 100e18);
        vm.prank(USER);
        stock.approve(address(desk), type(uint256).max);
    }

    function testBuyAtOraclePriceLessSpread() public {
        vm.prank(USER);
        uint256 out = desk.buy{value: 1_000e18}(address(stock), 0, address(0));
        assertEq(out, 4.975e18, "$1,000 / $200 * 99.5%");
        assertEq(stock.balanceOf(USER), 104.975e18);
        (uint256 bought,) = desk.flowOf(address(stock));
        assertEq(bought, 1_000e18);
    }

    function testSellAtOraclePriceLessSpread() public {
        uint256 before = USER.balance;
        vm.prank(USER);
        uint256 out = desk.sell(address(stock), 2e18, 0, address(0));
        assertEq(out, 396e18, "2 * $200 * 99%");
        assertEq(USER.balance, before + 396e18);
        assertEq(stock.balanceOf(address(desk)), 102e18);
    }

    function testTradeAndHourlyFlowCaps() public {
        stock.mint(address(desk), 1_000e18);
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.OverTradeCap.selector, 10_001e18, 10_000e18));
        desk.buy{value: 10_001e18}(address(stock), 0, address(0));
        desk.buy{value: 10_000e18}(address(stock), 0, address(0));
        desk.buy{value: 9_000e18}(address(stock), 0, address(0));
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.OverFlowCap.selector, 2_000e18, 1_000e18));
        desk.buy{value: 2_000e18}(address(stock), 0, address(0));
        vm.warp((block.timestamp / 1 hours + 1) * 1 hours); // next clock hour
        source.set(NVDA, 200e18, 2);
        desk.buy{value: 2_000e18}(address(stock), 0, address(0));
        vm.stopPrank();
    }

    function testInventoryAndSlippageLimits() public {
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.Slippage.selector, 4.975e18, 5e18));
        desk.buy{value: 1_000e18}(address(stock), 5e18, address(0));
        vm.prank(OWNER);
        desk.withdraw(address(stock), 99e18);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.OutOfStock.selector, 4.975e18, 1e18));
        desk.buy{value: 1_000e18}(address(stock), 0, address(0));
    }

    function testNoLivePriceNoTrade() public {
        vm.warp(block.timestamp + 16 minutes); // observation older than maxAge
        vm.prank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(SolonStockOracle.PriceNotLive.selector, address(stock), SolonStockOracle.Status.Stale)
        );
        desk.buy{value: 100e18}(address(stock), 0, address(0));
        (uint256 q, bool ok) = desk.quoteBuy(address(stock), 100e18);
        assertEq(q, 0);
        assertFalse(ok);
        (uint256 b, uint256 s) = desk.capacity(address(stock));
        assertEq(b + s, 0);
    }

    function testHubTradingPauseAndDeskPause() public {
        hub.setPaused(address(stock), true);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.NotListed.selector, address(stock)));
        desk.buy{value: 100e18}(address(stock), 0, address(0));
        hub.setPaused(address(stock), false);
        vm.prank(GUARDIAN);
        desk.pause();
        vm.prank(USER);
        vm.expectRevert(InstantStockDesk.IsPaused.selector);
        desk.buy{value: 100e18}(address(stock), 0, address(0));
        vm.prank(GUARDIAN);
        vm.expectRevert(InstantStockDesk.NotOwner.selector);
        desk.unpause();
        vm.prank(OWNER);
        desk.unpause();
        vm.prank(USER);
        desk.buy{value: 100e18}(address(stock), 0, address(0));
    }

    function testRestockMinimumsAreOracleBound() public {
        vm.prank(USER);
        vm.expectRevert(InstantStockDesk.NotRestocker.selector);
        desk.restock(address(stock), 1_000e18, 5e18);
        vm.startPrank(RESTOCKER);
        // $1,000 at $200 = 5 shares; floor = 5 * (1 - 0.25% - 1%) = 4.9375
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.Slippage.selector, 4.9e18, 4.9375e18));
        desk.restock(address(stock), 1_000e18, 4.9e18);
        uint256 id = desk.restock(address(stock), 1_000e18, 4.9375e18);
        (uint8 kind, address u, uint256 amount, uint256 min, uint256 value,) = hub.calls(id - 1);
        assertEq(kind, 0);
        assertEq(u, NVDA);
        assertEq(amount, 1_000e18);
        assertEq(min, 4.9375e18);
        assertEq(value, 1_000.05e18, "principal + LZ fee");
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.Slippage.selector, 0, 395e18));
        desk.unstock(address(stock), 2e18, 0);
        desk.unstock(address(stock), 2e18, 395e18);
        vm.stopPrank();
    }

    function testExitsGoOnlyToTheFixedRecipient() public {
        vm.startPrank(RESTOCKER);
        desk.escalateHubOrder(7);
        desk.escalateHubFunds(8);
        desk.cancelHubOrder(9);
        desk.claimHub(10);
        vm.stopPrank();
        (uint8 kind,,,, uint256 value, address to) = hub.calls(0);
        assertEq(kind, 4);
        assertEq(value, 1e18, "1 USDC canonical hook");
        assertEq(to, RH_RECIPIENT);
        (kind,,,,, to) = hub.calls(1);
        assertEq(kind, 5);
        assertEq(to, RH_RECIPIENT);
    }

    function testWithdrawOnlyByOwnerOnlyToTreasury() public {
        vm.prank(RESTOCKER);
        vm.expectRevert(InstantStockDesk.NotOwner.selector);
        desk.withdraw(address(0), 1e18);
        vm.startPrank(OWNER);
        desk.withdraw(address(0), 5e18);
        desk.withdraw(address(stock), 1e18);
        vm.stopPrank();
        assertEq(TREASURY.balance, 5e18);
        assertEq(stock.balanceOf(TREASURY), 1e18);
    }

    function testTermsAreGovernedAndBounded() public {
        vm.expectRevert(InstantStockDesk.NotOwner.selector);
        desk.setTerms(address(stock), 50, 50, 1, 1, true);
        vm.startPrank(OWNER);
        vm.expectRevert(InstantStockDesk.SpreadTooHigh.selector);
        desk.setTerms(address(stock), 501, 50, 1, 1, true);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.NotAStock.selector, address(0xBEEF)));
        desk.setTerms(address(0xBEEF), 50, 50, 1, 1, true);
        desk.setTerms(address(stock), 50, 100, 10_000e18, 20_000e18, false);
        vm.stopPrank();
        assertEq(desk.stocks().length, 1);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(InstantStockDesk.NotListed.selector, address(stock)));
        desk.buy{value: 1e18}(address(stock), 0, address(0));
    }

    function testQuotesMatchTrades() public {
        (uint256 q, bool ok) = desk.quoteBuy(address(stock), 1_000e18);
        assertTrue(ok);
        vm.prank(USER);
        assertEq(desk.buy{value: 1_000e18}(address(stock), 0, address(0)), q);
        (uint256 qs, bool oks) = desk.quoteSell(address(stock), 1e18);
        assertTrue(oks);
        vm.prank(USER);
        assertEq(desk.sell(address(stock), 1e18, 0, address(0)), qs);
        (uint256 b, uint256 s) = desk.capacity(address(stock));
        assertEq(b, 10_000e18);
        assertEq(s, 10_000e18);
    }

    /// @dev At any Live price and size, a buy followed by selling everything back never leaves the desk poorer
    ///      at the oracle price (the spreads only ever accrue to the desk), and buy/sell match their quotes.
    function testFuzzRoundTripNeverDrainsDesk(uint256 usdIn, uint256 price) public {
        price = bound(price, 1e15, 1e24); // $0.001 .. $1M per share
        usdIn = bound(usdIn, 1e12, 10_000e18);
        source.set(NVDA, price, 2);
        vm.prank(OWNER);
        oracle.configureAsset(NVDA, address(stock), source, OracleTestLib.params()); // unchanged source: keep anchor
        oracle.poke(address(stock));
        if (oracle.status(address(stock)) != SolonStockOracle.Status.Live) {
            source.set(NVDA, price, 3);
            oracle.poke(address(stock)); // the second observation confirms a jump
        }
        stock.mint(address(desk), 1e30);
        uint256 valueBefore = address(desk).balance + stock.balanceOf(address(desk)) * price / 1e18;
        (uint256 qb, bool okb) = desk.quoteBuy(address(stock), usdIn);
        vm.prank(USER);
        uint256 shares = desk.buy{value: usdIn}(address(stock), 0, address(0));
        assertTrue(okb);
        assertEq(shares, qb);
        assertLe(shares * price / 1e18, usdIn, "never more than the USDC paid, at the oracle price");
        if (shares * price / 1e18 <= 10_000e18 && shares > 0) {
            (uint256 qs,) = desk.quoteSell(address(stock), shares);
            vm.prank(USER);
            uint256 back = desk.sell(address(stock), shares, 0, address(0));
            assertEq(back, qs);
            assertLe(back, usdIn, "a round trip never profits");
        }
        uint256 valueAfter = address(desk).balance + stock.balanceOf(address(desk)) * price / 1e18;
        assertGe(valueAfter + 1, valueBefore, "desk value at the oracle price never falls (1 wei rounding)");
    }
}

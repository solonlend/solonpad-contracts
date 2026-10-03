// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkStockFeed, IAggregatorV3} from "../../../../src/v3/oracle/ChainlinkStockFeed.sol";
import {ChainlinkStockSource} from "../../../../src/v3/oracle/ChainlinkStockSource.sol";
import {StockObservation} from "../../../../src/v3/oracle/IStockPriceSource.sol";
import {MockAggregator, MockMultiplierToken, MockV3Pool, MockDecimalsToken} from "../../helpers/OracleMocks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice V3 pool double with arbitrary tick cumulatives (to hit the TWAP floor-rounding branch).
contract CovDCumPool {
    address public token0;
    address public token1;
    int56 public c0;
    int56 public c1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function setCum(int56 a, int56 b) external {
        c0 = a;
        c1 = b;
    }

    function observe(uint32[] calldata ago) external view returns (int56[] memory c, uint160[] memory l) {
        c = new int56[](ago.length);
        l = new uint160[](ago.length);
        c[0] = c0;
        c[1] = c1;
    }
}

/// @notice Branch coverage for ChainlinkStockFeed (library) and ChainlinkStockSource.
contract CovDOracleFeedSourceTest is Test {
    address constant OWNER = address(0x71);
    address constant NVDA = address(0x1D);
    uint256 constant WIDE = 4 days;

    MockAggregator feed;
    MockAggregator usdg;
    MockMultiplierToken rhToken;
    ChainlinkStockSource src;

    function setUp() public {
        vm.warp(1_760_000_000);
        feed = new MockAggregator(8, 180e8);
        usdg = new MockAggregator(8, 1e8);
        rhToken = new MockMultiplierToken();
        src = new ChainlinkStockSource(OWNER, address(usdg), WIDE, 2 days, new ChainlinkStockSource.FeedInit[](0));
        vm.prank(OWNER);
        src.setFeed(NVDA, address(feed), true, address(rhToken));
    }

    function _empty() internal pure returns (ChainlinkStockSource.FeedInit[] memory) {
        return new ChainlinkStockSource.FeedInit[](0);
    }

    // ================================================================ ChainlinkStockFeed.read

    /// L57 both arms on the quote leg (second read site): a zero / negative stable answer fails closed.
    function test_read_quoteLegNonPositiveReverts() public {
        usdg.set(0, block.timestamp);
        vm.expectRevert(ChainlinkStockFeed.NonPositive.selector);
        src.observe(NVDA);
        usdg.set(-1, block.timestamp);
        vm.expectRevert(ChainlinkStockFeed.NonPositive.selector);
        src.observe(NVDA);
        usdg.set(1, block.timestamp); // smallest positive answer: 1e-8 USD, passes L57 and L62
        assertEq(src.observe(NVDA).quoteUsd18, 1e10);
    }

    /// L59 true arm: a feed whose decimals() rises above 36 after configuration (proxy upgrade) fails closed.
    function test_read_stockFeedDecimalsAbove36Reverts() public {
        vm.mockCall(address(feed), abi.encodeWithSelector(IAggregatorV3.decimals.selector), abi.encode(uint8(37)));
        vm.expectRevert(ChainlinkStockFeed.FeedDecimals.selector);
        src.observe(NVDA);
        vm.mockCall(address(feed), abi.encodeWithSelector(IAggregatorV3.decimals.selector), abi.encode(uint8(255)));
        vm.expectRevert(ChainlinkStockFeed.FeedDecimals.selector);
        src.observe(NVDA);
    }

    /// L59 true arm on the quote leg.
    function test_read_quoteFeedDecimalsAbove36Reverts() public {
        vm.mockCall(address(usdg), abi.encodeWithSelector(IAggregatorV3.decimals.selector), abi.encode(uint8(37)));
        vm.expectRevert(ChainlinkStockFeed.FeedDecimals.selector);
        src.observe(NVDA);
    }

    /// L59 boundary (36 accepted) and L61 dec > 18 arm (divide down).
    function test_read_decimalsAbove18DivideDown() public {
        MockAggregator f36 = new MockAggregator(36, 180e36);
        MockAggregator f20 = new MockAggregator(20, 180.5e20 + 99); // sub-1e-18 dust is truncated
        vm.startPrank(OWNER);
        src.setFeed(address(0x36), address(f36), true, address(0));
        src.setFeed(address(0x20), address(f20), true, address(0));
        vm.stopPrank();
        assertEq(src.observe(address(0x36)).price18, 180e18);
        assertEq(src.observe(address(0x20)).price18, 180.5e18);
    }

    /// L62 true arm: a >18-dp answer that truncates to 0 must not read as a price.
    function test_read_dividedToZeroReverts() public {
        MockAggregator f36 = new MockAggregator(36, 1e18 - 1);
        vm.prank(OWNER);
        src.setFeed(address(0x37), address(f36), true, address(0));
        vm.expectRevert(ChainlinkStockFeed.NonPositive.selector);
        src.observe(address(0x37));
        f36.set(1e18, block.timestamp); // exactly 1 wei of price18: smallest accepted value
        assertEq(src.observe(address(0x37)).price18, 1);
    }

    /// L62 true arm on the quote leg (24-dp stable feed).
    function test_read_quoteLegDividedToZeroReverts() public {
        MockAggregator q24 = new MockAggregator(24, 1e24);
        ChainlinkStockSource s = new ChainlinkStockSource(OWNER, address(q24), WIDE, 2 days, _empty());
        vm.prank(OWNER);
        s.setFeed(NVDA, address(feed), true, address(0));
        assertEq(s.observe(NVDA).quoteUsd18, 1e18);
        q24.set(999_999, block.timestamp); // < 1e6 -> 0 after /1e6
        vm.expectRevert(ChainlinkStockFeed.NonPositive.selector);
        s.observe(NVDA);
    }

    // ================================================================ ChainlinkStockFeed.applyMultiplier

    /// L72 both arms: branch B price that rounds to 0 after the multiplier fails closed.
    function test_applyMultiplier_roundsToZeroReverts() public {
        MockMultiplierToken t = new MockMultiplierToken();
        MockAggregator f18 = new MockAggregator(18, 1); // 1 wei of price18
        vm.prank(OWNER);
        src.setFeed(address(0xB0), address(f18), false, address(t));
        t.setMultiplier(1e18 - 1);
        vm.expectRevert(ChainlinkStockFeed.NonPositive.selector);
        src.observe(address(0xB0));
        t.setMultiplier(1e18);
        assertEq(src.observe(address(0xB0)).price18, 1);
        t.setMultiplier(3e18);
        StockObservation memory o = src.observe(address(0xB0));
        assertEq(o.price18, 3);
        assertEq(o.multiplier, 3e18);
    }

    // ================================================================ ChainlinkStockSource constructor (L85, L88)

    function test_ctor_rejectsZeroOwner() public {
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        new ChainlinkStockSource(address(0), address(usdg), WIDE, 2 days, _empty());
    }

    function test_ctor_rejectsZeroMaxStaleness() public {
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        new ChainlinkStockSource(OWNER, address(usdg), 0, 2 days, _empty());
    }

    function test_ctor_rejectsQuoteFeedWithoutQuoteStaleness() public {
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        new ChainlinkStockSource(OWNER, address(usdg), WIDE, 0, _empty());
    }

    /// L85/L88 quoteFeed == 0 arms: no quote feed needs no quote staleness; the stable then reads as $1.
    function test_ctor_noQuoteFeedReportsOneDollar() public {
        ChainlinkStockSource s = new ChainlinkStockSource(OWNER, address(0), WIDE, 0, _empty());
        assertEq(s.quoteFeed(), address(0));
        assertEq(s.quoteMaxStaleness(), 0);
        vm.prank(OWNER);
        s.setFeed(NVDA, address(feed), true, address(0));
        StockObservation memory o = s.observe(NVDA);
        assertEq(o.quoteUsd18, 1e18);
        assertEq(o.price18, 180e18);
        assertEq(o.multiplier, 0); // branch A without a token: multiplier unknown
    }

    /// L88 true arm: a quote feed with > 36 decimals is refused at deployment; 36 is accepted.
    function test_ctor_rejectsQuoteFeedDecimalsAbove36() public {
        MockAggregator q37 = new MockAggregator(37, 1);
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        new ChainlinkStockSource(OWNER, address(q37), WIDE, 2 days, _empty());
        MockAggregator q36 = new MockAggregator(36, 1e36);
        ChainlinkStockSource s = new ChainlinkStockSource(OWNER, address(q36), WIDE, 2 days, _empty());
        assertEq(s.quoteFeed(), address(q36));
    }

    // ================================================================ _setFeed (L107-110) and feedOf

    function test_setFeed_rejectsBadInputs() public {
        MockAggregator f37 = new MockAggregator(37, 1);
        vm.startPrank(OWNER);
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setFeed(address(0), address(feed), true, address(0)); // zero underlying
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setFeed(address(0xA1), address(0xFEED), true, address(0)); // feed without code
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setFeed(address(0xA1), address(f37), true, address(0)); // feed decimals > 36
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setFeed(address(0xA1), address(feed), false, address(0xC0DE)); // branch B token without code
        vm.stopPrank();
        assertEq(src.feedOf(address(0xA1)).feed, address(0));
        assertEq(src.underlyings().length, 1);
    }

    function test_feedOf_reportsConfiguration() public {
        ChainlinkStockSource.Feed memory f = src.feedOf(NVDA);
        assertEq(f.feed, address(feed));
        assertTrue(f.includesMultiplier);
        assertEq(f.stockToken, address(rhToken));
        MockMultiplierToken t = new MockMultiplierToken();
        vm.prank(OWNER);
        src.setFeed(address(0xB1), address(feed), false, address(t));
        f = src.feedOf(address(0xB1));
        assertFalse(f.includesMultiplier);
        assertEq(f.stockToken, address(t));
        f = src.feedOf(address(0xDEAD));
        assertEq(f.feed, address(0));
        assertEq(f.stockToken, address(0));
    }

    // ================================================================ _setTwapPool (L125, L131) and twapPoolOf

    function _stockWithFeed(uint8 dec) internal returns (address stock) {
        stock = address(new MockDecimalsToken(dec));
        vm.prank(OWNER);
        src.setFeed(stock, address(feed), true, address(0));
    }

    /// L125: pool without code, window below MIN, window above MAX; both window boundaries accepted.
    function test_setTwapPool_rejectsNoCodeAndWindowOutOfBounds() public {
        address stock = _stockWithFeed(18);
        address usd = address(new MockDecimalsToken(6));
        MockV3Pool pool = new MockV3Pool(stock, usd);
        vm.startPrank(OWNER);
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setTwapPool(stock, address(0x900D), 30 minutes);
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setTwapPool(stock, address(pool), 5 minutes - 1);
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setTwapPool(stock, address(pool), 1 days + 1);
        vm.stopPrank();
        assertEq(src.twapPoolOf(stock).pool, address(0)); // nothing written by the failed attempts
        assertEq(src.twapOf(stock), 0);

        vm.prank(OWNER);
        src.setTwapPool(stock, address(pool), 5 minutes); // lower boundary
        ChainlinkStockSource.TwapPool memory t = src.twapPoolOf(stock);
        assertEq(t.pool, address(pool));
        assertEq(t.window, 5 minutes);
        assertTrue(t.stockIsToken0);
        assertEq(t.stableDecimals, 6);

        address stock2 = _stockWithFeed(18);
        MockV3Pool pool2 = new MockV3Pool(usd, stock2);
        vm.prank(OWNER);
        src.setTwapPool(stock2, address(pool2), 1 days); // upper boundary
        t = src.twapPoolOf(stock2);
        assertEq(t.window, 1 days);
        assertFalse(t.stockIsToken0);
    }

    /// L131: stable leg with > 18 decimals, and an underlying that is not 18 dp, are refused; 18-dp stable ok.
    function test_setTwapPool_rejectsBadDecimals() public {
        address stock = _stockWithFeed(18);
        MockV3Pool p19 = new MockV3Pool(stock, address(new MockDecimalsToken(19)));
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setTwapPool(stock, address(p19), 30 minutes);

        address stock6 = _stockWithFeed(6);
        MockV3Pool p6 = new MockV3Pool(address(new MockDecimalsToken(6)), stock6);
        vm.prank(OWNER);
        vm.expectRevert(ChainlinkStockSource.BadFeed.selector);
        src.setTwapPool(stock6, address(p6), 30 minutes);

        MockV3Pool p18 = new MockV3Pool(stock, address(new MockDecimalsToken(18)));
        vm.prank(OWNER);
        src.setTwapPool(stock, address(p18), 30 minutes);
        assertEq(src.twapPoolOf(stock).stableDecimals, 18);
        p18.setTick(0);
        assertEq(src.twapOf(stock), 1e18); // tick 0, 18-dp stable: 1 stable per stock
    }

    /// L150 (extra): a negative non-exact mean tick rounds towards -inf, like Uniswap's OracleLibrary.
    function test_twap_negativeTickRoundsDown() public {
        address stock = _stockWithFeed(18);
        CovDCumPool pool = new CovDCumPool(stock, address(new MockDecimalsToken(18)));
        vm.prank(OWNER);
        src.setTwapPool(stock, address(pool), 300);
        uint256 r = uint256(TickMath.getSqrtPriceAtTick(-1));
        uint256 atMinus1 = FullMath.mulDiv(r * r, 1e18, 1 << 192);
        pool.setCum(0, -1); // mean -1/300: truncation gives 0, floor gives -1
        assertEq(src.twapOf(stock), atMinus1);
        pool.setCum(0, -300); // exact -1: no extra decrement
        assertEq(src.twapOf(stock), atMinus1);
        pool.setCum(0, 1); // positive non-exact: truncation (= floor) gives 0
        assertEq(src.twapOf(stock), 1e18);
    }
}

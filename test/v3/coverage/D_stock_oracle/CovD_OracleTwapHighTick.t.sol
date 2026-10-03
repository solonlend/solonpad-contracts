// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainlinkStockSource} from "../../../../src/v3/oracle/ChainlinkStockSource.sol";
import {MockAggregator, MockV3Pool, MockDecimalsToken} from "../../helpers/OracleMocks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice ChainlinkStockSource L157-163 `_quoteAtTick`, high branch (sqrtP > type(uint128).max), reached through
///         the public `twapOf` path for both token orders, checked against an independent exact computation and
///         against the low branch across the boundary tick.
contract CovDOracleTwapHighTickTest is Test {
    address constant OWNER = address(0x71);
    ChainlinkStockSource src;
    MockAggregator feed;
    address stock0; // stock is token0 of pool0
    address stock1; // stock is token1 of pool1
    MockV3Pool pool0;
    MockV3Pool pool1;

    function setUp() public {
        vm.warp(1_760_000_000);
        feed = new MockAggregator(8, 180e8);
        src = new ChainlinkStockSource(OWNER, address(0), 4 days, 0, new ChainlinkStockSource.FeedInit[](0));
        stock0 = address(new MockDecimalsToken(18));
        stock1 = address(new MockDecimalsToken(18));
        address stable = address(new MockDecimalsToken(18));
        pool0 = new MockV3Pool(stock0, stable);
        pool1 = new MockV3Pool(stable, stock1);
        vm.startPrank(OWNER);
        src.setFeed(stock0, address(feed), true, address(0));
        src.setFeed(stock1, address(feed), true, address(0));
        src.setTwapPool(stock0, address(pool0), 30 minutes);
        src.setTwapPool(stock1, address(pool1), 30 minutes);
        vm.stopPrank();
    }

    /// Largest tick whose sqrtP still fits in uint128 (binary search over TickMath, independent of the source).
    function _boundary() internal pure returns (int24 lo) {
        lo = 0;
        int24 hi = TickMath.MAX_TICK;
        while (hi - lo > 1) {
            int24 mid = lo + (hi - lo) / 2;
            if (TickMath.getSqrtPriceAtTick(mid) <= type(uint128).max) lo = mid;
            else hi = mid;
        }
    }

    /// Exact floor(sqrtP^2 * 1e18 / 2^192): token1 per 1e18 token0.
    function _ref0(int24 t) internal pure returns (uint256) {
        uint256 sq = TickMath.getSqrtPriceAtTick(t);
        return FullMath.mulDiv(sq * 1e18, sq, 1 << 192);
    }

    /// Exact floor(2^192 * 1e18 / sqrtP^2): token0 per 1e18 token1 (nested floors are exact).
    function _ref1(int24 t) internal pure returns (uint256) {
        uint256 sq = TickMath.getSqrtPriceAtTick(t);
        return FullMath.mulDiv(1 << 192, 1e18, sq) / sq;
    }

    function _twap0(int24 t) internal returns (uint256) {
        pool0.setTick(t);
        return src.twapOf(stock0);
    }

    function _twap1(int24 t) internal returns (uint256) {
        pool1.setTick(t);
        return src.twapOf(stock1);
    }

    function testCovD_HighTickBranchStockIsToken0MatchesExactQuote() public {
        int24 b = _boundary();
        assertLe(TickMath.getSqrtPriceAtTick(b), type(uint128).max);
        assertGt(TickMath.getSqrtPriceAtTick(b + 1), type(uint128).max);
        int24[4] memory ticks = [b + 1, b + 1000, int24(800_000), TickMath.MAX_TICK];
        for (uint256 i; i < ticks.length; ++i) {
            uint256 got = _twap0(ticks[i]);
            uint256 ref = _ref0(ticks[i]);
            // the high branch floors sqrtP^2/2^64 first: at most 1 unit below the exact floor
            assertLe(got, ref);
            assertLe(ref - got, 1);
            assertGt(got, 0);
        }
        // across the boundary the two formulas agree with one tick step (x1.0001)
        uint256 low = _twap0(b);
        uint256 high = _twap0(b + 1);
        assertEq(low, _ref0(b), "low branch is exact");
        assertGt(high, low);
        assertApproxEqRel(high, low * 10_001 / 10_000, 1e12); // 1e-6 relative
    }

    function testCovD_HighTickBranchStockIsToken1MatchesExactQuote() public {
        int24 b = _boundary();
        int24[3] memory ticks = [b + 1, int24(800_000), TickMath.MAX_TICK];
        for (uint256 i; i < ticks.length; ++i) {
            uint256 got = _twap1(ticks[i]);
            uint256 ref = _ref1(ticks[i]);
            // r128 is floored, so the quotient can only be >= the exact one; here both are below 1 wei:
            // 1 stock is worth < 1e-18 stable, which SolonStockOracle treats as no TWAP (Divergent, fail closed).
            assertGe(got, ref);
            assertLe(got - ref, 1);
            assertEq(got, 0);
        }
        // monotone non-increasing across the boundary (stock price falls as the tick rises)
        assertGe(_twap1(b), _twap1(b + 1));
        assertEq(_twap1(b), _ref1(b), "low branch is exact");
        // mirror check: the high-tick quote of token0 equals the low branch at the mirrored negative tick
        // for the inverse orientation, within rounding
        uint256 viaHigh = _twap0(b + 1000);
        uint256 viaMirror = _twap1(-(b + 1000));
        assertApproxEqRel(viaHigh, viaMirror, 1e12);
    }
}

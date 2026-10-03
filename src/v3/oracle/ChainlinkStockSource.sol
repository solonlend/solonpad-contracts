// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {ChainlinkStockFeed, IAggregatorV3, IStockMultiplier} from "./ChainlinkStockFeed.sol";
import {IStockPriceSource, StockObservation} from "./IStockPriceSource.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IV3PoolObserve {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title ChainlinkStockSource — direct, fail-closed Chainlink reads per stock
/// @notice Used on Robinhood Chain by `StockPriceSender` (the RH equity feeds, USDG/USD as the quote leg), and
///         usable on Arc as a direct source once Chainlink publishes equity feeds there (checked 2026-10-01:
///         the Arc mainnet feed directory lists 34 feeds, no NVDA/AAPL/TSLA; USDC/USD 0x84EA…7905 exists).
///         Reads follow `ChainlinkStockFeed` (adapted from stocklend's StockOracleAdapter). Feeds are set once
///         per underlying by the owner (timelock); a feed change is a new source behind the oracle's timelocked
///         configuration, never an in-place edit.
contract ChainlinkStockSource is IStockPriceSource {
    struct Feed {
        address feed; // stock/USD
        bool includesMultiplier; // branch A (true) / B (false)
        address stockToken; // token exposing uiMultiplier(); required for branch B, optional (reporting) for A
    }

    address public immutable owner;
    /// @notice USD feed of the settlement stable (USDG/USD on RH, USDC/USD on Arc); address(0) = reported as $1.
    address public immutable quoteFeed;
    /// @notice Very wide bound on the stock feed's age (a long weekend plus a holiday); fine checks are off-chain.
    uint256 public immutable maxStaleness;
    /// @notice Bound on the quote feed's age (stable feeds move on a 0.5% deviation / 24h heartbeat).
    uint256 public immutable quoteMaxStaleness;

    /// @notice Optional cross-check: the underlying's Uniswap V3 pool against the settlement stable (design §12.2:
    ///         30-minute TWAP of the RH stock/USDG pool). Never an execution price; the oracle only compares.
    struct TwapPool {
        address pool;
        uint32 window; // seconds
        bool stockIsToken0;
        uint8 stableDecimals;
    }

    uint32 public constant MIN_TWAP_WINDOW = 5 minutes;
    uint32 public constant MAX_TWAP_WINDOW = 1 days;

    mapping(address underlying => Feed) private _feeds;
    mapping(address underlying => TwapPool) private _pools;
    address[] private _underlyings;

    event FeedSet(address indexed underlying, address feed, bool includesMultiplier, address stockToken);
    event TwapPoolSet(address indexed underlying, address pool, uint32 window);

    error NotOwner();
    error AlreadySet();
    error BadFeed();
    error NoFeed(address underlying);

    /// @notice A feed (and optional TWAP pool) set at deployment, so a timelock owner needs no follow-up op.
    struct FeedInit {
        address underlying;
        address feed;
        bool includesMultiplier;
        address stockToken;
        address pool; // address(0) = no TWAP cross-check
        uint32 window;
    }

    constructor(
        address owner_,
        address quoteFeed_,
        uint256 maxStaleness_,
        uint256 quoteMaxStaleness_,
        FeedInit[] memory init
    ) {
        if (owner_ == address(0) || maxStaleness_ == 0 || (quoteFeed_ != address(0) && quoteMaxStaleness_ == 0)) {
            revert BadFeed();
        }
        if (quoteFeed_ != address(0) && IAggregatorV3(quoteFeed_).decimals() > 36) revert BadFeed();
        owner = owner_;
        quoteFeed = quoteFeed_;
        maxStaleness = maxStaleness_;
        quoteMaxStaleness = quoteMaxStaleness_;
        for (uint256 i; i < init.length; ++i) {
            FeedInit memory f = init[i];
            _setFeed(f.underlying, f.feed, f.includesMultiplier, f.stockToken);
            if (f.pool != address(0)) _setTwapPool(f.underlying, f.pool, f.window);
        }
    }

    function setFeed(address underlying, address feed, bool includesMultiplier, address stockToken) external {
        if (msg.sender != owner) revert NotOwner();
        _setFeed(underlying, feed, includesMultiplier, stockToken);
    }

    function _setFeed(address underlying, address feed, bool includesMultiplier, address stockToken) private {
        if (_feeds[underlying].feed != address(0)) revert AlreadySet();
        if (
            underlying == address(0) || feed.code.length == 0 || IAggregatorV3(feed).decimals() > 36
                || (!includesMultiplier && stockToken.code.length == 0)
        ) revert BadFeed();
        _feeds[underlying] = Feed(feed, includesMultiplier, stockToken);
        _underlyings.push(underlying);
        emit FeedSet(underlying, feed, includesMultiplier, stockToken);
    }

    /// @notice Set once per underlying (owner): the V3 pool of `underlying` against a stable of `stableDecimals`.
    function setTwapPool(address underlying, address pool, uint32 window) external {
        if (msg.sender != owner) revert NotOwner();
        _setTwapPool(underlying, pool, window);
    }

    function _setTwapPool(address underlying, address pool, uint32 window) private {
        if (_feeds[underlying].feed == address(0)) revert NoFeed(underlying);
        if (_pools[underlying].pool != address(0)) revert AlreadySet();
        if (pool.code.length == 0 || window < MIN_TWAP_WINDOW || window > MAX_TWAP_WINDOW) revert BadFeed();
        address t0 = IV3PoolObserve(pool).token0();
        address t1 = IV3PoolObserve(pool).token1();
        if (t0 != underlying && t1 != underlying) revert BadFeed();
        bool stock0 = t0 == underlying;
        uint8 dec = IDecimals(stock0 ? t1 : t0).decimals();
        if (dec > 18 || IDecimals(underlying).decimals() != 18) revert BadFeed();
        _pools[underlying] = TwapPool(pool, window, stock0, dec);
        emit TwapPoolSet(underlying, pool, window);
    }

    function twapPoolOf(address underlying) external view returns (TwapPool memory) {
        return _pools[underlying];
    }

    /// @notice Stable per 1e18 raw stock over the pool's window, 18 dp (0 when no pool is set). Reverts when the
    ///         pool cannot answer for the whole window (e.g. too little observation cardinality): fail closed.
    function twapOf(address underlying) public view returns (uint256) {
        TwapPool memory t = _pools[underlying];
        if (t.pool == address(0)) return 0;
        uint32[] memory ago = new uint32[](2);
        ago[0] = t.window;
        (int56[] memory cum,) = IV3PoolObserve(t.pool).observe(ago);
        int56 delta = cum[1] - cum[0];
        int24 tick = int24(delta / int56(uint56(t.window)));
        if (delta < 0 && (delta % int56(uint56(t.window)) != 0)) tick--;
        uint256 out = _quoteAtTick(tick, t.stockIsToken0);
        return out * 10 ** (18 - t.stableDecimals);
    }

    /// @dev Uniswap OracleLibrary.getQuoteAtTick for a base amount of 1e18 raw stock.
    function _quoteAtTick(int24 tick, bool stockIsToken0) private pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtP <= type(uint128).max) {
            uint256 r = uint256(sqrtP) * sqrtP;
            return stockIsToken0 ? FullMath.mulDiv(r, 1e18, 1 << 192) : FullMath.mulDiv(1 << 192, 1e18, r);
        }
        uint256 r128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
        return stockIsToken0 ? FullMath.mulDiv(r128, 1e18, 1 << 128) : FullMath.mulDiv(1 << 128, 1e18, r128);
    }

    function feedOf(address underlying) external view returns (Feed memory) {
        return _feeds[underlying];
    }

    function underlyings() external view returns (address[] memory) {
        return _underlyings;
    }

    function observe(address underlying) external view returns (StockObservation memory o) {
        Feed memory f = _feeds[underlying];
        if (f.feed == address(0)) revert NoFeed(underlying);
        ChainlinkStockFeed.Reading memory r = ChainlinkStockFeed.read(f.feed, maxStaleness);
        if (f.includesMultiplier) {
            o.price18 = r.price18;
            // Reporting only: branch A never depends on the token's multiplier.
            if (f.stockToken != address(0)) {
                try IStockMultiplier(f.stockToken).uiMultiplier() returns (uint256 m) {
                    o.multiplier = m;
                } catch {}
            }
        } else {
            o.price18 = ChainlinkStockFeed.applyMultiplier(r.price18, f.stockToken);
            o.multiplier = IStockMultiplier(f.stockToken).uiMultiplier();
        }
        o.quoteUsd18 = quoteFeed == address(0) ? 1e18 : ChainlinkStockFeed.read(quoteFeed, quoteMaxStaleness).price18;
        o.twapPrice18 = twapOf(underlying);
        o.sourceUpdatedAt = uint64(r.updatedAt);
        o.roundId = r.roundId;
        o.observedAt = uint64(block.timestamp);
        o.sourceBlock = uint64(block.number);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStockPriceSource, StockObservation} from "./IStockPriceSource.sol";

/// @title SolonStockOracle — the stock execution price on Arc (design r7 §12.2)
/// @notice Forked in structure from ArcStocksOracleV2 (MIT, Arc 5042 0x77905f095FA62FC472e56f17BDC039DC764C1595,
///         verified Sourcify source in arc-launchpad/docs/evidence/v3-stock-rewards/arcstocks-more/oracleV2): one
///         quote per Robinhood underlying, a maximum age, a maximum move per update, and the same read API
///         (`peek`, `getPrice`, `quoteOf`, `multiplierOf`, `isStale`). What changed, and why:
///         - No poster. ArcStocks' keeper posts a number; here every price comes from a Chainlink read behind a
///           fixed `IStockPriceSource` (direct `ChainlinkStockSource`, or the RH read relayed over LayerZero by
///           `RelayedStockSource`), fail-closed and multiplier-aware per stocklend's StockOracleAdapter. Keepers
///           may only `poke` (make the oracle look at its source); nobody can write a price.
///         - A move beyond `maxMoveBps` does not revert and wait for the owner (ArcStocks `MovedTooFar`); the
///           asset turns Suspect until a later Chainlink round confirms it within `confirmBps` (two observations).
///         - Explicit status per asset: Live / Stale (source read failed, or observation older than `maxAge`) /
///           Divergent (settlement stable off $1 by more than `maxDepegBps`, or Chainlink off the RH pool TWAP by
///           more than `maxTwapBps`) / Suspect / Paused (guardian). Stale also covers a closed market: Chainlink
///           equity feeds freeze while closed, so a feed update older than `maxSourceAge` stops execution
///           (stocklend's rule: only a wide on-chain bound; the 26h default outlasts a 24/5 feed's overnight).
///           Execution consumers use `execPrice` (reverts unless Live); `priceUSD18` never reverts ((0,0) unless Live).
///         - 18-dp USD per raw token instead of 6-dp USDC; keyed by the underlying, callable with the Arc token too.
///         - Governance: owner = timelock (48h) configures; guardian may pause or only tighten; owner resumes.
contract SolonStockOracle {
    enum Status {
        None,
        Live,
        Stale,
        Divergent,
        Suspect,
        Paused
    }

    struct Params {
        uint32 maxAge; // max observation age (s)
        uint16 maxMoveBps; // move vs the accepted price that needs a second observation
        uint16 confirmBps; // second observation must be within this of the first
        uint16 maxDepegBps; // settlement stable vs $1
        uint32 maxSourceAge; // max Chainlink updatedAt age (s): a closed market freezes the feed (design 26h)
        uint16 maxTwapBps; // Chainlink vs the RH pool TWAP (in USD); 0 = no TWAP cross-check for this source
    }

    struct Asset {
        address token; // the Arc SolonStockToken
        IStockPriceSource source;
        Params params;
        bool paused;
    }

    /// @notice The accepted (anchor) price, ArcStocks' Quote with 18 dp.
    struct Quote {
        uint128 price18;
        uint64 sourceUpdatedAt;
        uint64 updatedAt; // observedAt of the accepted observation
    }

    uint32 public constant MAX_AGE_LIMIT = 7 days;
    uint16 public constant MAX_MOVE_LIMIT = 5_000;
    uint16 public constant MAX_DEPEG_LIMIT = 1_000;

    address public immutable owner; // timelock
    address public immutable guardian; // may pause and tighten only

    mapping(address underlying => Asset) private _assets;
    mapping(address token => address underlying) public underlyingOf;
    mapping(address underlying => Quote) private _anchor;
    mapping(address underlying => Quote) private _candidate;
    address[] private _underlyings;

    event AssetConfigured(address indexed underlying, address indexed token, address source, Params params);
    event ParamsTightened(address indexed underlying, Params params);
    event AssetPaused(address indexed underlying, bytes32 reasonHash);
    event AssetResumed(address indexed underlying);
    event PriceObserved(
        address indexed underlying,
        uint256 price18,
        uint256 quoteUsd18,
        uint256 twapPrice18,
        uint64 sourceUpdatedAt,
        uint80 roundId,
        uint64 observedAt,
        uint64 sourceBlock,
        Status status
    );
    event PriceAccepted(address indexed underlying, uint256 price18, uint64 sourceUpdatedAt, bool confirmedJump);

    error NotOwner();
    error NotGuardian();
    error BadParams();
    error UnknownAsset(address asset);
    error PriceNotLive(address asset, Status status);

    constructor(address owner_, address guardian_) {
        require(owner_ != address(0) && guardian_ != address(0));
        owner = owner_;
        guardian = guardian_;
    }

    // ------------------------------------------------------------------ governance

    /// @notice List or re-point an asset (timelock). The token binding is permanent; a new source resets the
    ///         accepted price, so the first read after a switch is accepted fresh.
    function configureAsset(address underlying, address token, IStockPriceSource source, Params calldata p)
        external
    {
        if (msg.sender != owner) revert NotOwner();
        _validate(p);
        if (underlying == address(0) || token.code.length == 0 || address(source).code.length == 0) revert BadParams();
        Asset storage a = _assets[underlying];
        if (a.token == address(0)) {
            if (underlyingOf[token] != address(0)) revert BadParams();
            a.token = token;
            underlyingOf[token] = underlying;
            _underlyings.push(underlying);
        } else if (a.token != token) {
            revert BadParams();
        }
        if (a.source != source) {
            delete _anchor[underlying];
            delete _candidate[underlying];
        }
        a.source = source;
        a.params = p;
        emit AssetConfigured(underlying, token, address(source), p);
    }

    /// @notice Guardian (or owner): make any threshold stricter at once. Never loosens.
    function tighten(address asset, Params calldata p) external {
        if (msg.sender != guardian && msg.sender != owner) revert NotGuardian();
        address u = _known(asset);
        Params memory c = _assets[u].params;
        _validate(p);
        if (
            p.maxAge > c.maxAge || p.maxMoveBps > c.maxMoveBps || p.confirmBps > c.confirmBps
                || p.maxDepegBps > c.maxDepegBps || p.maxSourceAge > c.maxSourceAge || p.maxTwapBps > c.maxTwapBps
                || (c.maxTwapBps != 0 && p.maxTwapBps == 0)
        ) revert BadParams();
        _assets[u].params = p;
        emit ParamsTightened(u, p);
    }

    function pause(address asset, bytes32 reasonHash) external {
        if (msg.sender != guardian && msg.sender != owner) revert NotGuardian();
        address u = _known(asset);
        _assets[u].paused = true;
        emit AssetPaused(u, reasonHash);
    }

    function resume(address asset) external {
        if (msg.sender != owner) revert NotOwner();
        address u = _known(asset);
        _assets[u].paused = false;
        emit AssetResumed(u);
    }

    // ------------------------------------------------------------------ observation

    /// @notice Anyone: look at the source now. Moves the accepted price when the observation is usable and within
    ///         `maxMoveBps`, or when it confirms an earlier jump (a later Chainlink round within `confirmBps`).
    function poke(address asset) external returns (Status s) {
        address u = _known(asset);
        StockObservation memory o;
        bool ok;
        (s, o, ok) = _evaluate(u, true);
        if (ok && (s == Status.Live || s == Status.Suspect)) {
            Quote memory anc = _anchor[u];
            Params memory p = _assets[u].params;
            if (anc.price18 == 0 || !_moved(o.price18, anc.price18, p.maxMoveBps)) {
                _accept(u, o, false);
            } else {
                Quote memory c = _candidate[u];
                if (c.price18 != 0 && o.sourceUpdatedAt > c.sourceUpdatedAt && !_moved(o.price18, c.price18, p.confirmBps))
                {
                    _accept(u, o, true);
                } else {
                    _candidate[u] = Quote(uint128(o.price18), o.sourceUpdatedAt, o.observedAt);
                }
            }
            (s,,) = _evaluate(u, true);
        }
        if (ok) {
            emit PriceObserved(
                u, o.price18, o.quoteUsd18, o.twapPrice18, o.sourceUpdatedAt, o.roundId, o.observedAt, o.sourceBlock, s
            );
        }
    }

    function _accept(address u, StockObservation memory o, bool jump) private {
        _anchor[u] = Quote(uint128(o.price18), o.sourceUpdatedAt, o.observedAt);
        delete _candidate[u];
        emit PriceAccepted(u, o.price18, o.sourceUpdatedAt, jump);
    }

    // ------------------------------------------------------------------ consumer reads

    /// @notice Execution price (USD per raw token, 18 dp) and its observation time; reverts unless Live.
    function execPrice(address asset) public view returns (uint256 price18, uint256 observedAt) {
        address u = _known(asset);
        (Status s, StockObservation memory o,) = _evaluate(u, true);
        if (s != Status.Live) revert PriceNotLive(asset, s);
        return (o.price18, o.observedAt);
    }

    /// @notice IRewardPrice / IDeskServicePrice: (price, observedAt), or (0, 0) unless the price would be Live
    ///         apart from the observation age. Never reverts. Those consumers only compare a push against a
    ///         minimum and bound the age themselves (`oracleMaxAge`, 1–2h against an hourly relay), so the
    ///         15-minute execution freshness is not applied here; every other state (closed market, divergent,
    ///         suspect, paused, failed read) still returns (0, 0).
    function priceUSD18(address asset) external view returns (uint256 price, uint256 updatedAt) {
        address u = underlyingOf[asset];
        if (u == address(0)) u = asset;
        if (address(_assets[u].source) == address(0)) return (0, 0);
        (Status s, StockObservation memory o,) = _evaluate(u, false);
        if (s != Status.Live) return (0, 0);
        return (o.price18, o.observedAt);
    }

    /// @notice Raw tokens `usd18` buys at the execution price (rounded down). Reverts unless Live.
    function rawFor(address asset, uint256 usd18) external view returns (uint256) {
        (uint256 p,) = execPrice(asset);
        return Math.mulDiv(usd18, 1e18, p);
    }

    /// @notice USD value (18 dp) of `raw` at the execution price (rounded down). Reverts unless Live.
    function usdFor(address asset, uint256 raw) external view returns (uint256) {
        (uint256 p,) = execPrice(asset);
        return Math.mulDiv(raw, p, 1e18);
    }

    function status(address asset) external view returns (Status s) {
        address u = underlyingOf[asset];
        if (u == address(0)) u = asset;
        if (address(_assets[u].source) == address(0)) return Status.None;
        (s,,) = _evaluate(u, true);
    }

    /// @notice The current source observation (zeroed if the read fails) and the status.
    function latest(address asset) external view returns (StockObservation memory o, Status s) {
        (s, o,) = _evaluate(_known(asset), true);
    }

    // ArcStocksOracleV2-compatible reads -----------------------------------------------------------------

    /// @notice The accepted price (18 dp) and when it was observed; zero if none.
    function peek(address asset) external view returns (uint128 price18, uint64 updatedAt) {
        Quote memory q = _anchor[_key(asset)];
        return (q.price18, q.updatedAt);
    }

    /// @notice The execution price, or a revert when it is not Live (ArcStocks `getPrice` shape).
    function getPrice(address asset) external view returns (uint256 price18) {
        (price18,) = execPrice(asset);
    }

    function quoteOf(address asset) external view returns (Quote memory) {
        return _anchor[_key(asset)];
    }

    function candidateOf(address asset) external view returns (Quote memory) {
        return _candidate[_key(asset)];
    }

    /// @notice Robinhood's uiMultiplier (18 dp) as last reported by the source; 0 when unknown.
    function multiplierOf(address asset) external view returns (uint256) {
        (, StockObservation memory o,) = _evaluate(_known(asset), true);
        return o.multiplier;
    }

    function isStale(address asset) external view returns (bool) {
        address u = underlyingOf[asset];
        if (u == address(0)) u = asset;
        if (address(_assets[u].source) == address(0)) return true;
        (Status s,,) = _evaluate(u, true);
        return s != Status.Live;
    }

    function assetOf(address asset) external view returns (Asset memory) {
        return _assets[_key(asset)];
    }

    function underlyings() external view returns (address[] memory) {
        return _underlyings;
    }

    // ------------------------------------------------------------------ internals

    function _evaluate(address u, bool checkAge) private view returns (Status s, StockObservation memory o, bool ok) {
        Asset storage a = _assets[u];
        try a.source.observe(u) returns (StockObservation memory r) {
            o = r;
            ok = r.price18 != 0 && r.observedAt != 0;
        } catch {}
        if (a.paused) return (Status.Paused, o, ok);
        if (!ok) return (Status.Stale, o, ok);
        Params memory p = a.params;
        uint256 age = block.timestamp > o.observedAt ? block.timestamp - o.observedAt : 0;
        if (checkAge && age > p.maxAge) return (Status.Stale, o, ok);
        // Feed age at execution time (a relayed RH timestamp a few seconds ahead of Arc counts as 0).
        if (block.timestamp > o.sourceUpdatedAt && block.timestamp - o.sourceUpdatedAt > p.maxSourceAge) {
            return (Status.Stale, o, ok);
        }
        if (_moved(o.quoteUsd18, 1e18, p.maxDepegBps)) return (Status.Divergent, o, ok);
        if (p.maxTwapBps != 0) {
            // The TWAP is in the settlement stable; compare in USD. A missing TWAP fails closed.
            if (o.twapPrice18 == 0) return (Status.Divergent, o, ok);
            if (_moved(o.price18, Math.mulDiv(o.twapPrice18, o.quoteUsd18, 1e18), p.maxTwapBps)) {
                return (Status.Divergent, o, ok);
            }
        }
        Quote memory anc = _anchor[u];
        if (anc.price18 == 0 || _moved(o.price18, anc.price18, p.maxMoveBps)) return (Status.Suspect, o, ok);
        return (Status.Live, o, ok);
    }

    /// @dev |a - ref| > ref * bps / 10_000, without rounding in a's favour.
    function _moved(uint256 a, uint256 ref, uint256 bps) private pure returns (bool) {
        uint256 d = a > ref ? a - ref : ref - a;
        return d * 10_000 > ref * bps;
    }

    function _validate(Params calldata p) private pure {
        if (
            p.maxAge == 0 || p.maxAge > MAX_AGE_LIMIT || p.maxMoveBps == 0 || p.maxMoveBps > MAX_MOVE_LIMIT
                || p.confirmBps > p.maxMoveBps || p.maxDepegBps > MAX_DEPEG_LIMIT || p.maxSourceAge == 0
                || p.maxSourceAge > MAX_AGE_LIMIT || p.maxTwapBps > MAX_MOVE_LIMIT
        ) revert BadParams();
    }

    function _key(address asset) private view returns (address u) {
        u = underlyingOf[asset];
        if (u == address(0)) u = asset;
    }

    function _known(address asset) private view returns (address u) {
        u = _key(asset);
        if (address(_assets[u].source) == address(0)) revert UnknownAsset(asset);
    }
}

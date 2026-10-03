// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IDeskPriceOracle {
    function execPrice(address asset) external view returns (uint256 price18, uint256 observedAt);
    function rawFor(address asset, uint256 usd18) external view returns (uint256);
    function usdFor(address asset, uint256 raw) external view returns (uint256);
}

interface IInstantDeskHub {
    function requestBuy(address underlying, uint256 usdcIn, uint256 minSharesOut) external payable returns (uint256);
    function requestSell(address underlying, uint256 sharesIn, uint256 minUsdcOut) external payable returns (uint256);
    function quoteOrder(address underlying) external view returns (uint256);
    function cancel(uint256 id) external;
    function claim(uint256 id) external;
    function escalate(uint256 id, address to) external payable;
    function escalateFunds(uint256 id, address to) external payable;
    function underlyingOfToken(address token) external view returns (address);
    function stockState(address token) external view returns (bool marketOpen, bool transferable, uint256 version);
}

/// @title InstantStockDesk — STOCK.sol for native USDC and back at the oracle price, in one transaction
/// @notice Forked from ArcStocks StockDesk (MIT, Arc 5042 0xc32c274c48a48e34872f8EEA1bBBC0B3b6E43977, source in
///         arc-launchpad/docs/evidence/v3-stock-rewards/arcstocks-more/stockDesk): a small protocol inventory of each
///         listed STOCK.sol and of native USDC, swapped one for the other at the oracle price with a spread that only
///         pays for refilling, a per-trade cap and an hourly flow cap per side (an old price can cost at most one
///         hour's cap), refilled by the keeper through the stock hub like any user. It never creates or borrows
///         stock: everything it hands out was minted 1:1 by the hub, so the layer's backing is untouched, and it
///         needs no Arc AMM pool per stock (AAPL/TSLA are reward assets without pools).
///         Solon changes (governance rules; no single-EOA upgradeability):
///         - not a UUPS proxy; hub, oracle, treasury and the canonical-exit recipient are immutable;
///         - price = `SolonStockOracle.execPrice` (Chainlink, Live only) instead of a keeper-posted number;
///         - the owner (timelock, 48h) withdraws only to the fixed treasury, never to an arbitrary address;
///         - restock/unstock minimums are bound to the oracle (hub fee + 1%), never keeper-chosen zeros;
///         - hub exits for the desk's own orders go only to the fixed reserve-chain recipient;
///         - amounts are 18-dp native USDC throughout (ArcStocks used 6-dp caps).
///         Named "Instant…" to avoid confusion with the Solon Desk NFT.
contract InstantStockDesk is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Terms {
        address underlying;
        uint16 spreadBps; // off what a buyer gets: pays for buying back through the hub
        uint16 sellSpreadBps; // off what a seller is paid
        uint128 maxTradeUsd; // 18 dp
        uint128 flowCapUsd; // per side per clock hour, 18 dp
        bool enabled;
    }

    struct Flow {
        uint64 hour;
        uint128 boughtUsd;
        uint128 soldUsd;
    }

    uint256 private constant BPS = 10_000;
    uint16 public constant MAX_SPREAD_BPS = 500;
    uint256 public constant HUB_FEE_BPS = 25;
    uint256 public constant RESTOCK_SLIPPAGE_BPS = 100;
    uint256 public constant HOOK_FEE = 1 ether; // the gate's 1 USDC for canonical exits

    address public immutable owner; // timelock
    address public immutable guardian;
    IInstantDeskHub public immutable hub;
    IDeskPriceOracle public immutable oracle;
    address public immutable restocker;
    address public immutable treasury;
    address public immutable reserveRecipient; // fixed RH recipient of canonical exits

    bool public paused;
    mapping(address stock => Terms) private _terms;
    mapping(address stock => Flow) private _flow;
    address[] private _stocks;

    event Bought(address indexed stock, address indexed buyer, address to, uint256 usdcIn, uint256 sharesOut, uint256 price);
    event Sold(address indexed stock, address indexed seller, address to, uint256 sharesIn, uint256 usdcOut, uint256 price);
    event Restocked(address indexed stock, uint256 indexed orderId, uint256 usdcIn, uint256 minShares, uint256 lzFee);
    event Unstocked(address indexed stock, uint256 indexed orderId, uint256 sharesIn, uint256 minUsdc, uint256 lzFee);
    event TermsSet(address indexed stock, Terms terms);
    event Withdrawn(address indexed asset, uint256 amount);
    event Funded(address indexed from, uint256 amount);
    event Paused(bool paused);

    error NotOwner();
    error NotGuardian();
    error NotRestocker();
    error NotListed(address stock);
    error NotAStock(address stock);
    error IsPaused();
    error OverTradeCap(uint256 usd, uint256 cap);
    error OverFlowCap(uint256 usd, uint256 left);
    error OutOfStock(uint256 want, uint256 have);
    error OutOfUsdc(uint256 want, uint256 have);
    error Slippage(uint256 out, uint256 min);
    error ZeroAmount();
    error SpreadTooHigh();
    error TransferFailed();

    constructor(
        address owner_,
        address guardian_,
        address hub_,
        address oracle_,
        address restocker_,
        address treasury_,
        address reserveRecipient_
    ) {
        require(
            owner_ != address(0) && guardian_ != address(0) && hub_.code.length != 0 && oracle_.code.length != 0
                && restocker_ != address(0) && treasury_ != address(0) && reserveRecipient_ != address(0)
        );
        owner = owner_;
        guardian = guardian_;
        hub = IInstantDeskHub(hub_);
        oracle = IDeskPriceOracle(oracle_);
        restocker = restocker_;
        treasury = treasury_;
        reserveRecipient = reserveRecipient_;
    }

    /// @notice Native USDC in: funding, and the hub paying a sell back.
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    // ------------------------------------------------------------------ trade

    /// @notice Buy `stock` with the native USDC sent; the shares go to `to` (the caller when zero).
    function buy(address stock, uint256 minSharesOut, address to)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 sharesOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (to == address(0)) to = msg.sender;
        (Terms memory t, uint256 price) = _live(stock);
        _capped(msg.value, t);
        _useFlow(stock, t, msg.value, true);
        sharesOut = _sharesFor(msg.value, price, t.spreadBps);
        uint256 have = IERC20(stock).balanceOf(address(this));
        if (sharesOut > have) revert OutOfStock(sharesOut, have);
        if (sharesOut < minSharesOut) revert Slippage(sharesOut, minSharesOut);
        IERC20(stock).safeTransfer(to, sharesOut);
        emit Bought(stock, msg.sender, to, msg.value, sharesOut, price);
    }

    /// @notice Sell `sharesIn` of `stock` (pulled from the caller) for native USDC to `to`.
    function sell(address stock, uint256 sharesIn, uint256 minUsdcOut, address to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcOut)
    {
        if (sharesIn == 0) revert ZeroAmount();
        if (to == address(0)) to = msg.sender;
        (Terms memory t, uint256 price) = _live(stock);
        uint256 gross = Math.mulDiv(sharesIn, price, 1e18);
        _capped(gross, t);
        _useFlow(stock, t, gross, false);
        usdcOut = (gross * (BPS - t.sellSpreadBps)) / BPS;
        if (usdcOut > address(this).balance) revert OutOfUsdc(usdcOut, address(this).balance);
        if (usdcOut < minUsdcOut) revert Slippage(usdcOut, minUsdcOut);
        IERC20(stock).safeTransferFrom(msg.sender, address(this), sharesIn);
        (bool ok,) = to.call{value: usdcOut}("");
        if (!ok) revert TransferFailed();
        emit Sold(stock, msg.sender, to, sharesIn, usdcOut, price);
    }

    function quoteBuy(address stock, uint256 usdcIn) external view returns (uint256 sharesOut, bool ok) {
        (Terms memory t, uint256 price, bool live) = _peek(stock);
        if (price == 0) return (0, false);
        sharesOut = _sharesFor(usdcIn, price, t.spreadBps);
        ok = live && !paused && usdcIn > 0 && usdcIn <= t.maxTradeUsd && usdcIn <= _flowLeft(stock, t, true)
            && sharesOut <= IERC20(stock).balanceOf(address(this));
    }

    function quoteSell(address stock, uint256 sharesIn) external view returns (uint256 usdcOut, bool ok) {
        (Terms memory t, uint256 price, bool live) = _peek(stock);
        if (price == 0) return (0, false);
        uint256 gross = Math.mulDiv(sharesIn, price, 1e18);
        usdcOut = (gross * (BPS - t.sellSpreadBps)) / BPS;
        ok = live && !paused && sharesIn > 0 && gross <= t.maxTradeUsd && gross <= _flowLeft(stock, t, false)
            && usdcOut <= address(this).balance;
    }

    /// @notice The most one trade can move now (native USDC 18 dp): per-trade cap, hour's flow and inventory.
    function capacity(address stock) external view returns (uint256 buyUsdc, uint256 sellUsdc) {
        (Terms memory t, uint256 price, bool live) = _peek(stock);
        if (!live || paused || price == 0) return (0, 0);
        uint256 stockUsd = Math.mulDiv(IERC20(stock).balanceOf(address(this)), price, 1e18);
        buyUsdc = Math.min(
            Math.min((stockUsd * BPS) / (BPS - t.spreadBps), t.maxTradeUsd), _flowLeft(stock, t, true)
        );
        sellUsdc = Math.min(
            Math.min((address(this).balance * BPS) / (BPS - t.sellSpreadBps), t.maxTradeUsd),
            _flowLeft(stock, t, false)
        );
    }

    // ------------------------------------------------------------------ refilling through the hub

    /// @notice Buy `usdcIn` of `stock` from the reserve; the hub mints it here when RH answers. The minimum is at
    ///         least the oracle amount less the hub fee and 1%.
    function restock(address stock, uint256 usdcIn, uint256 minShares) external nonReentrant returns (uint256 id) {
        _restockerOnly();
        address underlying = _listed(stock).underlying;
        uint256 floor = oracle.rawFor(stock, usdcIn) * (BPS - HUB_FEE_BPS - RESTOCK_SLIPPAGE_BPS) / BPS;
        if (minShares == 0 || minShares < floor) revert Slippage(minShares, floor);
        uint256 lzFee = hub.quoteOrder(underlying);
        if (usdcIn + lzFee > address(this).balance) revert OutOfUsdc(usdcIn + lzFee, address(this).balance);
        id = hub.requestBuy{value: usdcIn + lzFee}(underlying, usdcIn, minShares);
        emit Restocked(stock, id, usdcIn, minShares, lzFee);
    }

    /// @notice Sell `sharesIn` of `stock` into the reserve; the hub pays the USDC here. Oracle-bound minimum.
    function unstock(address stock, uint256 sharesIn, uint256 minUsdc) external nonReentrant returns (uint256 id) {
        _restockerOnly();
        address underlying = _listed(stock).underlying;
        uint256 floor = oracle.usdFor(stock, sharesIn) * (BPS - HUB_FEE_BPS - RESTOCK_SLIPPAGE_BPS) / BPS;
        if (minUsdc == 0 || minUsdc < floor) revert Slippage(minUsdc, floor);
        uint256 lzFee = hub.quoteOrder(underlying);
        if (lzFee > address(this).balance) revert OutOfUsdc(lzFee, address(this).balance);
        id = hub.requestSell{value: lzFee}(underlying, sharesIn, minUsdc);
        emit Unstocked(stock, id, sharesIn, minUsdc, lzFee);
    }

    function cancelHubOrder(uint256 id) external nonReentrant {
        _restockerOnly();
        hub.cancel(id);
    }

    function claimHub(uint256 id) external nonReentrant {
        _restockerOnly();
        hub.claim(id);
    }

    /// @notice A stuck desk sell goes canonical; proceeds to the fixed reserve-chain recipient only.
    function escalateHubOrder(uint256 id) external nonReentrant {
        _restockerOnly();
        hub.escalate{value: HOOK_FEE}(id, reserveRecipient);
    }

    function escalateHubFunds(uint256 id) external nonReentrant {
        _restockerOnly();
        hub.escalateFunds{value: HOOK_FEE}(id, reserveRecipient);
    }

    // ------------------------------------------------------------------ admin (timelock / guardian)

    function setTerms(
        address stock,
        uint16 spreadBps,
        uint16 sellSpreadBps,
        uint128 maxTradeUsd,
        uint128 flowCapUsd,
        bool enabled
    ) external {
        if (msg.sender != owner) revert NotOwner();
        if (spreadBps > MAX_SPREAD_BPS || sellSpreadBps > MAX_SPREAD_BPS) revert SpreadTooHigh();
        address underlying = hub.underlyingOfToken(stock);
        if (underlying == address(0)) revert NotAStock(stock);
        if (_terms[stock].underlying == address(0)) _stocks.push(stock);
        Terms memory t = Terms(underlying, spreadBps, sellSpreadBps, maxTradeUsd, flowCapUsd, enabled);
        _terms[stock] = t;
        emit TermsSet(stock, t);
    }

    /// @notice Idle inventory back to the fixed treasury only (stock, or native USDC with `asset == address(0)`).
    function withdraw(address asset, uint256 amount) external nonReentrant {
        if (msg.sender != owner) revert NotOwner();
        if (asset == address(0)) {
            (bool ok,) = treasury.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(asset).safeTransfer(treasury, amount);
        }
        emit Withdrawn(asset, amount);
    }

    /// @notice The stop: guardian or owner. Only the owner resumes.
    function pause() external {
        if (msg.sender != guardian && msg.sender != owner) revert NotGuardian();
        paused = true;
        emit Paused(true);
    }

    function unpause() external {
        if (msg.sender != owner) revert NotOwner();
        paused = false;
        emit Paused(false);
    }

    // ------------------------------------------------------------------ views

    function terms(address stock) external view returns (Terms memory) {
        return _terms[stock];
    }

    function flowOf(address stock) external view returns (uint256 boughtUsd, uint256 soldUsd) {
        Flow memory f = _flow[stock];
        if (f.hour != block.timestamp / 1 hours) return (0, 0);
        return (f.boughtUsd, f.soldUsd);
    }

    function stocks() external view returns (address[] memory) {
        return _stocks;
    }

    // ------------------------------------------------------------------ internals

    /// @dev shares (18 dp) = usdc (18 dp) * 1e18 / price (18 dp), less the spread.
    function _sharesFor(uint256 usdcIn, uint256 price, uint16 spreadBps) internal pure returns (uint256) {
        return Math.mulDiv(usdcIn, 1e18 * (BPS - spreadBps), price * BPS);
    }

    function _capped(uint256 usd, Terms memory t) internal pure {
        if (usd > t.maxTradeUsd) revert OverTradeCap(usd, t.maxTradeUsd);
    }

    function _useFlow(address stock, Terms memory t, uint256 usd, bool buySide) internal {
        Flow storage f = _flow[stock];
        uint64 hour = uint64(block.timestamp / 1 hours);
        if (f.hour != hour) {
            f.hour = hour;
            f.boughtUsd = 0;
            f.soldUsd = 0;
        }
        uint256 used = buySide ? f.boughtUsd : f.soldUsd;
        if (used + usd > t.flowCapUsd) revert OverFlowCap(usd, t.flowCapUsd > used ? t.flowCapUsd - used : 0);
        if (buySide) f.boughtUsd = uint128(used + usd);
        else f.soldUsd = uint128(used + usd);
    }

    function _flowLeft(address stock, Terms memory t, bool buySide) internal view returns (uint256) {
        Flow memory f = _flow[stock];
        uint256 used = f.hour == block.timestamp / 1 hours ? (buySide ? f.boughtUsd : f.soldUsd) : 0;
        return used >= t.flowCapUsd ? 0 : t.flowCapUsd - used;
    }

    function _listed(address stock) internal view returns (Terms memory t) {
        t = _terms[stock];
        if (t.underlying == address(0)) revert NotListed(stock);
    }

    /// @dev Enabled, trading on the hub and Live on the oracle, or a revert saying which.
    function _live(address stock) internal view returns (Terms memory t, uint256 price) {
        t = _listed(stock);
        (, bool transferable,) = hub.stockState(stock);
        if (!t.enabled || !transferable) revert NotListed(stock);
        (price,) = oracle.execPrice(stock);
    }

    function _peek(address stock) internal view returns (Terms memory t, uint256 price, bool live) {
        t = _terms[stock];
        if (t.underlying == address(0)) return (t, 0, false);
        try oracle.execPrice(stock) returns (uint256 p, uint256) {
            price = p;
        } catch {
            return (t, 0, false);
        }
        (, bool transferable,) = hub.stockState(stock);
        live = t.enabled && transferable;
    }

    function _restockerOnly() internal view {
        if (msg.sender != restocker && msg.sender != owner) revert NotRestocker();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IExecutionVenue} from "../interfaces/IExecutionVenue.sol";
import {IStableRail} from "../interfaces/IStableRail.sol";
import {IV3SwapRouter} from "../interfaces/IV3SwapRouter.sol"; // GPL-2.0-or-later interface (see NOTICE)

/// @title RestrictedVenue — buys and sells Robinhood Stock Tokens in Uniswap v3 STOCK/USDG pools
/// @notice Forked from ArcStocks v2 `UniswapV3Venue` (MIT, verified RH 0x9f9abde1…1f95). Settlement token
///         is USDC or USDG. If a rail is configured, the settlement token is converted 1:1 to the pool quote
///         before the swap (and back after a sale). If the settlement token *is* the pool quote token (the
///         Solon USDG-settled deployment), the rail is skipped entirely. The order's `minOut` is passed to
///         the router unchanged (A12: no additional oracle gate is invented here).
/// @dev Solon changes (A06 narrowed): the vault is bound once; pool fee tiers are set once per stock at
///      listing and any later change waits `CONFIG_DELAY`; a buy reports the shares that actually reached
///      the recipient, not the router's claim.
contract RestrictedVenue is IExecutionVenue, Ownable {
    using SafeERC20 for IERC20;

    uint64 public constant CONFIG_DELAY = 48 hours;

    IV3SwapRouter public immutable router;
    IERC20 public immutable settlement;
    IERC20 public immutable quote;
    IStableRail public immutable rail;

    /// @notice Authorised caller (the vault). Bound once.
    address public vault;
    /// @notice Fee tier of the STOCK/USDG pool to route through, 0 = not listed.
    mapping(address stock => uint24 fee) public poolFee;
    mapping(address stock => uint24 fee) public pendingPoolFee;
    mapping(address stock => uint64 eta) public pendingPoolEta;

    event VaultSet(address vault);
    event PoolSet(address indexed stock, uint24 fee);
    event PoolProposed(address indexed stock, uint24 fee, uint64 eta);

    error NotVault();
    error UnsupportedStock(address stock);
    error RailMismatch();
    error AlreadySet();
    error Timelocked();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address router_, address settlement_, address quote_, address rail_, address owner_) Ownable(owner_) {
        router = IV3SwapRouter(router_);
        settlement = IERC20(settlement_);
        quote = IERC20(quote_);
        rail = IStableRail(rail_);
        if (rail_ != address(0)) {
            if (rail.settlement() != settlement_ || rail.quote() != quote_) revert RailMismatch();
        } else if (settlement_ != quote_) {
            revert RailMismatch();
        }
    }

    // ------------------------------------------------------------------ admin

    function setVault(address vault_) external onlyOwner {
        if (vault != address(0)) revert AlreadySet();
        vault = vault_;
        emit VaultSet(vault_);
    }

    /// @notice First fee tier of a stock immediately; any change (including delisting with 0) after 48h.
    function setPool(address stock, uint24 fee) external onlyOwner {
        if (poolFee[stock] == 0) {
            poolFee[stock] = fee;
            emit PoolSet(stock, fee);
            return;
        }
        pendingPoolFee[stock] = fee;
        pendingPoolEta[stock] = uint64(block.timestamp) + CONFIG_DELAY;
        emit PoolProposed(stock, fee, pendingPoolEta[stock]);
    }

    function executePool(address stock) external onlyOwner {
        uint64 eta = pendingPoolEta[stock];
        if (eta == 0 || block.timestamp < eta) revert Timelocked();
        poolFee[stock] = pendingPoolFee[stock];
        delete pendingPoolFee[stock];
        delete pendingPoolEta[stock];
        emit PoolSet(stock, poolFee[stock]);
    }

    // ------------------------------------------------------------------ venue

    function buy(address stock, uint256 settlementIn, uint256 minSharesOut, address recipient)
        external
        onlyVault
        returns (uint256 sharesOut)
    {
        uint24 fee = poolFee[stock];
        if (fee == 0) revert UnsupportedStock(stock);

        settlement.safeTransferFrom(msg.sender, address(this), settlementIn);
        uint256 quoteIn = _toQuote(settlementIn);

        uint256 before = IERC20(stock).balanceOf(recipient);
        quote.forceApprove(address(router), quoteIn);
        uint256 reported = router.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: address(quote),
                tokenOut: stock,
                fee: fee,
                recipient: recipient,
                amountIn: quoteIn,
                amountOutMinimum: minSharesOut,
                sqrtPriceLimitX96: 0
            })
        );
        quote.forceApprove(address(router), 0);
        sharesOut = IERC20(stock).balanceOf(recipient) - before;
        if (reported < sharesOut) sharesOut = reported;
    }

    function sell(address stock, uint256 sharesIn, uint256 minSettlementOut, address recipient)
        external
        onlyVault
        returns (uint256 settlementOut)
    {
        uint24 fee = poolFee[stock];
        if (fee == 0) revert UnsupportedStock(stock);

        IERC20(stock).safeTransferFrom(msg.sender, address(this), sharesIn);
        IERC20(stock).forceApprove(address(router), sharesIn);
        uint256 quoteOut = router.exactInputSingle(
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: stock,
                tokenOut: address(quote),
                fee: fee,
                recipient: address(this),
                amountIn: sharesIn,
                amountOutMinimum: minSettlementOut, // 1:1 rail, so the floor carries over
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(stock).forceApprove(address(router), 0);

        settlementOut = _toSettlement(quoteOut);
        settlement.safeTransfer(recipient, settlementOut);
    }

    function settlementToken() external view returns (address) {
        return address(settlement);
    }

    function isSupported(address stock) external view returns (bool) {
        return poolFee[stock] != 0;
    }

    // ------------------------------------------------------------------ rail

    function _toQuote(uint256 amount) internal returns (uint256) {
        if (address(rail) == address(0)) return amount;
        settlement.forceApprove(address(rail), amount);
        return rail.toQuote(amount);
    }

    function _toSettlement(uint256 amount) internal returns (uint256) {
        if (address(rail) == address(0)) return amount;
        quote.forceApprove(address(rail), amount);
        return rail.toSettlement(amount);
    }
}

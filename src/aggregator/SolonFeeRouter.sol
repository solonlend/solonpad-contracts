// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
}

/// Stateless interface-fee router for aggregated external pans. Every trade
/// pays FEE_BPS of its quote leg to the treasury: buys skim the quote input
/// before it reaches the venue, sells skim the quote output on the way back.
/// The router holds no balances between transactions; refunds and outputs are
/// forwarded within the same call.
contract SolonFeeRouter {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_BPS = 50;
    uint256 internal constant BPS = 10_000;
    address public immutable treasury;
    address public immutable swapRouter;

    error NativeMismatch();
    error NativeSendFailed();

    constructor(address treasury_, address swapRouter_) {
        treasury = treasury_;
        swapRouter = swapRouter_;
    }

    /// Curve buys deliver tokens straight to the caller (the curve takes a
    /// recipient), so only the fee and a possible partial-fill refund pass
    /// through here. `quote` is address(0) for native-quoted curves.
    function curveBuy(address curve, address quote, uint256 quoteIn, uint256 minTokensOut)
        external
        payable
        returns (uint256 tokensOut)
    {
        uint256 fee = (quoteIn * FEE_BPS) / BPS;
        uint256 spend = quoteIn - fee;
        if (quote == address(0)) {
            if (msg.value != quoteIn) revert NativeMismatch();
            _sendNative(treasury, fee);
            tokensOut = IPonsCurve(curve).buy{value: spend}(spend, minTokensOut, msg.sender);
            // Partial fills refund the unspent quote to msg.sender (us).
            uint256 refund = address(this).balance;
            if (refund != 0) _sendNative(msg.sender, refund);
        } else {
            if (msg.value != 0) revert NativeMismatch();
            IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteIn);
            IERC20(quote).safeTransfer(treasury, fee);
            IERC20(quote).forceApprove(curve, spend);
            tokensOut = IPonsCurve(curve).buy(spend, minTokensOut, msg.sender);
            IERC20(quote).forceApprove(curve, 0);
            uint256 refund = IERC20(quote).balanceOf(address(this));
            if (refund != 0) IERC20(quote).safeTransfer(msg.sender, refund);
        }
    }

    error SlippageExceeded(uint256 netOut, uint256 minOut);

    /// Curve sells route the quote output through the router so the fee can
    /// come off the quote leg; `minQuoteOut` bounds what the CALLER receives
    /// net of our fee, so the curve's own check runs unbounded here.
    function curveSell(address curve, address token, address quote, uint256 tokensIn, uint256 minQuoteOut)
        external
        returns (uint256 netQuoteOut)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        IERC20(token).forceApprove(curve, tokensIn);
        uint256 grossOut = IPonsCurve(curve).sell(tokensIn, 0, address(this));
        IERC20(token).forceApprove(curve, 0);
        uint256 fee = (grossOut * FEE_BPS) / BPS;
        netQuoteOut = grossOut - fee;
        if (netQuoteOut < minQuoteOut) revert SlippageExceeded(netQuoteOut, minQuoteOut);
        if (quote == address(0)) {
            _sendNative(treasury, fee);
            _sendNative(msg.sender, netQuoteOut);
        } else {
            IERC20(quote).safeTransfer(treasury, fee);
            IERC20(quote).safeTransfer(msg.sender, netQuoteOut);
        }
    }

    /// Exact-input v4 swap with the fee on the quote leg: `feeOnOutput` is
    /// false when the input side is the quote (a buy) and true when the
    /// output side is (a sell). `minOut` always bounds what the caller
    /// receives net of the fee. Works for any pool our venues use, hooked or
    /// not, native- or ERC20-quoted.
    function v4Swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minOut, bool feeOnOutput)
        external
        payable
        returns (uint256 netOut)
    {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;

        uint256 swapIn = amountIn;
        if (!feeOnOutput) {
            uint256 feeIn = (amountIn * FEE_BPS) / BPS;
            swapIn = amountIn - feeIn;
            _pay(input, treasury, feeIn, true);
        }

        uint256 value;
        if (input.isAddressZero()) {
            if (msg.value != amountIn) revert NativeMismatch();
            value = swapIn;
        } else {
            if (msg.value != 0) revert NativeMismatch();
            IERC20 erc = IERC20(Currency.unwrap(input));
            erc.safeTransferFrom(msg.sender, address(this), feeOnOutput ? amountIn : swapIn);
            erc.forceApprove(swapRouter, swapIn);
        }

        uint256 outBefore = _balance(output);
        PoolSwapTest(payable(swapRouter)).swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(swapIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        if (!input.isAddressZero()) IERC20(Currency.unwrap(input)).forceApprove(swapRouter, 0);
        uint256 grossOut = _balance(output) - outBefore;

        netOut = grossOut;
        if (feeOnOutput) {
            uint256 feeOut = (grossOut * FEE_BPS) / BPS;
            netOut = grossOut - feeOut;
            _pay(output, treasury, feeOut, false);
        }
        if (netOut < minOut) revert SlippageExceeded(netOut, minOut);
        _pay(output, msg.sender, netOut, false);

        // Return any unspent input (price-limit partial fill or native change).
        uint256 inputResidue = _balance(input);
        if (inputResidue != 0) _pay(input, msg.sender, inputResidue, false);
    }

    function _balance(Currency currency) internal view returns (uint256) {
        return currency.isAddressZero()
            ? address(this).balance
            : IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /// `fromCaller` pays native fees out of msg.value already at the router;
    /// ERC20 input fees are pulled straight from the caller instead.
    function _pay(Currency currency, address to, uint256 amount, bool fromCaller) internal {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            _sendNative(to, amount);
        } else if (fromCaller) {
            IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, to, amount);
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }

    receive() external payable {}
}

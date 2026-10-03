// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V3Router} from "./V3Router.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Real four-mode swap simulation with complete rollback, following the
/// Uniswap v4 reverting-quoter pattern, but executing the fixed official router.
/// @dev FUNDED simulation: payer needs input balance and router allowance; native
/// callers supply the input budget as msg.value (refunded). Exact output needs
/// maxIn funded up front. This lets beforeSwap take fees even on the FIRST buy
/// with empty quote reserves. Prefer eth_call; this is deliberately not view.
/// No swaps, allowances, fee lots, recipient balances or manager state persist.
contract V3Quoter is ReentrancyGuard {
    struct Quote {
        uint8 quoteKind; // 0 native USDC18; 1 stock raw18.
        address quoteAsset;
        uint8 quoteDecimals;
        uint256 grossQuote; // Buy: total quote input; sell: pre-fee quote output.
        uint256 netQuote; // Buy: quote reaching core; sell: user quote output.
        uint256 hookFee;
        uint256 minOut; // Simulated net output, a zero-slippage bound.
        uint256 maxIn; // Simulated total input, a zero-slippage bound.
        bool fullFillOnly;
        bytes32 poolId;
    }

    V3Router public immutable router;
    error InvalidRouter();
    error UnexpectedSimulationSuccess();
    error NativeRefundFailed();

    constructor(V3Router router_) {
        if (address(router_).code.length == 0) revert InvalidRouter();
        router = router_;
    }

    function quote(V3Router.SwapRequest calldata request, address payer)
        external
        payable
        nonReentrant
        returns (Quote memory q)
    {
        V3Router.PoolMetadata memory p = router.validateRequest(request, payer);
        try router.simulate{value: msg.value}(request, payer) {
            revert UnexpectedSimulationSuccess();
        } catch (bytes memory reason) {
            if (reason.length != 68 || bytes4(reason) != V3Router.SimulationResult.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            int256 rawDelta;
            uint256 fee;
            assembly ("memory-safe") {
                rawDelta := mload(add(reason, 36))
                fee := mload(add(reason, 68))
            }
            BalanceDelta d = BalanceDelta.wrap(rawDelta);
            uint256 amountIn = uint256(-int256(p.zeroForOne ? d.amount0() : d.amount1()));
            uint256 amountOut = uint256(int256(p.zeroForOne ? d.amount1() : d.amount0()));
            uint256 quoteAmount = request.buy ? amountIn : amountOut;
            q = Quote({
                quoteKind: p.quoteKind,
                quoteAsset: p.quoteAsset,
                quoteDecimals: 18,
                grossQuote: request.buy ? quoteAmount : quoteAmount + fee,
                netQuote: request.buy ? quoteAmount - fee : quoteAmount,
                hookFee: fee,
                minOut: amountOut,
                maxIn: amountIn,
                fullFillOnly: true,
                poolId: PoolId.unwrap(request.key.toId())
            });
        }
        // simulate reverted its entire value transfer; return only this caller's
        // supplied value, never sweep donations or any previous caller's funds.
        if (msg.value != 0) {
            (bool ok,) = payable(msg.sender).call{value: msg.value}("");
            if (!ok) revert NativeRefundFailed();
        }
    }
}

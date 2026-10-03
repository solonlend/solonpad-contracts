// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {V3LaunchFactory, IV3LaunchStockStatus} from "../V3LaunchFactory.sol";

interface IV3LaunchPriceOracle {
    function execPrice(address asset) external view returns (uint256 price18, uint256 observedAt);
}

/// @notice Fixed linked validation of the launch quote asset.
/// @dev r7 (design §12.2): the stock-quote opening price is the SolonStockOracle execution price (Chainlink,
///      reverts unless Live), no longer an off-chain signed quote; launches no longer depend on a signing service.
library V3LaunchValidation {
    error InvalidQuote();

    /// @return priceUsd18 The opening price for a stock quote (0 for native USDC).
    function validateQuote(
        mapping(address => bytes32) storage approvedQuote,
        address priceOracle,
        address stockStatus,
        V3LaunchFactory.QuoteConfig calldata q
    ) external view returns (uint256 priceUsd18) {
        if (q.kind == 0) {
            if (q.asset != address(0) || q.assetId != 0 || q.underlying != address(0)) revert InvalidQuote();
            return 0;
        }
        if (q.kind != 1 || approvedQuote[q.asset] != keccak256(abi.encode(q))) revert InvalidQuote();
        (bool marketOpen, bool transferable,) = IV3LaunchStockStatus(stockStatus).stockState(q.asset);
        if (!marketOpen || !transferable) revert InvalidQuote();
        (priceUsd18,) = IV3LaunchPriceOracle(priceOracle).execPrice(q.asset);
        if (priceUsd18 == 0) revert InvalidQuote();
    }
}

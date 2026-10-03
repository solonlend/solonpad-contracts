// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice One price observation of a stock, as every Solon price source reports it.
struct StockObservation {
    uint256 price18; // USD per raw stock token, 18 dp, multiplier applied
    uint256 multiplier; // the Robinhood token's uiMultiplier (18 dp) when the source can read it; 0 = unknown
    uint256 quoteUsd18; // the settlement stable (USDG on Robinhood Chain, USDC on Arc) in USD, 1e18 = $1
    uint256 twapPrice18; // stock/stable pool TWAP, stable per raw stock token, 18 dp; 0 = no pool configured
    uint64 sourceUpdatedAt; // Chainlink updatedAt of the stock feed
    uint80 roundId; // Chainlink round of the stock feed
    uint64 observedAt; // when the feed was read (Arc block time for a direct read, RH block time when relayed)
    uint64 sourceBlock; // block number of that read on its chain
}

/// @notice A stock price source behind `SolonStockOracle`: a direct Chainlink read (`ChainlinkStockSource`) or
///         the Robinhood Chain Chainlink read relayed over LayerZero (`RelayedStockSource`). Keyed by the RH
///         underlying. Must revert (fail closed) rather than return an unchecked value.
interface IStockPriceSource {
    function observe(address underlying) external view returns (StockObservation memory);
}

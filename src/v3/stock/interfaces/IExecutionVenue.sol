// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IExecutionVenue
/// @notice Where the vault actually buys and sells the underlying stock tokens.
///         The vault only knows "settlement token in, shares out" — the venue hides the route
///         (Uniswap v3 on Robinhood Chain today, anything else tomorrow).
interface IExecutionVenue {
    /// @notice Pulls `settlementIn` of the settlement token from the caller, buys `stock`
    ///         and sends the purchased shares to `recipient`.
    /// @return sharesOut Amount of `stock` (18 dp) delivered to `recipient`.
    function buy(address stock, uint256 settlementIn, uint256 minSharesOut, address recipient)
        external
        returns (uint256 sharesOut);

    /// @notice Pulls `sharesIn` of `stock` from the caller, sells it and sends the proceeds
    ///         in the settlement token to `recipient`.
    /// @return settlementOut Amount of settlement token delivered to `recipient`.
    function sell(address stock, uint256 sharesIn, uint256 minSettlementOut, address recipient)
        external
        returns (uint256 settlementOut);

    /// @notice The token the venue is paid in and pays out (USDC for ArcStocks).
    function settlementToken() external view returns (address);

    /// @notice Whether the venue knows how to trade `stock`.
    function isSupported(address stock) external view returns (bool);
}

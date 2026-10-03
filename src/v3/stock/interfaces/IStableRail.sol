// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStableRail
/// @notice 1:1 conversion between the settlement stable (USDC) and the pool quote stable (USDG).
///         On the fork this is an inventory contract; on mainnet it is the piece to replace with a
///         real dollar rail (CCTP / Paxos conversion / a stable pool) — the vault never sees it.
interface IStableRail {
    /// @notice Pulls `amount` of settlement token, returns the same amount of quote token.
    function toQuote(uint256 amount) external returns (uint256 quoteOut);
    /// @notice Pulls `amount` of quote token, returns the same amount of settlement token.
    function toSettlement(uint256 amount) external returns (uint256 settlementOut);
    function settlement() external view returns (address);
    function quote() external view returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice A fixed, governance-registered money route between the Arc hub and the reserve vault on
///         Robinhood Chain (Solon addition for the zero-float sequential mode, design r5 §8.6).
///         The route carries principal for exactly one order `ref` per call; it never picks recipients.
interface IFundingRoute {
    /// @notice Send `amountIn` (+ `fee` in the same asset) for `ref` to the route's fixed destination so
    ///         that at least `minOut` arrives there. Native routes take `amountIn + fee` as `msg.value`;
    ///         ERC20 routes pull `amountIn + fee` from the caller. `quote` is the route's signed quote.
    function send(bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, bytes calldata quote)
        external
        payable
        returns (bytes32 transferId);

    /// @notice Reverts unless `send` with the same arguments would be accepted now.
    function validate(bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, bytes calldata quote) external view;

    /// @notice address(0) for the chain's native asset, otherwise the ERC20 moved.
    function asset() external view returns (address);

    /// @notice The only address funds arrive at on the other chain.
    function destination() external view returns (address);
}

/// @notice The Arc hub side of a return (refund of an unfilled buy, proceeds of a sell).
interface IFundingReturnSink {
    function receiveReturn(bytes32 ref) external payable;
}

/// @notice The reserve vault side of a funding leg: pays `amount` of the settlement token for `ref`.
interface IReserveFunding {
    function fund(bytes32 ref, uint256 amount) external;
}

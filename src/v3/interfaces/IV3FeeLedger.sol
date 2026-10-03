// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Fixed local accounting receiver; must not perform user payouts here.
interface IV3FeeReceiver {
    function onFeeCredit(bytes32 poolId, address quote, uint8 settlementKind, uint256 amount) external;
}

interface IV3FeeLedger {
    /// @dev Every call creates a new, automatically numbered, actually funded lot.
    function creditNative(bytes32 poolId) external payable;
    function creditStock(bytes32 poolId, uint256 amount) external;
    function creditClaims(bytes32 poolId, uint256 amount) external;
    function redeemClaims(bytes32 poolId) external;
    function claim(bytes32 poolId, uint8 bucket, uint256 amount) external returns (bool);
    function claimUSDC6(bytes32 poolId, uint8 bucket, uint256 amount18) external returns (bool);
    function accrued(bytes32 poolId, uint256 bucket) external view returns (uint256);
}

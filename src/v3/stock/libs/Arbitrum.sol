// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Arbitrum — the slice of the Nitro bridge that ArcStocks talks to
/// @notice Robinhood Chain is an Arbitrum Nitro rollup settling to Ethereum. Ethereum → Robinhood
///         goes through the Delayed Inbox as a retryable ticket; Robinhood → Ethereum goes through
///         ArbSys and, seven days later, the Outbox.

/// @notice Delayed Inbox on the parent chain.
interface IInbox {
    function createRetryableTicket(
        address to,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        bytes calldata data
    ) external payable returns (uint256);

    function calculateRetryableSubmissionFee(uint256 dataLength, uint256 baseFee) external view returns (uint256);
}

/// @notice ArbSys precompile at 0x64 on the rollup.
interface IArbSys {
    function sendTxToL1(address destination, bytes calldata data) external payable returns (uint256);
}

/// @notice Bridge on the parent chain: every executed outbox message is a call from here.
interface IBridge {
    function activeOutbox() external view returns (address);
}

/// @notice Outbox on the parent chain: tells the callee which L2 account sent the message being executed.
interface IOutbox {
    function l2ToL1Sender() external view returns (address);
}

library AddressAlias {
    uint160 internal constant OFFSET = uint160(0x1111000000000000000000000000000000001111);

    /// @notice What `msg.sender` looks like on the rollup when a parent-chain contract sends a retryable.
    function applyL1ToL2Alias(address l1) internal pure returns (address) {
        unchecked {
            return address(uint160(l1) + OFFSET);
        }
    }

    function undoL1ToL2Alias(address l2) internal pure returns (address) {
        unchecked {
            return address(uint160(l2) - OFFSET);
        }
    }
}

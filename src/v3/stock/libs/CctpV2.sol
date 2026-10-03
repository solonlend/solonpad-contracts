// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CctpV2 — the slice of Circle's CCTP v2 that ArcStocks talks to
/// @notice Hooks in CCTP v2 are opaque: Circle attests the burn, the destination caller executes
///         `receiveMessage` itself and then reads the hook data out of the message. This library
///         parses the MessageV2 header and BurnMessageV2 body exactly as Circle lays them out
///         (see evm-cctp-contracts `MessageV2.sol` / `BurnMessageV2.sol`).
library CctpV2 {
    // MessageV2 header offsets
    uint256 private constant VERSION_INDEX = 0; // uint32
    uint256 private constant SOURCE_DOMAIN_INDEX = 4; // uint32
    uint256 private constant DESTINATION_DOMAIN_INDEX = 8; // uint32
    uint256 private constant NONCE_INDEX = 12; // bytes32
    uint256 private constant SENDER_INDEX = 44; // bytes32
    uint256 private constant RECIPIENT_INDEX = 76; // bytes32
    uint256 private constant DESTINATION_CALLER_INDEX = 108; // bytes32
    uint256 private constant MIN_FINALITY_THRESHOLD_INDEX = 140; // uint32
    uint256 private constant FINALITY_THRESHOLD_EXECUTED_INDEX = 144; // uint32
    uint256 private constant MESSAGE_BODY_INDEX = 148;

    // BurnMessageV2 body offsets (relative to body start)
    uint256 private constant BODY_VERSION_INDEX = 0; // uint32
    uint256 private constant BURN_TOKEN_INDEX = 4; // bytes32
    uint256 private constant MINT_RECIPIENT_INDEX = 36; // bytes32
    uint256 private constant AMOUNT_INDEX = 68; // uint256
    uint256 private constant MSG_SENDER_INDEX = 100; // bytes32
    uint256 private constant MAX_FEE_INDEX = 132; // uint256
    uint256 private constant FEE_EXECUTED_INDEX = 164; // uint256
    uint256 private constant EXPIRATION_BLOCK_INDEX = 196; // uint256
    uint256 private constant HOOK_DATA_INDEX = 228;

    /// @notice Finality thresholds: Fast (confirmed) vs Standard (finalized).
    uint32 internal constant FINALITY_CONFIRMED = 1000;
    uint32 internal constant FINALITY_FINALIZED = 2000;

    struct Parsed {
        uint32 sourceDomain;
        uint32 destinationDomain;
        bytes32 nonce;
        bytes32 sender; // the TokenMessengerV2 on the source chain
        bytes32 recipient; // the TokenMessengerV2 on this chain
        bytes32 destinationCaller;
        uint32 finalityThresholdExecuted;
        bytes32 burnToken;
        bytes32 mintRecipient;
        uint256 amount;
        bytes32 messageSender; // who called depositForBurnWithHook on the source chain
        bytes hookData;
    }

    error MessageTooShort(uint256 length);

    function parse(bytes memory message) internal pure returns (Parsed memory p) {
        if (message.length < MESSAGE_BODY_INDEX + HOOK_DATA_INDEX) revert MessageTooShort(message.length);
        p.sourceDomain = uint32(_u(message, SOURCE_DOMAIN_INDEX, 4));
        p.destinationDomain = uint32(_u(message, DESTINATION_DOMAIN_INDEX, 4));
        p.nonce = bytes32(_u(message, NONCE_INDEX, 32));
        p.sender = bytes32(_u(message, SENDER_INDEX, 32));
        p.recipient = bytes32(_u(message, RECIPIENT_INDEX, 32));
        p.destinationCaller = bytes32(_u(message, DESTINATION_CALLER_INDEX, 32));
        p.finalityThresholdExecuted = uint32(_u(message, FINALITY_THRESHOLD_EXECUTED_INDEX, 4));
        uint256 b = MESSAGE_BODY_INDEX;
        p.burnToken = bytes32(_u(message, b + BURN_TOKEN_INDEX, 32));
        p.mintRecipient = bytes32(_u(message, b + MINT_RECIPIENT_INDEX, 32));
        p.amount = _u(message, b + AMOUNT_INDEX, 32);
        p.messageSender = bytes32(_u(message, b + MSG_SENDER_INDEX, 32));
        uint256 hookStart = b + HOOK_DATA_INDEX;
        bytes memory hook = new bytes(message.length - hookStart);
        for (uint256 i; i < hook.length; ++i) {
            hook[i] = message[hookStart + i];
        }
        p.hookData = hook;
    }

    /// @notice Builds a message in Circle's layout. Used by tests and by tooling that wants to
    ///         preview what a burn will look like; production messages come from the attester.
    function build(
        uint32 sourceDomain,
        uint32 destinationDomain,
        bytes32 nonce,
        bytes32 sender,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinality,
        uint32 finalityExecuted,
        bytes32 burnToken,
        bytes32 mintRecipient,
        uint256 amount,
        bytes32 messageSender,
        bytes memory hookData
    ) internal pure returns (bytes memory) {
        bytes memory body = abi.encodePacked(
            uint32(1), burnToken, mintRecipient, amount, messageSender, uint256(0), uint256(0), uint256(0), hookData
        );
        return abi.encodePacked(
            uint32(1),
            sourceDomain,
            destinationDomain,
            nonce,
            sender,
            recipient,
            destinationCaller,
            minFinality,
            finalityExecuted,
            body
        );
    }

    function toBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function toAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }

    function _u(bytes memory m, uint256 start, uint256 len) private pure returns (uint256 v) {
        for (uint256 i; i < len; ++i) {
            v = (v << 8) | uint8(m[start + i]);
        }
    }
}

/// @notice Circle's TokenMessengerV2, the entry point of a burn.
interface ITokenMessengerV2 {
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}

/// @notice Circle's MessageTransmitterV2, where an attested message is redeemed.
interface IMessageTransmitterV2 {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MessagingFee, MessagingReceipt} from "../lz/ILayerZeroEndpointV2.sol";

/// @notice The slice of the LayerZero OFT v2 ABI the float adapter uses (SendParam/OFTReceipt layout of
///         @layerzerolabs/oft-evm IOFT). Written for Solon; must be checked against the Paxos USDG OFT
///         deployments (Ethereum 0x147BdE4F…6bf9c4, RH 0x0d54755f…0628d1) before any use.
struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

interface IOFTLike {
    function send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory);

    function token() external view returns (address);
}

/// @notice Whitelisted stable conversion on Ethereum (USDC <-> USDG); pulls `amountIn` from the caller.
interface IStableConverter {
    function convert(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) external returns (uint256);
}

/// @notice LayerZero composer entry (called by the endpoint after an OFT credit with a compose message).
interface ILayerZeroComposerLike {
    function lzCompose(address from, bytes32 guid, bytes calldata message, address executor, bytes calldata extraData)
        external
        payable;
}

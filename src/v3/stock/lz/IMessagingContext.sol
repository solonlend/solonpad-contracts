// Vendored verbatim from @layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessagingContext.sol (LayerZero Labs, MIT) as embedded in the verified
// ArcStocksHubV2 Sourcify record; only import paths were flattened.
// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

interface IMessagingContext {
    function isSendingMessage() external view returns (bool);

    function getSendContext() external view returns (uint32 dstEid, address sender);
}

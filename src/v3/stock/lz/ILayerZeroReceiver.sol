// Vendored verbatim from @layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol (LayerZero Labs, MIT) as embedded in the verified
// ArcStocksHubV2 Sourcify record; only import paths were flattened.
// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import {Origin} from "./ILayerZeroEndpointV2.sol";

interface ILayerZeroReceiver {
    function allowInitializePath(Origin calldata _origin) external view returns (bool);

    function nextNonce(uint32 _eid, bytes32 _sender) external view returns (uint64);

    function lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

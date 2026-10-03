// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Immutable STOP-prefixed creation-code data. No callable methods or storage writes.
/// @dev Factory constructor alone creates both chunks from the compiled reward-token bytecode.
contract V3TokenCodeStore {
    constructor(bytes memory code, uint256 start, uint256 length) {
        require(start + length <= code.length && length <= 24000);
        bytes memory data = new bytes(length + 1);
        assembly ("memory-safe") {
            mcopy(add(data, 33), add(add(code, 32), start), length)
            return(add(data, 32), mload(data))
        }
    }
}

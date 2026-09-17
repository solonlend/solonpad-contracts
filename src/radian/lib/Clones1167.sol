// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev EIP-1167 minimal proxies with CREATE2, so a template instance's address
///      can be predicted before the launch transaction that needs it (the token's
///      creator-fee recipient is fixed at launch). Hand-rolled because the vendored
///      OpenZeppelin tree does not ship Clones.
library Clones1167 {
    error CloneFailed();

    function clone(address impl, bytes32 salt) internal returns (address inst) {
        bytes20 target = bytes20(impl);
        assembly {
            let p := mload(0x40)
            mstore(p, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(p, 0x14), target)
            mstore(add(p, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            inst := create2(0, p, 0x37, salt)
        }
        if (inst == address(0)) revert CloneFailed();
    }

    function predict(address impl, bytes32 salt, address deployer) internal pure returns (address) {
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", bytes20(impl), hex"5af43d82803e903d91602b57fd5bf3"
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, keccak256(code))))));
    }
}

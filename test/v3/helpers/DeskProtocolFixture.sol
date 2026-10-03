// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract DeskProtocolFixture {
    uint256 public revenue;
    mapping(bytes32 => bool) public receipts;

    function receiveDeskProtocol(bytes32 receipt) external payable {
        require(!receipts[receipt]);
        receipts[receipt] = true;
        revenue += msg.value;
    }
    receive() external payable {}
}

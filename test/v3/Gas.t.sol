// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract A is ERC20 {
    constructor() ERC20("S", "S") {}
}

contract GasTest is Test {
    V3RewardToken token;

    function testCarryDepositGas() public {
        vm.warp(10 days);
        token = new V3RewardToken("R", "R", address(this), address(this), new address[](0));
        A a = new A();
        token.configurePool(bytes32(uint256(1)), address(a), 1);
        token.onFeeCredit(bytes32(uint256(1)), address(a), 1, 100);
        vm.warp(block.timestamp + 5);
        uint256 g = gasleft();
        token.onFeeCredit(bytes32(uint256(1)), address(a), 1, 100);
        uint256 used = g - gasleft();
        console.log("2nd carry deposit gas (warm in-test)", used);
        assertLt(used, 50_000, "zero-weight credit must not update the carry tree");
    }
}

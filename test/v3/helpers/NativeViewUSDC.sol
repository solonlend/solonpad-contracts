// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Arc's USDC ERC-20 view at 0x3600… (6 dp) for unit tests: it has no balance of its own, it reads and moves
///         the account's NATIVE balance (18 dp). balanceOf = native / 1e12 (the sub-1e12 tail is invisible); a transfer
///         of x moves x * 1e12 native wei. This is the "same money, two decimals" property (AGENTS.md §4.6) that
///         MockUSDG / vm.deal fixtures do not model. Uses cheatcodes to move native balances, so test-only.
contract NativeViewUSDC {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SCALE = 1e12;

    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function balanceOf(address a) public view returns (uint256) {
        return a.balance / SCALE;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(balanceOf(from) >= amount, "balance");
        VM.deal(from, from.balance - amount * SCALE);
        VM.deal(to, to.balance + amount * SCALE);
        emit Transfer(from, to, amount);
    }
}

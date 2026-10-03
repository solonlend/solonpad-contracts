// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Unit-test stand-in for Arc's native USDC ERC-20 view (0x3600…0000, 6 dp): `balanceOf` / `transferFrom` read
///         and move the 18-dp NATIVE balance (amount × 1e12), like the real view does through Arc's system precompile.
///         `sticky` leaves the allowance in place (allowance-check arm); `short` moves 1e12 wei less (balance-check arm).
contract ArcUsdcViewStub {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant SCALE = 1e12;

    mapping(address => mapping(address => uint256)) public allowance;
    bool public sticky;
    bool public short;

    function setModes(bool sticky_, bool short_) external {
        (sticky, short) = (sticky_, short_);
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function balanceOf(address a) external view returns (uint256) {
        return a.balance / SCALE;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (!sticky) allowance[f][msg.sender] -= a;
        uint256 wei_ = a * SCALE - (short ? SCALE : 0);
        vm.deal(f, f.balance - wei_);
        vm.deal(t, t.balance + wei_);
        return true;
    }
}

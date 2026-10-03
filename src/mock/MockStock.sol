// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockStock
/// @notice A TESTNET STAND-IN for a tokenized stock (e.g. Ondo NVDAon on BSC, or
///         a Robinhood Stock Token). It is a plain 18-decimal ERC-20 used only to
///         demonstrate the "launch a memecoin denominated in a stock" mechanic on
///         Arc testnet, where no real tokenized stock exists. On mainnet (BSC /
///         Robinhood Chain) this is replaced by the real stock token — the
///         launchpad pairing logic is identical and needs no oracle or API.
contract MockStock {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public minter;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
        minter = msg.sender;
    }

    function mint(address to, uint256 value) external {
        require(msg.sender == minter, "only minter");
        balanceOf[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "insufficient allowance");
            allowance[from][msg.sender] = allowed - value;
        }
        return _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        require(to != address(0), "to zero");
        uint256 bal = balanceOf[from];
        require(bal >= value, "insufficient balance");
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        return true;
    }
}

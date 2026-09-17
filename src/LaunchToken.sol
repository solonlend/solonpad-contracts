// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LaunchToken
/// @notice Fixed-supply ERC20 launched through the Pons-style launchpad.
///         The entire 1B supply is minted to the bonding-curve pool at creation;
///         there is no owner, no mint function, and no way to change supply.
contract LaunchToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    string public metadataURI;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public immutable totalSupply = TOTAL_SUPPLY;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, string memory metadataURI_, address pool) {
        name = name_;
        symbol = symbol_;
        metadataURI = metadataURI_;
        balanceOf[pool] = TOTAL_SUPPLY;
        emit Transfer(address(0), pool, TOTAL_SUPPLY);
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
        require(to != address(0), "transfer to zero");
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

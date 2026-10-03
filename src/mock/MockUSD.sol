// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal dollar stand-in for testnets whose real stablecoin (USDG,
///         USDC) is not deployed there. Unrestricted mint, clearly labeled.
///         Never deploy on a mainnet.
contract MockUSD is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice r12 (review M4): does the RH ChainlinkStockSource carry a TWAP pool for `underlying`? Read from the RH
///   deployment inputs ORACLE_STOCKS / ORACLE_POOLS (DeployV3PriceSender's lists, same order; a zero pool = no TWAP).
///   Without the lists every stock is assumed to have a pool (the pre-r12 default of the Arc 150 bps TWAP check).
function rhTwapPoolListed(Vm vm, address underlying) view returns (bool) {
    address[] memory stocks = vm.envOr("ORACLE_STOCKS", ",", new address[](0));
    address[] memory pools = vm.envOr("ORACLE_POOLS", ",", new address[](0));
    if (stocks.length == 0) return true;
    require(stocks.length == pools.length, "ORACLE_STOCKS / ORACLE_POOLS lengths");
    for (uint256 i; i < stocks.length; ++i) {
        if (stocks[i] == underlying) return pools[i] != address(0);
    }
    revert("ORACLE_STOCKS does not list the stock");
}

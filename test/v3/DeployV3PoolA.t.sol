// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployV3} from "../../script/v3/DeployV3.s.sol";

contract DeployV3PoolAHarness is DeployV3 {
    function loadConfig() external {
        _loadConfig();
    }

    function poolA() external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (cfg.poolASeedUsd, cfg.poolASeedStockRaw, cfg.poolAPoolUsd, cfg.poolAStockUsd, cfg.poolAReserveUsd);
    }
}

/// @notice r9 (2026-10-01): pool A starts as $1,000 NVDA.sol + $1,000 USDC in range and $1,000 USDC kept idle
///         in the vault as the restock reserve. One test function because env vars are process-wide.
contract DeployV3PoolATest is Test {
    function test_poolAStartingStructure() public {
        vm.chainId(31337);
        vm.setEnv("LOCAL_STANDINS", "true");
        DeployV3PoolAHarness h = new DeployV3PoolAHarness();

        h.loadConfig();
        (uint256 seed, uint256 stockRaw, uint256 pool, uint256 stock, uint256 reserve) = h.poolA();
        assertEq(pool, 1000, "USDC side");
        assertEq(stock, 1000, "NVDA.sol side");
        assertEq(reserve, 1000, "idle USDC reserve");
        assertEq(stockRaw, 0);
        assertEq(seed, 3000, "stock side bought with USDC by the keeper");

        vm.setEnv("POOL_A_SEED_STOCK_RAW", "5000000000000000000"); // deployer brings NVDA.sol for the stock side
        h.loadConfig();
        (seed, stockRaw,,,) = h.poolA();
        assertEq(seed, 2000);
        assertEq(stockRaw, 5e18);

        vm.setEnv("POOL_A_FUND", "false");
        vm.expectRevert(bytes("POOL_A_SEED_STOCK_RAW needs POOL_A_FUND"));
        h.loadConfig();
        vm.setEnv("POOL_A_SEED_STOCK_RAW", "0");
        h.loadConfig();
        (seed,, pool, stock, reserve) = h.poolA();
        assertEq(seed + pool + stock + reserve, 0, "deploy only");
        vm.setEnv("POOL_A_FUND", "true");

        vm.setEnv("POOL_A_RESERVE_USD", "99000"); // above the $100k sanity bound
        vm.expectRevert(bytes("pool A seed <= 100000 (more goes through the treasury later)"));
        h.loadConfig();
        vm.setEnv("POOL_A_RESERVE_USD", "1000");

        vm.setEnv("POOL_A_STOCK_USD", "0");
        vm.expectRevert(bytes("POOL_A_POOL_USD and POOL_A_STOCK_USD > 0"));
        h.loadConfig();
        vm.setEnv("POOL_A_STOCK_USD", "1000");

        vm.setEnv("POOL_A_SEED_USD", "3000"); // r8 knob retired
        vm.expectRevert(bytes("POOL_A_SEED_USD retired: POOL_A_POOL/STOCK/RESERVE_USD"));
        h.loadConfig();
        vm.setEnv("POOL_A_SEED_USD", "0");
    }
}

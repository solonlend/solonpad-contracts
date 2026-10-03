// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {V3LzConfig} from "../V3LzConfig.sol";
import {
    TestnetMockStock,
    TestnetMockFeed,
    TestnetMockTwapPool,
    TestnetMockStockRouter,
    TestnetMockSolon,
    TestnetMockSolonFeeRouter
} from "./TestnetMocks.sol";

/// @notice TESTNET ONLY. RH side (Arbitrum Sepolia stand-in or the RH testnet): Mock NVDA/AAPL/TSLA, mock Chainlink
///   feeds (+ USDG/USD), mock TWAP pools and the mock venue router over the real Paxos USDG. Env: DEPLOYER_PRIVATE_KEY,
///   MOCK_OWNER (price operator: feeds + TWAP overrides), RH_USDG (Paxos testnet USDG, 6 dp). Prints one TESTNET_RH_MOCKS_JSON= line.
contract DeployTestnetRhMocks is Script {
    function run() external {
        require(
            block.chainid == V3LzConfig.ARB_SEPOLIA_CHAIN_ID || block.chainid == V3LzConfig.RH_TESTNET_CHAIN_ID,
            "RH-side testnets only"
        );
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("MOCK_OWNER");
        address usdg = vm.envAddress("RH_USDG");
        string[3] memory t = ["NVDA", "AAPL", "TSLA"];
        int256[3] memory px = [int256(180e8), int256(230e8), int256(250e8)];
        vm.startBroadcast(pk);
        TestnetMockStockRouter router = new TestnetMockStockRouter(IERC20(usdg), vm.addr(pk));
        TestnetMockFeed usdgFeed = new TestnetMockFeed("Mock USDG / USD (Solon testnet)", owner, 1e8);
        string memory j = "rhmocks";
        vm.serializeAddress(j, "router", address(router));
        vm.serializeAddress(j, "usdgFeed", address(usdgFeed));
        vm.serializeAddress(j, "usdg", usdg);
        string memory out;
        for (uint256 i; i < 3; ++i) {
            TestnetMockStock s = new TestnetMockStock(
                string.concat("Mock ", t[i], " (Solon testnet)"), string.concat("m", t[i]), vm.addr(pk)
            );
            s.setMinter(address(router));
            TestnetMockFeed f = new TestnetMockFeed(string.concat("Mock ", t[i], " / USD (Solon testnet)"), owner, px[i]);
            TestnetMockTwapPool p = new TestnetMockTwapPool(address(s), usdg, 6, f, owner);
            vm.serializeAddress(j, string.concat("stock_", t[i]), address(s));
            vm.serializeAddress(j, string.concat("feed_", t[i]), address(f));
            out = vm.serializeAddress(j, string.concat("pool_", t[i]), address(p));
            router.setFeed(address(s), f);
        }
        vm.stopBroadcast();
        console2.log(string.concat("TESTNET_RH_MOCKS_JSON=", out));
    }
}

/// @notice TESTNET ONLY. Arc testnet externals: a pinned Uniswap v4 PoolManager / PositionManager / PoolSwapTest from
///   lib/ (no Uniswap-endorsed Arc testnet deployment exists), Mock SOLON and the mock legacy fee router.
///   Env: DEPLOYER_PRIVATE_KEY, V4_OWNER. Prints one TESTNET_ARC_EXTERNALS_JSON= line.
contract DeployTestnetArcExternals is Script {
    function run() external {
        require(block.chainid == V3LzConfig.ARC_TESTNET_CHAIN_ID, "Arc testnet only");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);
        PoolManager pm = new PoolManager(vm.envAddress("V4_OWNER"));
        PositionManager posm = new PositionManager(
            IPoolManager(address(pm)), IAllowanceTransfer(address(0)), 100000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        PoolSwapTest swap = new PoolSwapTest(IPoolManager(address(pm)));
        TestnetMockSolon solon = new TestnetMockSolon(vm.addr(pk));
        TestnetMockSolonFeeRouter fr = new TestnetMockSolonFeeRouter();
        vm.stopBroadcast();
        string memory j = "arcext";
        vm.serializeAddress(j, "poolManager", address(pm));
        vm.serializeAddress(j, "positionManager", address(posm));
        vm.serializeAddress(j, "poolSwapTest", address(swap));
        vm.serializeAddress(j, "mockSolon", address(solon));
        string memory out = vm.serializeAddress(j, "mockSolonFeeRouter", address(fr));
        console2.log(string.concat("TESTNET_ARC_EXTERNALS_JSON=", out));
    }
}

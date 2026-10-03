// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolASwapRouter, IPoolAVault} from "../../../src/v3/stock/PoolASwapRouter.sol";

/// @notice Deploys PoolASwapRouter (stock page: pool-A single-hop buy/sell). One transaction, no owner, no wiring.
///         Env: DEPLOYER_PRIVATE_KEY (from script/v3/keys.sh key_env, never argv), POOL_MANAGER, POOL_A_VAULTS
///         (comma-separated StockPoolVault addresses; mainnet: the NVDA.sol vault from DeployV3).
///         Prints POOL_A_ROUTER=<address> and checks every listed vault's pool key is served.
contract DeployPoolASwapRouter is Script {
    function run() external returns (PoolASwapRouter r) {
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address[] memory raw = vm.envAddress("POOL_A_VAULTS", ",");
        IPoolAVault[] memory vaults = new IPoolAVault[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            vaults[i] = IPoolAVault(raw[i]);
        }
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        r = new PoolASwapRouter(manager, vaults);
        vm.stopBroadcast();
        require(address(r.manager()) == address(manager), "manager");
        address[] memory s = r.stocks();
        require(s.length == raw.length, "stocks");
        for (uint256 i; i < raw.length; ++i) {
            require(
                keccak256(abi.encode(r.poolKey(s[i]))) == keccak256(abi.encode(vaults[i].poolKey())), "pool key"
            );
        }
        console2.log("POOL_A_ROUTER=%s", address(r));
    }
}

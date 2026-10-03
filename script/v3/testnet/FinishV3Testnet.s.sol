// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {V3Governance} from "../../../src/v3/governance/V3Governance.sol";
import {SolonStockOracle} from "../../../src/v3/oracle/SolonStockOracle.sol";
import {OracleRefTickSigner} from "../../../src/v3/oracle/OracleRefTickSigner.sol";
import {StockPoolVault} from "../../../src/v3/stock/StockPoolVault.sol";
import {V3LzConfig} from "../V3LzConfig.sol";

/// @notice TESTNET ONLY (Arc testnet). Second half of a `TESTNET_KEEP_BOOTSTRAP_OPEN` DeployV3: once the first prices
///   relayed over real LayerZero reached RelayedStockSource, accept them in the oracle (permissionless poke), initialize
///   pool A at the Live oracle tick inside the bootstrap (what DeployV3 does in-script on the local devnet), then close
///   the bootstrap so only the 48h timelock remains. Env: DEPLOYER_PRIVATE_KEY (the bootstrapper), MANIFEST_JSON.
///   Prints POOL_A_INIT_TICK= for the manifest update.
contract FinishV3Testnet is Script {
    function run() external {
        require(block.chainid == V3LzConfig.ARC_TESTNET_CHAIN_ID, "Arc testnet only");
        string memory json = vm.envString("MANIFEST_JSON");
        V3Governance gov = V3Governance(payable(vm.parseJsonAddress(json, ".contracts.V3Governance")));
        SolonStockOracle oracle = SolonStockOracle(vm.parseJsonAddress(json, ".contracts.SolonStockOracle"));
        address nvda = vm.parseJsonAddress(json, ".config.rewardAsset");
        address[] memory extra = vm.parseJsonAddressArray(json, ".config.extraTokens");
        StockPoolVault v = StockPoolVault(payable(vm.parseJsonAddress(json, ".contracts.StockPoolVault")));
        require(!gov.bootstrapClosed(), "bootstrap already closed");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        require(oracle.poke(nvda) == SolonStockOracle.Status.Live, "NVDA.sol not Live (relayed price missing?)");
        for (uint256 i; i < extra.length; ++i) {
            require(oracle.poke(extra[i]) == SolonStockOracle.Status.Live, "extra stock not Live");
        }
        int24 t = OracleRefTickSigner(vm.parseJsonAddress(json, ".contracts.OracleRefTickSigner")).refTickOf(nvda);
        gov.bootstrapCall(address(v), abi.encodeCall(StockPoolVault.initialize, (TickMath.getSqrtPriceAtTick(t))));
        gov.closeBootstrap();
        vm.stopBroadcast();
        console2.log("POOL_A_INIT_TICK=", t);
    }
}

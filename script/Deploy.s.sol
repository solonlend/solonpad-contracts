// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {LaunchpadFactory} from "../src/LaunchpadFactory.sol";

/// Deploys the LaunchpadFactory to Arc.
/// TREASURY env var is optional; defaults to the deployer address.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address treasury = vm.envOr("TREASURY", deployer);

        vm.startBroadcast(pk);
        LaunchpadFactory factory = new LaunchpadFactory(treasury);
        vm.stopBroadcast();

        console.log("LaunchpadFactory:", address(factory));
        console.log("treasury:", treasury);
        console.log("owner:", deployer);
    }
}

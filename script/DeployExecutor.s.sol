// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {RadianExecutor} from "../src/radian/RadianExecutor.sol";

/// Deploys RadianExecutor (delegated buys under signed, bounded authority) and,
/// when the broadcaster owns the factory, sets the platform keeper.
///
/// Env:
///   PRIVATE_KEY   broadcaster
///   FACTORY       PonsV2LaunchFactory (default: Arc testnet)
///   KEEPER        keeper allowed to execute (default: broadcaster)
contract DeployExecutor is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        PonsV2LaunchFactory factory =
            PonsV2LaunchFactory(payable(vm.envOr("FACTORY", address(0x90022cC2107De9c070F889E3A67009FcA270E4E2))));
        address keeper = vm.envOr("KEEPER", me);
        bool isOwner = factory.owner() == me;

        vm.startBroadcast(pk);
        RadianExecutor ex = new RadianExecutor(factory);
        if (isOwner) ex.setKeeper(keeper);
        vm.stopBroadcast();

        console.log("RadianExecutor:", address(ex));
        console.log("keeper:", ex.keeper());
        console.log("FEE_BPS:", ex.FEE_BPS());
        console.log("GAS_STIPEND:", ex.GAS_STIPEND());
    }
}

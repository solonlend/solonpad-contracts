// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2MemeHook} from "../src/v2/hooks/PonsV2MemeHook.sol";
import {RadianStaking} from "../src/radian/RadianStaking.sol";
import {RadianTreasury} from "../src/radian/RadianTreasury.sol";

/// Redeploys only the flywheel (RadianStaking + RadianTreasury) for an
/// EXISTING $RADIAN token + curve — used to roll out the hardened v2 contracts
/// on testnet without relaunching the token. Wires the pair, points the hook's
/// protocol-fee recipient at the new treasury, and optionally starts the
/// two-step handover to `OWNER`.
///
/// Env:
///   PRIVATE_KEY     deployer (must own the hook to re-point the fee recipient)
///   RADIAN_TOKEN    existing $RADIAN (default: Arc testnet)
///   RADIAN_CURVE    its bonding curve (default: Arc testnet)
///   HOOK            PonsV2MemeHook (default: Arc testnet)
///   OWNER           final owner (default: deployer)
///   KEEPER          flush() caller (default: deployer)
contract DeployRadianFlywheel is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address token = vm.envOr("RADIAN_TOKEN", address(0x0B764B1e50E4D17A897Cdd9494CaC3355579fDcD));
        address curve = vm.envOr("RADIAN_CURVE", address(0x8925494f3cfB34cD0df2b4Bf83328928Fe22F126));
        PonsV2MemeHook hook = PonsV2MemeHook(payable(vm.envOr("HOOK", address(0x15eB3aeE2f96A199165dc58e6C8dc3Ce2e02e044))));
        address owner = vm.envOr("OWNER", me);
        address keeper = vm.envOr("KEEPER", me);
        address feeEscrow = address(hook.feeEscrow());

        vm.startBroadcast(pk);
        RadianStaking staking = new RadianStaking(token, me);
        RadianTreasury treasury = new RadianTreasury(token, curve, feeEscrow, me);
        treasury.setStaking(address(staking));
        treasury.setKeeper(keeper);
        staking.setRewardsDistributor(address(treasury));
        hook.setProtocolFeeRecipient(address(treasury));
        if (owner != me) {
            staking.transferOwnership(owner);
            treasury.transferOwnership(owner);
        }
        vm.stopBroadcast();

        console.log("RadianStaking v2:  ", address(staking));
        console.log("RadianTreasury v2: ", address(treasury));
        console.log("hook.protocolFeeRecipient ->", address(treasury));
        if (owner != me) console.log("NEXT: owner must call acceptOwnership() on staking and treasury:", owner);
    }
}

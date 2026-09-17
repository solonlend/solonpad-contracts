// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2MemeHook} from "../src/v2/hooks/PonsV2MemeHook.sol";
import {RadianStaking} from "../src/radian/RadianStaking.sol";
import {RadianTreasury} from "../src/radian/RadianTreasury.sol";

/// Deploys the $RADIAN flywheel against an existing Radian launchpad:
/// 1. adds a non-graduating launch config (so $RADIAN keeps its curve as the
///    buyback venue), 2. launches $RADIAN on Radian itself (dogfood), 3. deploys
///    RadianStaking + RadianTreasury and wires them, 4. points the hook's
///    protocol-fee recipient at the treasury so platform revenue flows into the
///    flywheel (the treasury pulls its escrow balance via `claimFees()`).
///
/// Env:
///   PRIVATE_KEY   deployer (must own the factory + hook)
///   FACTORY       PonsV2LaunchFactory (default: Arc testnet)
///   HOOK          PonsV2MemeHook      (default: Arc testnet)
///   OWNER         final owner of staking + treasury (default: deployer; use the multisig on mainnet)
///   KEEPER        flush() caller       (default: deployer)
///   PHANTOM_USDC  opening virtual reserve, whole USDC (default 6000)
contract DeployRadian is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        PonsV2LaunchFactory factory =
            PonsV2LaunchFactory(payable(vm.envOr("FACTORY", address(0x90022cC2107De9c070F889E3A67009FcA270E4E2))));
        PonsV2MemeHook hook = PonsV2MemeHook(payable(vm.envOr("HOOK", address(0x15eB3aeE2f96A199165dc58e6C8dc3Ce2e02e044))));
        address owner = vm.envOr("OWNER", me);
        address keeper = vm.envOr("KEEPER", me);
        uint256 phantom = vm.envOr("PHANTOM_USDC", uint256(6_000)) * 1e18;
        uint256 launchFee = factory.launchFee(); // never hardcode: the owner can change it
        address feeEscrow = address(hook.feeEscrow());

        vm.startBroadcast(pk);

        // Non-graduating config for the protocol token (huge graduation threshold).
        uint256 configId = factory.addLaunchConfig(
            PonsV2LaunchFactory.LaunchConfig({
                supply: 1_000_000_000e18,
                curveFeeBps: 100,
                phantomQuote: phantom,
                graduationThreshold: 1_000_000e18, // effectively never graduates
                poolFee: 0,
                tickSpacing: 200,
                enabled: true
            })
        );

        (address token, address curve) = factory.launchToken{value: launchFee}(
            PonsV2LaunchFactory.TokenParams({
                name: "Radian",
                symbol: "RADIAN",
                logo: "",
                description: "The Radian protocol token. Stake it to earn a share of every fee the platform collects, in USDC. Fees also buy it back and burn it. Launched fair on Radian's own launchpad.",
                socials: PonsV2LauncherToken.Socials("", "", "", "", ""),
                creatorFeeRecipient: me,
                creatorTaxBps: 0,
                buybackEnabled: true,
                expectedEconomics: bytes32(0),
                salt: bytes32(uint256(0x2AD1A4))
            }),
            configId,
            address(0)
        );

        // Deploy with the deployer as owner so the wiring calls below succeed,
        // then hand over (two-step: `owner` must call acceptOwnership on both).
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

        console.log("RADIAN token:   ", token);
        console.log("RADIAN curve:   ", curve);
        console.log("RadianStaking:  ", address(staking));
        console.log("RadianTreasury: ", address(treasury));
        console.log("fee escrow:     ", feeEscrow);
        console.log("configId:       ", configId);
        if (owner != me) console.log("NEXT: owner must call acceptOwnership() on staking and treasury:", owner);
    }
}

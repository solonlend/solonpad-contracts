// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {MockStock} from "../src/mock/MockStock.sol";

/// @notice Launches The Wall ($WALL) — Radian's flagship product — on the
/// existing launchpad. Phase 1: no new contracts. The token is denominated in
/// NVDA shares (NVDAx stand-in on testnet) and launched in Buyback & Lock mode,
/// so the buyback share of every trade fee buys $WALL back and locks it in the
/// platform's 5-year vault: the wall is being built from day one. Phase 2 adds
/// the NVDA-hoarding treasury + floor-price buy wall (see the product repo).
///
/// Env: PRIVATE_KEY (deployer; must hold NVDAx for the opening buy).
///      WALL_LOGO (optional): logo URL to store on-chain.
contract LaunchWall is Script {
    address constant FACTORY = 0x90022cC2107De9c070F889E3A67009FcA270E4E2;
    address constant NVDAX = 0xDebcC47bf6e1DEFE1eC76290441836E4981dA882;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory logo = vm.envOr("WALL_LOGO", string(""));
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(FACTORY));

        vm.startBroadcast(pk);
        (address token, address curve) = factory.launchToken{value: 1e18}(
            PonsV2LaunchFactory.TokenParams({
                name: "The Wall",
                symbol: "WALL",
                logo: logo,
                // Immutable on-chain. Every clause must match the contracts:
                // the vault is a 5-year linear VEST, the buyback runs when the
                // platform sweeps fees, and the treasury is Phase 2 (not live).
                description: "The Wall ($WALL) is Radian's flagship product, priced in NVDA shares (NVDAx, a testnet stand-in). "
                    "Launched in Buyback & Lock mode: the buyback share of trade fees buys $WALL back into a 5-year vesting vault "
                    "when the platform sweeps fees. Phase 2 - a treasury that accumulates NVDA and defends a floor price - is in design, not live.",
                socials: PonsV2LauncherToken.Socials("", "", "", "", ""),
                creatorFeeRecipient: me, // placeholder for the Phase 2 treasury
                creatorTaxBps: 0,
                buybackEnabled: true,
                expectedEconomics: bytes32(0),
                salt: bytes32(uint256(0x0A12)) // v2: relaunch with the corrected description
            }),
            0,
            NVDAX
        );

        // Opening buy: 10 NVDAx (20% of the 50-share graduation goal).
        MockStock(NVDAX).approve(curve, type(uint256).max);
        PonsV2BondingCurve(payable(curve)).buy(10e18, 0, me);
        vm.stopBroadcast();

        console.log("WALL token:", token);
        console.log("WALL curve:", curve);
    }
}

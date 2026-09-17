// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";

/// Seeds REAL launches on the live Arc testnet factory at varied bonding
/// progress, so Explore / Stats / Live / Portfolio run on genuine on-chain
/// data (no mocks). The broadcaster is the creator of each launch (snipe-tax
/// exempt), so its follow-on buy settles untaxed in the same run.
contract SeedLaunches is Script {
    address constant FACTORY = 0x90022cC2107De9c070F889E3A67009FcA270E4E2;

    struct Seed {
        string name;
        string symbol;
        string description;
        uint256 buyUsdc; // 18-dec native USDC to buy after launch
        uint256 saltNonce;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(FACTORY));

        Seed[5] memory seeds = [
            Seed("Circle Cat", "CCAT", "The first cat on Circle's Arc chain. Priced in real dollars.", 3e18, 0xCA7),
            Seed("Arc Angel", "AANGEL", "Guardian of the arc. Almost graduated.", 8e18, 0xA9E1),
            Seed("Dollar Dog", "DDOG", "Good boy. Fetches USDC.", 1e18, 0xD06),
            Seed("Stable Shiba", "SSHIB", "Much stable. Very dollar. On Arc.", 5e18, 0x5417),
            Seed("Green Candle", "GCNDL", "Only goes up (not financial advice).", 4e17, 0x6CD1)
        ];

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < seeds.length; i++) {
            Seed memory s = seeds[i];
            (address token, address curve) = factory.launchToken{value: 1e18}(
                PonsV2LaunchFactory.TokenParams({
                    name: s.name,
                    symbol: s.symbol,
                    logo: "",
                    description: s.description,
                    socials: PonsV2LauncherToken.Socials("", "", "", "", ""),
                    creatorFeeRecipient: me,
                    creatorTaxBps: 0,
                    buybackEnabled: true,
                    expectedEconomics: bytes32(0),
                    salt: bytes32(s.saltNonce)
                }),
                0,
                address(0)
            );
            PonsV2BondingCurve(curve).buy{value: s.buyUsdc}(s.buyUsdc, 0, me);
            console.log(s.symbol, "token", token);
            console.log(s.symbol, "curve", curve);
        }
        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";

/// Launches one EURC-paired token (no dev buy → only the 1 USDC launch fee),
/// proving single-asset pairing against an approved ERC-20 works end-to-end.
contract LaunchEurc is Script {
    address constant FACTORY = 0x90022cC2107De9c070F889E3A67009FcA270E4E2;
    address constant EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        (address token, address curve) = PonsV2LaunchFactory(payable(FACTORY)).launchToken{value: 1e18}(
            PonsV2LaunchFactory.TokenParams({
                name: "Euro Doge",
                symbol: "EDOGE",
                logo: "",
                description: "The first EURC-paired token on Radian.",
                socials: PonsV2LauncherToken.Socials("", "", "", "", ""),
                creatorFeeRecipient: me,
                creatorTaxBps: 0,
                buybackEnabled: true,
                expectedEconomics: bytes32(0),
                salt: bytes32(uint256(0xEED0))
            }),
            0,
            EURC
        );
        vm.stopBroadcast();
        console.log("EDOGE token", token);
        console.log("EDOGE curve", curve);
    }
}

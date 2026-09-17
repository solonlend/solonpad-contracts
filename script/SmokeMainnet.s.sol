// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2FeeEscrow} from "../src/v2/PonsV2FeeEscrow.sol";

/// Minimal mainnet smoke: enable → launch → curve buy 1 USDC → sell half →
/// sweep fees → assert protocol fees landed in the escrow. Graduation is NOT
/// exercised here (covered by 81 tests + fork rehearsal); it needs 10k USDC.
contract SmokeMainnet is Script {
    address constant FACTORY = 0xd6b86b9B1bB64b941b21AaA6a0e3A673e8405A3b;
    address constant ESCROW = 0x83922922776C121671072C9349D8Cc1867D4856f;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(FACTORY));

        vm.startBroadcast(pk);
        if (!factory.launchEnabled()) factory.setLaunchEnabled(true);

        (address token, address curve) = factory.launchToken{value: 1e18}(
            PonsV2LaunchFactory.TokenParams({
                name: "Solon Smoke",
                symbol: "SMOKE",
                logo: "",
                description: "mainnet smoke test",
                socials: PonsV2LauncherToken.Socials("", "", "", "", ""),
                creatorFeeRecipient: me,
                creatorTaxBps: 0,
                buybackEnabled: true,
                expectedEconomics: bytes32(0),
                salt: bytes32(uint256(0x50E))
            }),
            0,
            address(0)
        );
        PonsV2BondingCurve c = PonsV2BondingCurve(payable(curve));

        uint256 got = c.buy{value: 1e18}(1e18, 0, me);
        console.log("bought tokens:", got);

        PonsV2LauncherToken(token).approve(curve, got / 2);
        uint256 back = c.sell(got / 2, 0, me);
        console.log("sold half, got back USDC wei:", back);

        c.sweepFees(1);
        vm.stopBroadcast();

        uint256 escrowBal = ESCROW.balance;
        console.log("escrow native balance:", escrowBal);
        console.log("token:", token);
        console.log("curve:", curve);
        require(escrowBal > 0, "no fees in escrow");
        console.log("SMOKE OK");
    }
}

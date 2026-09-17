// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Launches the stock-section flagships on Arc mainnet: CMAXI (priced in
/// CRCL) and TMAXI (priced in TSLA), each seeded with the launcher's full
/// stock-token balance as a first buy. Env: PRIVATE_KEY.
contract LaunchStockFlagships is Script {
    address constant FACTORY = 0xd6b86b9B1bB64b941b21AaA6a0e3A673e8405A3b;
    address constant CRCL = 0x2ba0f44BDfC17FbA30edA9cdBeCB908cA45B043B;
    address constant TSLA = 0x4d1Efa7f5629f89FBDd7950b5eF73403A350Ad59;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);
        _launch(
            me,
            CRCL,
            "Circle Maxi",
            "CMAXI",
            "/uploads/b09960e41e012628519dc36e28be4ad12d2fe8fd7824097709c211efcb82fedf.png",
            "Priced in CRCL shares, not dollars. On Circle's own chain, you stack the house's stock. First stock-denominated meme on Arc.",
            0xCA11
        );
        _launch(
            me,
            TSLA,
            "Tesla Maxi",
            "TMAXI",
            "/uploads/d2bbc325c0abb4d54a0a41b9622d5ca4d99441d22d3b42fe972f76975bbd06df.png",
            "A meme that trades in TSLA shares. Every buy is measured in Tesla stock. Buy the dip, buy the meme.",
            0xCA12
        );
        vm.stopBroadcast();
    }

    function _launch(
        address me,
        address stock,
        string memory name,
        string memory symbol,
        string memory logo,
        string memory description,
        uint256 salt
    ) internal {
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(FACTORY));
        (address token, address curveAddr) = factory.launchToken{value: 1e18}(
            PonsV2LaunchFactory.TokenParams({
                name: name,
                symbol: symbol,
                logo: logo,
                description: description,
                socials: PonsV2LauncherToken.Socials("https://solonpad.fun", "", "https://x.com/Solonlabs1", "", ""),
                creatorFeeRecipient: me,
                creatorTaxBps: 0,
                buybackEnabled: true,
                expectedEconomics: bytes32(0),
                salt: bytes32(salt)
            }),
            0,
            stock
        );
        uint256 bal = IERC20(stock).balanceOf(me);
        require(bal > 0, "no stock inventory for first buy");
        IERC20(stock).approve(curveAddr, bal);
        PonsV2BondingCurve(payable(curveAddr)).buy(bal, 0, me);
        console.log("== %s", symbol);
        console.log("  token:", token);
        console.log("  curve:", curveAddr);
        console.log("  first buy (shares 1e18):", bal);
        console.log("  minted:", IERC20(token).balanceOf(me));
    }
}

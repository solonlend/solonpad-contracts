// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// FORK-ONLY rehearsal for the stock section: launches a meme priced in CRCL
/// and one priced in TSLA, then exercises the ERC20 buy/sell path on each
/// curve. Run against an anvil fork after OpenStockSection has configured the
/// pair tokens. Env: PRIVATE_KEY (a wallet holding CRCL+TSLA on the fork).
contract RehearseStockLaunch is Script {
    address constant FACTORY = 0xd6b86b9B1bB64b941b21AaA6a0e3A673e8405A3b;
    address constant CRCL = 0x2ba0f44BDfC17FbA30edA9cdBeCB908cA45B043B;
    address constant TSLA = 0x4d1Efa7f5629f89FBDd7950b5eF73403A350Ad59;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);
        _exercise(me, CRCL, "Circle Maxi Rehearsal", "CMAXR", 0xC1, 2e18);
        _exercise(me, TSLA, "Tesla Rehearsal", "TSLR", 0xC2, 5e17);
        vm.stopBroadcast();
    }

    function _exercise(
        address me,
        address stock,
        string memory name,
        string memory symbol,
        uint256 salt,
        uint256 buyAmount
    ) internal {
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(FACTORY));
        (address token, address curveAddr) = factory.launchToken{value: 1e18}(
            PonsV2LaunchFactory.TokenParams({
                name: name,
                symbol: symbol,
                logo: "",
                description: "fork rehearsal only",
                socials: PonsV2LauncherToken.Socials("", "", "", "", ""),
                creatorFeeRecipient: me,
                creatorTaxBps: 0,
                buybackEnabled: true,
                expectedEconomics: bytes32(0),
                salt: bytes32(salt)
            }),
            0,
            stock
        );
        PonsV2BondingCurve curve = PonsV2BondingCurve(payable(curveAddr));

        IERC20(stock).approve(curveAddr, type(uint256).max);
        curve.buy(buyAmount, 0, me);
        uint256 got = IERC20(token).balanceOf(me);
        require(got > 0, "buy minted nothing");

        IERC20(token).approve(curveAddr, type(uint256).max);
        uint256 stockBefore = IERC20(stock).balanceOf(me);
        curve.sell(got / 2, 0, me);
        uint256 refund = IERC20(stock).balanceOf(me) - stockBefore;
        require(refund > 0, "sell returned nothing");

        console.log("== %s (%s-priced)", symbol, IERC20Metadata(stock).symbol());
        console.log("  token/curve:", token, curveAddr);
        console.log("  spent (shares, 1e18):", buyAmount);
        console.log("  minted meme:", got);
        console.log("  sell-half refund (shares, 1e18):", refund);
    }
}

interface IERC20Metadata {
    function symbol() external view returns (string memory);
}

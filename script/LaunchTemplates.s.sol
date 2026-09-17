// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {RadianLaunchRouter} from "../src/radian/RadianLaunchRouter.sol";
import {WallTreasury} from "../src/radian/wall/WallTreasury.sol";
import {PoFVault} from "../src/radian/pof/PoFVault.sol";
import {MockStock} from "../src/mock/MockStock.sol";

/// Launches one showcase instance of each template on Arc testnet so the site,
/// the indexer and the keeper have real contracts to run against. Clearly
/// labeled as showcases in their immutable on-chain descriptions.
contract LaunchTemplates is Script {
    address[] noExempt;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        RadianLaunchRouter router =
            RadianLaunchRouter(payable(vm.envOr("ROUTER", address(0xB9F097662302F220989AAeBa6776041d7d625fAE))));
        MockStock nvda = MockStock(vm.envOr("NVDAX", address(0xDebcC47bf6e1DEFE1eC76290441836E4981dA882)));
        uint256 fee = router.factory().launchFee();

        vm.startBroadcast(pk);
        // 1) Stock treasury (The Wall template), quoted in NVDAx, 2 NVDAx opening buy
        nvda.mint(me, 2e18);
        nvda.approve(address(router), 2e18);
        WallTreasury.Config memory wcfg = WallTreasury.Config({
            marginBps: 500, epochBudgetBps: 1000, streamBps: 3000, maxSlippageBps: 500, minInterval: 3600, keeperBounty: 0.01e18
        });
        (address wt, address wc, address wtr, address wst) = router.launchWall{value: fee}(
            PonsV2LaunchFactory.TokenParams({
                name: "Stock Treasury Showcase",
                symbol: "STSHOW",
                logo: "",
                description: "Template showcase launched by the Radian team on Arc testnet: a Stock Treasury (The Wall) launch quoted in NVDAx, a clearly labeled testnet stand-in. Creator fees build an NVDAx pile that is never sold; 30% of every claim streams to stakers, the rest keeps a standing bid under book value on the curve. Not a real project.",
                socials: PonsV2LauncherToken.Socials("", "", "", "https://github.com/adrianhihi/radian-wall", ""),
                creatorFeeRecipient: me,
                creatorTaxBps: 0,
                buybackEnabled: false,
                expectedEconomics: bytes32(0),
                salt: bytes32(uint256(0xA21))
            }),
            0,
            address(nvda),
            2e18,
            0,
            noExempt,
            wcfg
        );
        // 2) Proof-of-Fee, quoted in native USDC, 1 USDC opening buy
        PoFVault.Config memory pcfg = PoFVault.Config({targetWork: 5e18, roundSeconds: 600, minInterval: 600, maxBuybackReserveBps: 500});
        (address pt, address pc, address pv) = router.launchPoF{value: fee + 1e18}(
            PonsV2LaunchFactory.TokenParams({
                name: "Proof-of-Fee Showcase",
                symbol: "PFSHOW",
                logo: "",
                description: "Template showcase launched by the Radian team on Arc testnet: a Proof-of-Fee launch. The creator-fee share buys the token back on its own curve, and every 10-minute round the buybacks are paid out to the traders whose fees funded them, by share of USDC spent through the official router. Nothing is minted. Not a real project.",
                socials: PonsV2LauncherToken.Socials("", "", "", "", ""),
                creatorFeeRecipient: me,
                creatorTaxBps: 0,
                buybackEnabled: false,
                expectedEconomics: bytes32(0),
                salt: bytes32(uint256(0xA22))
            }),
            0,
            address(0),
            1e18,
            0,
            noExempt,
            pcfg
        );
        vm.stopBroadcast();

        console.log("WALL token:", wt);
        console.log("WALL curve:", wc);
        console.log("WALL treasury:", wtr);
        console.log("WALL staking:", wst);
        console.log("POF token:", pt);
        console.log("POF curve:", pc);
        console.log("POF vault:", pv);
    }
}

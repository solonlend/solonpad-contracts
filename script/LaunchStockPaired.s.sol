// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {MockStock} from "../src/mock/MockStock.sol";

/// @notice The "penny-stock + pump.fun" demo, safe-real version on Arc testnet.
///
/// There is no real tokenized stock on Arc, so we deploy clearly-labeled TESTNET
/// STAND-IN stock ERC-20s (NVDAx / TSLAx, 18-dec) and approve them as pair
/// assets — exactly the mechanic BSP/PONS/PAIR/Stratton use with real stock
/// tokens on Robinhood Chain / BSC. The launchpad needs NO oracle and NO API:
/// a meme launched here is *denominated in the stock token*, and the curve's
/// own trading price IS the price. (The frontend shows a real NVDA/TSLA dollar
/// price from Pyth Hermes purely as a human reference — it never touches the
/// contract.) On mainnet the stand-in is swapped for the real stock token and
/// this same script runs unchanged.
///
/// Env: PRIVATE_KEY (must own the factory on testnet).
contract LaunchStockPaired is Script {
    address constant FACTORY = 0x90022cC2107De9c070F889E3A67009FcA270E4E2;

    // Curve shape denominated in the STOCK token, not dollars. A meme opens with
    // a 20-share phantom reserve and graduates once 50 real shares are in the
    // curve — the "priced in shares" analogue of our 4000/10000 USDC shape.
    uint256 constant PHANTOM_SHARES = 20e18;
    uint256 constant GRAD_SHARES = 50e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(FACTORY));

        vm.startBroadcast(pk);

        // 1. Deploy the clearly-labeled stand-in stock tokens and mint inventory.
        MockStock nvda = new MockStock("Nvidia (Radian testnet stand-in)", "NVDAx");
        MockStock tsla = new MockStock("Tesla (Radian testnet stand-in)", "TSLAx");
        nvda.mint(me, 1_000e18);
        tsla.mint(me, 1_000e18);
        console.log("NVDAx (stand-in):", address(nvda));
        console.log("TSLAx (stand-in):", address(tsla));

        // 2. Approve both as pair assets (economics denominated in the token).
        _approveStock(factory, address(nvda));
        _approveStock(factory, address(tsla));

        // 3. Launch a meme denominated in NVDAx and one in TSLAx.
        address rktnCurve = _launch(
            factory, me, address(nvda), "Rocket Nvidia", "RKTN", 0x00A1,
            "The first stock-denominated meme on Radian. Priced in NVDA shares, not dollars."
        );
        address tslmCurve = _launch(
            factory, me, address(tsla), "Tesla To The Moon", "TSLM", 0x00A2,
            "A meme that trades in TSLA shares. Buy the dip, buy the meme."
        );

        // 4. Seed each curve with a real buy so it opens with live state.
        //    A pair-token buy pulls the stock token via transferFrom → approve first.
        nvda.approve(rktnCurve, type(uint256).max);
        PonsV2BondingCurve(payable(rktnCurve)).buy(5e18, 0, me); // spend 5 NVDAx
        tsla.approve(tslmCurve, type(uint256).max);
        PonsV2BondingCurve(payable(tslmCurve)).buy(4e18, 0, me); // spend 4 TSLAx

        vm.stopBroadcast();

        console.log("RKTN curve:", rktnCurve);
        console.log("TSLM curve:", tslmCurve);
        console.log("Seeded RKTN with 5 NVDAx, TSLM with 4 TSLAx.");
    }

    function _approveStock(PonsV2LaunchFactory factory, address stock) internal {
        factory.setPairTokenEconomics(stock, PHANTOM_SHARES, GRAD_SHARES, 18);
        factory.setPairTokenApproved(stock, true);
    }

    function _launch(
        PonsV2LaunchFactory factory,
        address me,
        address stock,
        string memory name,
        string memory symbol,
        uint256 salt,
        string memory description
    ) internal returns (address curve) {
        (, curve) = factory.launchToken{value: 1e18}(
            PonsV2LaunchFactory.TokenParams({
                name: name,
                symbol: symbol,
                logo: "",
                description: description,
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
    }
}

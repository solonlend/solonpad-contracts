// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {MockStock} from "../src/mock/MockStock.sol";

/// @notice Expands the curated menu of pairable stocks. Deploys clearly-labeled
/// testnet stand-ins for a set of well-known tickers and approves each as a pair
/// asset, so the launch UI can offer users a real choice of "which stock do you
/// want to denominate your meme in." NVDA/TSLA are deployed separately by
/// LaunchStockPaired; this adds the rest.
///
/// On mainnet the same curation happens against REAL tokenized stocks (Ondo's
/// ~263 on BSC, or Robinhood stock tokens) — the owner approves the ones to
/// feature; users pick from the approved menu. Approval stays owner-gated on
/// purpose: a pair token with a transfer hook could brick a graduated pool.
///
/// Env: PRIVATE_KEY (must own the factory on testnet).
contract AddStockStandIns is Script {
    address constant FACTORY = 0x90022cC2107De9c070F889E3A67009FcA270E4E2;
    uint256 constant PHANTOM_SHARES = 20e18;
    uint256 constant GRAD_SHARES = 50e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(FACTORY));

        string[6] memory names = [
            "Apple (Radian testnet stand-in)",
            "Alphabet (Radian testnet stand-in)",
            "Microsoft (Radian testnet stand-in)",
            "Amazon (Radian testnet stand-in)",
            "Meta (Radian testnet stand-in)",
            "S&P 500 ETF (Radian testnet stand-in)"
        ];
        string[6] memory symbols = ["AAPLx", "GOOGLx", "MSFTx", "AMZNx", "METAx", "SPYx"];

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < names.length; i++) {
            MockStock s = new MockStock(names[i], symbols[i]);
            s.mint(me, 1_000e18);
            factory.setPairTokenEconomics(address(s), PHANTOM_SHARES, GRAD_SHARES, 18);
            factory.setPairTokenApproved(address(s), true);
            console.log(symbols[i], address(s));
        }
        vm.stopBroadcast();
    }
}

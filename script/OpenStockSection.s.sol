// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";

/// Opens the stock section on Arc mainnet: approves CRCL and TSLA (Circle's
/// "• Arc Token" tokenized stocks) as pair assets, so memes can launch priced
/// in shares instead of USDC. Economics mirror the 4000/10000 USDC curve shape
/// at current share prices (CRCL ~$81, TSLA ~$328):
///   CRCL: phantom 50 shares (~$4,050), graduation 125 shares (~$10,125)
///   TSLA: phantom 12 shares (~$3,932), graduation 30 shares  (~$9,829)
/// Env: PRIVATE_KEY (factory owner).
contract OpenStockSection is Script {
    address constant FACTORY = 0xd6b86b9B1bB64b941b21AaA6a0e3A673e8405A3b;
    address constant CRCL = 0x2ba0f44BDfC17FbA30edA9cdBeCB908cA45B043B;
    address constant TSLA = 0x4d1Efa7f5629f89FBDd7950b5eF73403A350Ad59;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(FACTORY));

        vm.startBroadcast(pk);
        factory.setPairTokenEconomics(CRCL, 50e18, 125e18, 18);
        factory.setPairTokenApproved(CRCL, true);
        factory.setPairTokenEconomics(TSLA, 12e18, 30e18, 18);
        factory.setPairTokenApproved(TSLA, true);
        vm.stopBroadcast();

        console.log("CRCL approved:", factory.approvedPairTokens(CRCL));
        console.log("TSLA approved:", factory.approvedPairTokens(TSLA));
    }
}

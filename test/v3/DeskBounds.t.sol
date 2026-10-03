// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {BuybackToken} from "./Buyback.t.sol";
import {BurnSink} from "../../src/v3/BurnSink.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {ProtocolVault} from "../../src/v3/ProtocolVault.sol";

contract DeskBoundsTest is Test {
    function makeDesk(uint256 solPrice, uint256 usdcPrice)
        internal
        returns (DeskNFT nft, BuybackToken solon, BurnSink sink, ProtocolVault protocol)
    {
        solon = new BuybackToken();
        sink = new BurnSink();
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        DeskRewards rewards = new DeskRewards(ledger, address(this));
        protocol = new ProtocolVault(address(this), address(11), address(12), address(ledger));
        nft = new DeskNFT(
            address(this),
            address(solon),
            address(sink),
            address(rewards),
            address(protocol),
            address(0),
            DeskNFT.Quote(solPrice, usdcPrice, vm.getBlockTimestamp(), 1, keccak256("normalized-public-feed"))
        );
        rewards.configureNFT(nft);
        protocol.configureSources(address(13), address(nft));
    }

    function testGlobalFiveThousandCapLocksExactFiveHundredMillion() public {
        (DeskNFT nft, BuybackToken solon, BurnSink sink,) = makeDesk(2 ether, 1 ether);
        solon.mint(address(this), 600000000 ether);
        solon.approve(address(nft), type(uint256).max);
        vm.deal(address(this), 6000 ether);
        // r9: 50 cards per address at most, so the 5000 go to 125 recipients (40 each)
        for (uint256 i; i < 250; ++i) {
            nft.mint{value: 20 ether}(20, address(uint160(0xCAFE0000 + i / 2)));
        }
        assertEq(nft.totalSupply(), 5000);
        assertEq(solon.balanceOf(address(sink)), 500000000 ether);
        assertEq(solon.totalSupply(), 600000000 ether);
        vm.expectRevert(bytes("mint capacity"));
        nft.mint{value: 1 ether}(1, address(0xCAFE));
    }

    function testSurchargeNormalizesUsdcQuoteAndNeverDriftsAfterActivation() public {
        (DeskNFT nft, BuybackToken solon,, ProtocolVault protocol) = makeDesk(150 ether, 0.99 ether);
        uint256 fee = (uint256(150 ether) * 1e18 / uint256(0.99 ether)) / 2;
        assertEq(nft.surchargeUSDC18(), fee);
        solon.mint(address(this), 100000 ether);
        solon.approve(address(nft), 100000 ether);
        vm.deal(address(this), fee);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        nft.mint{value: fee}(1, address(0xCAFE));
        assertEq(nft.surchargeUSDC18(), fee);
        assertEq(protocol.deskRevenue(), fee / 10);
    }
}

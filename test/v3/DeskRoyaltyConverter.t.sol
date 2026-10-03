// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {DeskRoyaltyConverter} from "../../src/v3/DeskRoyaltyConverter.sol";
import {V2FeeConverter} from "../../src/v3/V2FeeConverter.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {LedgerStock} from "./V3FeeLedger.t.sol";
import {DeskProtocolFixture} from "./helpers/DeskProtocolFixture.sol";

contract RoyaltySellFixture {
    address public immutable asset;
    uint256 public output = 10 ether;
    bool public lie;

    constructor(address a) {
        asset = a;
    }

    function feePpm() external pure returns (uint24) {
        return 10000;
    }

    function path() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function setLie(bool x) external {
        lie = x;
    }

    function sell(address token, uint256 raw, uint256, address recipient, bytes32) external payable returns (uint256) {
        require(token == asset);
        LedgerStock(token).transferFrom(msg.sender, address(this), raw);
        if (!lie) {
            (bool ok,) = recipient.call{value: output}("");
            require(ok);
        }
        return output;
    }
    receive() external payable {}
}

contract DeskRoyaltyConverterTest is Test {
    LedgerStock raw;
    DeskRewards rewards;
    DeskNFT nft;
    DeskRoyaltyConverter escrow;
    RoyaltySellFixture route;
    LedgerStock solon;

    function setUp() public {
        vm.warp(10 days);
        vm.deal(address(this), 100 ether);
        raw = new LedgerStock();
        solon = new LedgerStock();
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        rewards = new DeskRewards(ledger, address(this));
        nft = new DeskNFT(
            address(this),
            address(solon),
            address(0xdead),
            address(rewards),
            address(new DeskProtocolFixture()),
            address(0),
            DeskNFT.Quote(2e18, 1e18, vm.getBlockTimestamp(), 1, keccak256("quote"))
        );
        rewards.configureNFT(nft);
        solon.mint(address(this), 300000 ether);
        solon.approve(address(nft), type(uint256).max);
        nft.mint{value: 1 ether}(1, address(0xA));
        route = new RoyaltySellFixture(address(raw));
        vm.deal(address(route), 100 ether);
        escrow = new DeskRoyaltyConverter(
            address(rewards), address(raw), address(route), vm.addr(42), address(0xFEE), bytes32(uint256(1)), 1
        );
        raw.mint(address(this), 100 ether);
        raw.approve(address(escrow), type(uint256).max);
    }

    function quote(bytes32 id, uint256 rawAmount, uint256 nonce_) internal view returns (bytes memory) {
        V2FeeConverter c = escrow.converter();
        V2FeeConverter.Quote memory q = V2FeeConverter.Quote(
            id,
            address(raw),
            rawAmount,
            9.9 ether,
            10 ether,
            vm.getBlockTimestamp(),
            vm.getBlockTimestamp() + 60,
            nonce_,
            0
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(42, c.quoteDigest(q));
        return abi.encode(q, abi.encodePacked(r, s, v));
    }

    function testOtherCurrencyRoyaltyCreditsOnlyActualConversionTimeCards() public {
        bytes32 id = escrow.deposit(20 ether);
        nft.mint{value: 1 ether}(1, address(0xB));
        bytes32 key = rewards.streamKey(rewards.ROYALTY(), vm.getBlockTimestamp() / 1 days, address(0), 0);
        assertEq(rewards.credit27(1, key), 0);
        bytes memory data = quote(escrow.nextConversionId(id), 10 ether, 1);
        assertEq(escrow.convert(id, 10 ether, data), 10 ether);
        assertEq(escrow.pending(id), 10 ether);
        assertEq(rewards.credit27(1, key), 5e45);
        assertEq(rewards.credit27(2, key), 5e45);
        vm.expectRevert();
        escrow.convert(id, 10 ether, data);
        escrow.convert(id, 10 ether, quote(escrow.nextConversionId(id), 10 ether, 2));
        assertEq(escrow.pending(id), 0);
        assertEq(rewards.credit27(2, key), 10e45);
    }

    function testRevertedRoyaltyConversionKeepsRawAndCannotUseDonationAsReceipt() public {
        bytes32 id = escrow.deposit(10 ether);
        vm.deal(address(escrow), 10 ether);
        route.setLie(true);
        bytes memory data = quote(escrow.nextConversionId(id), 10 ether, 1);
        vm.expectCall(address(route), abi.encodeWithSelector(RoyaltySellFixture.sell.selector));
        vm.expectRevert();
        escrow.convert(id, 10 ether, data);
        assertEq(escrow.pending(id), 10 ether);
        assertEq(raw.balanceOf(address(escrow)), 10 ether);
        assertEq(address(escrow).balance, 10 ether);
    }
}

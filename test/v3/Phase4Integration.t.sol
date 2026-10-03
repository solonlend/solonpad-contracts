// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {BuybackToken, BuybackRouteFixture} from "./Buyback.t.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {BurnSink} from "../../src/v3/BurnSink.sol";
import {BuybackBurnExecutor} from "../../src/v3/BuybackBurnExecutor.sol";
import {ProtocolVault} from "../../src/v3/ProtocolVault.sol";
import {OpsVault} from "../../src/v3/OpsVault.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {ProtocolDeskVault} from "../../src/v3/ProtocolDeskVault.sol";
import {SolonStakingV2} from "../../src/v3/SolonStakingV2.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";

contract Phase4Receiver {
    function onFeeCredit(bytes32, address, uint8, uint256) external {}
}

contract Phase4IntegrationTest is Test {
    // Fixture contracts live in storage (not locals) only to keep `forge coverage --ir-minimum` within the stack limit.
    BuybackToken solon;
    BuybackToken stock;
    BurnSink sink;
    V3FeeLedger ledger;
    DeskRewards rewards;
    ProtocolVault protocol;
    OpsVault ops;
    DeskNFT nft;
    BuybackRouteFixture route;
    ProtocolDeskVault cards;
    BuybackBurnExecutor buyer;
    EligibilityController controller;
    SolonStakingV2 staking;

    function testBuybackProtocolDeskUsesRealOpsAndMirrorsFeeTimeStaker() public {
        vm.warp(10 days);
        vm.deal(address(this), 1000 ether);
        solon = new BuybackToken();
        stock = new BuybackToken();
        sink = new BurnSink();
        ledger = new V3FeeLedger(address(this), address(0));
        rewards = new DeskRewards(ledger, address(this));
        address predictedOps = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        protocol = new ProtocolVault(address(this), address(0xABCD), predictedOps, address(ledger));
        ops = new OpsVault(address(this), address(protocol), vm.addr(99));
        assertEq(address(ops), predictedOps);
        nft = new DeskNFT(
            address(this),
            address(solon),
            address(sink),
            address(rewards),
            address(protocol),
            address(0),
            DeskNFT.Quote(2 ether, 1 ether, vm.getBlockTimestamp(), 1, keccak256("public-price"))
        );
        rewards.configureNFT(nft);
        protocol.configureSources(address(99), address(nft));
        route = new BuybackRouteFixture(solon);
        address predictedBuyer = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        cards = new ProtocolDeskVault(nft, solon, address(sink), predictedBuyer, address(ops));
        buyer = new BuybackBurnExecutor(
            BuybackBurnExecutor.Config(
                address(this),
                address(solon),
                address(ledger),
                address(route),
                keccak256("path"),
                vm.addr(88),
                address(sink),
                address(cards)
            )
        );
        assertEq(address(buyer), predictedBuyer);
        buyer.configureSources(address(98), address(this));
        nft.configureProtocolVault(address(cards));
        ops.configureDesk(address(nft), address(cards));
        controller = new EligibilityController(address(this));
        staking = new SolonStakingV2(address(solon), address(ledger), controller);
        staking.configureProtocolDesk(address(rewards), address(stock), keccak256("stock"), 1, keccak256("policy"));
        rewards.configureProtocolStaking(address(staking));
        address alice = address(0xA11CE);
        solon.mint(alice, 100001 ether);
        vm.prank(alice);
        solon.approve(address(staking), 1 ether);
        vm.prank(alice);
        staking.stake(1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        solon.approve(address(nft), 100000 ether);
        vm.prank(alice);
        nft.mint{value: 1 ether}(1, alice);
        (bool ok,) = address(protocol).call{value: 200 ether}("");
        require(ok);
        protocol.schedule(keccak256(abi.encodeCall(protocol.setCommitments, (0, 10 ether, 100 ether))));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        protocol.setCommitments(0, 10 ether, 100 ether);
        protocol.schedule(keccak256(abi.encodeCall(protocol.allocateOps, (10 ether, 7))));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        protocol.allocateOps(10 ether, 7);
        bytes32 buyLot = keccak256("other-v2-actual-platform-fee");
        buyer.fundV2{value: 100 ether}(buyLot, true);
        route.setOutput(250000 ether);
        BuybackBurnExecutor.Quote memory q = BuybackBurnExecutor.Quote(
            buyLot, 100 ether, 240000 ether, 1, vm.getBlockTimestamp(), vm.getBlockTimestamp() + 60, 1
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(88, buyer.quoteDigest(q));
        buyer.execute(q, abi.encodePacked(r, s, v));
        uint256 supply = solon.totalSupply();
        assertEq(cards.pendingSolon(), 250000 ether);
        assertEq(cards.mintAvailable(20), 2);
        assertEq(cards.pendingSolon(), 50000 ether);
        assertEq(solon.balanceOf(address(sink)), 300000 ether);
        assertEq(solon.totalSupply(), supply);
        assertEq(ops.budget(7), 8 ether);
        assertEq(protocol.deskRevenue(), 0.3 ether);
        assertEq(nft.balanceOf(address(cards)), 2);
        bytes32 pool = keccak256("stock-pool");
        address receiver = address(new Phase4Receiver());
        ledger.registerPool(
            pool,
            address(stock),
            1,
            address(this),
            [receiver, address(4), address(rewards), receiver, address(5), address(6)]
        );
        stock.mint(address(this), 3000);
        stock.approve(address(ledger), 3000);
        ledger.creditStock(pool, 3000);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        uint256 credit = staking.creditOf(staking.protocolSource(pool), epoch, address(stock), 1, alice);
        assertEq(credit, 200e27);
        vm.prank(alice);
        staking.unstake(1 ether, alice);
        bytes32 key = rewards.streamKey(pool, epoch, address(stock), 1);
        assertEq(rewards.forwardProtocolDesk(key), 200);
        assertEq(stock.balanceOf(address(staking)), 200);
        assertEq(staking.creditOf(staking.protocolSource(pool), epoch, address(stock), 1, alice), credit);
        assertEq(rewards.forwardProtocolDesk(key), 0);
    }
}

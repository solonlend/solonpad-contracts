// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {LedgerStock, LedgerReceiver} from "./V3FeeLedger.t.sol";
import {DeskProtocolFixture} from "./helpers/DeskProtocolFixture.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {RewardAssetSchedule} from "../../src/v3/RewardAssetSchedule.sol";
import {RoundRegistry, RoundAdapter, RoundStock} from "./RewardRounds.t.sol";

contract RoyaltyPurchasedSource {
    LedgerStock public immutable token;
    RewardPayoutVault public payout;

    constructor(LedgerStock token_) {
        token = token_;
    }

    function bind(RewardPayoutVault p) external {
        require(address(payout) == address(0));
        payout = p;
    }

    function stageCredit(address, uint256[] calldata, address) external returns (uint256 raw) {
        require(msg.sender == address(payout));
        raw = token.balanceOf(address(this));
        token.transfer(address(payout), raw);
    }

    function push(address account) external {
        payout.claimFor(account, address(token));
    }
}

contract DeskRoyaltyTest is Test {
    DeskNFT nft;
    DeskRewards rewards;
    LedgerStock solon;
    LedgerStock stock;
    V3FeeLedger ledger;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    bytes32 constant POOL = keccak256("royalty-stock");

    function setUp() public {
        ledger = new V3FeeLedger(address(this), address(0));
        rewards = new DeskRewards(ledger, address(this));
        solon = new LedgerStock();
        stock = new LedgerStock();
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
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        rewards.configureRoyaltyAssets(assets);
        solon.mint(address(this), 300000 ether);
        solon.approve(address(nft), type(uint256).max);
        vm.deal(address(this), 100 ether);
        nft.mint{value: 1 ether}(1, alice);
        nft.mint{value: 1 ether}(1, bob);
        address[6] memory receivers;
        for (uint256 i; i < 6; i++) {
            receivers[i] = address(new LedgerReceiver());
        }
        receivers[2] = address(rewards);
        ledger.registerPool(POOL, address(stock), 1, address(this), receivers);
        stock.mint(address(this), 1000000);
        stock.approve(address(ledger), type(uint256).max);
        stock.approve(address(rewards), type(uint256).max);
    }

    function key(bytes32 source) internal view returns (bytes32) {
        return rewards.streamKey(source, vm.getBlockTimestamp() / 1 days, address(stock), 1);
    }

    function claim(address owner, uint256 id, bytes32 source) internal {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key(source);
        vm.prank(owner);
        nft.claim(id, keys);
    }

    function testDirectStockRoyaltyIsWhitelistedExactAndNeverSixSplit() public {
        rewards.depositRoyalty(address(stock), 100);
        assertEq(rewards.credit27(1, key(rewards.ROYALTY())), 50e27);
        assertEq(rewards.rawCustody(address(stock)), 100);
        assertEq(ledger.totalReceived(POOL), 0);
        claim(alice, 1, rewards.ROYALTY());
        assertEq(stock.balanceOf(alice), 50);
        assertEq(rewards.rawCustody(address(stock)), 50);
        LedgerStock unknown = new LedgerStock();
        unknown.mint(address(this), 100);
        unknown.approve(address(rewards), 100);
        vm.expectRevert();
        rewards.depositRoyalty(address(unknown), 100);
    }

    function testAlreadyPaidPurchaseInventoryIsNotReclassifiedAsRoyalty() public {
        EligibilityController control = new EligibilityController(address(this));
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), control);
        RoyaltyPurchasedSource source = new RoyaltyPurchasedSource(stock);
        source.bind(payout);
        payout.configureFactory(address(this));
        payout.registerSource(address(source));
        RoundStock resultAsset = new RoundStock();
        RoundAdapter adapter = new RoundAdapter(resultAsset);
        RoundRegistry registry = new RoundRegistry(address(resultAsset), address(adapter));
        RewardRoundManager rounds =
            new RewardRoundManager(address(this), address(registry), address(payout), address(0xFEE));
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32("STOCK");
        uint32[] memory versions = new uint32[](1);
        versions[0] = 1;
        bytes32[] memory policies = new bytes32[](1);
        policies[0] = bytes32("price");
        RewardAssetSchedule schedule = new RewardAssetSchedule(0, 1, assets, ids, versions, policies);
        rewards.configureRounds(address(rounds), address(payout), address(schedule));
        stock.transfer(address(source), 100);
        uint256[] memory epochs = new uint256[](1);
        payout.stageCredit(address(source), address(rewards), epochs, address(stock));
        source.push(address(rewards));
        assertEq(stock.balanceOf(address(rewards)), 100);
        assertEq(payout.paidTotal(address(rewards), address(stock)), 100);
        assertEq(rewards.syncRoyalty(address(stock)), 0);
        stock.transfer(address(rewards), 20);
        assertEq(rewards.syncRoyalty(address(stock)), 20);
        assertEq(rewards.credit27(1, key(rewards.ROYALTY())), 10e27);
    }

    function testMarketDirectReceiptCannotRecreditExistingLedgerOrRoyaltyDebt() public {
        ledger.creditStock(POOL, 1000);
        assertTrue(ledger.controlledClaim(POOL, 2));
        vm.prank(bob);
        vm.expectRevert();
        ledger.claim(POOL, 2, 100);
        claim(alice, 1, POOL);
        assertEq(rewards.rawCustody(address(stock)), 50);
        assertEq(rewards.syncRoyalty(address(stock)), 0);
        stock.transfer(address(rewards), 100);
        assertEq(rewards.syncRoyalty(address(stock)), 100);
        assertEq(rewards.syncRoyalty(address(stock)), 0);
        claim(bob, 2, POOL);
        claim(alice, 1, rewards.ROYALTY());
        claim(bob, 2, rewards.ROYALTY());
        assertEq(stock.balanceOf(alice), 100);
        assertEq(stock.balanceOf(bob), 100);
        assertEq(rewards.rawCustody(address(stock)), 0);
    }
}

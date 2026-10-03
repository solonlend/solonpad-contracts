// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {DeskProtocolFixture} from "./helpers/DeskProtocolFixture.sol";
import {Test} from "forge-std/Test.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {LedgerStock} from "./V3FeeLedger.t.sol";

contract DeskRewardStub {
    uint256 public received;

    function recordMintSurcharge() external payable {
        received += msg.value;
    }
}

contract DeskTest is Test {
    DeskNFT nft;
    LedgerStock solon;
    DeskRewardStub rewards;
    address sink = address(0xD00D);
    address protocol = address(new DeskProtocolFixture());
    address alice = address(0xA11CE);

    function setUp() public {
        solon = new LedgerStock();
        rewards = new DeskRewardStub();
        nft = new DeskNFT(
            address(this),
            address(solon),
            sink,
            address(rewards),
            protocol,
            address(0),
            DeskNFT.Quote(150e18, 1e18, block.timestamp, 1, keccak256("public SOL/USD"))
        );
        solon.mint(alice, 500000e18);
        vm.deal(alice, 1000e18);
        vm.prank(alice);
        solon.approve(address(nft), type(uint256).max);
    }

    function testMintProtocolSurchargeHasTrackedIndependentReceipt() public {
        vm.prank(alice);
        nft.mint{value: 75e18}(1, alice);
        assertEq(DeskProtocolFixture(payable(protocol)).revenue(), 7.5e18);
    }

    function testSponsoredGrantRequiresSponsorFullPaymentAndConsent() public {
        vm.prank(alice);
        nft.authorizeSponsored{value: 75e18}(address(0xB0B));
        nft.grantSponsored(address(0xB0B), alice);
        assertEq(nft.ownerOf(1), address(0xB0B));
        assertEq(solon.balanceOf(sink), 100000e18);
        assertEq(rewards.received(), 67.5e18);
        vm.expectRevert();
        nft.grantSponsored(address(0xB0B), alice);
    }

    function testModeAChecksBothTransferParties() public {
        DeskEligibility policy = new DeskEligibility();
        DeskNFT gated = new DeskNFT(
            address(this),
            address(solon),
            sink,
            address(rewards),
            protocol,
            address(policy),
            DeskNFT.Quote(150e18, 1e18, block.timestamp, 1, keccak256("quote"))
        );
        vm.prank(alice);
        solon.approve(address(gated), type(uint256).max);
        vm.prank(alice);
        gated.mint{value: 75e18}(1, alice);
        policy.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert();
        gated.transferFrom(alice, address(0xB0B), 1);
    }

    function testMintBurnsExactSolonAndPaysLockedSurcharge() public {
        vm.prank(alice);
        nft.mint{value: 150e18}(2, alice);
        assertEq(nft.totalSupply(), 2);
        assertEq(nft.ownerOf(1), alice);
        assertEq(solon.balanceOf(sink), 200000e18);
        assertEq(protocol.balance, 15e18);
        assertEq(rewards.received(), 135e18);
        assertEq(nft.surchargeUSDC18(), 75e18);
    }
}

import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {LedgerReceiver} from "./V3FeeLedger.t.sol";

contract DeskRewardsTest is Test {
    function onRoundFinalized(uint256) external {}

    DeskNFT nft;
    DeskRewards rewards;
    LedgerStock solon;
    LedgerStock stock;
    V3FeeLedger ledger;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    bytes32 constant POOL = keccak256("desk-stock");

    function setUp() public {
        ledger = new V3FeeLedger(address(this), address(0));
        rewards = new DeskRewards(ledger, address(this));
        solon = new LedgerStock();
        stock = new LedgerStock();
        nft = new DeskNFT(
            address(this),
            address(solon),
            address(0xD00D),
            address(rewards),
            address(new DeskProtocolFixture()),
            address(0),
            DeskNFT.Quote(2e18, 1e18, block.timestamp, 1, keccak256("quote"))
        );
        rewards.configureNFT(nft);
        solon.mint(alice, 1000000e18);
        solon.mint(bob, 1000000e18);
        vm.deal(alice, 100e18);
        vm.deal(bob, 100e18);
        vm.prank(alice);
        solon.approve(address(nft), type(uint256).max);
        vm.prank(bob);
        solon.approve(address(nft), type(uint256).max);
        address[6] memory receivers;
        for (uint256 i; i < 6; i++) {
            receivers[i] = address(new LedgerReceiver());
        }
        receivers[2] = address(rewards);
        ledger.registerPool(POOL, address(stock), 1, address(this), receivers);
        stock.mint(address(this), 1000000);
        stock.approve(address(ledger), type(uint256).max);
    }

    function testAutomaticDeskQueueUsesFixedCursorAndSharedServicePolicy() public {
        vm.warp(10 days + 10 minutes);
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        vm.prank(bob);
        nft.mint{value: 1e18}(1, bob);
        stock.mint(address(this), 1000e18);
        ledger.creditStock(POOL, 1000e18);
        bytes32 key = rewards.streamKey(POOL, 10, address(stock), 1);
        EligibilityController control = new EligibilityController(address(this));
        RewardPayoutVault p = new RewardPayoutVault(new address[](0), control);
        DeskPrice price = new DeskPrice();
        RewardDistributor policy = new RewardDistributor(p, address(price));
        (bool ok,) = address(nft).call(abi.encodeWithSignature("configureServicePolicy(address)", address(policy)));
        assertTrue(ok, "service policy binding");
        bytes memory data;
        (ok, data) = address(nft).call(abi.encodeWithSignature("openDeskQueue(bytes32)", key));
        assertTrue(ok);
        uint256 q = abi.decode(data, (uint256));
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        (ok,) = address(nft).call(abi.encodeWithSignature("batchDistributeDesk(uint256,uint256)", q, 1));
        assertTrue(ok);
        assertEq(stock.balanceOf(alice), 50e18);
        assertEq(stock.balanceOf(bob), 0);
        (ok,) = address(nft).call(abi.encodeWithSignature("batchDistributeDesk(uint256,uint256)", q, 1));
        assertFalse(ok, "schedule enforced");
        vm.warp(10 days + 25 minutes);
        (ok,) = address(nft).call(abi.encodeWithSignature("batchDistributeDesk(uint256,uint256)", q, 1));
        assertTrue(ok);
        assertEq(stock.balanceOf(bob), 50e18);
        vm.warp(10 days + 40 minutes);
        (ok,) = address(nft).call(abi.encodeWithSignature("batchDistributeDesk(uint256,uint256)", q, 32));
        assertFalse(ok, "completed cycle waits until next day");
        vm.warp(11 days + 10 minutes);
        (ok,) = address(nft).call(abi.encodeWithSignature("batchDistributeDesk(uint256,uint256)", q, 32));
        assertTrue(ok);
        assertEq(stock.balanceOf(alice), 50e18);
    }

    function testAutomaticDeskQueueAggregatesSameAssetStreams() public {
        vm.warp(10 days + 10 minutes);
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        bytes32 other = keccak256("desk-second");
        address[6] memory receivers;
        for (uint256 i; i < 6; ++i) {
            receivers[i] = address(new LedgerReceiver());
        }
        receivers[2] = address(rewards);
        ledger.registerPool(other, address(stock), 1, address(this), receivers);
        stock.mint(address(this), 20e18);
        ledger.creditStock(POOL, 10e18);
        ledger.creditStock(other, 10e18);
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = rewards.streamKey(POOL, 10, address(stock), 1);
        keys[1] = rewards.streamKey(other, 10, address(stock), 1);
        EligibilityController control = new EligibilityController(address(this));
        RewardPayoutVault p = new RewardPayoutVault(new address[](0), control);
        RewardDistributor policy = new RewardDistributor(p, address(new DeskPrice()));
        nft.configureServicePolicy(address(policy));
        (bool ok, bytes memory data) = address(nft).call(abi.encodeWithSignature("openDeskQueue(bytes32[])", keys));
        assertTrue(ok, "cumulative stream queue required");
        uint256 q = abi.decode(data, (uint256));
        (uint256 paid, uint256 failed) = nft.batchDistributeDesk(q, 32);
        assertEq(paid, 1);
        assertEq(failed, 0);
        assertEq(stock.balanceOf(alice), 2e18, "two subthreshold streams reach cumulative threshold");
        vm.prank(alice);
        nft.claim(1, keys);
        assertEq(stock.balanceOf(alice), 2e18);
        keys[1] = keys[0];
        (ok,) = address(nft).call(abi.encodeWithSignature("openDeskQueue(bytes32[])", keys));
        assertFalse(ok, "duplicates cannot inflate threshold");
    }

    function testPermissionlessBatchSharesClaimDebtAndIsolatesFailures() public {
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        vm.prank(bob);
        nft.mint{value: 1e18}(1, bob);
        ledger.creditStock(POOL, 1000);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = rewards.streamKey(POOL, block.timestamp / 1 days, address(stock), 1);
        vm.prank(alice);
        nft.claim(1, keys);
        uint256[] memory ids = new uint256[](4);
        ids[0] = 999;
        ids[1] = 1;
        ids[2] = 2;
        ids[3] = 1;
        (uint256 paid, uint256 failed) = nft.batchDistributeDesk(ids, keys);
        assertEq(paid, 1);
        assertEq(failed, 1);
        assertEq(stock.balanceOf(alice), 50);
        assertEq(stock.balanceOf(bob), 50);
        (paid, failed) = nft.batchDistributeDesk(ids, keys);
        assertEq(paid, 0);
        assertEq(failed, 1);
        ids = new uint256[](33);
        vm.expectRevert();
        nft.batchDistributeDesk(ids, keys);
    }

    function testOldDenominatorRemainderIsFrozenThenRolledOnlyIntoNextEpoch() public {
        vm.prank(alice);
        nft.mint{value: 3e18}(3, alice);
        ledger.creditStock(POOL, 10);
        uint256 epoch = block.timestamp / 1 days;
        bytes32 oldKey = rewards.streamKey(POOL, epoch, address(stock), 1);
        bytes32 nextKey = rewards.streamKey(POOL, epoch + 1, address(stock), 1);
        vm.prank(bob);
        nft.mint{value: 1e18}(1, bob);
        ledger.creditStock(POOL, 10);
        assertEq(rewards.nextEpochRemainder(nextKey), 1);
        assertEq(rewards.credit27(4, oldKey), 1e27 / 4);
        vm.warp((epoch + 1) * 1 days);
        ledger.creditStock(POOL, 10);
        (,,,,, uint256 remainder,,,) = rewards.streams(nextKey);
        assertEq(remainder, 1);
        assertEq(rewards.nextEpochRemainder(nextKey), 0);
    }

    function testSignedSafeSaleProtectsBuyerWhenSellerClaimsFirst() public {
        address seller = vm.addr(123);
        solon.mint(seller, 200000e18);
        vm.deal(seller, 2e18);
        vm.prank(seller);
        solon.approve(address(nft), type(uint256).max);
        vm.prank(seller);
        nft.mint{value: 2e18}(2, seller);
        ledger.creditStock(POOL, 1000);
        bytes32 key = rewards.streamKey(POOL, block.timestamp / 1 days, address(stock), 1);
        DeskNFT.Purchase memory order = DeskNFT.Purchase(1, seller, bob, key, 0, block.timestamp + 1 hours, 50, 0);
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(123, nft.purchaseDigest(order));
        bytes memory sig = abi.encodePacked(r, ss, v);
        vm.prank(bob);
        nft.purchase(order, sig);
        assertEq(nft.ownerOf(1), bob);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(bob);
        nft.claim(1, keys);
        assertEq(stock.balanceOf(bob), 50);
        order.tokenId = 2;
        (v, r, ss) = vm.sign(123, nft.purchaseDigest(order));
        sig = abi.encodePacked(r, ss, v);
        vm.prank(seller);
        nft.claim(2, keys);
        vm.prank(bob);
        vm.expectRevert();
        nft.purchase(order, sig);
        assertEq(nft.ownerOf(2), seller);
    }

    function testFivePercentRoyaltyGoesToDistinctDeskPotWithoutSixWaySplit() public {
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        (bool ok, bytes memory data) =
            address(nft).staticcall(abi.encodeWithSignature("royaltyInfo(uint256,uint256)", 1, 100e18));
        assertTrue(ok);
        (address receiver, uint256 amount) = abi.decode(data, (address, uint256));
        assertEq(receiver, address(rewards));
        assertEq(amount, 5e18);
        vm.deal(address(this), 5e18);
        (ok,) = receiver.call{value: amount}("");
        assertTrue(ok);
        bytes32 key = rewards.streamKey(keccak256("DESK_ROYALTY"), block.timestamp / 1 days, address(0), 0);
        assertEq(rewards.credit27(1, key), 5e45);
        assertTrue(nft.supportsInterface(0x2a55205a));
    }

    function testNativeDeskBudgetUsesExistingRoundAndTransferKeepsUndeliveredRights() public {
        _nativeRound(false);
    }

    function testThirdPartyStagingCannotStrandPurchasedDeskStock() public {
        _nativeRound(true);
    }

    /// @dev Split out of `_nativeRound` only to keep `forge coverage --ir-minimum` within the stack limit.
    function _nvdaSchedule(address asset) internal returns (RewardAssetSchedule schedule) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        bytes32[] memory ids0 = new bytes32[](1);
        ids0[0] = bytes32("NVDA");
        uint32[] memory vers = new uint32[](1);
        vers[0] = 1;
        bytes32[] memory policies = new bytes32[](1);
        policies[0] = bytes32("price");
        schedule = new RewardAssetSchedule(0, 1, assets, ids0, vers, policies);
    }

    function _nativeRound(bool preStage) internal {
        vm.warp(10 days);
        RoundStock rewardStock = new RoundStock();
        RoundAdapter adapter = new RoundAdapter(rewardStock);
        RoundRegistry registry = new RoundRegistry(address(rewardStock), address(adapter));
        EligibilityController control = new EligibilityController(address(this));
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), control);
        payout.configureFactory(address(this));
        RewardRoundManager rounds =
            new RewardRoundManager(address(this), address(registry), address(payout), address(0xFEE));
        payout.registerSource(address(rounds.vault()));
        rounds.configureExecution(address(this), address(new RoundCapacity()));
        RewardAssetSchedule schedule = _nvdaSchedule(address(rewardStock));
        rewards.configureRounds(address(rounds), address(payout), address(schedule));
        rounds.configureRewardModules(address(rewards), address(0));
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        bytes32 nativePool = keccak256("desk-native");
        address[6] memory receivers;
        for (uint256 i; i < 6; ++i) {
            receivers[i] = address(new LedgerReceiver());
        }
        receivers[2] = address(rewards);
        ledger.registerPool(nativePool, address(0), 0, address(this), receivers);
        vm.deal(address(this), 1000e18);
        ledger.creditNative{value: 1000e18}(nativePool);
        bytes32 key = rewards.streamKey(nativePool, 10, address(0), 0);
        address source = rewards.entrySource(key);
        assertEq(rounds.sourcePool(source), nativePool, "permissionless module registration");
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        vm.warp(11 days);
        uint256 eid = rounds.seal(source, 10, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        assertEq(rounds.entry(eid).budget18, 100e18);
        uint256[] memory ids = new uint256[](1);
        ids[0] = eid;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        uint256 rid = rounds.reserveBatch(ids, amounts, 1, block.timestamp + 1 hours);
        rounds.start(rid, "");
        adapter.verifyFunding();
        rounds.poke(rid);
        rounds.submit(rid);
        adapter.setResult(1, 99, 0);
        rounds.finalize(rid, "");
        if (preStage) payout.stageCredit(address(rounds.vault()), address(rewards), ids, address(rewardStock));
        rewards.syncPurchased(key, eid);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(bob);
        nft.claim(1, keys);
        assertEq(rewardStock.balanceOf(bob), 99);
        assertEq(rewardStock.balanceOf(alice), 0);
        rewards.syncPurchased(key, eid);
        vm.prank(bob);
        nft.claim(1, keys);
        assertEq(rewardStock.balanceOf(bob), 99);
    }

    function testDirectStockClaimPaysCurrentOwnerAndCannotDoubleClaim() public {
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        ledger.creditStock(POOL, 1000);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = rewards.streamKey(POOL, block.timestamp / 1 days, address(stock), 1);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        vm.prank(bob);
        nft.approve(alice, 1);
        vm.prank(alice);
        nft.claim(1, keys);
        assertEq(stock.balanceOf(bob), 100);
        assertEq(stock.balanceOf(alice), 0);
        vm.prank(bob);
        nft.claim(1, keys);
        assertEq(stock.balanceOf(bob), 100);
    }

    function testFeeTimeRightsExcludeNewCardsAndFollowTokenId() public {
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        ledger.creditStock(POOL, 1000);
        bytes32 key = rewards.streamKey(POOL, block.timestamp / 1 days, address(stock), 1);
        assertEq(rewards.credit27(1, key), 100e27);
        vm.prank(bob);
        nft.mint{value: 1e18}(1, bob);
        ledger.creditStock(POOL, 1000);
        assertEq(rewards.credit27(1, key), 150e27);
        assertEq(rewards.credit27(2, key), 50e27);
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(rewards.credit27(1, key), 150e27);
    }
}

contract DeskEligibility {
    mapping(address => bool) public blocked;

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function canReceiveStock(address, address a) external view returns (bool) {
        return !blocked[a];
    }

    function eligibilityEnabled() external pure returns (bool) {
        return true;
    }
}

import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {RewardAssetSchedule} from "../../src/v3/RewardAssetSchedule.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {RoundStock, RoundRegistry, RoundAdapter, RoundCapacity} from "./RewardRounds.t.sol";

import {RewardDistributor} from "../../src/v3/RewardDistributor.sol";

contract DeskPrice {
    function priceUSD18(address) external view returns (uint256, uint256) {
        return (1e18, block.timestamp);
    }
}

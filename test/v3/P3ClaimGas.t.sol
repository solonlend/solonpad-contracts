// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {RewardDistributor} from "../../src/v3/RewardDistributor.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {PayoutAsset, PayoutOracle} from "./RewardDistributor.t.sol";

// Seed via a single outer call: isolated Foundry transactions otherwise copy
// the entire growing state for each root-level transfer in the test fixture.
contract P3HistorySeeder is Test {
    function seed(V3RewardToken token, PayoutAsset asset) external {
        for (uint256 e = 10; e < 30; ++e) {
            for (uint256 i; i < 256; ++i) {
                vm.warp(e * 1 days + 1 hours + i * 300);
                asset.mint(address(token), 1 ether);
                token.onFeeCredit(bytes32(uint256(77)), address(asset), 1, 1 ether);
                vm.prank(address(0xA));
                token.transfer(address(0xB), 1);
                vm.prank(address(0xB));
                token.transfer(address(0xA), 1);
            }
        }
    }
}

contract P3ClaimGasTest is Test {
    V3RewardToken token;
    RewardPayoutVault payout;
    RewardDistributor distributor;
    PayoutAsset asset;
    address alice = address(0xA);
    address bob = address(0xB);
    bytes32 constant POOL = bytes32(uint256(77));
    uint256[] epochs;
    uint256 expected;

    function setUp() public {
        vm.pauseGasMetering();
        vm.warp(10 days);
        asset = new PayoutAsset();
        P3HistorySeeder seeder = new P3HistorySeeder();
        token = new V3RewardToken("Deep", "D", address(this), address(seeder), new address[](0));
        token.configurePool(POOL, address(asset), 1);
        address[] memory sources = new address[](1);
        sources[0] = address(token);
        EligibilityController controller = new EligibilityController(address(this));
        payout = new RewardPayoutVault(sources, controller);
        token.configurePayout(address(payout));
        token.transfer(alice, 100000 ether);
        vm.warp(10 days + 1 hours);
        seeder.seed(token, asset);
        for (uint256 e = 10; e < 30; ++e) {
            epochs.push(e);
        }
        vm.warp(30 days + 1 hours);
        for (uint256 i; i < epochs.length; ++i) {
            expected += token.epochCredit27(alice, epochs[i]) / 1e27;
        }
        distributor = new RewardDistributor(payout, address(new PayoutOracle()));
        payout.configureDistributor(address(distributor));
        vm.resumeGasMetering();
    }

    function testTwentyColdDeepHistoryEpochsFitClaimGasCap() public {
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        vm.cool(address(token));
        vm.cool(address(payout));
        vm.cool(address(asset));
        vm.cool(address(distributor));
        vm.prank(alice);
        uint256 beforeGas = gasleft();
        distributor.claim(address(token), epochs, assets);
        uint256 consumed = beforeGas - gasleft();
        emit log_named_uint("20 epochs, 5120 index/account points, cold claim gas", consumed);
        assertEq(asset.balanceOf(alice), expected, "claim child must not silently OOG");
        assertLt(consumed, 6000000);
    }

    function testColdDeepSingleEpochRetriesWithoutDelayAtLargerGasBudget() public {
        uint256 q = distributor.openQueue(address(token), epochs[0], address(asset));
        vm.cool(address(token));
        vm.cool(address(payout));
        vm.cool(address(asset));
        vm.cool(address(distributor));
        distributor.batchDistribute(q, 32, 20, 300000);
        (RewardDistributor.Queue memory state, uint256 next,) = distributor.previewBatch(q);
        assertEq(state.cursor, 0);
        assertEq(next, 0);
        distributor.batchDistribute(q, 32, 20, 2000000);
        (state,,) = distributor.previewBatch(q);
        assertEq(state.cursor, state.upperBound);
        assertGt(asset.balanceOf(alice), 255 ether);
    }

    function testCappedCallerPreservesStagedPrefixAndRetryCannotDoublePay() public {
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        vm.cool(address(token));
        vm.cool(address(payout));
        vm.cool(address(asset));
        vm.cool(address(distributor));
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) =
            address(distributor).call{gas: 3000000}(abi.encodeCall(distributor.claim, (address(token), epochs, assets)));
        assertTrue(ok);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool stopped;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != keccak256("ClaimPageStopped(address,address,address,uint256,uint256)")) continue;
            (uint256 assetIndex, uint256 nextEpoch) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(assetIndex, 0);
            assertGt(nextEpoch, 0);
            assertLt(nextEpoch, epochs.length);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), alice);
            stopped = true;
        }
        assertTrue(stopped, "partial page emits resume index");
        assertGt(payout.readyRaw(alice, address(asset)), 0, "successful prefix retained");
        assertEq(asset.balanceOf(alice), 0);
        assertLt(payout.readyRaw(alice, address(asset)), expected);
        vm.prank(alice);
        distributor.claim(address(token), epochs, assets);
        assertEq(asset.balanceOf(alice), expected);
        assertEq(payout.readyRaw(alice, address(asset)), 0);
        vm.prank(alice);
        distributor.claim(address(token), epochs, assets);
        assertEq(asset.balanceOf(alice), expected);
    }

    function testMeasureUncappedColdTwentyEpochClaim() public {
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        vm.cool(address(token));
        vm.cool(address(payout));
        vm.cool(address(asset));
        vm.prank(alice);
        uint256 beforeGas = gasleft();
        token.claim(epochs, assets);
        emit log_named_uint("uncapped 20 epochs, 5120 points cold gas", beforeGas - gasleft());
        assertEq(asset.balanceOf(alice), expected);
    }
}

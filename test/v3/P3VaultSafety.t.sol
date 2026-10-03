// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RewardVault} from "../../src/v3/RewardVault.sol";
import {PayoutAsset, PayoutOracle, PayoutSource} from "./RewardDistributor.t.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {RewardDistributor} from "../../src/v3/RewardDistributor.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";

contract P3CreditSource {
    address[] public people;
    mapping(address => uint256) public credit;

    function add(address account, uint256 amount) external {
        people.push(account);
        credit[account] = amount;
    }

    function queueSnapshot(uint256) external view returns (uint256, uint256) {
        return (people.length, 1);
    }

    function participantAt(uint256 i) external view returns (address) {
        return people[i];
    }

    function creditOf(address account, uint256, uint8) external view returns (uint256) {
        return credit[account];
    }
}

contract P3VaultSafetyTest is Test {
    RewardVault vault;
    PayoutAsset asset;
    P3CreditSource source;
    address alice = address(0xA);
    address bob = address(0xB);

    function setUp() public {
        asset = new PayoutAsset();
        vault = new RewardVault(address(this));
        source = new P3CreditSource();
        source.add(alice, 10);
        source.add(bob, 10);
        vault.registerAllocation(1, address(source), 1, 0, address(asset), 10);
        vault.registerAllocation(2, address(source), 2, 0, address(asset), 10);
        asset.mint(address(vault), 20);
        vault.recordDelivery(1, 10);
        vault.recordDelivery(2, 10);
    }

    function ids(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    function testParticipantSnapshotsAreSourceScopedAndFreezeOriginalBound() public {
        P3CreditSource other = new P3CreditSource();
        other.add(address(0xC), 10);
        vault.registerAllocation(3, address(other), 1, 0, address(asset), 10);
        source.add(address(0xD), 0);
        vault.registerAllocation(4, address(source), 3, 0, address(asset), 10);
        vault.registerParticipants(address(other), 64);
        vault.registerParticipants(address(source), 64);
        vault.sealParticipantIndex(1);
        vault.sealParticipantIndex(3);
        vault.sealParticipantIndex(4);
        (uint256 originalBound,) = vault.queueSnapshot(1);
        (uint256 otherBound,) = vault.queueSnapshot(3);
        (uint256 newerBound,) = vault.queueSnapshot(4);
        assertEq(originalBound, 2);
        assertEq(otherBound, 1);
        assertEq(newerBound, 3);
        (bool ok, bytes memory data) =
            address(vault).staticcall(abi.encodeWithSignature("participantAt(uint256,uint256)", 3, 0));
        assertTrue(ok);
        assertEq(abi.decode(data, (address)), address(0xC));
        (ok,) = address(vault).staticcall(abi.encodeWithSignature("participantAt(uint256,uint256)", 1, 2));
        assertFalse(ok, "sealed allocation bound must apply to lookup");
    }

    function testOverReportedCreditsCannotSpendAnotherAllocationInventory() public {
        vault.stageCredit(alice, ids(1), address(asset));
        vm.expectRevert();
        vault.stageCredit(bob, ids(1), address(asset));
        assertEq(asset.balanceOf(address(vault)), 10);
        vault.stageCredit(bob, ids(2), address(asset));
        assertEq(asset.balanceOf(address(vault)), 0);
    }
}

contract P3VaultHandler {
    RewardVault public vault;
    PayoutAsset public asset;

    constructor() {
        vault = new RewardVault(address(this));
        asset = new PayoutAsset();
        P3CreditSource source = new P3CreditSource();
        source.add(address(0xA), 10);
        source.add(address(0xB), 10);
        for (uint256 i = 1; i <= 2; ++i) {
            vault.registerAllocation(i, address(source), i, 0, address(asset), 10);
        }
    }

    function deliver(uint8 which, uint96 raw) external {
        uint256 amount = uint256(raw) % 1e20;
        asset.mint(address(vault), amount);
        vault.recordDelivery(uint256(which) % 2 + 1, amount);
    }

    function stage(uint8 which, bool alice) external {
        uint256[] memory ids = new uint256[](1);
        ids[0] = uint256(which) % 2 + 1;
        try vault.stageCredit(alice ? address(0xA) : address(0xB), ids, address(asset)) {} catch {}
    }
}

contract P3VaultInvariantTest is StdInvariant, Test {
    P3VaultHandler handler;

    function setUp() public {
        handler = new P3VaultHandler();
        targetContract(address(handler));
    }

    function invariant_EveryAllocationStagedIsCoveredByItsOwnDelivery() public view {
        RewardVault vault = handler.vault();
        for (uint256 i = 1; i <= 2; ++i) {
            (,,,,, uint256 delivered,) = vault.allocations(i);
            uint256 staged = vault.creditedToPayout(i, address(0xA)) + vault.creditedToPayout(i, address(0xB));
            assertEq(staged, vault.allocationStaged(i));
            assertLe(staged, delivered);
        }
    }
}

contract P3ScopedDistributionTest is Test {
    function testColdVaultStagingAtMinimumGasUsesOnlyAllocationSource() public {
        vm.warp(10 days + 1 hours);
        PayoutAsset asset = new PayoutAsset();
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), new EligibilityController(address(this)));
        payout.configureFactory(address(this));
        RewardVault vault = new RewardVault(address(payout));
        payout.registerSource(address(vault));
        RewardDistributor distributor = new RewardDistributor(payout, address(new PayoutOracle()));
        payout.configureDistributor(address(distributor));
        P3CreditSource first = new P3CreditSource();
        P3CreditSource second = new P3CreditSource();
        first.add(address(0xA), 10);
        second.add(address(0xB), 10);
        vault.registerAllocation(1, address(first), 9, 0, address(asset), 10);
        vault.registerAllocation(2, address(second), 9, 0, address(asset), 10);
        asset.mint(address(vault), 20 ether);
        vault.recordDelivery(1, 10 ether);
        vault.recordDelivery(2, 10 ether);
        vault.registerParticipants(address(first), 64);
        vault.registerParticipants(address(second), 64);
        vault.sealParticipantIndex(1);
        vault.sealParticipantIndex(2);
        uint256 q = distributor.openQueue(address(vault), 2, address(asset));
        vm.cool(address(vault));
        vm.cool(address(payout));
        vm.cool(address(asset));
        vm.cool(address(second));
        vm.cool(address(distributor));
        uint256 beforeGas = gasleft();
        distributor.batchDistribute(q, 32, 20, 300000);
        emit log_named_uint("cold vault stage + pay page gas", beforeGas - gasleft());
        (RewardDistributor.Queue memory state,,) = distributor.previewBatch(q);
        assertEq(state.upperBound, 1);
        assertEq(state.cursor, 1);
        assertEq(asset.balanceOf(address(0xB)), 10 ether);
        assertEq(asset.balanceOf(address(0xA)), 0);
        assertEq(vault.allocationStaged(1), 0);
        assertEq(vault.allocationStaged(2), 10 ether);
    }
}

contract P3BrokenScopedSource is PayoutSource {
    constructor(PayoutAsset asset) PayoutSource(asset) {}

    function scopedParticipantIndex() external pure returns (bool) {
        return true;
    }

    function participantAt(uint256, uint256) external pure returns (address) {
        revert("scope unavailable");
    }
}

contract P3ScopedFailureTest is Test {
    function testDeclaredScopedSourceNeverFallsBackToGlobalParticipant() public {
        vm.warp(10 days + 1 hours);
        PayoutAsset asset = new PayoutAsset();
        P3BrokenScopedSource source = new P3BrokenScopedSource(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(source);
        RewardPayoutVault payout = new RewardPayoutVault(sources, new EligibilityController(address(this)));
        source.configurePayout(address(payout));
        source.add(address(0xA));
        source.fund(9, address(0xA), 2 ether);
        RewardDistributor distributor = new RewardDistributor(payout, address(new PayoutOracle()));
        payout.configureDistributor(address(distributor));
        uint256 q = distributor.openQueue(address(source), 9, address(asset));
        vm.expectRevert("scoped participant");
        distributor.batchDistribute(q, 32, 20, 300000);
        assertEq(asset.balanceOf(address(0xA)), 0);
        (RewardDistributor.Queue memory state, uint256 next,) = distributor.previewBatch(q);
        assertEq(state.cursor, 0);
        assertEq(next, 0);
    }
}

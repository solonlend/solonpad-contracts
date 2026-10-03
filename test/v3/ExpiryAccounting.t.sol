// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {EligibilityRegistry} from "../../src/v3/EligibilityRegistry.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ExpiryStock is ERC20 {
    constructor() ERC20("Stock", "STK") {}
}

contract ExpiryAccountingTest is Test {
    V3RewardToken t;
    EligibilityController c;
    EligibilityRegistry r;
    ExpiryStock stock;
    address alice;
    address bob;
    bytes32 pool = bytes32(uint256(1));
    bytes32 policy = keccak256("policy");

    function setUp() public {
        vm.warp(10 days);
        alice = vm.addr(3);
        bob = vm.addr(4);
        stock = new ExpiryStock();
        c = new EligibilityController(address(this));
        r = new EligibilityRegistry(address(this));
        c.bindAsset(address(stock), 0);
        t = new V3RewardToken("Reward", "R", address(this), address(this), new address[](0));
        t.configurePool(pool, address(stock), 1);
        (bool ok,) = address(t).call(abi.encodeWithSignature("configureEligibility(address)", address(c)));
        assertTrue(ok, "eligibility wiring absent");
        r.allowRewardPool(address(t));
        r.scheduleIssuer(vm.addr(1), true);
        r.scheduleIssuer(vm.addr(2), true);
        c.scheduleEnable(address(r), policy, 13);
        t.transfer(alice, 100);
        t.transfer(bob, 100);
        vm.warp(10 days + 1 hours);
        t.onFeeCredit(pool, address(stock), 1, 20);
        vm.warp(13 days);
        r.executeIssuer(vm.addr(1));
        r.executeIssuer(vm.addr(2));
    }

    function credential(uint256 key, uint256 expiry) internal returns (bytes32) {
        address wallet = vm.addr(key);
        EligibilityRegistry.Attestation memory a = EligibilityRegistry.Attestation(
            block.chainid,
            address(r),
            wallet,
            keccak256(abi.encode(wallet)),
            1,
            1,
            policy,
            block.timestamp,
            expiry,
            r.nonces(wallet),
            keccak256("terms")
        );
        bytes32 hash = r.digest(a);
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(1);
        signers[1] = vm.addr(2);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sig(1, hash);
        sigs[1] = sig(2, hash);
        r.register(a, signers, sigs, sig(key, hash));
        return hash;
    }

    function sig(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 x, bytes32 y) = vm.sign(key, hash);
        return abi.encodePacked(x, y, v);
    }

    function testModeSwitchFreezesBAndRequalifiesWithoutActivation() public {
        assertEq(t.effectiveEligible(), 0, "old B weights leaked into A");
        t.onFeeCredit(pool, address(stock), 1, 10);
        assertEq(t.epochCredit27(alice, 10), 10e27);
        credential(3, 15 days);
        // Permissionless sync (keeper, frontend or any transfer) re-qualifies the whole balance.
        vm.prank(address(0xbeef));
        t.syncEligibility(alice);
        assertEq(t.eligible(alice), 100);
        assertEq(t.effectiveEligible(), 100);
        (uint256 deposited, uint256 released,,) = t.carryState();
        assertEq(deposited, 10);
        assertEq(released, 0);
    }

    function testExpiryCutsHistoricalIndexWithoutKeeper() public {
        credential(3, 14 days);
        credential(4, 16 days);
        t.syncEligibility(alice);
        t.syncEligibility(bob);
        t.onFeeCredit(pool, address(stock), 1, 20);
        vm.warp(14 days);
        t.onFeeCredit(pool, address(stock), 1, 40);
        vm.warp(15 days);
        assertEq(t.effectiveEligible(), 100);
        assertEq(t.epochCredit27(alice, 13), 10e27);
        assertEq(t.epochCredit27(alice, 14), 0);
        assertEq(t.epochCredit27(bob, 14), 40e27);
        vm.prank(alice);
        t.transfer(bob, 100);
    }

    function testRenewalDoesNotAwardExpiredGap() public {
        credential(3, 14 days);
        credential(4, 20 days);
        t.syncEligibility(alice);
        t.syncEligibility(bob);
        t.onFeeCredit(pool, address(stock), 1, 20);
        vm.warp(14 days);
        t.onFeeCredit(pool, address(stock), 1, 40);
        vm.warp(15 days);
        credential(3, 20 days);
        assertEq(t.effectiveEligible(), 100);
        t.syncEligibility(alice);
        t.onFeeCredit(pool, address(stock), 1, 20);
        assertEq(t.epochCredit27(alice, 14), 0);
        assertEq(t.epochCredit27(alice, 15), 10e27);
    }

    function testAutomaticExpiryFreezesOldDenominatorRemainder() public {
        credential(3, 13 days + 2 hours);
        credential(4, 20 days);
        vm.prank(alice);
        t.transfer(address(this), 99);
        vm.prank(bob);
        t.transfer(address(this), 98);
        t.syncEligibility(alice);
        t.syncEligibility(bob);
        assertEq(t.effectiveEligible(), 3);
        t.onFeeCredit(pool, address(stock), 1, 1);
        assertEq(t.indexRemainder(), 1);
        vm.warp(13 days + 2 hours);
        t.onFeeCredit(pool, address(stock), 1, 1);
        assertEq(t.epochDust27(13), 1, "expired denominator dust reassigned");
        assertEq(t.indexRemainder(), 0);
    }

    function testCheckpointExpiryUsesHistoricalTwoIndices() public {
        credential(3, 14 days);
        credential(4, 20 days);
        t.syncEligibility(alice);
        t.syncEligibility(bob);
        t.onFeeCredit(pool, address(stock), 1, 20);
        uint256 beforeIndex = t.rewardPerEligibleToken();
        vm.warp(14 days);
        t.onFeeCredit(pool, address(stock), 1, 40);
        vm.warp(15 days);
        (uint256 ordinary, uint256 carryIndex) = t.checkpointExpiry(uint32(14 days));
        assertEq(ordinary + carryIndex, beforeIndex);
        (ordinary, carryIndex) = t.checkpointExpiry(uint32(14 days));
        assertEq(ordinary + carryIndex, beforeIndex);
    }

    function testATransferInQualifiesWholeBalanceAutomatically() public {
        credential(3, 20 days);
        t.transfer(alice, 100);
        assertEq(t.eligible(alice), 200, "credentialed receiver must earn without activation");
        assertEq(t.effectiveEligible(), 200);
        t.transfer(bob, 100);
        assertEq(t.eligible(bob), 0, "uncredentialed receiver earned in A");
        assertEq(t.effectiveEligible(), 200);
        t.onFeeCredit(pool, address(stock), 1, 20);
        assertEq(t.epochCredit27(alice, 13), 20e27);
        assertEq(t.epochCredit27(bob, 13), 0);
        vm.prank(alice);
        t.transfer(bob, 50);
        assertEq(t.eligible(alice), 150);
        assertEq(t.eligible(bob), 0);
    }

    function testFullPoolBindingCapacityDoesNotBlockTransfers() public {
        credential(3, 20 days);
        for (uint256 i; i < 8; ++i) {
            address module = address(new ExpiryStock());
            r.allowRewardPool(module);
            vm.prank(module);
            r.bindRewardPool(alice);
        }
        t.transfer(alice, 100);
        assertEq(t.balanceOf(alice), 200);
        assertEq(t.eligible(alice), 0, "ninth binding cannot earn");
        vm.prank(alice);
        t.transfer(bob, 10);
        assertEq(t.balanceOf(bob), 110);
    }

    function testDifferentPolicyCannotReceiveAfterA() public {
        policy = keccak256("different policy");
        credential(3, 20 days);
        assertFalse(t.deliveryAllowed(alice, address(stock)), "wrong policy accepted for delivery");
    }

    function testSameSecondRevocationPreservesOnlyEarlierFee() public {
        bytes32 id = credential(3, 20 days);
        credential(4, 20 days);
        t.syncEligibility(alice);
        t.syncEligibility(bob);
        t.onFeeCredit(pool, address(stock), 1, 20);
        r.revoke(id, keccak256("reason"));
        t.onFeeCredit(pool, address(stock), 1, 40);
        assertEq(t.epochCredit27(alice, 13), 10e27);
        assertEq(t.epochCredit27(bob, 13), 50e27);
        assertEq(t.effectiveEligible(), 100);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {RewardDistributor} from "../../src/v3/RewardDistributor.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";

contract PayoutAsset is ERC20 {
    address public blocked;
    constructor() ERC20("Stock", "S") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function blockRecipient(address who) external {
        blocked = who;
    }

    function _update(address from, address to, uint256 n) internal override {
        require(to != blocked || to == address(0), "blocked");
        super._update(from, to, n);
    }
}

contract PayoutSource {
    PayoutAsset public asset;
    address public payout;
    address[] public people;
    mapping(address => bool) public denied;
    mapping(uint256 => mapping(address => uint256)) public entitlement;
    mapping(uint256 => mapping(address => uint256)) public staged;
    address public gasHog;

    function burnGasFor(address a) external {
        gasHog = a;
    }
    uint256 public revision = 1;

    constructor(PayoutAsset a) {
        asset = a;
    }

    function configurePayout(address p) external {
        require(payout == address(0));
        payout = p;
    }

    function add(address a) external {
        people.push(a);
    }

    function fund(uint256 epoch, address a, uint256 amount) external {
        entitlement[epoch][a] += amount;
        asset.mint(address(this), amount);
        revision++;
    }

    function deny(address a, bool b) external {
        denied[a] = b;
    }

    function participantCount() external view returns (uint256) {
        return people.length;
    }

    function participantAt(uint256 i) external view returns (address) {
        return people[i];
    }

    function queueSnapshot(uint256) external view returns (uint256, uint256) {
        return (people.length, revision);
    }

    function queueAsset(uint256) external view returns (address) {
        return address(asset);
    }

    function poolId() external view returns (bytes32) {
        return bytes32(uint256(uint160(address(this))));
    }

    function settlementKind() external pure returns (uint8) {
        return 1;
    }

    function deliveryAllowed(address a, address) external view returns (bool) {
        return !denied[a];
    }

    function stageCredit(address a, uint256[] calldata epochs, address token) external returns (uint256 amount) {
        require(msg.sender == payout && token == address(asset));
        if (a == gasHog) {
            assembly { for {} 1 {} {} }
        }
        for (uint256 i; i < epochs.length; i++) {
            uint256 e = epochs[i];
            amount += entitlement[e][a] - staged[e][a];
            staged[e][a] = entitlement[e][a];
        }
        if (amount != 0) asset.transfer(payout, amount);
    }
}

contract PayoutEligibilityStatus {
    bool public allowed;

    function policyOf(address) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function allow(bool yes) external {
        allowed = yes;
    }

    function status(address, uint8, uint256) external view returns (bool) {
        return allowed;
    }
}

contract PayoutOracle {
    uint256 public price = 1 ether;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function set(uint256 p, uint256 t) external {
        price = p;
        updatedAt = t;
    }

    function priceUSD18(address) external view returns (uint256, uint256) {
        return (price, updatedAt);
    }
}

contract RewardDistributorTest is Test {
    EligibilityController controller;
    PayoutAsset asset;
    PayoutSource source;
    RewardPayoutVault payout;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(10 days + 1 hours);
        controller = new EligibilityController(address(this));
        asset = new PayoutAsset();
        source = new PayoutSource(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(source);
        payout = new RewardPayoutVault(sources, controller);
        source.configurePayout(address(payout));
        source.add(alice);
        source.add(bob);
    }

    function epochs(uint256 e) internal pure returns (uint256[] memory v) {
        v = new uint256[](1);
        v[0] = e;
    }
    function onFeeCredit(bytes32, address, uint8, uint256) external {}

    function testRealLedgerTokenPayoutPreservesSellerRightsAndClaimBatchRace() public {
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        V3RewardToken token = new V3RewardToken("Holder", "H", address(this), address(ledger), new address[](0));
        address[] memory ss = new address[](1);
        ss[0] = address(token);
        RewardPayoutVault p = new RewardPayoutVault(ss, controller);
        controller.bindAsset(address(asset), 0);
        token.configureEligibility(controller);
        token.configurePayout(address(p));
        bytes32 pool = keccak256("real-payout");
        token.configurePool(pool, address(asset), 1);
        address[6] memory beneficiaries;
        for (uint256 i; i < 6; i++) {
            beneficiaries[i] = address(this);
        }
        beneficiaries[0] = address(token);
        ledger.registerPool(pool, address(asset), 1, address(this), beneficiaries);
        token.transfer(alice, 100 ether);
        vm.warp(block.timestamp + 1 hours);
        asset.mint(address(this), 10 ether);
        asset.approve(address(ledger), 10 ether);
        ledger.creditStock(pool, 10 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        uint256 e = block.timestamp / 1 days;
        vm.prank(alice);
        token.claim(epochs(e), assets());
        assertEq(asset.balanceOf(alice), 5.75 ether);
        assertEq(asset.balanceOf(bob), 0);
        assertEq(token.creditedToPayout(e, alice), 5.75 ether);
        assertEq(p.paidTotal(alice, address(asset)), 5.75 ether);
        vm.warp((e + 1) * 1 days + 10 minutes);
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(p, address(oracle));
        p.configureDistributor(address(d));
        d.batchDistribute(d.openQueue(address(token), e, address(asset)), 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 5.75 ether);
        assertEq(ledger.accrued(pool, 0), 0);
    }

    function testCurrentAEligibilityFreezesPriorBReadyDebt() public {
        source.fund(9, alice, 1 ether);
        payout.stageCredit(address(source), alice, epochs(9), address(asset));
        PayoutEligibilityStatus status = new PayoutEligibilityStatus();
        controller.bindAsset(address(asset), 0);
        controller.scheduleEnable(address(status), bytes32(uint256(1)), 13);
        vm.warp(13 days);
        vm.prank(alice);
        payout.claim(assets());
        assertEq(payout.readyRaw(alice, address(asset)), 1 ether);
        assertEq(asset.balanceOf(alice), 0);
        status.allow(true);
        vm.prank(alice);
        payout.claim(assets());
        assertEq(asset.balanceOf(alice), 1 ether);
    }

    function testThreeSourcesAggregateSameAssetToTwoDollars() public {
        PayoutSource second = new PayoutSource(asset);
        PayoutSource third = new PayoutSource(asset);
        payout.configureFactory(address(this));
        payout.registerSource(address(second));
        payout.registerSource(address(third));
        second.configurePayout(address(payout));
        third.configurePayout(address(payout));
        second.add(alice);
        third.add(alice);
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 0.75 ether);
        second.fund(9, alice, 0.75 ether);
        third.fund(9, alice, 0.5 ether);
        d.batchDistribute(d.openQueue(address(source), 9, address(asset)), 32, 20, 500000);
        d.batchDistribute(d.openQueue(address(second), 9, address(asset)), 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 0);
        d.batchDistribute(d.openQueue(address(third), 9, address(asset)), 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 2 ether);
    }

    function testNewDeliveryRevisionPaysOnlyIncrementAndOldRevisionCanRescan() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 2 ether);
        uint256 old = d.openQueue(address(source), 9, address(asset));
        d.batchDistribute(old, 32, 20, 500000);
        source.fund(9, alice, 3 ether);
        uint256 fresh = d.openQueue(address(source), 9, address(asset));
        assertTrue(fresh != old);
        d.batchDistribute(fresh, 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 5 ether);
        vm.warp(block.timestamp + 15 minutes);
        d.batchDistribute(old, 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 5 ether);
        assertEq(payout.totalLiability(address(asset)), 0);
    }

    function testThirtyTwoAccountPageAndHardLimits() public {
        address last;
        for (uint256 i; i < 31; i++) {
            last = address(uint160(100 + i));
            source.add(last);
            source.fund(9, last, 2 ether);
        }
        source.fund(9, alice, 2 ether);
        source.fund(9, bob, 2 ether);
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        uint256 q = d.openQueue(address(source), 9, address(asset));
        vm.expectRevert();
        d.batchDistribute(q, 33, 20, 500000);
        vm.expectRevert();
        d.batchDistribute(q, 32, 21, 500000);
        d.batchDistribute(q, 32, 20, 500000);
        assertEq(asset.balanceOf(last), 0);
        (RewardDistributor.Queue memory beforeQ,,) = d.previewBatch(q);
        assertEq(beforeQ.cursor, 32);
        vm.warp(block.timestamp + 15 minutes);
        d.batchDistribute(q, 32, 20, 500000);
        assertEq(asset.balanceOf(last), 2 ether);
        vm.expectRevert();
        payout.stageCredit(address(source), alice, new uint256[](21), address(asset));
        vm.expectRevert();
        payout.claim(new address[](5));
    }

    function testFourAssetsClaimSeparatelyWithoutMixingRawBalances() public {
        address[] memory ss = new address[](4);
        address[] memory aa = new address[](4);
        for (uint256 i; i < 4; i++) {
            PayoutAsset a = new PayoutAsset();
            aa[i] = address(a);
            ss[i] = address(new PayoutSource(a));
        }
        RewardPayoutVault p = new RewardPayoutVault(ss, controller);
        for (uint256 i; i < 4; i++) {
            PayoutSource(ss[i]).configurePayout(address(p));
            PayoutSource(ss[i]).fund(9, alice, (i + 1) * 1 ether);
            p.stageCredit(ss[i], alice, epochs(9), aa[i]);
        }
        vm.prank(alice);
        p.claim(aa);
        for (uint256 i; i < 4; i++) {
            assertEq(PayoutAsset(aa[i]).balanceOf(alice), (i + 1) * 1 ether);
            assertEq(p.totalLiability(aa[i]), 0);
        }
    }

    function testDonationCannotCreateCreditAndStageFailureRollsBackSourceDebt() public {
        asset.mint(address(payout), 10 ether);
        payout.stageCredit(address(source), alice, epochs(9), address(asset));
        assertEq(payout.readyRaw(alice, address(asset)), 0);
        source.fund(9, alice, 1 ether);
        asset.blockRecipient(address(payout));
        vm.expectRevert();
        payout.stageCredit(address(source), alice, epochs(9), address(asset));
        assertEq(source.staged(9, alice), 0);
        assertEq(asset.balanceOf(address(source)), 1 ether);
    }

    function testStageFailureKeepsCursorAndImmediateRetry() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 2 ether);
        source.fund(9, bob, 2 ether);
        source.burnGasFor(alice);
        uint256 q = d.openQueue(address(source), 9, address(asset));
        d.batchDistribute(q, 32, 20, 300000);
        (RewardDistributor.Queue memory state, uint256 next,) = d.previewBatch(q);
        assertEq(state.cursor, 0, "failed account must remain next");
        assertEq(next, 0, "failure must not defer retry");
        source.burnGasFor(address(0));
        d.batchDistribute(q, 32, 20, 300000);
        assertEq(asset.balanceOf(alice), 2 ether);
        assertEq(asset.balanceOf(bob), 2 ether);
    }

    /// @dev r7 (design §12.3): one BatchSummary per batch with the exact raw pushed, for the payout reports.
    function testBatchSummaryTotalsPushedRaw() public {
        PayoutSource second = new PayoutSource(asset);
        payout.configureFactory(address(this));
        payout.registerSource(address(second));
        second.configurePayout(address(payout));
        second.add(alice);
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 1 ether);
        source.fund(9, bob, 3 ether);
        second.fund(9, alice, 1.5 ether);
        uint256 q1 = d.openQueue(address(second), 9, address(asset));
        vm.expectEmit(true, true, true, true, address(d));
        emit RewardDistributor.BatchSummary(q1, address(asset), 9, 0, 1, 0, 0); // $1.5 < $2: staged, not pushed
        d.batchDistribute(q1, 32, 20, 500000);
        uint256 q2 = d.openQueue(address(source), 9, address(asset));
        vm.expectEmit(true, true, true, true, address(d));
        emit RewardDistributor.BatchSummary(q2, address(asset), 9, 0, 2, 2, 5.5 ether);
        d.batchDistribute(q2, 32, 20, 500000);
        assertEq(asset.balanceOf(alice) + asset.balanceOf(bob), 5.5 ether);
    }

    function testLaterFailedStagePreservesSuccessfulPrefixWithoutDelay() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 2 ether);
        source.fund(9, bob, 2 ether);
        source.burnGasFor(bob);
        uint256 q = d.openQueue(address(source), 9, address(asset));
        d.batchDistribute(q, 32, 20, 300000);
        (RewardDistributor.Queue memory state, uint256 next,) = d.previewBatch(q);
        assertEq(state.cursor, 1);
        assertEq(next, 0);
        assertEq(asset.balanceOf(alice), 2 ether);
        source.burnGasFor(address(0));
        d.batchDistribute(q, 32, 20, 300000);
        assertEq(asset.balanceOf(alice), 2 ether);
        assertEq(asset.balanceOf(bob), 2 ether);
    }

    function testCallerCannotSelectUnderfundedStageGas() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        uint256 q = d.openQueue(address(source), 9, address(asset));
        vm.expectRevert();
        d.batchDistribute(q, 32, 20, 100000);
    }

    function testLowGasCannotRollBackProgressOrDelayQueue() public {
        source.fund(9, alice, 2 ether);
        source.fund(9, bob, 2 ether);
        source.burnGasFor(bob);
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        uint256 q = d.openQueue(address(source), 9, address(asset));
        (bool ok,) = address(d).call{gas: 600000}(abi.encodeWithSelector(d.batchDistribute.selector, q, 32, 20, 500000));
        assertTrue(ok);
        (RewardDistributor.Queue memory state, uint256 next,) = d.previewBatch(q);
        assertEq(state.cursor, 0);
        assertEq(next, 0);
        source.burnGasFor(address(0));
        d.batchDistribute(q, 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 2 ether);
        assertEq(asset.balanceOf(bob), 2 ether);
    }

    function testPreviewExposesFrozenBoundRevisionAndCursor() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        uint256 id = d.openQueue(address(source), 9, address(asset));
        source.add(address(0x1234));
        (bool ok, bytes memory data) = address(d).staticcall(abi.encodeWithSignature("previewBatch(uint256)", id));
        assertTrue(ok);
        (RewardDistributor.Queue memory q, uint256 next, uint256 day) =
            abi.decode(data, (RewardDistributor.Queue, uint256, uint256));
        assertEq(q.upperBound, 2);
        assertEq(q.cursor, 0);
        assertEq(q.revision, source.revision());
        assertEq(next, 0);
        assertEq(day, 0);
    }

    function testManualClaimRejectsGasTooLowToAttemptOneEpoch() public {
        RewardDistributor d = new RewardDistributor(payout, address(new PayoutOracle()));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(d).call{gas: 1000000}(abi.encodeCall(d.claim, (address(source), epochs(9), assets())));
        assertFalse(ok, "zero-progress low-gas claim must revert");
        assertEq(payout.readyRaw(alice, address(asset)), 0);
    }

    function testDistributorManualClaimIsolatesUnsupportedAsset() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 1 ether);
        address[] memory aa = new address[](2);
        aa[0] = address(new PayoutAsset());
        aa[1] = address(asset);
        vm.prank(alice);
        d.claim(address(source), epochs(9), aa);
        assertEq(asset.balanceOf(alice), 1 ether);
        assertEq(payout.readyRaw(alice, address(asset)), 0);
    }

    function testDistributorManualClaimStagesTwentyEpochsBelowThreshold() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        uint256[] memory es = new uint256[](20);
        for (uint256 i; i < 20; i++) {
            es[i] = i;
            source.fund(i, alice, 0.05 ether);
        }
        vm.prank(alice);
        (bool ok,) = address(d)
            .call(abi.encodeWithSignature("claim(address,uint256[],address[])", address(source), es, assets()));
        assertTrue(ok);
        assertEq(asset.balanceOf(alice), 1 ether);
    }

    function testQueueRejectsUnrelatedAsset() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        vm.expectRevert();
        d.openQueue(address(source), 9, address(0xBAD));
    }

    function testOnlyFixedFactoryCanRegisterFutureSources() public {
        PayoutSource second = new PayoutSource(asset);
        vm.prank(alice);
        (bool ok,) = address(payout).call(abi.encodeWithSignature("configureFactory(address)", address(this)));
        assertFalse(ok);
        (ok,) = address(payout).call(abi.encodeWithSignature("configureFactory(address)", address(this)));
        assertTrue(ok);
        vm.prank(alice);
        (ok,) = address(payout).call(abi.encodeWithSignature("registerSource(address)", address(second)));
        assertFalse(ok);
        (ok,) = address(payout).call(abi.encodeWithSignature("registerSource(address)", address(second)));
        assertTrue(ok);
        assertTrue(payout.trustedSource(address(second)));
        (ok,) = address(payout).call(abi.encodeWithSignature("configureFactory(address)", address(second)));
        assertFalse(ok);
        PayoutSource unknown = new PayoutSource(asset);
        vm.expectRevert();
        payout.stageCredit(address(unknown), alice, epochs(9), address(asset));
    }

    function testPayoutUsesUnifiedControllerRatherThanUnrelatedSourceGate() public {
        source.fund(9, alice, 1 ether);
        payout.stageCredit(address(source), alice, epochs(9), address(asset));
        source.deny(alice, true);
        vm.prank(alice);
        payout.claim(assets());
        assertEq(asset.balanceOf(alice), 1 ether);
    }

    function testMultiAssetClaimIsolatesBadToken() public {
        PayoutAsset good = new PayoutAsset();
        PayoutSource second = new PayoutSource(good);
        address[] memory ss = new address[](2);
        ss[0] = address(source);
        ss[1] = address(second);
        RewardPayoutVault p = new RewardPayoutVault(ss, controller);
        PayoutSource first = new PayoutSource(asset);
        ss[0] = address(first);
        p = new RewardPayoutVault(ss, controller);
        first.configurePayout(address(p));
        second.configurePayout(address(p));
        first.fund(9, alice, 1 ether);
        second.fund(9, alice, 1 ether);
        p.stageCredit(address(first), alice, epochs(9), address(asset));
        p.stageCredit(address(second), alice, epochs(9), address(good));
        address[] memory aa = new address[](2);
        aa[0] = address(asset);
        aa[1] = address(good);
        asset.blockRecipient(alice);
        vm.prank(alice);
        p.claim(aa);
        assertEq(good.balanceOf(alice), 1 ether);
        assertEq(p.readyRaw(alice, address(asset)), 1 ether);
    }

    function testDailyStartAnd15MinuteRetryRecoverBlockedPayment() public {
        vm.warp(10 days + 9 minutes);
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 2 ether);
        uint256 q = d.openQueue(address(source), 9, address(asset));
        vm.expectRevert();
        d.batchDistribute(q, 32, 20, 500000);
        vm.warp(10 days + 10 minutes);
        asset.blockRecipient(alice);
        d.batchDistribute(q, 32, 20, 500000);
        assertEq(payout.readyRaw(alice, address(asset)), 2 ether);
        asset.blockRecipient(address(0));
        vm.expectRevert();
        d.batchDistribute(q, 32, 20, 500000);
        vm.warp(10 days + 25 minutes);
        d.batchDistribute(q, 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 2 ether);
    }

    function testAutomaticCostPolicyRequires48HoursAndCannotRestrictClaim() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        (bool ok,) = address(d).call(abi.encodeWithSignature("schedulePolicy(uint256,uint256)", 0.02 ether, 1 hours));
        assertTrue(ok);
        (ok,) = address(d).call(abi.encodeWithSignature("applyPolicy()"));
        assertFalse(ok);
        vm.warp(block.timestamp + 48 hours);
        (ok,) = address(d).call(abi.encodeWithSignature("applyPolicy()"));
        assertTrue(ok);
        oracle.set(1 ether, block.timestamp);
        source.fund(9, alice, 3 ether);
        d.batchDistribute(d.openQueue(address(source), 9, address(asset)), 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 0);
        vm.prank(alice);
        payout.claim(assets());
        assertEq(asset.balanceOf(alice), 3 ether);
    }

    function testStaleOracleOnlyStopsAutomaticPayment() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 2 ether);
        assertEq(d.oracleMaxAge(), 2 hours, "r7: hourly oracle relay");
        oracle.set(1 ether, block.timestamp - d.oracleMaxAge() - 1);
        d.batchDistribute(d.openQueue(address(source), 9, address(asset)), 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 0);
        vm.prank(alice);
        payout.claim(assets());
        assertEq(asset.balanceOf(alice), 2 ether);
    }

    function testThresholdAggregatesTwoEpochsBeforePushing() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(8, alice, 1 ether);
        source.fund(9, alice, 1 ether);
        d.batchDistribute(d.openQueue(address(source), 8, address(asset)), 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 0);
        assertEq(payout.readyRaw(alice, address(asset)), 1 ether);
        d.batchDistribute(d.openQueue(address(source), 9, address(asset)), 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 2 ether);
    }

    function testBatchBadRecipientDoesNotBlockNextAndKeepsStagedDebt() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 2 ether);
        source.fund(9, bob, 3 ether);
        asset.blockRecipient(alice);
        uint256 q = d.openQueue(address(source), 9, address(asset));
        d.batchDistribute(q, 32, 20, 500000);
        assertEq(asset.balanceOf(bob), 3 ether);
        assertEq(payout.readyRaw(alice, address(asset)), 2 ether);
        assertEq(payout.paidTotal(alice, address(asset)), 0);
    }

    function testBatchUsesChainParticipantsAndFixedRecipient() public {
        PayoutOracle oracle = new PayoutOracle();
        RewardDistributor d = new RewardDistributor(payout, address(oracle));
        payout.configureDistributor(address(d));
        source.fund(9, alice, 2 ether);
        source.fund(9, bob, 3 ether);
        uint256 q = d.openQueue(address(source), 9, address(asset));
        d.batchDistribute(q, 32, 20, 500000);
        assertEq(asset.balanceOf(alice), 2 ether);
        assertEq(asset.balanceOf(bob), 3 ether);
        assertEq(asset.balanceOf(address(this)), 0);
    }

    function testSmallClaimAndBlockedTransferPreserveDebt() public {
        source.fund(9, alice, 0.5 ether);
        payout.stageCredit(address(source), alice, epochs(9), address(asset));
        asset.blockRecipient(alice);
        vm.prank(alice);
        (bool ok,) = address(payout).call(abi.encodeWithSignature("claim(address[])", assets()));
        assertTrue(ok);
        assertEq(payout.readyRaw(alice, address(asset)), 0.5 ether);
        asset.blockRecipient(address(0));
        vm.prank(alice);
        (ok,) = address(payout).call(abi.encodeWithSignature("claim(address[])", assets()));
        assertTrue(ok);
        assertEq(asset.balanceOf(alice), 0.5 ether);
        assertEq(payout.paidTotal(alice, address(asset)), 0.5 ether);
    }

    function assets() internal view returns (address[] memory a) {
        a = new address[](1);
        a[0] = address(asset);
    }

    function testStageMovesRealAssetsOnceWithoutPayingRecipient() public {
        source.fund(9, alice, 1 ether);
        payout.stageCredit(address(source), alice, epochs(9), address(asset));
        assertEq(payout.readyRaw(alice, address(asset)), 1 ether);
        assertEq(asset.balanceOf(address(payout)), 1 ether);
        assertEq(asset.balanceOf(alice), 0);
        payout.stageCredit(address(source), alice, epochs(9), address(asset));
        assertEq(payout.readyRaw(alice, address(asset)), 1 ether);
    }
}

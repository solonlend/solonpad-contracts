// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SolonStakingV2} from "../../../../src/v3/SolonStakingV2.sol";
import {StakingRewardSource, StakingRewardSourceFactory} from "../../../../src/v3/StakingRewardSource.sol";
import {EligibilityController} from "../../../../src/v3/EligibilityController.sol";
import {EligibilityRegistry} from "../../../../src/v3/EligibilityRegistry.sol";
import {V3FeeLedger} from "../../../../src/v3/V3FeeLedger.sol";
import {CovBTaxToken, CovBSink} from "./CovBHelpers.sol";

/// @notice Round-manager stand-in that seals a StakingRewardSource and can reject the native budget.
contract CovBRoundsMgr {
    bool public reject;

    function setReject(bool r) external {
        reject = r;
    }

    function seal(StakingRewardSource s, uint256 epoch, uint8 cohort) external returns (uint256, uint256, uint8) {
        return s.sealReward(epoch, cohort);
    }

    receive() external payable {
        require(!reject, "mgr rejects");
    }
}

/// @notice Holder-token policy stand-in with no per-epoch asset and no schedule (default asset path).
contract CovBHolder {
    address public defaultRewardAsset;

    constructor(address a) {
        defaultRewardAsset = a;
    }

    function queueAsset(uint256) external pure returns (address) {
        return address(0);
    }

    function assetSchedule() external pure returns (address) {
        return address(0);
    }

    function rewardPolicy(uint256, uint8) external pure returns (bytes32, uint32, bytes32, uint8) {
        return (keccak256("id"), 3, keccak256("pol"), 0);
    }
}

/// @notice Minimal V3FeeLedger read surface for StakingRewardSourceFactory.resolvePool.
contract CovBLedgerView {
    address public holder;
    address public staking;
    uint8 public kind;

    constructor(address h, address s) {
        holder = h;
        staking = s;
    }

    function setKind(uint8 k) external {
        kind = k;
    }

    function legacyHolderPool(bytes32) external pure returns (bytes32) {
        return 0;
    }

    function poolInfo(bytes32) external view returns (V3FeeLedger.Pool memory p) {
        p.settlementKind = kind;
        p.beneficiaries[0] = holder;
        p.beneficiaries[3] = staking;
    }
}

contract CovBSchedule {
    address[] public assets;

    constructor(address[] memory a) {
        assets = a;
    }

    function policyCount() external view returns (uint256) {
        return assets.length;
    }

    function policyAt(uint256 i) external view returns (address, bytes32, uint32, bytes32) {
        return (assets[i], bytes32(0), 0, bytes32(0));
    }

    function resolve(uint256) external view returns (address, bytes32, uint32, bytes32) {
        return (assets[0], bytes32(0), 0, bytes32(0));
    }
}

/// @notice This test contract is the staking `ledger`, `configurator`, protocol-desk and V2 notifier.
contract CovBStakingTest is Test {
    CovBTaxToken solon;
    CovBTaxToken stock;
    CovBTaxToken other;
    SolonStakingV2 staking;
    EligibilityController controller;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    // IV3FeeLedger.claim behaviour: 0 = return false, 1 = return true without paying, 2 = pay and return true.
    uint8 claimMode;
    bool claimNative;

    function claim(bytes32, uint8, uint256 amount) external returns (bool) {
        if (claimMode == 0) return false;
        if (claimMode == 2) {
            if (claimNative) {
                (bool ok,) = payable(msg.sender).call{value: amount}("");
                require(ok);
            } else {
                stock.transfer(msg.sender, amount);
            }
        }
        return true;
    }

    function legacyHolderPool(bytes32) external pure returns (bytes32) {
        return 0;
    }

    receive() external payable {}

    function setUp() public {
        vm.warp(10 days);
        solon = new CovBTaxToken();
        stock = new CovBTaxToken();
        other = new CovBTaxToken();
        controller = new EligibilityController(address(this));
        staking = new SolonStakingV2(address(solon), address(this), controller);
    }

    function _stake(address who, uint256 amount) internal {
        solon.mint(who, amount);
        vm.startPrank(who);
        solon.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _assets(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _v2Funded() internal returns (bytes32 key, address src) {
        staking.configureV2(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        _stake(alice, 100 ether);
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 100 ether);
        staking.notifyV2Budget{value: 100 ether}(keccak256("lot"), 100 ether);
        key = staking.v2Lane();
        src = staking.createEntrySource(key);
    }

    function _protocolStockLane(uint256 credit) internal returns (bytes32 pool, bytes32 key, address src) {
        staking.configureProtocolDesk(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        _stake(alice, 100 ether);
        vm.warp(10 days + 1 hours);
        pool = bytes32(uint256(99));
        staking.notifyProtocolDeskCredit(pool, 10, address(stock), 1, credit * 1e27);
        key = staking.laneKey(staking.protocolSource(pool), address(stock), 1);
        src = staking.createEntrySource(key);
    }

    // ---------------------------------------------------------------- views / snapshots

    /// lines 76-81 (never-called views), 131 (unsealed epoch), 137 (both binary-search arms).
    function testParticipantIndexAndQueueSnapshot() public {
        _stake(alice, 100 ether); // day 10
        vm.warp(12 days);
        _stake(bob, 50 ether); // day 12
        vm.warp(13 days);
        assertEq(staking.participantCount(), 2);
        assertEq(staking.participantAt(0), alice);
        assertEq(staking.participantAt(1), bob);
        bytes32 key = keccak256("any lane");
        (uint256 upper, uint256 revision) = staking.sourceQueueSnapshot(key, 10);
        assertEq(upper, 1, "bob joined after epoch 10");
        assertEq(revision, 1);
        (upper,) = staking.sourceQueueSnapshot(key, 12);
        assertEq(upper, 2);
        (upper,) = staking.sourceQueueSnapshot(key, 9);
        assertEq(upper, 0);
        vm.expectRevert(SolonStakingV2.UnsealedEpochError.selector);
        staking.sourceQueueSnapshot(key, 13);
    }

    /// line 121 + StakingRewardSource never-called views and guards (43, 67, 78, 85, 102).
    function testDirectSourceViewsAndGuards() public {
        (bytes32 pool, bytes32 key, address srcAddr) = _protocolStockLane(100 ether);
        StakingRewardSource src = StakingRewardSource(payable(srcAddr));
        assertEq(src.poolId(), staking.protocolSource(pool));
        assertEq(src.settlementKind(), 1);
        assertEq(src.queueAsset(10), address(stock));
        assertEq(staking.sourceAsset(key, 10), address(stock));
        assertEq(src.creditOf(alice, 10, 0), 100 ether * 1e27);
        vm.expectRevert(bytes("credit cohort"));
        src.creditOf(alice, 10, 1);
        assertEq(src.lastFeeAt(), 10 days + 1 hours);
        assertEq(src.participantAt(0), alice);
        assertTrue(src.deliveryAllowed(alice, address(stock)));
        assertTrue(staking.deliveryAllowed(alice, address(stock)));
        (bytes32 aid, uint32 ver, bytes32 pol, uint8 mode) = src.rewardPolicy(10, 0);
        assertEq(aid, keccak256("stock"));
        assertEq(ver, 1);
        assertEq(pol, keccak256("price"));
        assertEq(mode, 0);
        vm.expectRevert(bytes("cohort"));
        src.rewardPolicy(10, 1);
        (bool ok, bytes memory data) = address(src).call{value: 1}("");
        assertFalse(ok);
        assertEq(data, abi.encodeWithSignature("Error(string)", "staking"));
        vm.expectRevert(bytes("payout"));
        src.stageCredit(alice, _one(10), address(stock));
        // Other asset: skipped without touching the (unset) payout.
        vm.prank(alice);
        src.claim(_one(10), _assets(address(other)));
        assertEq(stock.balanceOf(alice), 0);
    }

    /// StakingRewardSource line 75: PurchaseStock (kind 0) lanes cannot be claimed directly.
    function testPurchaseLaneCannotClaimDirect() public {
        (, address src) = _v2Funded();
        vm.expectRevert(bytes("claim purchase through reward vault"));
        StakingRewardSource(payable(src)).claim(_one(10), _assets(address(stock)));
    }

    /// StakingRewardSource lines 137, 279: factory hooks are staking-only.
    function testFactoryHooksStakingOnly() public {
        StakingRewardSourceFactory f = staking.sourceFactory();
        vm.expectRevert(bytes("staking"));
        f.checkpointCarry(bytes32(0), true, block.timestamp, 1);
        vm.expectRevert(bytes("staking"));
        f.create(bytes32(0));
    }

    /// StakingRewardSource line 167: holder with neither per-epoch asset nor schedule falls back to the default asset.
    function testFactoryResolvePoolDefaultAsset() public {
        StakingRewardSourceFactory f = new StakingRewardSourceFactory(address(this));
        CovBHolder holder = new CovBHolder(address(stock));
        CovBLedgerView ledger = new CovBLedgerView(address(holder), address(this));
        (address asset, bytes32 id, uint32 version, bytes32 policy) =
            f.resolvePool(address(ledger), bytes32(uint256(1)), address(0), 0, 10);
        assertEq(asset, address(stock));
        assertEq(id, keccak256("id"));
        assertEq(version, 3);
        assertEq(policy, keccak256("pol"));
        ledger.setKind(1);
        vm.expectRevert(bytes("ledger source"));
        f.resolvePool(address(ledger), bytes32(uint256(1)), address(0), 0, 10);
    }

    /// StakingRewardSource lines 202, 227: schedule configuration guards and basket mask of bound assets only.
    function testFactoryConfigureSchedules() public {
        StakingRewardSourceFactory f = new StakingRewardSourceFactory(address(this));
        controller.bindAsset(address(stock), 2);
        address[] memory list = new address[](2);
        (list[0], list[1]) = (address(stock), address(other));
        CovBSchedule sched = new CovBSchedule(list);
        vm.expectRevert(bytes("schedules"));
        f.configureSchedules(address(0), address(0), address(controller));
        vm.expectRevert(bytes("schedules"));
        f.configureSchedules(address(0xD00D), address(0), address(controller)); // no code
        vm.prank(bob);
        vm.expectRevert(bytes("schedules"));
        f.configureSchedules(address(sched), address(0), address(controller));
        assertEq(f.configureSchedules(address(sched), address(0), address(controller)), uint256(1) << 2);
        assertEq(f.v2Schedule(), address(sched));
        vm.expectRevert(bytes("schedules"));
        f.configureSchedules(address(sched), address(0), address(controller));
    }

    // ---------------------------------------------------------------- sealSource (PurchaseStock lanes)

    /// lines 149-169: seal state, empty budget and the funded happy path.
    function testSealSourceStateAndEmptyBudget() public {
        (bytes32 key, address src) = _v2Funded();
        vm.expectRevert(SolonStakingV2.SealStateError.selector);
        staking.sealSource(key, 10); // not the entry source
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.SealStateError.selector);
        staking.sealSource(key, 10); // epoch still open
        vm.warp(11 days);
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.EmptyBudgetError.selector);
        staking.sealSource(key, 9);
        vm.prank(src);
        (uint256 budget, uint256 total, uint8 kind) = staking.sealSource(key, 10);
        assertEq(budget, 100 ether);
        assertEq(total, 100 ether * 1e27);
        assertEq(kind, 0);
        assertEq(src.balance, 100 ether);
        assertEq(address(staking).balance, 0);
        assertEq(staking.nativeAvailable(key), 0);
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.SealStateError.selector);
        staking.sealSource(key, 10);
    }

    /// line 154: a long carry backlog must be checkpointed before sealing.
    function testSealSourceRequiresCarryCheckpoint() public {
        (bytes32 key, address src) = _v2Funded();
        solon.mint(alice, 300);
        vm.startPrank(alice);
        solon.approve(address(staking), 300);
        for (uint256 i; i < 300; ++i) {
            staking.stake(1);
        }
        vm.stopPrank();
        vm.warp(11 days);
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.CheckpointCarryFirstError.selector);
        staking.sealSource(key, 10);
        assertFalse(staking.releaseCarry(key, 256));
        assertTrue(staking.releaseCarry(key, 256));
        vm.prank(src);
        (uint256 budget,,) = staking.sealSource(key, 10);
        assertEq(budget, 100 ether);
    }

    /// lines 161-162: ledger-funded native lanes require a successful, exact ledger claim.
    function testSealSourceLedgerClaimChecks() public {
        bytes32 pool = bytes32(uint256(5));
        staking.configureSource(pool, address(0), 0, address(stock), keccak256("stock"), 1, keccak256("price"));
        bytes32 key = staking.laneKey(pool, address(stock), 0);
        _stake(alice, 100 ether);
        vm.warp(10 days + 1 hours);
        staking.onFeeCredit(pool, address(0), 0, 50 ether);
        address src = staking.createEntrySource(key);
        vm.warp(11 days);
        claimMode = 0;
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.LedgerClaimError.selector);
        staking.sealSource(key, 10);
        claimMode = 1;
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.LedgerDeltaError.selector);
        staking.sealSource(key, 10);
        assertFalse(staking.rewardSealed(key, 10));
        claimMode = 2;
        claimNative = true;
        vm.deal(address(this), 50 ether);
        vm.prank(src);
        (uint256 budget,,) = staking.sealSource(key, 10);
        assertEq(budget, 50 ether);
        assertEq(src.balance, 50 ether);
        assertEq(address(staking).balance, 0);
    }

    /// lines 165, 662: protocol native credit must be funded (exact msg.value) before it can be sealed.
    function testSealSourceBudgetUnfundedAndNativeFunding() public {
        staking.configureProtocolDesk(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        _stake(alice, 100 ether);
        vm.warp(10 days + 1 hours);
        bytes32 pool = bytes32(uint256(7));
        staking.notifyProtocolDeskCredit(pool, 10, address(0), 0, 40 ether * 1e27);
        bytes32 key = staking.laneKey(staking.protocolSource(pool), address(0), 0);
        address src = staking.createEntrySource(key);
        vm.deal(address(this), 100 ether);
        vm.expectRevert(SolonStakingV2.NativeDeltaError.selector);
        staking.fundProtocolDesk{value: 39 ether}(pool, 10, address(0), 0, 40 ether);
        vm.warp(11 days);
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.BudgetUnfundedError.selector);
        staking.sealSource(key, 10);
        staking.fundProtocolDesk{value: 40 ether}(pool, 10, address(0), 0, 40 ether);
        assertEq(staking.nativeAvailable(key), 40 ether);
        vm.prank(src);
        (uint256 budget,,) = staking.sealSource(key, 10);
        assertEq(budget, 40 ether);
        assertEq(src.balance, 40 ether);
    }

    /// StakingRewardSource lines 48, 51: only the rounds manager seals cohort 0, and must accept the budget.
    function testSourceSealRewardManagerAndFunding() public {
        (, address srcAddr) = _v2Funded();
        StakingRewardSource src = StakingRewardSource(payable(srcAddr));
        CovBRoundsMgr mgr = new CovBRoundsMgr();
        staking.configureRewards(address(mgr), address(new CovBSink()));
        vm.warp(11 days);
        vm.expectRevert(bytes("manager/cohort"));
        src.sealReward(10, 0);
        vm.expectRevert(bytes("manager/cohort"));
        mgr.seal(src, 10, 1);
        mgr.setReject(true);
        vm.expectRevert(bytes("round funding"));
        mgr.seal(src, 10, 0);
        assertFalse(staking.rewardSealed(staking.v2Lane(), 10));
        mgr.setReject(false);
        (uint256 budget,,) = mgr.seal(src, 10, 0);
        assertEq(budget, 100 ether);
        assertEq(address(mgr).balance, 100 ether);
        assertEq(address(src).balance, 0);
    }

    // ---------------------------------------------------------------- stageSource (DirectStock lanes)

    /// lines 247, 252: staging requires funded coverage and an exact transfer to payout.
    function testStageSourceCoverageAndDelta() public {
        (bytes32 pool, bytes32 key, address src) = _protocolStockLane(100 ether);
        CovBSink sink = new CovBSink();
        staking.configureRewards(address(this), address(sink));
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.SourceCoverageError.selector);
        staking.stageSource(key, alice, _one(10), address(stock));
        stock.mint(address(this), 100 ether);
        stock.approve(address(staking), 100 ether);
        staking.fundProtocolDesk(pool, 10, address(stock), 1, 100 ether);
        stock.setTaxTo(address(sink), true);
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.StageDeltaError.selector);
        staking.stageSource(key, alice, _one(10), address(stock));
        stock.setTaxTo(address(sink), false);
        vm.prank(src);
        assertEq(staking.stageSource(key, alice, _one(10), address(stock)), 100 ether);
        assertEq(stock.balanceOf(address(sink)), 100 ether);
        assertEq(staking.totalStaged(key), 100 ether);
        vm.prank(src);
        assertEq(staking.stageSource(key, alice, _one(10), address(stock)), 0, "no double stage");
    }

    /// line 230: a long carry backlog must be checkpointed before staging.
    function testStageSourceRequiresCarryCheckpoint() public {
        (bytes32 pool, bytes32 key, address src) = _protocolStockLane(100 ether);
        stock.mint(address(this), 100 ether);
        stock.approve(address(staking), 100 ether);
        staking.fundProtocolDesk(pool, 10, address(stock), 1, 100 ether);
        staking.configureRewards(address(this), address(new CovBSink()));
        solon.mint(alice, 300);
        vm.startPrank(alice);
        solon.approve(address(staking), 300);
        for (uint256 i; i < 300; ++i) {
            staking.stake(1);
        }
        vm.stopPrank();
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.CheckpointCarryFirstError.selector);
        staking.stageSource(key, alice, _one(10), address(stock));
        staking.releaseCarry(key, 256);
        vm.prank(src);
        assertEq(staking.stageSource(key, alice, _one(10), address(stock)), 100 ether);
    }

    /// lines 243-244: ledger-funded stock lanes require a successful, exact ledger claim.
    function testStageSourceLedgerClaimChecks() public {
        bytes32 pool = bytes32(uint256(8));
        staking.configureSource(pool, address(stock), 1, address(stock), 0, 0, 0);
        bytes32 key = staking.laneKey(pool, address(stock), 1);
        _stake(alice, 100 ether);
        vm.warp(10 days + 1 hours);
        staking.onFeeCredit(pool, address(stock), 1, 30 ether);
        address src = staking.createEntrySource(key);
        CovBSink sink = new CovBSink();
        staking.configureRewards(address(this), address(sink));
        claimMode = 0;
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.LedgerClaimError.selector);
        staking.stageSource(key, alice, _one(10), address(stock));
        claimMode = 1;
        vm.prank(src);
        vm.expectRevert(SolonStakingV2.LedgerDeltaError.selector);
        staking.stageSource(key, alice, _one(10), address(stock));
        claimMode = 2;
        stock.mint(address(this), 30 ether);
        vm.prank(src);
        assertEq(staking.stageSource(key, alice, _one(10), address(stock)), 30 ether);
        assertEq(stock.balanceOf(address(sink)), 30 ether);
        assertEq(staking.fundedAmount(key), 30 ether);
    }

    // ---------------------------------------------------------------- protocol desk / configuration

    /// lines 665, 668: stock funding carries no native and must arrive exactly.
    function testFundProtocolDeskStockChecks() public {
        (bytes32 pool, bytes32 key,) = _protocolStockLane(10 ether);
        stock.mint(address(this), 10 ether);
        stock.approve(address(staking), 10 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(SolonStakingV2.StockFundingError.selector);
        staking.fundProtocolDesk{value: 1}(pool, 10, address(stock), 1, 10 ether);
        stock.setTaxTo(address(staking), true);
        vm.expectRevert(SolonStakingV2.StockDeltaError.selector);
        staking.fundProtocolDesk(pool, 10, address(stock), 1, 10 ether);
        stock.setTaxTo(address(staking), false);
        staking.fundProtocolDesk(pool, 10, address(stock), 1, 10 ether);
        assertEq(staking.fundedAmount(key), 10 ether);
        assertEq(stock.balanceOf(address(staking)), 10 ether);
    }

    /// line 631: zero credit notifications are rejected.
    function testNotifyZeroAmountRejected() public {
        staking.configureProtocolDesk(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        vm.expectRevert(SolonStakingV2.AmountError.selector);
        staking.notifyProtocolDeskCredit(bytes32(uint256(1)), 10, address(stock), 1, 0);
        assertEq(staking.sequence(), 0);
    }

    /// lines 499, 500, 521: configurator-only, one lane per pool, and no collision with an existing lane key.
    function testConfigureSourceGuards() public {
        bytes32 pool = bytes32(uint256(1));
        vm.prank(bob);
        vm.expectRevert(SolonStakingV2.ConfiguratorError.selector);
        staking.configureSource(pool, address(stock), 1, address(stock), 0, 0, 0);
        staking.configureSource(pool, address(stock), 1, address(stock), 0, 0, 0);
        vm.expectRevert(SolonStakingV2.ConfiguredError.selector);
        staking.configureSource(pool, address(other), 1, address(other), 0, 0, 0);
        staking.configureProtocolDesk(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        bytes32 deskPool = bytes32(uint256(2));
        staking.notifyProtocolDeskCredit(deskPool, 10, address(stock), 1, 1e27);
        bytes32 ps = staking.protocolSource(deskPool);
        vm.expectRevert(SolonStakingV2.ConfiguredError.selector);
        staking.configureSource(ps, address(stock), 1, address(stock), 0, 0, 0);
        assertEq(staking.poolLane(ps), bytes32(0));
        assertFalse(staking.ledgerLane(staking.laneKey(ps, address(stock), 1)));
    }

    /// lines 589, 601: protocol desk configuration guards; a bound asset joins the required basket.
    function testProtocolDeskConfigGuardsAndMask() public {
        controller.bindAsset(address(stock), 3);
        vm.prank(bob);
        vm.expectRevert(SolonStakingV2.ProtocolConfigurationError.selector);
        staking.configureProtocolDesk(address(this), address(stock), keccak256("s"), 1, keccak256("p"));
        vm.expectRevert(SolonStakingV2.ProtocolConfigurationError.selector);
        staking.configureProtocolDesk(address(this), address(solon), keccak256("s"), 1, keccak256("p"));
        vm.expectRevert(SolonStakingV2.ProtocolConfigurationError.selector);
        staking.configureProtocolDesk(address(0xD00D), address(stock), keccak256("s"), 1, keccak256("p"));
        staking.configureProtocolDesk(address(this), address(stock), keccak256("s"), 1, keccak256("p"));
        assertEq(staking.requiredAssetMask(), uint256(1) << 3);
        assertEq(staking.protocolDesk(), address(this));
        vm.expectRevert(SolonStakingV2.ProtocolConfigurationError.selector);
        staking.configureProtocolDesk(address(this), address(stock), keccak256("s"), 1, keccak256("p"));
    }

    /// lines 173, 193, 300, 677: ledger-only receive/onFeeCredit, registry-only notification, known lanes only.
    function testCallerGuards() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok, bytes memory data) = address(staking).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(data), SolonStakingV2.LedgerError.selector);
        vm.deal(address(this), 1);
        (ok,) = address(staking).call{value: 1}("");
        assertTrue(ok, "ledger may fund");
        vm.prank(bob);
        vm.expectRevert(SolonStakingV2.RegistryError.selector);
        staking.onEligibilityChange(alice);
        vm.prank(bob);
        vm.expectRevert(SolonStakingV2.LedgerError.selector);
        staking.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 1);
        vm.expectRevert(SolonStakingV2.SourceError.selector);
        staking.createEntrySource(bytes32(uint256(123)));
    }

    // ---------------------------------------------------------------- stake / principal

    /// lines 787-806: beneficiary, consent deadline/signature, zero amount, and self-stake without consent.
    function testStakeArgumentGuards() public {
        solon.mint(alice, 100);
        vm.startPrank(alice);
        solon.approve(address(staking), 100);
        vm.expectRevert(SolonStakingV2.BeneficiaryError.selector);
        staking.stake(1, address(0), 0, "");
        vm.expectRevert(SolonStakingV2.ConsentExpiredError.selector);
        staking.stake(1, bob, block.timestamp - 1, "");
        vm.expectRevert(SolonStakingV2.BeneficiaryConsentError.selector);
        staking.stake(1, bob, block.timestamp, new bytes(65));
        vm.expectRevert(SolonStakingV2.AmountError.selector);
        staking.stake(0);
        vm.expectRevert(SolonStakingV2.AmountError.selector);
        staking.stake(0, alice, 0, "");
        staking.stake(10, alice, 0, ""); // self: no consent, no deadline
        vm.stopPrank();
        assertEq(staking.stakedOf(alice), 10);
        assertEq(staking.stakedOf(bob), 0);
        assertEq(staking.consentNonces(bob), 0);
        assertEq(solon.balanceOf(address(staking)), 10);
    }

    /// line 806: principal must arrive exactly (lossy SOLON rejected).
    function testPrincipalMustArriveExactly() public {
        CovBTaxToken taxed = new CovBTaxToken();
        SolonStakingV2 s2 = new SolonStakingV2(address(taxed), address(this), controller);
        taxed.mint(alice, 10 ether);
        taxed.setTaxTo(address(s2), true);
        vm.startPrank(alice);
        taxed.approve(address(s2), 10 ether);
        vm.expectRevert(SolonStakingV2.PrincipalDeltaError.selector);
        s2.stake(1 ether);
        vm.stopPrank();
        assertEq(s2.stakedOf(alice), 0);
        assertEq(taxed.balanceOf(alice), 10 ether);
    }

    // ---------------------------------------------------------------- A mode

    function _sig(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _credential(EligibilityRegistry registry, uint256 pk, uint256 expiry) internal returns (address user) {
        user = vm.addr(pk);
        EligibilityRegistry.Attestation memory a = EligibilityRegistry.Attestation(
            block.chainid,
            address(registry),
            user,
            keccak256("beneficiary"),
            1,
            1,
            keccak256("policy"),
            vm.getBlockTimestamp(),
            expiry,
            registry.nonces(user),
            keccak256("terms")
        );
        bytes32 id = registry.digest(a);
        address[] memory issuers = new address[](2);
        issuers[0] = vm.addr(1);
        issuers[1] = vm.addr(2);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sig(1, id);
        sigs[1] = _sig(2, id);
        registry.register(a, issuers, sigs, _sig(pk, id));
    }

    /// lines 346, 524-525, 547, 589: A-mode re-weigh of an existing weight, frozen basket for new lanes,
    /// and configuration that is closed once A is effective.
    function testAModeReweighAndFrozenConfiguration() public {
        controller.bindAsset(address(stock), 0);
        staking.configureSource(bytes32(uint256(1)), address(stock), 1, address(stock), 0, 0, 0);
        assertEq(staking.requiredAssetMask(), 1);
        EligibilityRegistry registry = new EligibilityRegistry(address(this));
        registry.scheduleIssuer(vm.addr(1), true);
        registry.scheduleIssuer(vm.addr(2), true);
        registry.setFixedModules(address(0), address(staking));
        controller.scheduleEnable(address(registry), keccak256("policy"), 13);
        vm.warp(13 days);
        registry.executeIssuer(vm.addr(1));
        registry.executeIssuer(vm.addr(2));
        address user = _credential(registry, 101, 30 days);
        _stake(user, 100 ether);
        assertEq(staking.eligible(user), 100 ether);
        _stake(user, 50 ether); // previous weight != 0 in generation 1: tree sub + add
        assertEq(staking.eligible(user), 150 ether);
        assertEq(staking.effectiveEligible(), 150 ether);
        assertEq(staking.totalEligible(), 150 ether);
        // New lane on a bound, required asset is allowed in A mode.
        staking.configureSource(bytes32(uint256(2)), address(stock), 1, address(stock), 0, 0, 0);
        // A new, unbound asset cannot widen the frozen basket.
        vm.expectRevert(SolonStakingV2.BasketFrozenError.selector);
        staking.configureSource(bytes32(uint256(3)), address(other), 1, address(other), 0, 0, 0);
        vm.expectRevert(SolonStakingV2.RewardConfigurationError.selector);
        staking.configureEligibilityAssets(new address[](0));
        vm.expectRevert(SolonStakingV2.ProtocolConfigurationError.selector);
        staking.configureProtocolDesk(address(this), address(stock), keccak256("s"), 1, keccak256("p"));
        assertEq(staking.requiredAssetMask(), 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3RewardToken} from "../../../../src/v3/V3RewardToken.sol";
import {RewardAssetSchedule} from "../../../../src/v3/RewardAssetSchedule.sol";
import {EligibilityController} from "../../../../src/v3/EligibilityController.sol";
import {EligibilityRegistry} from "../../../../src/v3/EligibilityRegistry.sol";
import {RewardAsset, InexactPayoutAsset} from "../../V3RewardToken.t.sol";

/// @dev Misbehaving-schedule stand-in: configurable count and a resolve() that may return no asset.
contract CovASchedule {
    uint256 public policyCount;
    address public asset;
    bool public nullResolve;

    constructor(uint256 count, address asset_, bool nullResolve_) {
        policyCount = count;
        asset = asset_;
        nullResolve = nullResolve_;
    }

    function policyAt(uint256) external view returns (address, bytes32, uint32, bytes32) {
        return (asset, bytes32("id"), 1, bytes32("p"));
    }

    function resolve(uint256) external view returns (address, bytes32, uint32, bytes32) {
        return (nullResolve ? address(0) : asset, bytes32("id"), 1, bytes32("p"));
    }

    function nextRoundAt(uint256 epoch) external pure returns (uint256) {
        return (epoch + 1) * 1 days;
    }
}

/// @notice Branch coverage for V3RewardToken (default B mode). The test contract plays the
/// configurator, the strategy (holds the supply), the fee ledger and, where needed, rounds manager / payout.
contract CovARewardTokenTest is Test {
    V3RewardToken token;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    bytes32 constant POOL = bytes32(uint256(1));

    // ledger-claim behaviour: 0 honest, 1 return false, 2 short-deliver by one unit
    uint8 claimMode;
    address claimAsset; // 0 = native
    bool rejectNative;

    function claim(bytes32, uint8, uint256 amount) external returns (bool) {
        if (claimMode == 1) return false;
        uint256 send = claimMode == 2 ? amount - 1 : amount;
        if (claimAsset == address(0)) {
            (bool ok,) = msg.sender.call{value: send}("");
            return ok;
        }
        RewardAsset(claimAsset).mint(msg.sender, send);
        return true;
    }

    receive() external payable {
        require(!rejectNative, "reject native");
    }

    function setUp() public {
        vm.warp(10 days);
        vm.deal(address(this), 100 ether);
        token = new V3RewardToken("Reward", "RWD", address(this), address(this), new address[](0));
    }

    function _one(uint256 e) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = e;
    }

    function _oneA(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _purchaseToken(address asset) internal {
        token.setDefaultRewardAsset(asset);
        token.configurePool(POOL, address(0), 0);
    }

    // lines 47, 110, 127, 225, 231, 440, 672, 683, 696: every configurator-only entry point
    function testConfiguratorOnlyEntryPoints() public {
        RewardAsset a = new RewardAsset();
        vm.startPrank(address(0xBAD));
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.configureAssetSchedule(address(a));
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.configureRounds(address(a), bytes32("id"), 1, bytes32("p"));
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.declareEpochRewardPolicy(20, address(a), bytes32("id"), 1, bytes32("p"));
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.configurePayout(address(a));
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.configureEligibility(EligibilityController(address(a)));
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.configurePool(POOL, address(a), 1);
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.setDefaultRewardAsset(address(a));
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.declareEpochAsset(20, address(a));
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.deliver(5, address(a), 1);
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.onFeeCredit(POOL, address(0), 0, 1);
        vm.stopPrank();
        assertFalse(token.configured());
        assertEq(token.payout(), address(0));
        assertEq(token.roundsManager(), address(0));
        assertEq(token.defaultRewardAsset(), address(0));
    }

    // line 55: empty schedule; plus the never-called schedule views on both arms
    function testAssetScheduleEmptyAndScheduleViews() public {
        RewardAsset a = new RewardAsset();
        _purchaseToken(address(a));
        assertEq(token.roundInterval(), 1 days);
        assertEq(token.rotationIndex(123), 0);
        assertEq(token.nextRoundAt(10), 11 days);
        token.configureRounds(address(this), bytes32("id"), 1, bytes32("p"));
        CovASchedule empty = new CovASchedule(0, address(a), false);
        vm.expectRevert(bytes("empty schedule"));
        token.configureAssetSchedule(address(empty));
        address[] memory assets = new address[](2);
        assets[0] = address(a);
        assets[1] = address(new RewardAsset());
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = "one";
        ids[1] = "two";
        uint32[] memory versions = new uint32[](2);
        versions[0] = 1;
        versions[1] = 2;
        bytes32[] memory prices = new bytes32[](2);
        prices[0] = "p1";
        prices[1] = "p2";
        RewardAssetSchedule real = new RewardAssetSchedule(10, 3, assets, ids, versions, prices);
        token.configureAssetSchedule(address(real));
        assertEq(token.roundInterval(), 3 days);
        assertEq(token.rotationIndex(13), 1);
        assertEq(token.nextRoundAt(10), 13 days);
        assertTrue(token.inRewardBasket(assets[1]));
    }

    // line 95 both arms: basket asset must be bound in the controller
    function testEligibilityRequiresBoundBasketAssets() public {
        RewardAsset stock = new RewardAsset();
        token.configurePool(POOL, address(stock), 1);
        EligibilityController controller = new EligibilityController(address(this));
        vm.expectRevert(bytes("unbound eligibility asset"));
        token.configureEligibility(controller);
        controller.bindAsset(address(stock), 2);
        token.configureEligibility(controller);
        assertEq(token.requiredAssetMask(), 1 << 2);
        // line 233: rebinding / codeless / after credit
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.configureEligibility(controller);
    }

    function testConfigureEligibilityRejectsCodelessAndCredited() public {
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.configureEligibility(EligibilityController(address(0xDEAD)));
        RewardAsset stock = new RewardAsset();
        token.configurePool(POOL, address(stock), 1);
        token.onFeeCredit(POOL, address(stock), 1, 5);
        EligibilityController controller = new EligibilityController(address(this));
        controller.bindAsset(address(stock), 0);
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.configureEligibility(controller);
        assertEq(address(token.eligibilityController()), address(0));
    }

    // lines 144, 155: only holder cohort 0
    function testHolderCohortOnly() public {
        RewardAsset a = new RewardAsset();
        _purchaseToken(address(a));
        token.configureRounds(address(this), bytes32("id"), 7, bytes32("p"));
        vm.expectRevert(bytes("holder cohort"));
        token.rewardPolicy(10, 1);
        vm.expectRevert(bytes("holder cohort"));
        token.creditOf(alice, 10, 1);
        (bytes32 id, uint32 v,, uint8 mode) = token.rewardPolicy(10, 0);
        assertEq(id, bytes32("id"));
        assertEq(v, 7);
        assertEq(mode, 0);
        assertEq(token.creditOf(alice, 10, 0), 0);
    }

    function _sealFixture() internal returns (uint256 epoch) {
        RewardAsset a = new RewardAsset();
        _purchaseToken(address(a));
        token.configureRounds(address(this), bytes32("id"), 1, bytes32("p"));
        token.transfer(alice, 100);
        epoch = block.timestamp / 1 days;
        token.onFeeCredit(POOL, address(0), 0, 100);
        vm.warp((epoch + 1) * 1 days);
    }

    // lines 170, 176, 178, 179, 182: every sealReward funding arm
    function testSealRewardFundingArms() public {
        uint256 epoch = _sealFixture();
        vm.expectRevert(bytes("empty budget"));
        token.sealReward(epoch - 1, 0);
        claimMode = 1;
        vm.expectRevert(bytes("ledger claim"));
        token.sealReward(epoch, 0);
        claimMode = 2;
        vm.expectRevert(bytes("budget delta"));
        token.sealReward(epoch, 0);
        claimMode = 0;
        rejectNative = true;
        vm.expectRevert(bytes("round funding"));
        token.sealReward(epoch, 0);
        assertFalse(token.rewardSealed(epoch));
        rejectNative = false;
        uint256 before = address(this).balance;
        (uint256 budget, uint256 credit, uint8 kind) = token.sealReward(epoch, 0);
        assertEq(budget, 100);
        assertEq(credit, 100 * 1e27);
        assertEq(kind, 0);
        assertEq(address(this).balance, before); // ledger sent 100, rounds manager received 100
        assertEq(address(token).balance, 0);
        assertTrue(token.rewardSealed(epoch));
        vm.expectRevert(bytes("seal state"));
        token.sealReward(epoch, 0);
    }

    // line 176 false arm: budget already held locally, no ledger pull
    function testSealRewardUsesLocalBalanceFirst() public {
        uint256 epoch = _sealFixture();
        (bool ok,) = address(token).call{value: 100}(""); // from the ledger (this)
        assertTrue(ok);
        claimMode = 1; // a ledger pull would fail
        (uint256 budget,,) = token.sealReward(epoch, 0);
        assertEq(budget, 100);
        assertEq(address(token).balance, 0);
    }

    // line 168 both arms: round interval from the schedule
    function testSealRewardWaitsForScheduledRoundEnd() public {
        RewardAsset a = new RewardAsset();
        address[] memory assets = new address[](1);
        assets[0] = address(a);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "one";
        uint32[] memory versions = new uint32[](1);
        versions[0] = 1;
        bytes32[] memory prices = new bytes32[](1);
        prices[0] = "p1";
        RewardAssetSchedule s = new RewardAssetSchedule(10, 3, assets, ids, versions, prices);
        _purchaseToken(address(a));
        token.configureRounds(address(this), bytes32("id"), 1, bytes32("p"));
        token.configureAssetSchedule(address(s));
        token.transfer(alice, 100);
        token.onFeeCredit(POOL, address(0), 0, 100);
        vm.warp(13 days - 1);
        vm.expectRevert(bytes("round interval"));
        token.sealReward(10, 0);
        vm.warp(13 days);
        (uint256 budget,,) = token.sealReward(10, 0);
        assertEq(budget, 100);
    }

    // line 187
    function testReceiveOnlyFromLedger() public {
        vm.deal(alice, 1);
        vm.prank(alice);
        (bool ok, bytes memory err) = address(token).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(err), V3RewardToken.Unauthorized.selector);
        (ok,) = address(token).call{value: 1}("");
        assertTrue(ok);
    }

    // line 212 both arms
    function testQueueSnapshotOnlyForPastEpochs() public {
        token.transfer(alice, 1);
        vm.expectRevert(bytes("unsealed epoch"));
        token.queueSnapshot(10);
        vm.warp(11 days);
        token.transfer(bob, 1);
        (uint256 upper, uint256 revision) = token.queueSnapshot(10);
        assertEq(upper, 1);
        assertEq(revision, 1);
        assertEq(token.participantCount(), 2);
        assertEq(token.participantAt(1), bob);
    }

    // line 295 (excluded account) via the public re-evaluation entry point
    function testSyncEligibilityOnExcludedAccountsNeverEarns() public {
        address pool = address(new RewardAsset());
        address[] memory ex = new address[](1);
        ex[0] = pool;
        token = new V3RewardToken("Reward", "RWD", address(this), address(this), ex);
        token.transfer(pool, 1000);
        token.syncEligibility(pool);
        token.syncEligibility(address(this));
        assertEq(token.eligible(pool), 0);
        assertEq(token.eligible(address(this)), 0);
        assertEq(token.totalEligible(), 0);
        assertEq(token.participantCount(), 0);
    }

    // line 297 both arms + line 298 (B mode with a bound controller)
    function testSystemVaultNeverEarnsInBMode() public {
        RewardAsset stock = new RewardAsset();
        token.configurePool(POOL, address(stock), 1);
        EligibilityController controller = new EligibilityController(address(this));
        controller.bindAsset(address(stock), 0);
        address vault = address(new RewardAsset());
        controller.bindSystemVault(vault, 1);
        token.configureEligibility(controller);
        token.transfer(vault, 100);
        token.transfer(alice, 100);
        assertEq(token.eligible(vault), 0);
        assertEq(token.eligible(alice), 100);
        assertEq(token.totalEligible(), 100);
    }

    // line 354 both arms
    function testCheckpointExpiryRejectsFutureTime() public {
        vm.expectRevert(bytes("future expiry"));
        token.checkpointExpiry(uint32(block.timestamp + 1));
        (uint256 ordinary, uint256 carryIndex) = token.checkpointExpiry(uint32(block.timestamp));
        assertEq(ordinary, 0);
        assertEq(carryIndex, 0);
        assertTrue(token.expiryCheckpointed(block.timestamp));
    }

    // line 458: unconfigured / wrong pool / quote / kind
    function testOnFeeCreditRejectsForeignReceipts() public {
        RewardAsset stock = new RewardAsset();
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.onFeeCredit(POOL, address(stock), 1, 1);
        token.configurePool(POOL, address(stock), 1);
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.onFeeCredit(bytes32(uint256(2)), address(stock), 1, 1);
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.onFeeCredit(POOL, address(0xBEEF), 1, 1);
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.onFeeCredit(POOL, address(stock), 0, 1);
        assertEq(token.totalCredited(), 0);
        token.onFeeCredit(POOL, address(stock), 1, 1);
        assertEq(token.totalCredited(), 1);
    }

    // line 495 both arms: a schedule resolving no asset blocks fee distribution
    function testScheduleResolvingNoAssetBlocksDistribution() public {
        RewardAsset a = new RewardAsset();
        _purchaseToken(address(a));
        token.configureRounds(address(this), bytes32("id"), 1, bytes32("p"));
        token.configureAssetSchedule(address(new CovASchedule(1, address(a), true)));
        token.transfer(alice, 100);
        vm.expectRevert(bytes("asset policy missing"));
        token.onFeeCredit(POOL, address(0), 0, 100);
        assertEq(token.totalCredited(), 0);
    }

    function _stockTokenWithPayout(address stock) internal returns (uint256 epoch) {
        token.configurePool(POOL, stock, 1);
        token.configurePayout(address(this));
        token.transfer(alice, 100);
        epoch = block.timestamp / 1 days;
        token.onFeeCredit(POOL, stock, 1, 10);
    }

    // lines 589, 590, 595, 606, 608, 609: stageCredit gates and funding arms
    function testStageCreditArms() public {
        RewardAsset stock = new RewardAsset();
        claimAsset = address(stock);
        uint256 epoch = _stockTokenWithPayout(address(stock));
        vm.prank(alice);
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.stageCredit(alice, _one(epoch), address(stock));
        vm.expectRevert(bytes("epoch page"));
        token.stageCredit(alice, new uint256[](21), address(stock));
        assertEq(token.stageCredit(alice, _one(epoch), address(0xBEEF)), 0); // asset mismatch: skipped
        assertEq(token.creditedToPayout(epoch, alice), 0);
        claimMode = 1;
        vm.expectRevert();
        token.stageCredit(alice, _one(epoch), address(stock));
        assertEq(token.creditedToPayout(epoch, alice), 0);
        assertEq(token.stagedTotal(address(stock)), 0);
        claimMode = 0;
        assertEq(token.stageCredit(alice, _one(epoch), address(stock)), 10);
        assertEq(stock.balanceOf(address(this)), 10);
        assertEq(token.stagedTotal(address(stock)), 10);
        assertEq(token.stageCredit(alice, _one(epoch), address(stock)), 0); // already staged
        assertEq(token.stageCredit(alice, new uint256[](20), address(stock)), 0); // page bound inclusive
    }

    function testStageCreditWithoutPayoutRejectsEveryone() public {
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.stageCredit(alice, _one(10), address(1));
    }

    // line 591: purchase-mode tokens with rounds must stage through the reward vault
    function testStageCreditPurchaseModeUsesVault() public {
        RewardAsset a = new RewardAsset();
        _purchaseToken(address(a));
        token.configurePayout(address(this));
        token.configureRounds(address(this), bytes32("id"), 1, bytes32("p"));
        vm.expectRevert(bytes("claim through reward vault"));
        token.stageCredit(alice, _one(10), address(a));
    }

    // line 615: taxed transfer to the payout
    function testStageCreditInexactTransfer() public {
        InexactPayoutAsset stock = new InexactPayoutAsset();
        uint256 epoch = _stockTokenWithPayout(address(stock));
        stock.mint(address(token), 10);
        stock.setTax(address(token), 1);
        vm.expectRevert(bytes("stage delta"));
        token.stageCredit(alice, _one(epoch), address(stock));
        assertEq(token.stagedTotal(address(stock)), 0);
        assertEq(stock.balanceOf(address(token)), 10);
    }

    // line 654: direct claim whose ledger top-up fails
    function testClaimLedgerTopUpFailure() public {
        RewardAsset stock = new RewardAsset();
        claimAsset = address(stock);
        token.configurePool(POOL, address(stock), 1);
        token.transfer(alice, 100);
        uint256 epoch = block.timestamp / 1 days;
        token.onFeeCredit(POOL, address(stock), 1, 10);
        claimMode = 1;
        vm.prank(alice);
        vm.expectRevert();
        token.claim(_one(epoch), _oneA(address(stock)));
        assertEq(token.paidTotal(address(stock)), 0);
        claimMode = 0;
        vm.prank(alice);
        token.claim(_one(epoch), _oneA(address(stock)));
        assertEq(stock.balanceOf(alice), 10);
        assertEq(token.rawLiability(address(stock)), 0);
    }

    // lines 682, 683, 687: declareEpochAsset arms
    function testDeclareEpochAssetArms() public {
        RewardAsset a = new RewardAsset();
        RewardAsset b = new RewardAsset();
        _purchaseToken(address(a));
        token.transfer(alice, 100);
        token.onFeeCredit(POOL, address(0), 0, 100); // budget for today
        uint256 today = block.timestamp / 1 days;
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.declareEpochAsset(today - 1, address(b));
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.declareEpochAsset(today, address(b)); // budget already nonzero
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.declareEpochAsset(today + 1, address(0xDEAD));
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.declareEpochAsset(today + 1, address(token));
        token.declareEpochAsset(today + 1, address(b));
        assertEq(token.epochAsset(today + 1), address(b));
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.declareEpochAsset(today + 1, address(a)); // already declared
    }

    // lines 682 / 695: purchase tokens with a rounds manager use the full policy / reward vault paths
    function testRoundsManagerDisablesLegacyDeclareAndDeliver() public {
        RewardAsset a = new RewardAsset();
        _purchaseToken(address(a));
        token.configureRounds(address(this), bytes32("id"), 1, bytes32("p"));
        address other = address(new RewardAsset());
        vm.expectRevert(bytes("declare full reward policy"));
        token.declareEpochAsset(20, other);
        vm.expectRevert(bytes("deliver through reward vault"));
        token.deliver(5, address(a), 1);
        // the full policy path is the one that works
        token.declareEpochRewardPolicy(20, address(a), bytes32("id2"), 2, bytes32("p2"));
        assertEq(token.queueAsset(20), address(a));
    }

    function testDeclareEpochAssetRejectedForDirectStock() public {
        RewardAsset stock = new RewardAsset();
        token.configurePool(POOL, address(stock), 1);
        address other = address(new RewardAsset());
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.declareEpochAsset(20, other);
    }

    // lines 695, 696, 700, 703: deliver arms
    function testDeliverArms() public {
        InexactPayoutAsset a = new InexactPayoutAsset();
        _purchaseToken(address(a));
        token.transfer(alice, 100);
        uint256 epoch = block.timestamp / 1 days;
        token.onFeeCredit(POOL, address(0), 0, 100);
        a.mint(address(this), 100);
        a.approve(address(token), 100);
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.deliver(epoch, address(a), 10); // epoch not finished
        vm.warp((epoch + 1) * 1 days);
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.deliver(epoch - 1, address(a), 10); // no budget
        address wrong = address(new RewardAsset());
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.deliver(epoch, wrong, 10); // wrong asset
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.deliver(epoch, address(a), 0);
        a.setTax(address(this), 1);
        vm.expectRevert(bytes("delivery delta"));
        token.deliver(epoch, address(a), 10);
        assertEq(token.cumulativeDelivered(epoch), 0);
        a.setTax(address(0), 0);
        token.deliver(epoch, address(a), 10);
        assertEq(token.cumulativeDelivered(epoch), 10);
        assertEq(token.deliveredTotal(address(a)), 10);
    }

    function testDeliverRejectedForDirectStock() public {
        RewardAsset stock = new RewardAsset();
        token.configurePool(POOL, address(stock), 1);
        token.transfer(alice, 100);
        uint256 epoch = block.timestamp / 1 days;
        token.onFeeCredit(POOL, address(stock), 1, 10);
        vm.warp((epoch + 1) * 1 days);
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.deliver(epoch, address(stock), 1);
    }
}

/// @notice A-mode arms (real controller + registry), setup copied from ExpiryAccounting.t.sol.
contract CovARewardAModeTest is Test {
    V3RewardToken t;
    EligibilityController c;
    EligibilityRegistry r;
    RewardAsset stock;
    address alice;
    address bob;
    bytes32 pool = bytes32(uint256(1));
    bytes32 policy = keccak256("policy");

    function claim(bytes32, uint8, uint256 amount) external returns (bool) {
        stock.mint(msg.sender, amount);
        return true;
    }

    function setUp() public {
        vm.warp(10 days);
        alice = vm.addr(3);
        bob = vm.addr(4);
        stock = new RewardAsset();
        c = new EligibilityController(address(this));
        r = new EligibilityRegistry(address(this));
        c.bindAsset(address(stock), 0);
        t = new V3RewardToken("Reward", "R", address(this), address(this), new address[](0));
        t.configurePool(pool, address(stock), 1);
        t.configureEligibility(c);
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

    // line 327 else arm: an A-mode holder selling out drops weight and unbinds the pool
    function testAModeSellOutUnbindsRewardPool() public {
        credential(3, 20 days);
        t.syncEligibility(alice);
        assertEq(t.eligible(alice), 100);
        assertEq(r.boundPools(alice).length, 1);
        vm.prank(alice);
        t.transfer(bob, 100);
        assertEq(t.eligible(alice), 0);
        assertEq(t.eligible(bob), 0, "uncredentialed receiver");
        assertEq(t.effectiveEligible(), 0);
        assertEq(r.boundPools(alice).length, 0);
    }

    // line 338 both arms
    function testOnEligibilityChangeOnlyFromRegistry() public {
        credential(3, 20 days);
        t.syncEligibility(alice);
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        t.onEligibilityChange(alice);
        assertEq(t.eligible(alice), 100);
        vm.prank(address(r));
        t.onEligibilityChange(alice);
        assertEq(t.eligible(alice), 0);
        assertEq(t.effectiveEligible(), 0);
        assertEq(r.boundPools(alice).length, 0);
        assertEq(t.balanceOf(alice), 100);
    }

    // line 636 both arms: A-mode direct delivery requires a credential
    function testDirectClaimRequiresDeliveryEligibility() public {
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 10;
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        vm.prank(bob);
        vm.expectRevert(bytes("ineligible delivery"));
        t.claim(epochs, assets);
        credential(3, 20 days);
        vm.prank(alice);
        t.claim(epochs, assets);
        assertEq(stock.balanceOf(alice), 10);
        assertEq(stock.balanceOf(bob), 0);
    }
}

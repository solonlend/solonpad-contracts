// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SolonStaking} from "../src/stake/SolonStaking.sol";

// Plain 18-dec ERC20 with open mint — the test stand-in for SOLON (the real
// token is a plain UERC20: no fee-on-transfer, no hooks).
contract MockSolon is ERC20 {
    constructor() ERC20("Solon", "SOLON") {}

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }
}

contract MockOther is ERC20 {
    constructor() ERC20("Other", "OTH") {}

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }
}

contract SolonStakingTest is Test {
    using stdStorage for StdStorage;

    MockSolon solon;
    SolonStaking staking;

    address owner = makeAddr("owner");
    address daemon = makeAddr("daemon");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant CAP = 200_000_000e18;
    uint256 constant WEEK = 7 days;
    uint256 constant MONTH = 30 days;
    // amounts chosen so the lane rates are exact: 1e18/s and 2e18/s
    uint256 constant BUY = 604_800e18; // / 7 days  = 1e18 per second
    uint256 constant GEN = 5_184_000e18; // / 30 days = 2e18 per second

    bytes32 constant TX1 = keccak256("buyback-1");

    event RewardAdded(uint8 indexed lane, uint256 amount, bytes32 buybackTx);
    event RewardSettleFailed(address indexed user);
    event Unstaked(address indexed user, uint256 amount);

    function setUp() public {
        vm.warp(1_760_000_000);
        solon = new MockSolon();
        staking = new SolonStaking(address(solon), owner, CAP);
        vm.prank(owner);
        staking.setDistributor(daemon);
        address[5] memory who = [owner, daemon, alice, bob, carol];
        for (uint256 i; i < who.length; i++) {
            solon.mint(who[i], 1_000_000_000e18);
            vm.prank(who[i]);
            solon.approve(address(staking), type(uint256).max);
        }
    }

    // ---------- helpers ----------

    function _stake(address u, uint256 a) internal {
        vm.prank(u);
        staking.stake(a);
    }

    function _unstake(address u, uint256 a) internal {
        vm.prank(u);
        staking.unstake(a);
    }

    function _notify(uint256 a) internal {
        vm.prank(daemon);
        staking.notifyBuyback(a, TX1);
    }

    function _seed(uint256 a) internal {
        vm.prank(owner);
        staking.seedGenesis(a);
    }

    function _skip(uint256 s) internal {
        vm.warp(block.timestamp + s);
    }

    // ---------- construction / roles ----------

    function test_constructor() public view {
        assertEq(address(staking.solon()), address(solon));
        assertEq(staking.owner(), owner);
        assertEq(staking.stakeCap(), CAP);
        assertEq(staking.distributor(), daemon);
        assertEq(staking.BUYBACK_DURATION(), 7 days);
        assertEq(staking.GENESIS_DURATION(), 30 days);
        assertEq(staking.MIN_NOTIFY(), 1_000e18);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(bytes("zero"));
        new SolonStaking(address(0), owner, CAP);
    }

    function test_onlyDistributorCanNotify() public {
        vm.prank(alice);
        vm.expectRevert(bytes("not distributor"));
        staking.notifyBuyback(BUY, TX1);
        // the owner is NOT implicitly a distributor
        vm.prank(owner);
        vm.expectRevert(bytes("not distributor"));
        staking.notifyBuyback(BUY, TX1);
    }

    function test_setDistributorOnlyOwner_andRotation() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setDistributor(alice);
        vm.prank(owner);
        staking.setDistributor(bob);
        vm.prank(daemon);
        vm.expectRevert(bytes("not distributor"));
        staking.notifyBuyback(BUY, TX1);
        vm.prank(bob);
        staking.notifyBuyback(BUY, TX1);
    }

    function test_adminFunctionsOnlyOwner() public {
        vm.startPrank(daemon);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, daemon);
        vm.expectRevert(err);
        staking.pause();
        vm.expectRevert(err);
        staking.unpause();
        vm.expectRevert(err);
        staking.setStakeCap(1);
        vm.expectRevert(err);
        staking.seedGenesis(GEN);
        vm.expectRevert(err);
        staking.reallocateIdle();
        vm.expectRevert(err);
        staking.rescue(address(solon), daemon, 1);
        vm.stopPrank();
    }

    function test_renounceDisabled_twoStepTransfer() public {
        vm.prank(owner);
        vm.expectRevert(bytes("renounce disabled"));
        staking.renounceOwnership();
        address cold = makeAddr("cold");
        vm.prank(owner);
        staking.transferOwnership(cold);
        assertEq(staking.owner(), owner); // pending only
        assertEq(staking.pendingOwner(), cold);
        vm.prank(cold);
        staking.acceptOwnership();
        assertEq(staking.owner(), cold);
    }

    function test_selfHooksNotExternallyCallable() public {
        vm.prank(alice);
        vm.expectRevert(bytes("self only"));
        staking.selfCheckpoint(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("self only"));
        staking.selfPay(alice);
    }

    // ---------- stake / unstake / claim ----------

    function test_stakeMovesTokensAndShares() public {
        _stake(alice, 100e18);
        assertEq(staking.stakedOf(alice), 100e18);
        assertEq(staking.totalStaked(), 100e18);
        assertEq(solon.balanceOf(address(staking)), 100e18);
    }

    function test_stakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("zero"));
        staking.stake(0);
    }

    function test_unstakeIsInstant_noCooldown() public {
        _stake(alice, 100e18);
        uint256 before = solon.balanceOf(alice);
        _unstake(alice, 40e18);
        // same block, same tx: shares and balance change together
        assertEq(staking.stakedOf(alice), 60e18);
        assertEq(staking.totalStaked(), 60e18);
        assertEq(solon.balanceOf(alice), before + 40e18);
    }

    function test_unstakeBadAmountReverts() public {
        _stake(alice, 100e18);
        vm.startPrank(alice);
        vm.expectRevert(bytes("bad amount"));
        staking.unstake(0);
        vm.expectRevert(bytes("bad amount"));
        staking.unstake(100e18 + 1);
        vm.stopPrank();
    }

    function test_sameBlockStakeUnstakeEarnsZero() public {
        _stake(bob, 100e18);
        _notify(BUY);
        _skip(1 days);
        uint256 before = solon.balanceOf(alice);
        _stake(alice, 1_000_000e18);
        assertEq(staking.earned(alice), 0);
        _unstake(alice, 1_000_000e18);
        assertEq(solon.balanceOf(alice), before, "principal back, zero reward");
        assertEq(staking.earned(alice), 0);
    }

    function test_singleStakerEarnsWholeStream() public {
        _stake(alice, 100e18);
        _notify(BUY);
        _skip(1 days);
        assertApproxEqAbs(staking.earned(alice), 86_400e18, 1e3);
        _skip(10 days); // stream ended at day 7
        assertApproxEqAbs(staking.earned(alice), BUY, 1e3);
        assertLe(staking.earned(alice), BUY);
    }

    function test_twoStakersProRata() public {
        _stake(alice, 100e18);
        _stake(bob, 300e18);
        _notify(BUY);
        _skip(1 days);
        assertApproxEqAbs(staking.earned(alice), 21_600e18, 1e3); // 1/4
        assertApproxEqAbs(staking.earned(bob), 64_800e18, 1e3); // 3/4
    }

    function test_lateJoinerOnlyEarnsAfterEntry() public {
        _stake(alice, 100e18);
        _notify(BUY);
        _skip(1 days);
        _stake(bob, 100e18);
        _skip(1 days);
        assertApproxEqAbs(staking.earned(alice), 86_400e18 + 43_200e18, 1e3);
        assertApproxEqAbs(staking.earned(bob), 43_200e18, 1e3);
    }

    function test_claimPaysAndResets() public {
        _stake(alice, 100e18);
        _notify(BUY);
        _skip(1 days);
        uint256 e = staking.earned(alice);
        uint256 before = solon.balanceOf(alice);
        vm.prank(alice);
        staking.claim();
        assertEq(solon.balanceOf(alice), before + e);
        assertEq(staking.earned(alice), 0);
        assertEq(staking.totalPaid(), e);
        assertEq(staking.stakedOf(alice), 100e18, "claim leaves principal");
    }

    function test_claimWithNothingIsNoop() public {
        vm.prank(alice);
        staking.claim();
        assertEq(staking.totalPaid(), 0);
    }

    function test_unstakeAutoClaimsInSameTx() public {
        _stake(alice, 100e18);
        _notify(BUY);
        _skip(1 days);
        uint256 e = staking.earned(alice);
        uint256 before = solon.balanceOf(alice);
        _unstake(alice, 100e18);
        assertEq(solon.balanceOf(alice), before + 100e18 + e, "principal + rewards in one tx");
        assertEq(staking.earned(alice), 0);
        assertEq(staking.stakedOf(alice), 0);
    }

    function test_partialUnstakeKeepsEarning() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        _notify(BUY);
        _skip(1 days);
        _unstake(alice, 50e18); // auto-claims 43_200
        _skip(1 days);
        // day 2: alice 50 / bob 100 of 150
        assertApproxEqAbs(staking.earned(alice), 28_800e18, 1e3);
        assertApproxEqAbs(staking.earned(bob), 43_200e18 + 57_600e18, 1e3);
    }

    function test_compound() public {
        _stake(alice, 100e18);
        _notify(BUY);
        _skip(1 days);
        uint256 e = staking.earned(alice);
        vm.prank(alice);
        staking.compound();
        assertEq(staking.stakedOf(alice), 100e18 + e);
        assertEq(staking.totalStaked(), 100e18 + e);
        assertEq(staking.earned(alice), 0);
        // compounded SOLON is principal now: withdrawable 1:1
        uint256 before = solon.balanceOf(alice);
        _unstake(alice, 100e18 + e);
        assertApproxEqAbs(solon.balanceOf(alice), before + 100e18 + e, 0);
    }

    function test_compoundNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("nothing"));
        staking.compound();
    }

    // ---------- lane math ----------

    function test_buybackRenotifyMidPeriodRecomputesRate() public {
        _stake(alice, 100e18);
        _notify(BUY); // rate 1e18
        _skip(3 days);
        _notify(BUY); // leftover 4 days * 1e18 = 345_600e18
        (uint256 rate, uint256 finish,,) = staking.laneInfo(0);
        assertEq(rate, (BUY + 345_600e18) / WEEK);
        assertEq(finish, block.timestamp + WEEK);
        _skip(WEEK);
        // everything injected ends up earned (minus rounding dust)
        assertApproxEqAbs(staking.earned(alice), 2 * BUY, 1e6);
        assertLe(staking.earned(alice), 2 * BUY);
    }

    function test_renotifyAfterFinishStartsFresh() public {
        _stake(alice, 100e18);
        _notify(BUY);
        _skip(8 days);
        _notify(BUY);
        (uint256 rate,,,) = staking.laneInfo(0);
        assertEq(rate, 1e18);
    }

    function test_genesisLaneThirtyDays() public {
        _stake(alice, 100e18);
        _seed(GEN);
        (uint256 rate, uint256 finish, uint256 dur, uint256 inj) = staking.laneInfo(1);
        assertEq(rate, 2e18);
        assertEq(finish, block.timestamp + MONTH);
        assertEq(dur, MONTH);
        assertEq(inj, GEN);
        _skip(15 days);
        assertApproxEqAbs(staking.earned(alice), GEN / 2, 1e3);
        _skip(20 days);
        assertApproxEqAbs(staking.earned(alice), GEN, 1e3);
    }

    function test_twoLanesStackRates() public {
        _stake(alice, 100e18);
        _seed(GEN); // 2e18/s for 30d
        _notify(BUY); // 1e18/s for 7d
        assertEq(staking.rewardRate(), 3e18);
        _skip(1 days);
        assertApproxEqAbs(staking.earned(alice), 3 * 86_400e18, 1e3);
        _skip(7 days); // day 8: buyback done, genesis continues
        assertEq(staking.rewardRate(), 2e18);
        assertApproxEqAbs(staking.earned(alice), BUY + 2e18 * 8 days, 1e4);
        // re-notify buyback mid-genesis: only the buyback lane is restretched
        _notify(BUY);
        (uint256 gRate, uint256 gFinish,,) = staking.laneInfo(1);
        assertEq(gRate, 2e18);
        assertEq(gFinish, 1_760_000_000 + MONTH);
        _skip(30 days);
        assertApproxEqAbs(staking.earned(alice), 2 * BUY + GEN, 1e5);
        assertLe(staking.earned(alice), 2 * BUY + GEN);
    }

    // lanes are linear: running both == running each alone, summed
    function test_lanesAreAdditive() public {
        uint256 snap = vm.snapshotState();
        uint256 eA = _laneScenario(true, false);
        vm.revertToState(snap);
        uint256 eB = _laneScenario(false, true);
        vm.revertToState(snap);
        uint256 eC = _laneScenario(true, true);
        assertApproxEqAbs(eC, eA + eB, 1e3);
    }

    function _laneScenario(bool buy, bool gen) internal returns (uint256) {
        _stake(alice, 123e18);
        _stake(bob, 77e18);
        if (gen) _seed(3_333_333e18);
        if (buy) _notify(777_777e18);
        _skip(2 days + 17);
        _unstake(bob, 30e18);
        if (buy) _notify(111_111e18);
        _skip(5 days);
        _stake(carol, 500e18);
        _skip(9 days);
        return staking.earned(alice) + staking.earned(bob) + staking.earned(carol) + staking.totalPaid();
    }

    function test_injectedOnDayBuckets() public {
        _notify(BUY);
        _notify(2_000e18);
        _seed(GEN);
        uint256 day = block.timestamp / 1 days;
        assertEq(staking.injectedOnDay(0, day), BUY + 2_000e18);
        assertEq(staking.injectedOnDay(1, day), GEN);
        _skip(1 days);
        _notify(BUY);
        assertEq(staking.injectedOnDay(0, day + 1), BUY);
    }

    function test_rewardAddedEventCarriesBuybackTx() public {
        vm.expectEmit(true, false, false, true, address(staking));
        emit RewardAdded(0, BUY, TX1);
        _notify(BUY);
        vm.expectEmit(true, false, false, true, address(staking));
        emit RewardAdded(1, GEN, bytes32(0));
        _seed(GEN);
    }

    function test_notifyBelowMinimumReverts() public {
        vm.prank(daemon);
        vm.expectRevert(bytes("below minimum"));
        staking.notifyBuyback(999e18, TX1);
        vm.prank(owner);
        vm.expectRevert(bytes("below minimum"));
        staking.seedGenesis(999e18);
    }

    function test_genesisOnlyOnce() public {
        _seed(GEN);
        vm.prank(owner);
        vm.expectRevert(bytes("genesis seeded"));
        staking.seedGenesis(GEN);
    }

    function test_notifyPullsExactAmount() public {
        uint256 before = solon.balanceOf(daemon);
        _notify(BUY);
        assertEq(solon.balanceOf(daemon), before - BUY);
        assertEq(staking.rewardReserve(), BUY);
        assertEq(solon.balanceOf(address(staking)), BUY);
    }

    function test_notifyWithoutAllowanceReverts() public {
        vm.prank(daemon);
        solon.approve(address(staking), 0);
        vm.prank(daemon);
        vm.expectRevert();
        staking.notifyBuyback(BUY, TX1);
    }

    // ---------- pause: entries blocked, exits never ----------

    function test_pauseBlocksEntriesOnly() public {
        _stake(alice, 100e18);
        _notify(BUY);
        _skip(1 days);
        vm.prank(owner);
        staking.pause();
        assertTrue(staking.paused());

        vm.prank(bob);
        vm.expectRevert(bytes("paused"));
        staking.stake(1e18);
        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        staking.compound();
        vm.prank(daemon);
        vm.expectRevert(bytes("paused"));
        staking.notifyBuyback(BUY, TX1);
        vm.prank(owner);
        vm.expectRevert(bytes("paused"));
        staking.seedGenesis(GEN);

        // exits keep working, and the stream keeps flowing while paused
        _skip(1 days);
        uint256 e = staking.earned(alice);
        assertApproxEqAbs(e, 2 * 86_400e18, 1e3);
        uint256 before = solon.balanceOf(alice);
        vm.prank(alice);
        staking.claim();
        assertEq(solon.balanceOf(alice), before + e);
        _skip(1 hours);
        uint256 e2 = staking.earned(alice);
        _unstake(alice, 100e18);
        assertEq(solon.balanceOf(alice), before + e + e2 + 100e18);

        vm.prank(owner);
        staking.unpause();
        _stake(bob, 1e18);
    }

    // ---------- cap ----------

    function test_stakeCap() public {
        vm.prank(owner);
        staking.setStakeCap(1_000e18);
        _stake(alice, 600e18);
        vm.prank(bob);
        vm.expectRevert(bytes("cap"));
        staking.stake(401e18);
        _stake(bob, 400e18);
        // cap blocks entries only, never exits
        vm.prank(owner);
        staking.setStakeCap(0);
        _unstake(alice, 600e18);
    }

    function test_compoundRespectsCap() public {
        vm.prank(owner);
        staking.setStakeCap(100e18);
        _stake(alice, 100e18);
        _notify(BUY);
        _skip(1 days);
        vm.prank(alice);
        vm.expectRevert(bytes("cap"));
        staking.compound();
    }

    // ---------- idle stream (nobody staked) ----------

    function test_idleRewardsAccrueAndReallocate() public {
        _notify(BUY); // nobody staked
        _skip(1 days);
        _stake(alice, 100e18); // checkpoints the idle day
        assertApproxEqAbs(staking.idleRewards(), 86_400e18, 1e6);
        _skip(6 days);
        assertApproxEqAbs(staking.earned(alice), 6 * 86_400e18, 1e3);
        vm.prank(owner);
        staking.reallocateIdle();
        assertLt(staking.idleRewards(), 7 days, "only the new truncation remainder is left");
        _skip(7 days);
        // now alice has the whole injection
        assertApproxEqAbs(staking.earned(alice), BUY, 1e6);
        assertLe(staking.earned(alice), BUY);
    }

    function test_reallocateIdleNothingReverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("nothing"));
        staking.reallocateIdle();
    }

    // ---------- rescue ----------

    function test_rescueOtherTokensOnly() public {
        MockOther other = new MockOther();
        other.mint(address(staking), 5e18);
        vm.prank(owner);
        staking.rescue(address(other), owner, 5e18);
        assertEq(other.balanceOf(owner), 5e18);
        vm.prank(owner);
        vm.expectRevert(bytes("not SOLON"));
        staking.rescue(address(solon), owner, 1);
    }

    // ---------- rounding / precision ----------

    function test_roundingNeverOverpays() public {
        vm.prank(owner);
        staking.setStakeCap(type(uint256).max);
        _stake(alice, 1); // 1 wei
        _stake(bob, 3e18 + 7);
        _stake(carol, 999_999_999e18 / 3);
        _notify(1_000e18 + 12_345); // odd amount -> truncated rate
        _seed(1_234_567e18 + 9);
        _skip(3 days + 1);
        vm.prank(bob);
        staking.claim();
        _skip(40 days);
        uint256 owed = staking.earned(alice) + staking.earned(bob) + staking.earned(carol);
        uint256 injected = 1_000e18 + 12_345 + 1_234_567e18 + 9;
        assertLe(owed + staking.totalPaid(), injected);
        // dust from truncation is tiny: < 1e-9 SOLON per staker per second-scale
        assertApproxEqAbs(owed + staking.totalPaid() + staking.idleRewards(), injected, 1e12);
        // everyone can actually be paid
        _unstake(alice, 1);
        _unstake(bob, 3e18 + 7);
        _unstake(carol, 999_999_999e18 / 3);
        assertEq(staking.totalStaked(), 0);
        assertGe(solon.balanceOf(address(staking)), staking.idleRewards());
    }

    function test_truncationRemainderGoesToIdle() public {
        _stake(alice, 1e18);
        uint256 amt = BUY + 604_799; // remainder 604_799 wei
        _notify(amt);
        assertEq(staking.idleRewards(), 604_799);
    }

    function test_extremeRatioNoOverflow() public {
        // worst case from the design: 1 wei staked, whole supply streamed
        vm.prank(owner);
        staking.setStakeCap(type(uint256).max);
        _stake(alice, 1);
        _notify(1_000_000_000e18);
        _seed(1_000_000_000e18);
        _skip(31 days);
        assertApproxEqAbs(staking.earned(alice), 2_000_000_000e18, 1e12);
        _stake(bob, 1_000_000_000e18);
        _skip(1 days);
        _unstake(alice, 1);
        _unstake(bob, 1_000_000_000e18);
    }

    // ---------- principal path independent of reward maths ----------

    // Genuinely break the reward maths: a stream so large that
    // (dt * rate * 1e18) overflows. Every reward-touching call reverts, yet
    // unstake still returns principal in full and flags the failure.
    function test_rewardMathRevert_principalStillWithdrawable() public {
        _stake(alice, 100e18);
        _stake(bob, 50e18);
        uint256 huge = 2 ** 200;
        solon.mint(daemon, huge);
        _notify(huge); // dt = 0 here, so notify itself succeeds
        _skip(1 days); // now dt*rate*1e18 > 2^256

        vm.expectRevert();
        staking.earned(alice);
        vm.prank(alice);
        vm.expectRevert();
        staking.claim();

        uint256 before = solon.balanceOf(alice);
        vm.expectEmit(true, false, false, false, address(staking));
        emit RewardSettleFailed(alice);
        vm.expectEmit(true, false, false, true, address(staking));
        emit Unstaked(alice, 100e18);
        _unstake(alice, 100e18);
        assertEq(solon.balanceOf(alice), before + 100e18, "principal returned in full");
        assertEq(staking.stakedOf(alice), 0);
        assertEq(staking.totalStaked(), 50e18);

        // bob too; the contract still holds the whole reward reserve
        _unstake(bob, 50e18);
        assertEq(staking.totalStaked(), 0);
        assertEq(solon.balanceOf(address(staking)), huge);
    }

    // Reward payout is bounded by the reward reserve: whatever the maths says,
    // a claim can never dip into staked principal.
    function test_payoutCappedByReserve() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        _notify(BUY);
        _skip(8 days);
        // forge an accounting bug: inflate alice's recorded rewards
        vm.prank(alice);
        staking.claim();
        stdstore.target(address(staking)).sig("rewards(address)").with_key(alice).checked_write(uint256(10_000_000e18));
        assertEq(staking.rewards(alice), 10_000_000e18);
        vm.prank(alice);
        staking.claim();
        // principal of both is intact and withdrawable
        assertEq(staking.rewardReserve(), 0);
        assertGe(solon.balanceOf(address(staking)), staking.totalStaked());
        _unstake(bob, 100e18);
        _unstake(alice, 100e18);
        assertGt(staking.rewards(alice), 0, "shortfall stays on the books");
    }

    // ---------- fuzz ----------

    function testFuzz_stakeUnstakeReturnsPrincipal(uint96 a, uint96 b, uint32 dt) public {
        uint256 x = bound(a, 1, 100_000_000e18);
        uint256 y = bound(b, 1, 100_000_000e18);
        _stake(alice, x);
        _stake(bob, y);
        _notify(BUY);
        _skip(bound(dt, 0, 60 days));
        uint256 ea = staking.earned(alice);
        uint256 before = solon.balanceOf(alice);
        _unstake(alice, x);
        assertEq(solon.balanceOf(alice), before + x + ea);
        assertLe(ea + staking.earned(bob), BUY);
    }

    function testFuzz_proRata(uint96 a, uint96 b, uint32 dt) public {
        uint256 x = bound(a, 1e18, 100_000_000e18);
        uint256 y = bound(b, 1e18, 100_000_000e18);
        _stake(alice, x);
        _stake(bob, y);
        _notify(BUY);
        _seed(GEN);
        uint256 t = bound(dt, 1, 40 days);
        _skip(t);
        uint256 flowed = 1e18 * (t < WEEK ? t : WEEK) + 2e18 * (t < MONTH ? t : MONTH);
        uint256 ea = staking.earned(alice);
        uint256 eb = staking.earned(bob);
        assertLe(ea + eb, flowed);
        assertApproxEqRel(ea + eb, flowed, 1e12); // 1e-6 relative
        assertApproxEqRel(ea, flowed * x / (x + y), 1e12);
    }
}

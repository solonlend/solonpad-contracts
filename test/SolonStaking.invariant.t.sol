// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SolonStaking} from "../src/stake/SolonStaking.sol";
import {MockSolon} from "./SolonStaking.t.sol";

/// Random operation sequences over a fixed actor set. Tracks its own clock
/// (vm.warp is re-applied at every call so time only moves forward).
contract StakeHandler is Test {
    SolonStaking public staking;
    MockSolon public solon;
    address public owner;
    address public daemon;
    address[] public actors;
    uint256 public time;

    uint256 public ghostInjected;
    uint256 public ghostPrincipalIn;
    uint256 public ghostPrincipalOut;
    mapping(bytes32 => uint256) public calls;

    constructor(SolonStaking s, MockSolon t, address o, address d) {
        staking = s;
        solon = t;
        owner = o;
        daemon = d;
        time = block.timestamp;
        for (uint256 i; i < 5; i++) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            solon.mint(a, 1_000_000_000e18);
            vm.prank(a);
            solon.approve(address(s), type(uint256).max);
        }
        solon.mint(d, 100_000_000_000e18);
        vm.prank(d);
        solon.approve(address(s), type(uint256).max);
        solon.mint(o, 100_000_000e18);
        vm.prank(o);
        solon.approve(address(s), type(uint256).max);
    }

    modifier tick() {
        vm.warp(time);
        _;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function stake(uint256 who, uint256 amt) external tick {
        if (staking.paused()) return;
        address a = actors[who % actors.length];
        uint256 room = staking.stakeCap() - staking.totalStaked();
        if (room == 0) return;
        amt = bound(amt, 1, room < 50_000_000e18 ? room : 50_000_000e18);
        vm.prank(a);
        staking.stake(amt);
        ghostPrincipalIn += amt;
        calls["stake"]++;
    }

    function unstake(uint256 who, uint256 amt) external tick {
        address a = actors[who % actors.length];
        uint256 s = staking.stakedOf(a);
        if (s == 0) return;
        amt = bound(amt, 1, s);
        uint256 bal = solon.balanceOf(a);
        uint256 e = staking.earned(a);
        vm.prank(a);
        staking.unstake(amt); // exits never revert
        // principal + all accrued reward land in the same tx; shares move with it
        assertEq(solon.balanceOf(a), bal + amt + e, "unstake payout");
        assertEq(staking.stakedOf(a), s - amt, "unstake shares");
        ghostPrincipalOut += amt;
        calls["unstake"]++;
    }

    function claim(uint256 who) external tick {
        address a = actors[who % actors.length];
        vm.prank(a);
        staking.claim(); // exits never revert, paused or not
        assertEq(staking.rewards(a), 0);
        calls["claim"]++;
    }

    function compound(uint256 who) external tick {
        if (staking.paused()) return;
        address a = actors[who % actors.length];
        uint256 e = staking.earned(a);
        if (e == 0 || staking.totalStaked() + e > staking.stakeCap()) return;
        vm.prank(a);
        staking.compound();
        calls["compound"]++;
    }

    function notifyBuyback(uint256 amt) external tick {
        if (staking.paused()) return;
        amt = bound(amt, 1_000e18, 5_000_000e18);
        vm.prank(daemon);
        staking.notifyBuyback(amt, bytes32(amt));
        ghostInjected += amt;
        calls["notify"]++;
    }

    function seedGenesis(uint256 amt) external tick {
        if (staking.paused() || staking.genesisSeeded()) return;
        amt = bound(amt, 1_000e18, 20_000_000e18);
        vm.prank(owner);
        staking.seedGenesis(amt);
        ghostInjected += amt;
        calls["genesis"]++;
    }

    function warp(uint256 dt) external {
        time += bound(dt, 0, 5 days);
        vm.warp(time);
        calls["warp"]++;
    }

    function togglePause() external tick {
        bool p = staking.paused(); // read before prank: a view call would consume it
        vm.prank(owner);
        if (p) staking.unpause();
        else staking.pause();
        calls["pause"]++;
    }

    function reallocateIdle() external tick {
        // settle the stream first so idle is current
        vm.prank(actors[0]);
        staking.claim();
        if (staking.idleRewards() < 604_800) return; // would round to rate 0
        vm.prank(owner);
        staking.reallocateIdle();
        calls["realloc"]++;
    }

    function sumEarned() external view returns (uint256 s) {
        for (uint256 i; i < actors.length; i++) {
            s += staking.earned(actors[i]);
        }
    }

    function sumStaked() external view returns (uint256 s) {
        for (uint256 i; i < actors.length; i++) {
            s += staking.stakedOf(actors[i]);
        }
    }
}

contract SolonStakingInvariantTest is Test {
    SolonStaking staking;
    MockSolon solon;
    StakeHandler handler;

    function setUp() public {
        vm.warp(1_760_000_000);
        solon = new MockSolon();
        address owner = makeAddr("owner");
        address daemon = makeAddr("daemon");
        staking = new SolonStaking(address(solon), owner, 200_000_000e18);
        vm.prank(owner);
        staking.setDistributor(daemon);
        handler = new StakeHandler(staking, solon, owner, daemon);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = StakeHandler.stake.selector;
        sel[1] = StakeHandler.unstake.selector;
        sel[2] = StakeHandler.claim.selector;
        sel[3] = StakeHandler.compound.selector;
        sel[4] = StakeHandler.notifyBuyback.selector;
        sel[5] = StakeHandler.seedGenesis.selector;
        sel[6] = StakeHandler.warp.selector;
        sel[7] = StakeHandler.togglePause.selector;
        sel[8] = StakeHandler.reallocateIdle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    function _now() internal {
        vm.warp(handler.time());
    }

    /// The core solvency property: SOLON held >= all principal + every reward
    /// already promised (accrued, not yet claimed).
    function invariant_solvent() public {
        _now();
        assertGe(solon.balanceOf(address(staking)), staking.totalStaked() + handler.sumEarned());
    }

    /// The reward reserve alone covers accrued rewards + the unflowed stream +
    /// idle — rewards never lean on principal.
    function invariant_rewardReserveCoversPromises() public {
        _now();
        assertGe(staking.rewardReserve(), handler.sumEarned() + staking.unflowedRewards() + staking.idleRewards());
        assertEq(solon.balanceOf(address(staking)), staking.totalStaked() + staking.rewardReserve());
    }

    /// Never over-issue: paid + owed <= injected.
    function invariant_noOverIssue() public {
        _now();
        assertLe(staking.totalPaid() + handler.sumEarned(), handler.ghostInjected());
        assertEq(staking.laneInjected(0) + staking.laneInjected(1), handler.ghostInjected());
    }

    function invariant_sharesAddUp() public view {
        assertEq(staking.totalStaked(), handler.sumStaked());
        assertLe(staking.totalStaked(), staking.stakeCap());
    }
}

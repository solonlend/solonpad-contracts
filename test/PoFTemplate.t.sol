// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PonsV2IntegrationTest} from "./PonsV2Integration.t.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {RadianLaunchRouter} from "../src/radian/RadianLaunchRouter.sol";
import {WallTreasury} from "../src/radian/wall/WallTreasury.sol";
import {WallStaking} from "../src/radian/wall/WallStaking.sol";
import {PoFVault} from "../src/radian/pof/PoFVault.sol";
import {PoFRouter} from "../src/radian/pof/PoFRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PoFTemplateTest is PonsV2IntegrationTest {
    RadianLaunchRouter router;
    PoFRouter pof;
    address dana = makeAddr("dana");
    address kp = makeAddr("keeper");
    address[] noExempt;

    function setUp() public override {
        super.setUp();
        router = new RadianLaunchRouter(factory, address(new WallTreasury()), address(new WallStaking()), address(new PoFVault()));
        pof = router.pofRouter();
        vm.startPrank(owner);
        factory.setLaunchForwarder(address(router));
        router.setKeeper(kp);
        vm.stopPrank();
        vm.deal(dana, 100e18);
    }

    function _cfg(uint128 target) internal pure returns (PoFVault.Config memory) {
        return PoFVault.Config({targetWork: target, roundSeconds: 600, minInterval: 600, maxBuybackReserveBps: 500});
    }

    function _launch(uint128 target, uint256 buyAmt, bytes32 salt) internal returns (address t, address c, PoFVault v) {
        PonsV2LaunchFactory.TokenParams memory p = _params(salt);
        vm.prank(dana);
        (address token, address curve, address vault) =
            router.launchPoF{value: LAUNCH_FEE + buyAmt}(p, 0, address(0), buyAmt, 0, noExempt, _cfg(target));
        return (token, curve, PoFVault(payable(vault)));
    }

    function _buy(address who, address t, uint256 amt) internal {
        vm.deal(who, who.balance + amt);
        vm.prank(who);
        pof.buy{value: amt}(t, amt, 0);
    }

    function test_pof_launch_wiresVaultAndRecordsOpeningWork() public {
        address pv = router.predictPoF(dana, bytes32(uint256(31)));
        (address t, address c, PoFVault v) = _launch(1e18, 1e18, bytes32(uint256(31)));
        assertEq(address(v), pv);
        assertEq(factory.getLaunchedToken(t).creatorFeeRecipient, address(v));
        assertEq(factory.getLaunchedToken(t).deployer, dana);
        (address vault, address curve, address pair) = pof.launches(t);
        assertEq(vault, address(v));
        assertEq(curve, c);
        assertEq(pair, address(0));
        assertEq(pof.workOf(t, 0, dana), 1e18, "the opening buy is Work for the creator");
        assertEq(pof.totalWork(t, 0), 1e18);
        assertEq(pof.activeRoundCount(t), 1);
        assertEq(v.currentRound(), 0);
    }

    function test_pof_workOnlyThroughTheRouter() public {
        (address t, address c,) = _launch(1e18, 1e18, bytes32(uint256(32)));
        vm.warp(vm.getBlockTimestamp() + 20);
        _buy(alice, t, 0.5e18);
        vm.prank(bob);
        PonsV2BondingCurve(c).buy{value: 0.5e18}(0.5e18, 0, bob); // direct: no Work
        assertEq(pof.workOf(t, 0, alice), 0.5e18);
        assertEq(pof.workOf(t, 0, bob), 0);
        assertEq(pof.totalWork(t, 0), 1.5e18);
        assertGt(IERC20(t).balanceOf(bob), 0, "direct buys still work, they just earn nothing");
    }

    function test_pof_roundSettlesFromBuybackAndPaysByWorkShare() public {
        (address t,, PoFVault v) = _launch(1e18, 1e18, bytes32(uint256(33)));
        vm.warp(vm.getBlockTimestamp() + 20);
        _buy(alice, t, 0.5e18);
        vm.warp(vm.getBlockTimestamp() + 600); // round 0 over
        assertEq(v.currentRound(), 1);

        vm.prank(kp);
        (uint256 spent, uint256 out) = v.claimAndBuy(1, vm.getBlockTimestamp() + 60);
        assertGt(spent, 0);
        assertGt(out, 0);
        assertTrue(v.settled(0), "the ended round settled right after the buyback");
        assertEq(v.roundPool(0), out, "total Work >= target: the whole pool");
        assertEq(v.unallocated(), 0);

        uint256[] memory r = new uint256[](1);
        r[0] = 0;
        assertEq(v.pendingOf(dana, r), (out * 1e18) / 1.5e18);
        vm.prank(dana);
        uint256 got = v.claim(r);
        assertEq(got, (out * 1e18) / 1.5e18);
        vm.prank(alice);
        uint256 gotA = v.claim(r);
        assertEq(gotA, (out * 0.5e18) / 1.5e18);
        assertLe(got + gotA, out);
        vm.prank(dana);
        assertEq(v.claim(r), 0, "no double claim");
        assertEq(v.totalPaid(), got + gotA);
    }

    function test_pof_underSubscribedRoundProRatesAndRollsOver() public {
        (address t,, PoFVault v) = _launch(10e18, 1e18, bytes32(uint256(34))); // target 10, total will be 1.5
        vm.warp(vm.getBlockTimestamp() + 20);
        _buy(alice, t, 0.5e18);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.prank(kp);
        (, uint256 out) = v.claimAndBuy(1, vm.getBlockTimestamp() + 60);
        assertEq(v.roundPool(0), (out * 1.5e18) / 10e18, "1.5 of 10 target: 15% of the pool");
        assertEq(v.unallocated(), out - v.roundPool(0), "the rest rolls over");
        // an active later round inherits the remainder
        _buy(bob, t, 20e18 / 10); // 2e18 work in round 1
        vm.warp(vm.getBlockTimestamp() + 600);
        v.poke();
        assertTrue(v.settled(1));
        assertEq(v.roundPool(1), ((out - (out * 1.5e18) / 10e18) * 2e18) / 10e18);
    }

    function test_pof_idleRoundsCostNothingToSkip() public {
        (address t,, PoFVault v) = _launch(1e18, 1e18, bytes32(uint256(35)));
        vm.warp(vm.getBlockTimestamp() + 600 * 500); // 500 empty rounds
        assertEq(v.currentRound(), 500);
        _buy(alice, t, 1e18); // round 500
        assertEq(pof.activeRoundCount(t), 2);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.prank(kp);
        v.claimAndBuy(1, vm.getBlockTimestamp() + 60);
        assertTrue(v.settled(0));
        assertTrue(v.settled(500));
        assertFalse(v.settled(250), "empty rounds are never touched");
    }

    function test_pof_keeperOnlyBuyback() public {
        (,, PoFVault v) = _launch(1e18, 1e18, bytes32(uint256(36)));
        vm.prank(alice);
        vm.expectRevert(PoFVault.NotKeeper.selector);
        v.claimAndBuy(1, vm.getBlockTimestamp() + 60);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PonsV2IntegrationTest} from "./PonsV2Integration.t.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {RadianLaunchRouter} from "../src/radian/RadianLaunchRouter.sol";
import {WallTreasury} from "../src/radian/wall/WallTreasury.sol";
import {WallStaking} from "../src/radian/wall/WallStaking.sol";
import {PoFVault} from "../src/radian/pof/PoFVault.sol";
import {MockStock} from "../src/mock/MockStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract WallTemplateTest is PonsV2IntegrationTest {
    RadianLaunchRouter router;
    MockStock stock;
    address dana = makeAddr("dana");
    address kp = makeAddr("keeper");
    address[] noExempt;

    function setUp() public override {
        super.setUp();
        router = new RadianLaunchRouter(factory, address(new WallTreasury()), address(new WallStaking()), address(new PoFVault()));
        vm.startPrank(owner);
        factory.setLaunchForwarder(address(router));
        router.setKeeper(kp);
        vm.stopPrank();
        stock = new MockStock("Nvidia (test stand-in)", "NVDAx");
        vm.startPrank(owner);
        factory.setPairTokenEconomics(address(stock), 20e18, 50e18, 18);
        factory.setPairTokenApproved(address(stock), true);
        vm.stopPrank();
        vm.deal(dana, 100e18);
        vm.deal(kp, 1e18);
        stock.mint(dana, 1_000e18);
        stock.mint(alice, 1_000e18);
    }

    function _cfg() internal pure returns (WallTreasury.Config memory) {
        return WallTreasury.Config({
            marginBps: 500, epochBudgetBps: 1000, streamBps: 3000, maxSlippageBps: 1000, minInterval: 3600, keeperBounty: 1e15
        });
    }

    function _launch(address pair, uint256 buyAmt, bytes32 salt)
        internal
        returns (address t, address c, WallTreasury tr, WallStaking st)
    {
        PonsV2LaunchFactory.TokenParams memory p = _params(salt);
        p.creatorFeeRecipient = dana;
        vm.startPrank(dana);
        if (pair != address(0)) stock.approve(address(router), buyAmt);
        (address token, address curve, address treasury, address staking) = router.launchWall{
            value: LAUNCH_FEE + (pair == address(0) ? buyAmt : 0)
        }(p, 0, pair, buyAmt, 0, noExempt, _cfg());
        vm.stopPrank();
        return (token, curve, WallTreasury(payable(treasury)), WallStaking(payable(staking)));
    }

    // ---- wiring ----

    function test_wall_launch_wiresTreasuryAsCreatorFeeRecipient() public {
        (address pt, address ps) = router.predictWall(dana, bytes32(uint256(21)));
        (address t, address c, WallTreasury tr, WallStaking st) = _launch(address(0), 1e18, bytes32(uint256(21)));
        assertEq(address(tr), pt, "treasury address predictable before launch");
        assertEq(address(st), ps);
        assertEq(factory.getLaunchedToken(t).creatorFeeRecipient, address(tr), "fees flow to the treasury");
        assertEq(factory.getLaunchedToken(t).deployer, dana, "launch attributed to the user");
        assertFalse(PonsV2BondingCurve(c).buybackEnabled(), "creator share must not go to the platform vault");
        assertEq(tr.token(), t);
        assertEq(tr.curve(), c);
        assertEq(st.distributor(), address(tr));
        assertEq(address(st.stakingToken()), t);
        assertEq(PonsV2BondingCurve(c).currentSnipeTaxBps(address(tr)), 0, "treasury exempt");
        assertGt(IERC20(t).balanceOf(dana), 0, "opening buy landed on the creator");
        assertEq(address(router).balance, 0);
    }

    function test_wall_rejectsOutOfBoundsConfig() public {
        WallTreasury.Config memory bad = _cfg();
        bad.marginBps = 3000;
        PonsV2LaunchFactory.TokenParams memory p = _params(bytes32(uint256(22)));
        vm.prank(dana);
        vm.expectRevert(bytes("config"));
        router.launchWall{value: LAUNCH_FEE}(p, 0, address(0), 0, 0, noExempt, bad);
    }

    // ---- fees → stakers + reserve ----

    function test_wall_claimFees_streamsToStakersKeepsRest() public {
        (address t,, WallTreasury tr, WallStaking st) = _launch(address(0), 1e18, bytes32(uint256(23)));
        vm.warp(vm.getBlockTimestamp() + 20); // snipe window over
        // dana stakes everything she bought
        uint256 bal = IERC20(t).balanceOf(dana);
        vm.startPrank(dana);
        IERC20(t).approve(address(st), bal);
        st.stake(bal);
        vm.stopPrank();
        // alice trades → creator fee share accrues to the treasury in the escrow
        vm.prank(alice);
        PonsV2BondingCurve(tr.curve()).buy{value: 3e18}(3e18, 0, alice);
        assertEq(tr.claimable(), 0, "fees sit on the curve until swept");
        (uint256 claimed, uint256 streamed) = tr.claimFees();
        assertGt(claimed, 0, "claimFees sweeps the curve, then claims the creator share");
        assertEq(streamed, (claimed * 3000) / 10_000);
        assertEq(tr.reserve(), claimed - streamed, "the rest is the pile");
        assertGt(st.rewardRate(), 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 before = dana.balance;
        vm.prank(dana);
        st.getReward();
        assertApproxEqAbs(dana.balance - before, streamed, streamed / 1000, "sole staker gets the stream");
        assertGt(tr.bookValue(), 0);
    }

    // ---- defend ----

    function _minOutFor(WallTreasury tr, uint256 spend) internal view returns (uint256) {
        PonsV2BondingCurve c = PonsV2BondingCurve(tr.curve());
        uint256 feeBps = c.feeBps() + c.creatorTaxBps();
        uint256 net = (spend * (10_000 - feeBps)) / 10_000;
        return ((net * 1e18) / tr.spot()) * (10_000 - 1000) / 10_000;
    }

    function test_wall_defend_buysAndBurnsUnderTheFloor() public {
        (address t,, WallTreasury tr,) = _launch(address(0), 1e18, bytes32(uint256(24)));
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.deal(address(tr), 5e18); // a pile accumulated from fees
        assertLt(tr.spot(), tr.floorPrice(), "market is under book value");
        uint256 supplyBefore = IERC20(t).totalSupply();
        uint256 kpBefore = kp.balance;
        uint256 spend = 0.1e18;

        uint256 minOut = _minOutFor(tr, spend);
        vm.prank(kp);
        (uint256 spent, uint256 burned) = tr.defend(spend, minOut, vm.getBlockTimestamp() + 60);
        assertEq(spent, spend);
        assertGt(burned, 0);
        assertEq(IERC20(t).totalSupply(), supplyBefore - burned, "bought tokens are burned, not held");
        assertEq(IERC20(t).balanceOf(address(tr)), 0);
        assertEq(kp.balance - kpBefore, 1e15, "keeper bounty paid last, in quote");
        assertEq(tr.totalSpent(), spend);
        assertEq(tr.spentInWindow(), spend);

        vm.prank(kp);
        vm.expectRevert(WallTreasury.TooSoon.selector);
        tr.defend(spend, 1, vm.getBlockTimestamp() + 60);
    }

    function test_wall_defend_capsAtWindowBudget() public {
        (,, WallTreasury tr,) = _launch(address(0), 1e18, bytes32(uint256(25)));
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.deal(address(tr), 5e18);
        uint256 budget = tr.budgetRemaining();
        assertEq(budget, 0.5e18, "10% of the pile per day");
        assertGt(tr.quoteToRestoreFloor(), budget, "restoring the floor would cost more than the budget");
        uint256 minOut = _minOutFor(tr, budget);
        vm.prank(kp);
        (uint256 spent,) = tr.defend(type(uint256).max, minOut, vm.getBlockTimestamp() + 60);
        assertEq(spent, budget - 0, "spend is capped at the window budget");
        assertEq(tr.budgetRemaining(), 0);
    }

    function test_wall_defend_guards() public {
        (,, WallTreasury tr,) = _launch(address(0), 1e18, bytes32(uint256(26)));
        vm.warp(vm.getBlockTimestamp() + 20);
        // nobody but the keeper / platform owner
        vm.deal(address(tr), 5e18);
        vm.prank(alice);
        vm.expectRevert(WallTreasury.NotKeeper.selector);
        tr.defend(1e17, 1, vm.getBlockTimestamp() + 60);
        // a minOut looser than spot − maxSlippage is refused
        uint256 floorOut = _minOutFor(tr, 1e17);
        vm.prank(kp);
        vm.expectRevert(abi.encodeWithSelector(WallTreasury.MinOutTooLow.selector, 1, floorOut));
        tr.defend(1e17, 1, vm.getBlockTimestamp() + 60);
        // expired
        vm.prank(kp);
        vm.expectRevert(WallTreasury.Expired.selector);
        tr.defend(1e17, floorOut, vm.getBlockTimestamp() - 1);
        // above the floor: nothing to defend
        vm.deal(address(tr), 0);
        vm.prank(kp);
        vm.expectRevert();
        tr.defend(1e17, 1, vm.getBlockTimestamp() + 60);
    }

    function test_wall_defend_revertsAfterGraduation() public {
        (, address c, WallTreasury tr,) = _launch(address(0), 1e18, bytes32(uint256(27)));
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.prank(alice);
        PonsV2BondingCurve(c).buy{value: 30e18}(30e18, 0, alice); // crosses the threshold → graduates
        assertTrue(PonsV2BondingCurve(c).graduated());
        vm.deal(address(tr), 5e18);
        vm.prank(kp);
        vm.expectRevert(WallTreasury.Graduated.selector);
        tr.defend(1e17, 1, vm.getBlockTimestamp() + 60);
    }

    // ---- ERC-20 (stock) quote ----

    function test_wall_stockQuote_endToEnd() public {
        (address t, address c, WallTreasury tr, WallStaking st) = _launch(address(stock), 5e18, bytes32(uint256(28)));
        assertEq(tr.pairToken(), address(stock));
        assertEq(st.rewardToken(), address(stock));
        vm.warp(vm.getBlockTimestamp() + 20);
        vm.startPrank(alice);
        stock.approve(c, 10e18);
        PonsV2BondingCurve(c).buy(10e18, 0, alice);
        vm.stopPrank();
        (uint256 claimed, uint256 streamed) = tr.claimFees();
        assertGt(claimed, 0);
        assertGt(streamed, 0);
        assertEq(stock.balanceOf(address(st)), streamed, "stakers' share is stock");
        assertEq(stock.balanceOf(address(tr)), claimed - streamed);

        stock.mint(address(tr), 50e18); // a pile
        assertLt(tr.spot(), tr.floorPrice());
        uint256 supplyBefore = IERC20(t).totalSupply();
        uint256 minOut = _minOutFor(tr, 1e18);
        vm.prank(kp);
        (uint256 spent, uint256 burned) = tr.defend(1e18, minOut, vm.getBlockTimestamp() + 60);
        assertEq(spent, 1e18);
        assertGt(burned, 0);
        assertEq(IERC20(t).totalSupply(), supplyBefore - burned);
        assertEq(stock.balanceOf(kp), 1e15, "bounty in stock");
    }
}

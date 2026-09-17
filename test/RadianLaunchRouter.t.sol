// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PonsV2IntegrationTest} from "./PonsV2Integration.t.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {RadianLaunchRouter} from "../src/radian/RadianLaunchRouter.sol";
import {WallTreasury} from "../src/radian/wall/WallTreasury.sol";
import {WallStaking} from "../src/radian/wall/WallStaking.sol";
import {PoFVault} from "../src/radian/pof/PoFVault.sol";
import {MockStock} from "../src/mock/MockStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Reuses the full V2 harness (PoolManager, hook, factory, one launched token)
/// and adds the atomic launch-and-buy router on top.
contract RadianLaunchRouterTest is PonsV2IntegrationTest {
    RadianLaunchRouter router;
    MockStock stock;
    address dana = makeAddr("dana");
    address teamWallet = makeAddr("teamWallet");
    address[] noExempt;

    function setUp() public override {
        super.setUp();
        router = _newRouter();
        vm.prank(owner);
        factory.setLaunchForwarder(address(router));

        stock = new MockStock("Nvidia (test stand-in)", "NVDAx");
        vm.prank(owner);
        factory.setPairTokenEconomics(address(stock), 20e18, 50e18, 18);
        vm.prank(owner);
        factory.setPairTokenApproved(address(stock), true);

        vm.deal(dana, 100e18);
        stock.mint(dana, 1_000e18);
    }

    function _newRouter() internal returns (RadianLaunchRouter) {
        return new RadianLaunchRouter(factory, address(new WallTreasury()), address(new WallStaking()), address(new PoFVault()));
    }

    function _p(bytes32 salt) internal view returns (PonsV2LaunchFactory.TokenParams memory p) {
        p = _params(salt);
        p.creatorFeeRecipient = dana;
    }

    // ---- native quote ----

    function test_router_nativeLaunchAndBuy_oneTx() public {
        uint256 buyAmt = 1e18;
        uint256 before = dana.balance;
        vm.prank(dana);
        (address t, address c, uint256 out) =
            router.launchAndBuy{value: LAUNCH_FEE + buyAmt}(_p(bytes32(uint256(7))), 0, address(0), buyAmt, 0, noExempt);

        assertGt(out, 0, "bought");
        assertEq(IERC20(t).balanceOf(dana), out, "tokens land on the user, not the router");
        assertEq(PonsV2BondingCurve(c).deployer(), dana, "launch attributed to the user");
        assertEq(PonsV2BondingCurve(c).currentSnipeTaxBps(dana), 0, "creator untaxed in the launch second");
        assertGt(PonsV2BondingCurve(c).currentSnipeTaxBps(bob), 0, "a stranger in the same second is taxed");
        assertEq(address(router).balance, 0, "router keeps nothing");
        assertEq(IERC20(t).balanceOf(address(router)), 0);
        assertEq(before - dana.balance, LAUNCH_FEE + buyAmt, "user paid exactly fee + buy");
        assertEq(factory.getLaunchedToken(t).curve, c, "registered in the factory");
    }

    function test_router_bundleWalletsExempt() public {
        address[] memory ex = new address[](1);
        ex[0] = teamWallet;
        vm.prank(dana);
        (, address c,) = router.launchAndBuy{value: LAUNCH_FEE}(_p(bytes32(uint256(8))), 0, address(0), 0, 0, ex);
        assertEq(PonsV2BondingCurve(c).currentSnipeTaxBps(teamWallet), 0, "declared wallet exempt");
        assertGt(PonsV2BondingCurve(c).currentSnipeTaxBps(alice), 0);
    }

    function test_router_launchOnly() public {
        vm.prank(dana);
        (address t, address c, uint256 out) =
            router.launchAndBuy{value: LAUNCH_FEE}(_p(bytes32(uint256(9))), 0, address(0), 0, 0, noExempt);
        assertEq(out, 0);
        assertEq(IERC20(t).balanceOf(dana), 0);
        assertEq(PonsV2BondingCurve(c).deployer(), dana);
    }

    function test_router_clampedFillRefundsUser() public {
        // Offer far more than the graduation threshold: the curve fills up to
        // its allocation and refunds the rest to msg.sender (the router), which
        // must pass it straight on in the same transaction.
        uint256 offer = GRADUATION * 3;
        uint256 before = dana.balance;
        vm.prank(dana);
        (address t, address c, uint256 out) =
            router.launchAndBuy{value: LAUNCH_FEE + offer}(_p(bytes32(uint256(10))), 0, address(0), offer, 0, noExempt);
        assertGt(out, 0);
        uint256 spent = before - dana.balance - LAUNCH_FEE;
        assertLt(spent, offer, "part of the offer was refunded");
        assertEq(address(router).balance, 0, "refund forwarded, none stuck");
        assertEq(IERC20(t).balanceOf(dana), out);
    }

    function test_router_slippageReverts() public {
        vm.prank(dana);
        vm.expectRevert();
        router.launchAndBuy{value: LAUNCH_FEE + 1e18}(_p(bytes32(uint256(11))), 0, address(0), 1e18, type(uint256).max, noExempt);
    }

    function test_router_wrongValueReverts() public {
        vm.prank(dana);
        vm.expectRevert(abi.encodeWithSelector(RadianLaunchRouter.BadValue.selector, LAUNCH_FEE + 1e18, LAUNCH_FEE));
        router.launchAndBuy{value: LAUNCH_FEE}(_p(bytes32(uint256(12))), 0, address(0), 1e18, 0, noExempt);
    }

    function test_router_onlyTrustedForwarder() public {
        RadianLaunchRouter rogue = _newRouter();
        vm.prank(dana);
        vm.expectRevert(PonsV2LaunchFactory.NotLaunchForwarder.selector);
        rogue.launchAndBuy{value: LAUNCH_FEE}(_p(bytes32(uint256(13))), 0, address(0), 0, 0, noExempt);
    }

    function test_router_whitelistGateAppliesToUserNotRouter() public {
        vm.prank(owner);
        factory.setLaunchEnabled(false);
        vm.prank(dana);
        vm.expectRevert(PonsV2LaunchFactory.NotWhitelisted.selector);
        router.launchAndBuy{value: LAUNCH_FEE}(_p(bytes32(uint256(14))), 0, address(0), 0, 0, noExempt);
    }

    // ---- ERC-20 (stock) quote ----

    function test_router_erc20LaunchAndBuy_oneTx() public {
        uint256 buyAmt = 5e18;
        vm.startPrank(dana);
        stock.approve(address(router), buyAmt);
        (address t, address c, uint256 out) =
            router.launchAndBuy{value: LAUNCH_FEE}(_p(bytes32(uint256(15))), 0, address(stock), buyAmt, 0, noExempt);
        vm.stopPrank();

        assertGt(out, 0);
        assertEq(IERC20(t).balanceOf(dana), out);
        assertEq(stock.balanceOf(dana), 1_000e18 - buyAmt, "exactly the buy was pulled");
        assertEq(stock.balanceOf(address(router)), 0, "router holds no stock");
        assertEq(stock.allowance(address(router), c), 0, "approval cleared");
        assertEq(address(router).balance, 0);
        assertEq(PonsV2BondingCurve(c).pairToken(), address(stock));
        assertEq(PonsV2BondingCurve(c).deployer(), dana);
    }

    function test_router_erc20_valueMustBeFeeOnly() public {
        vm.startPrank(dana);
        stock.approve(address(router), 5e18);
        vm.expectRevert(abi.encodeWithSelector(RadianLaunchRouter.BadValue.selector, LAUNCH_FEE, LAUNCH_FEE + 5e18));
        router.launchAndBuy{value: LAUNCH_FEE + 5e18}(_p(bytes32(uint256(16))), 0, address(stock), 5e18, 0, noExempt);
        vm.stopPrank();
    }

    function test_router_erc20_clampedFillReturnsLeftover() public {
        uint256 offer = 200e18; // > 50e18 graduation
        vm.startPrank(dana);
        stock.approve(address(router), offer);
        (, , uint256 out) =
            router.launchAndBuy{value: LAUNCH_FEE}(_p(bytes32(uint256(17))), 0, address(stock), offer, 0, noExempt);
        vm.stopPrank();
        assertGt(out, 0);
        uint256 spent = 1_000e18 - stock.balanceOf(dana);
        assertLt(spent, offer, "leftover returned");
        assertEq(stock.balanceOf(address(router)), 0);
    }
}

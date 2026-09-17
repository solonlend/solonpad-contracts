// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PonsV2IntegrationTest} from "./PonsV2Integration.t.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {SolonFeeRouter} from "../src/aggregator/SolonFeeRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// Aggregator interface-fee router against the full local Pons V2 suite:
/// the same curve + hook + v4 stack the aggregated pans live on in production.
contract SolonFeeRouterTest is PonsV2IntegrationTest {
    SolonFeeRouter feeRouter;
    address aggTreasury = makeAddr("aggTreasury");

    function setUp() public override {
        super.setUp();
        feeRouter = new SolonFeeRouter(aggTreasury, address(swapRouter));
    }

    function test_curveBuyNative_skimsHalfPercentAndForwardsTokens() public {
        uint256 spend = 1e18;
        uint256 fee = (spend * 50) / 10_000;
        vm.prank(alice);
        uint256 tokensOut = feeRouter.curveBuy{value: spend}(curve, address(0), spend, 0);

        assertEq(aggTreasury.balance, fee, "treasury got 0.5%");
        assertEq(IERC20(token).balanceOf(alice), tokensOut, "alice holds the bought tokens");
        assertGt(tokensOut, 0, "curve fill happened");
        assertEq(address(feeRouter).balance, 0, "router keeps no ETH");
        assertEq(IERC20(token).balanceOf(address(feeRouter)), 0, "router keeps no tokens");
    }

    function test_curveSellNative_skimsFeeFromQuoteOutput() public {
        vm.prank(alice);
        uint256 tokensOut = feeRouter.curveBuy{value: 1e18}(curve, address(0), 1e18, 0);

        uint256 aliceBefore = alice.balance;
        uint256 treasuryBefore = aggTreasury.balance;
        vm.startPrank(alice);
        IERC20(token).approve(address(feeRouter), tokensOut);
        uint256 netQuoteOut = feeRouter.curveSell(curve, token, address(0), tokensOut, 0);
        vm.stopPrank();

        uint256 skimmed = aggTreasury.balance - treasuryBefore;
        assertGt(netQuoteOut, 0, "sell produced quote");
        assertEq(alice.balance, aliceBefore + netQuoteOut, "alice got the net quote");
        // net + fee is the gross curve output; fee must be 0.5% of gross (rounded down).
        assertEq(skimmed, ((netQuoteOut + skimmed) * 50) / 10_000, "fee is 0.5% of gross output");
        assertEq(address(feeRouter).balance, 0, "router keeps no ETH");
        assertEq(IERC20(token).balanceOf(address(feeRouter)), 0, "router keeps no tokens");
    }

    function _graduate() internal returns (PoolKey memory key) {
        vm.warp(block.timestamp + 16);
        vm.prank(bob);
        PonsV2BondingCurve(curve).buy{value: 40e18}(40e18, 0, bob);
        if (!locker.isLocked(token)) factory.createGraduatedPool(token);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    function test_v4BuyThroughHookedPool_feeOnInput() public {
        PoolKey memory key = _graduate();
        uint256 spend = 1e18;
        uint256 fee = (spend * 50) / 10_000;
        vm.prank(alice);
        uint256 out = feeRouter.v4Swap{value: spend}(key, true, spend, 0, false);

        assertEq(aggTreasury.balance, fee, "treasury got 0.5% of quote input");
        assertEq(IERC20(token).balanceOf(alice), out, "alice holds output tokens");
        assertGt(out, 0, "swap filled");
        assertEq(address(feeRouter).balance, 0, "router keeps no ETH");
        assertEq(IERC20(token).balanceOf(address(feeRouter)), 0, "router keeps no tokens");
    }

    function test_v4SellThroughHookedPool_feeOnOutput() public {
        PoolKey memory key = _graduate();
        vm.prank(alice);
        uint256 bought = feeRouter.v4Swap{value: 1e18}(key, true, 1e18, 0, false);

        uint256 treasuryBefore = aggTreasury.balance;
        uint256 aliceBefore = alice.balance;
        vm.startPrank(alice);
        IERC20(token).approve(address(feeRouter), bought);
        uint256 netOut = feeRouter.v4Swap(key, false, bought, 0, true);
        vm.stopPrank();

        uint256 skimmed = aggTreasury.balance - treasuryBefore;
        assertGt(netOut, 0, "sell produced quote");
        assertEq(alice.balance, aliceBefore + netOut, "alice got net quote");
        assertEq(skimmed, ((netOut + skimmed) * 50) / 10_000, "fee is 0.5% of gross output");
        assertEq(address(feeRouter).balance, 0, "router keeps no ETH");
        assertEq(IERC20(token).balanceOf(address(feeRouter)), 0, "router keeps no tokens");
    }

    function test_v4Swap_minOutIsNetOfFee() public {
        PoolKey memory key = _graduate();
        vm.prank(alice);
        vm.expectRevert();
        feeRouter.v4Swap{value: 1e18}(key, true, 1e18, type(uint256).max, false);
    }

    function test_curveSell_slippageGuardIsNetOfFee() public {
        vm.prank(alice);
        uint256 tokensOut = feeRouter.curveBuy{value: 1e18}(curve, address(0), 1e18, 0);
        vm.startPrank(alice);
        IERC20(token).approve(address(feeRouter), tokensOut);
        vm.expectRevert();
        feeRouter.curveSell(curve, token, address(0), tokensOut, type(uint256).max);
        vm.stopPrank();
    }

    function test_curveBuyAndSell_erc20QuotedCurve() public {
        MockQuote usd = new MockQuote();
        vm.startPrank(owner);
        factory.setPairTokenEconomics(address(usd), PHANTOM, GRADUATION, 18);
        factory.setPairTokenApproved(address(usd), true);
        vm.stopPrank();
        vm.prank(creator);
        (address qToken, address qCurve) = factory.launchToken{value: LAUNCH_FEE}(_params(bytes32(uint256(2))), 0, address(usd));
        vm.warp(block.timestamp + 16);

        usd.mint(alice, 10e18);
        vm.startPrank(alice);
        usd.approve(address(feeRouter), 10e18);
        uint256 tokensOut = feeRouter.curveBuy(qCurve, address(usd), 10e18, 0);
        assertEq(usd.balanceOf(aggTreasury), (10e18 * 50) / 10_000, "treasury got 0.5% in quote token");
        assertEq(IERC20(qToken).balanceOf(alice), tokensOut, "alice holds bought tokens");

        IERC20(qToken).approve(address(feeRouter), tokensOut);
        uint256 usdBefore = usd.balanceOf(alice);
        uint256 treasuryBefore = usd.balanceOf(aggTreasury);
        uint256 netOut = feeRouter.curveSell(qCurve, qToken, address(usd), tokensOut, 0);
        vm.stopPrank();

        uint256 skimmed = usd.balanceOf(aggTreasury) - treasuryBefore;
        assertEq(usd.balanceOf(alice), usdBefore + netOut, "alice got net quote");
        assertEq(skimmed, ((netOut + skimmed) * 50) / 10_000, "sell fee is 0.5% of gross");
        assertEq(usd.balanceOf(address(feeRouter)), 0, "router keeps no quote");
        assertEq(IERC20(qToken).balanceOf(address(feeRouter)), 0, "router keeps no tokens");
    }
}

contract MockQuote {
    string public constant name = "Mock USD";
    string public constant symbol = "MUSD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function totalSupply() external pure returns (uint256) { return 0; }
}

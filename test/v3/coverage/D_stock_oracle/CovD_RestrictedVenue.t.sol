// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RestrictedVenue} from "../../../../src/v3/stock/robinhood/RestrictedVenue.sol";
import {IV3SwapRouter} from "../../../../src/v3/stock/interfaces/IV3SwapRouter.sol";
import {IStableRail} from "../../../../src/v3/stock/interfaces/IStableRail.sol";
import {MockUSDG, MockRHStock} from "../../helpers/StockMocks.sol";

/// @notice 1:1 rail double between two mintable stables.
contract CovDRail is IStableRail {
    MockUSDG public immutable s;
    MockUSDG public immutable q;

    constructor(MockUSDG s_, MockUSDG q_) {
        s = s_;
        q = q_;
    }

    function toQuote(uint256 amount) external returns (uint256) {
        s.transferFrom(msg.sender, address(this), amount);
        q.mint(msg.sender, amount);
        return amount;
    }

    function toSettlement(uint256 amount) external returns (uint256) {
        q.transferFrom(msg.sender, address(this), amount);
        s.mint(msg.sender, amount);
        return amount;
    }

    function settlement() external view returns (address) {
        return address(s);
    }

    function quote() external view returns (address) {
        return address(q);
    }
}

/// @notice Router double at $100 per 1e18 shares; `under` makes it report LESS than it delivered.
contract CovDRouter is IV3SwapRouter {
    MockRHStock public immutable stock;
    uint256 public under;

    constructor(MockRHStock stock_) {
        stock = stock_;
    }

    function setUnder(uint256 u) external {
        under = u;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        bool buying = p.tokenOut == address(stock);
        amountOut = buying ? p.amountIn * 1e18 / 100e6 : p.amountIn * 100e6 / 1e18;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        if (buying) stock.mint(p.recipient, amountOut);
        else MockUSDG(p.tokenOut).mint(p.recipient, amountOut);
        amountOut -= under;
    }
}

contract CovDRestrictedVenueTest is Test {
    MockUSDG usdc; // settlement when a rail is used
    MockUSDG usdg; // pool quote
    MockRHStock stock;
    CovDRouter router;
    CovDRail rail;
    RestrictedVenue railed; // usdc settlement, usdg quote, rail
    RestrictedVenue direct; // usdg settlement == quote, no rail
    address vault = address(0x7A);
    address recipient = address(0x7B);

    function setUp() public {
        usdc = new MockUSDG();
        usdg = new MockUSDG();
        stock = new MockRHStock();
        router = new CovDRouter(stock);
        rail = new CovDRail(usdc, usdg);
        railed = new RestrictedVenue(address(router), address(usdc), address(usdg), address(rail), address(this));
        direct = new RestrictedVenue(address(router), address(usdg), address(usdg), address(0), address(this));
        railed.setVault(vault);
        direct.setVault(vault);
        railed.setPool(address(stock), 3000);
        direct.setPool(address(stock), 3000);
        vm.startPrank(vault);
        usdc.approve(address(railed), type(uint256).max);
        usdg.approve(address(direct), type(uint256).max);
        stock.approve(address(railed), type(uint256).max);
        stock.approve(address(direct), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- constructor (57, 58, 59)

    function testCovD_constructorRailArms() public {
        // rail set, both sides match (57 true, 58 false) -- setUp built `railed`
        assertEq(address(railed.rail()), address(rail));
        assertEq(railed.settlementToken(), address(usdc));
        // rail settlement side mismatches
        CovDRail badS = new CovDRail(new MockUSDG(), usdg);
        vm.expectRevert(RestrictedVenue.RailMismatch.selector);
        new RestrictedVenue(address(router), address(usdc), address(usdg), address(badS), address(this));
        // rail settlement matches, quote side mismatches
        CovDRail badQ = new CovDRail(usdc, new MockUSDG());
        vm.expectRevert(RestrictedVenue.RailMismatch.selector);
        new RestrictedVenue(address(router), address(usdc), address(usdg), address(badQ), address(this));
        // no rail and settlement != quote (59 true)
        vm.expectRevert(RestrictedVenue.RailMismatch.selector);
        new RestrictedVenue(address(router), address(usdc), address(usdg), address(0), address(this));
        // no rail and settlement == quote (59 false) -- setUp built `direct`
        assertEq(address(direct.rail()), address(0));
        assertEq(direct.settlementToken(), address(usdg));
    }

    // ---------------------------------------------------------------- onlyVault (48), support (101, 130)

    function testCovD_onlyVaultOnBothSides() public {
        vm.expectRevert(RestrictedVenue.NotVault.selector);
        direct.buy(address(stock), 1, 0, address(this));
        vm.expectRevert(RestrictedVenue.NotVault.selector);
        direct.sell(address(stock), 1, 0, address(this));
    }

    function testCovD_unsupportedStockRevertsBothSides() public {
        MockRHStock other = new MockRHStock();
        assertFalse(direct.isSupported(address(other)));
        assertTrue(direct.isSupported(address(stock)));
        vm.startPrank(vault);
        vm.expectRevert(abi.encodeWithSelector(RestrictedVenue.UnsupportedStock.selector, address(other)));
        direct.buy(address(other), 1, 0, vault);
        vm.expectRevert(abi.encodeWithSelector(RestrictedVenue.UnsupportedStock.selector, address(other)));
        direct.sell(address(other), 1, 0, vault);
        vm.stopPrank();
    }

    function testCovD_delistingWithZeroFeeAfterTimelockStopsTrading() public {
        direct.setPool(address(stock), 0);
        vm.warp(block.timestamp + 48 hours);
        direct.executePool(address(stock));
        assertFalse(direct.isSupported(address(stock)));
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(RestrictedVenue.UnsupportedStock.selector, address(stock)));
        direct.sell(address(stock), 1, 0, vault);
    }

    // ---------------------------------------------------------------- buy (121)

    function testCovD_buyReportsRouterClaimWhenItIsLower() public {
        usdg.mint(vault, 100e6);
        router.setUnder(1);
        vm.prank(vault);
        uint256 out = direct.buy(address(stock), 100e6, 1, recipient);
        assertEq(stock.balanceOf(recipient), 1e18, "landed");
        assertEq(out, 1e18 - 1, "min(landed, reported)");
        assertEq(usdg.balanceOf(address(direct)), 0);
        assertEq(usdg.allowance(address(direct), address(router)), 0);
    }

    function testCovD_buyThroughRailConvertsSettlementFirst() public {
        usdc.mint(vault, 100e6);
        vm.prank(vault);
        uint256 out = railed.buy(address(stock), 100e6, 1e18, recipient);
        assertEq(out, 1e18);
        assertEq(stock.balanceOf(recipient), 1e18);
        assertEq(usdc.balanceOf(vault), 0);
        assertEq(usdc.balanceOf(address(rail)), 100e6, "settlement went into the rail");
        assertEq(usdg.balanceOf(address(router)), 100e6, "the pool got the quote token");
        assertEq(usdc.balanceOf(address(railed)), 0);
        assertEq(usdg.balanceOf(address(railed)), 0);
    }

    // ---------------------------------------------------------------- sell (_toSettlement 168)

    function testCovD_sellWithoutRailPaysQuoteDirectly() public {
        stock.mint(vault, 2e18);
        vm.prank(vault);
        uint256 out = direct.sell(address(stock), 2e18, 200e6, recipient);
        assertEq(out, 200e6);
        assertEq(usdg.balanceOf(recipient), 200e6);
        assertEq(stock.balanceOf(vault), 0);
        assertEq(stock.balanceOf(address(direct)), 0);
        assertEq(stock.allowance(address(direct), address(router)), 0);
    }

    function testCovD_sellThroughRailConvertsBack() public {
        stock.mint(vault, 1e18);
        vm.prank(vault);
        uint256 out = railed.sell(address(stock), 1e18, 100e6, recipient);
        assertEq(out, 100e6);
        assertEq(usdc.balanceOf(recipient), 100e6, "paid in the settlement token");
        assertEq(usdg.balanceOf(recipient), 0);
        assertEq(usdg.balanceOf(address(rail)), 100e6);
        assertEq(usdg.balanceOf(address(railed)), 0);
        assertEq(usdc.balanceOf(address(railed)), 0);
    }

    function testCovD_sellFloorPassedToRouter() public {
        stock.mint(vault, 1e18);
        vm.prank(vault);
        vm.expectRevert(bytes("Too little received"));
        direct.sell(address(stock), 1e18, 100e6 + 1, recipient);
        assertEq(stock.balanceOf(vault), 1e18);
    }

    function testCovD_adminIsOwnerOnly() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD));
        vm.startPrank(address(0xBAD));
        vm.expectRevert(err);
        direct.setVault(address(1));
        vm.expectRevert(err);
        direct.setPool(address(stock), 500);
        vm.expectRevert(err);
        direct.executePool(address(stock));
        vm.stopPrank();
        assertEq(direct.poolFee(address(stock)), 3000);
    }
}

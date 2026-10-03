// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {LedgerStock} from "./V3FeeLedger.t.sol";
import {FixedV4FeeSellRoute} from "../../src/v3/FixedV4FeeSellRoute.sol";

import {V2FeeConverter} from "../../src/v3/V2FeeConverter.sol";

import {V2PlatformRouter} from "../../src/v3/V2PlatformRouter.sol";

contract FeeSaleBudgetReceiver {
    mapping(bytes32 => uint256) public credits;

    function fundV2(bytes32 id, bool protocolDesk) external payable {
        require(protocolDesk);
        credits[id] += msg.value;
    }
}

contract FixedV4FeeSellRouteTest is Test {
    LedgerStock token;
    PoolManager manager;
    PoolSwapTest router;
    FixedV4FeeSellRoute route;
    PoolKey key;
    bytes32 path;

    function setUp() public {
        vm.deal(address(this), 10000 ether);
        token = new LedgerStock();
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 10000, 100, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        token.mint(address(this), 10000 ether);
        token.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 1000 ether}(
            key, ModifyLiquidityParams(-10000, 10000, 1000 ether, bytes32(uint256(1))), ""
        );
        route = new FixedV4FeeSellRoute(address(this), address(router), key);
        path = keccak256(abi.encode(key));
        token.approve(address(route), type(uint256).max);
    }
    receive() external payable {}

    function test_RealV4FeeTokenSaleDeliversNativeWithoutInterfaceFee() public {
        uint256 stockBefore = token.balanceOf(address(this));
        uint256 nativeBefore = address(this).balance;
        uint256 paid = route.sell(address(token), 1 ether, 0.98 ether, address(this), path);
        assertGe(paid, 0.98 ether, "real fixed v4 sale missing");
        assertEq(address(this).balance, nativeBefore + paid);
        assertEq(token.balanceOf(address(this)), stockBefore - 1 ether);
        assertEq(token.balanceOf(address(route)), 0);
        assertEq(token.allowance(address(route), address(router)), 0);
    }

    function test_RealConverterHonorsPostLPFeeNetFloor() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        FixedV4FeeSellRoute fixedRoute = new FixedV4FeeSellRoute(predicted, address(router), key);
        V2FeeConverter converter =
            new V2FeeConverter(address(this), address(fixedRoute), vm.addr(123), address(this), path, 1);
        assertEq(address(converter), predicted);
        token.approve(address(converter), 1 ether);
        V2FeeConverter.Quote memory q = V2FeeConverter.Quote(
            keccak256("net lp"),
            address(token),
            1 ether,
            0.9801 ether,
            1 ether,
            block.timestamp,
            block.timestamp + 60,
            0,
            0
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(123, converter.quoteDigest(q));
        uint256 beforeNative = address(this).balance;
        uint256 actual = converter.convert(q.lotId, address(token), 1 ether, abi.encode(q, abi.encodePacked(r, s, v)));
        assertGe(actual, q.minUSDC18);
        assertEq(address(this).balance, beforeNative + actual);
    }

    function _fixedConverter(V2PlatformRouter platform, PoolKey memory k) internal returns (V2FeeConverter c) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        FixedV4FeeSellRoute r = new FixedV4FeeSellRoute(predicted, address(router), k);
        c = new V2FeeConverter(address(platform), address(r), vm.addr(123), address(this), keccak256(abi.encode(k)), 1);
        assertEq(address(c), predicted);
    }

    function test_TwoAssetsUseIndependentlyApprovedFixedRoutesAndUnknownStaysHeld() public {
        LedgerStock second = new LedgerStock();
        PoolKey memory key2 =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(second)), 10000, 100, IHooks(address(0)));
        manager.initialize(key2, uint160(1 << 96));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        second.mint(address(this), 2000 ether);
        second.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: 1000 ether}(
            key2, ModifyLiquidityParams(-10000, 10000, 1000 ether, bytes32(uint256(1))), ""
        );
        FeeSaleBudgetReceiver budget = new FeeSaleBudgetReceiver();
        V2PlatformRouter platform =
            new V2PlatformRouter(address(this), address(this), address(this), address(budget), address(0xdead));
        V2FeeConverter a = _fixedConverter(platform, key);
        V2FeeConverter b = _fixedConverter(platform, key2);
        (bool ok,) = address(platform)
            .call(abi.encodeWithSignature("scheduleAssetConverter(address,address)", address(token), address(a)));
        assertTrue(ok, "per-asset route registration missing");
        (ok,) = address(platform)
            .call(abi.encodeWithSignature("scheduleAssetConverter(address,address)", address(second), address(b)));
        assertTrue(ok);
        (ok,) = address(platform)
            .call(abi.encodeWithSignature("activateAssetConverter(address,address)", address(token), address(a)));
        assertFalse(ok);
        vm.warp(block.timestamp + 48 hours);
        (ok,) = address(platform)
            .call(abi.encodeWithSignature("activateAssetConverter(address,address)", address(token), address(a)));
        assertTrue(ok);
        (ok,) = address(platform)
            .call(abi.encodeWithSignature("activateAssetConverter(address,address)", address(second), address(b)));
        assertTrue(ok);
        _routeActual(platform, token, a, bytes32(uint256(1)));
        _routeActual(platform, second, b, bytes32(uint256(2)));
        assertGt(budget.credits(bytes32(uint256(1))), 0.9801 ether);
        assertGt(budget.credits(bytes32(uint256(2))), 0.9801 ether);
        LedgerStock unknown = new LedgerStock();
        unknown.mint(address(platform), 1 ether);
        bytes32 id = bytes32(uint256(3));
        platform.onFunded(id, 2, address(unknown), 1 ether);
        platform.routeLot(id);
        vm.expectRevert();
        platform.convertLot(id, "");
        assertEq(unknown.balanceOf(address(platform)), 1 ether);
        assertEq(platform.state(id), 2);
    }

    function _routeActual(V2PlatformRouter platform, LedgerStock t, V2FeeConverter c, bytes32 id) internal {
        t.transfer(address(platform), 1 ether);
        platform.onFunded(id, 2, address(t), 1 ether);
        platform.routeLot(id);
        V2FeeConverter.Quote memory q = V2FeeConverter.Quote(
            id, address(t), 1 ether, 0.9801 ether, 1 ether, block.timestamp, block.timestamp + 60, 0, 0
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(123, c.quoteDigest(q));
        platform.convertLot(id, abi.encode(q, abi.encodePacked(r, s, v)));
        assertEq(t.balanceOf(address(platform)), 0);
    }

    function test_RealRouteRejectsSlippagePartialFillRecipientAndAttachedFee() public {
        uint256 beforeRaw = token.balanceOf(address(this));
        uint256 beforeNative = address(this).balance;
        vm.expectRevert();
        route.sell(address(token), 1 ether, 2 ether, address(this), path);
        vm.expectRevert();
        route.sell(address(token), 2000 ether, 1, address(this), path);
        vm.expectRevert();
        route.sell(address(token), 1 ether, 1, address(55), path);
        vm.expectRevert();
        route.sell{value: 1}(address(token), 1 ether, 1, address(this), path);
        assertEq(token.balanceOf(address(this)), beforeRaw);
        assertEq(address(this).balance, beforeNative);
        assertEq(token.allowance(address(route), address(router)), 0);
    }
}

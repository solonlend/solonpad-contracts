// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {V3QuoteFeeHook, IV3HookFeeLedger} from "../../src/v3/V3QuoteFeeHook.sol";

import {V3HookMiner} from "../../script/v3/MineV3Hook.s.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {HookToken, HookCallbackDriver} from "./helpers/HookHarness.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract V3QuoteFeeHookTest is HookFixture {
    function setUp() public {
        _setUp();
    }

    function _init() internal {
        _register(0);
        manager.initialize(keys[0], uint160(1 << 96));
    }

    function _callbackHook() internal returns (V3QuoteFeeHook h, HookCallbackDriver driver) {
        driver = new HookCallbackDriver();
        bytes32 hash =
            keccak256(abi.encodePacked(type(V3QuoteFeeHook).creationCode, abi.encode(driver, address(this), ledger)));
        (, bytes32 salt) = V3HookMiner.find(address(this), hash, 0, 1_000_000);
        h = new V3QuoteFeeHook{salt: salt}(
            IPoolManager(address(driver)), address(this), IV3HookFeeLedger(address(ledger))
        );
        keys[0].hooks = IHooks(address(h));
        h.registerPool(keys[0], _registration(0));
        vm.prank(address(driver));
        h.beforeInitialize(address(this), keys[0], uint160(1 << 96));
    }

    function _checkPair(
        V3QuoteFeeHook h,
        HookCallbackDriver driver,
        SwapParams memory p,
        bytes memory afterCall,
        bytes4 expected
    ) internal {
        (bool success, bytes memory data) = driver.pair(
            address(h), abi.encodeCall(IHooks.beforeSwap, (address(router), keys[0], p, bytes(""))), afterCall
        );
        assertFalse(success);
        assertEq(data, abi.encodeWithSelector(expected));
    }

    function testOnlyPoolManagerCanCallEnabledCallbacks() public {
        SwapParams memory p = SwapParams(true, 100, 1);
        bytes4 denied = bytes4(keccak256("NotPoolManager()"));
        vm.expectRevert(denied);
        hook.beforeInitialize(address(this), keys[0], 1);
        vm.expectRevert(denied);
        hook.beforeAddLiquidity(address(this), keys[0], _params(), "");
        vm.expectRevert(denied);
        hook.beforeSwap(address(this), keys[0], p, "");
        vm.expectRevert(denied);
        hook.afterSwap(address(this), keys[0], p, BalanceDelta.wrap(0), "");
    }

    function testFactoryOnlyAndRegistrationRejectsWrongKeyAndCode() public {
        V3QuoteFeeHook.PoolRegistration memory r = _registration(0);
        vm.prank(address(55));
        vm.expectRevert(V3QuoteFeeHook.NotFactory.selector);
        hook.registerPool(keys[0], r);
        PoolKey memory bad = keys[0];
        bad.fee = 100;
        vm.expectRevert(V3QuoteFeeHook.InvalidPoolKey.selector);
        hook.registerPool(bad, r);
        bad = keys[0];
        bad.tickSpacing = 60;
        vm.expectRevert(V3QuoteFeeHook.InvalidPoolKey.selector);
        hook.registerPool(bad, r);
        r.tokenCodeHash = bytes32(uint256(55));
        vm.expectRevert(V3QuoteFeeHook.InvalidTokenCode.selector);
        hook.registerPool(keys[0], r);
        r = _registration(0);
        r.quoteKind = 1;
        vm.expectRevert(V3QuoteFeeHook.InvalidPoolKey.selector);
        hook.registerPool(keys[0], r);
        vm.expectRevert();
        manager.initialize(keys[0], uint160(1 << 96));
    }

    function testInitializationConsumedOnceAndRechecksCodeHash() public {
        _init();
        vm.prank(address(manager));
        vm.expectRevert(V3QuoteFeeHook.InvalidInitialization.selector);
        hook.beforeInitialize(address(this), keys[0], uint160(1 << 96));
        vm.etch(memes[0], hex"00");
        vm.prank(address(manager));
        vm.expectRevert(V3QuoteFeeHook.InvalidTokenCode.selector);
        hook.beforeSwap(address(router), keys[0], SwapParams(true, 100, 1), "");
    }

    function testReceiptRejectsNestedSwapWrongSenderParamsAndPool() public {
        (V3QuoteFeeHook h, HookCallbackDriver driver) = _callbackHook();
        SwapParams memory p = SwapParams(true, 100, 1);
        _checkPair(
            h,
            driver,
            p,
            abi.encodeCall(IHooks.beforeSwap, (address(router), keys[0], p, bytes(""))),
            V3QuoteFeeHook.NestedSwap.selector
        );
        _checkPair(
            h,
            driver,
            p,
            abi.encodeCall(IHooks.afterSwap, (address(123), keys[0], p, toBalanceDelta(-101, 100), bytes(""))),
            V3QuoteFeeHook.InvalidReceipt.selector
        );
        _checkPair(
            h,
            driver,
            p,
            abi.encodeCall(IHooks.afterSwap, (address(router), keys[1], p, toBalanceDelta(-101, 100), bytes(""))),
            V3QuoteFeeHook.InvalidReceipt.selector
        );
        SwapParams memory other = SwapParams(true, 101, 1);
        _checkPair(
            h,
            driver,
            p,
            abi.encodeCall(IHooks.afterSwap, (address(router), keys[0], other, toBalanceDelta(-101, 100), bytes(""))),
            V3QuoteFeeHook.InvalidReceipt.selector
        );
    }

    function testRejectsUnpairedAfterSwap() public {
        _init();
        vm.prank(address(manager));
        vm.expectRevert(V3QuoteFeeHook.InvalidReceipt.selector);
        hook.afterSwap(address(router), keys[0], SwapParams(true, 100, 1), toBalanceDelta(-101, 100), "");
    }

    function testRejectsWrongCoreDirection() public {
        (V3QuoteFeeHook h, HookCallbackDriver driver) = _callbackHook();
        SwapParams memory p = SwapParams(true, 100, 1);
        _checkPair(
            h,
            driver,
            p,
            abi.encodeCall(IHooks.afterSwap, (address(router), keys[0], p, toBalanceDelta(101, 100), bytes(""))),
            V3QuoteFeeHook.InvalidSwap.selector
        );
    }

    function testRejectsInt128FeeAdjustedInputOverflow() public {
        (V3QuoteFeeHook h, HookCallbackDriver driver) = _callbackHook();
        SwapParams memory p = SwapParams(true, 100, 1);
        _checkPair(
            h,
            driver,
            p,
            abi.encodeCall(
                IHooks.afterSwap, (address(router), keys[0], p, toBalanceDelta(type(int128).min, 100), bytes(""))
            ),
            V3QuoteFeeHook.AmountOverflow.selector
        );
    }

    function testRejectsZeroDustArbitraryHookDataAndAmountOverflow() public {
        _init();
        vm.startPrank(address(manager));
        vm.expectRevert(V3QuoteFeeHook.InvalidSwap.selector);
        hook.beforeSwap(address(router), keys[0], SwapParams(true, 0, 1), "");
        vm.expectRevert(V3QuoteFeeHook.InvalidSwap.selector);
        hook.beforeSwap(address(router), keys[0], SwapParams(true, -1, 1), "");
        vm.expectRevert(V3QuoteFeeHook.InvalidSwap.selector);
        hook.beforeSwap(address(router), keys[0], SwapParams(true, 100, 1), hex"01");
        vm.expectRevert(V3QuoteFeeHook.AmountOverflow.selector);
        hook.beforeSwap(address(router), keys[0], SwapParams(true, type(int256).min, 1), "");
        vm.expectRevert(V3QuoteFeeHook.AmountOverflow.selector);
        hook.beforeSwap(address(router), keys[0], SwapParams(false, type(int128).max, 1), "");
        vm.stopPrank();
    }

    function testRejectsSellWhoseFeeConsumesEntireOutput() public {
        (V3QuoteFeeHook h, HookCallbackDriver driver) = _callbackHook();
        SwapParams memory p = SwapParams(false, -1, 1);
        _checkPair(
            h,
            driver,
            p,
            abi.encodeCall(IHooks.afterSwap, (address(router), keys[0], p, toBalanceDelta(1, -1), bytes(""))),
            V3QuoteFeeHook.InvalidSwap.selector
        );
    }

    function testNoLiquidityRevertsAllFourModesAndThreeLayouts() public {
        for (uint256 layout; layout < 3; ++layout) {
            _register(layout);
            manager.initialize(keys[layout], uint160(1 << 96));
            if (layout == 0) vm.deal(address(manager), 1e23);
            else HookToken(quotes[layout]).mint(address(manager), 1e23);
            for (uint256 mode; mode < 4; ++mode) {
                bool buy = mode == 0 || mode == 3;
                bool z = (layout != 2) == buy;
                vm.expectRevert(
                    abi.encodeWithSelector(
                        bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")),
                        address(hook),
                        IHooks.afterSwap.selector,
                        abi.encodeWithSelector(V3QuoteFeeHook.PartialFillUnsupported.selector),
                        abi.encodeWithSelector(Hooks.HookCallFailed.selector)
                    )
                );
                router.swap{value: layout == 0 && buy ? 1e22 : 0}(
                    keys[layout],
                    SwapParams(
                        z,
                        mode == 0 || mode == 2 ? -int256(10001) : int256(10001),
                        uint160(z ? (1 << 96) - 1 : (1 << 96) + 1)
                    ),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                );
                assertEq(ledger.totalReceived(PoolId.unwrap(keys[layout].toId())), 0);
                if (layout == 0) {
                    assertEq(address(manager).balance, 1e23);
                    assertEq(address(hook).balance, 0);
                    assertEq(address(ledger).balance, 0);
                } else {
                    assertEq(HookToken(quotes[layout]).balanceOf(address(manager)), 1e23);
                    assertEq(HookToken(quotes[layout]).balanceOf(address(hook)), 0);
                    assertEq(HookToken(quotes[layout]).balanceOf(address(ledger)), 0);
                }
            }
        }
    }

    function testWrongAddressBitsCannotDeployHook() public {
        bytes memory init =
            abi.encodePacked(type(V3QuoteFeeHook).creationCode, abi.encode(manager, address(this), ledger));
        bytes32 hash = keccak256(init);
        uint256 i;
        while (
            uint160(
                        address(
                            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash))))
                        )
                    ) & 0x3fff == 0x28cc
        ) ++i;
        vm.expectRevert();
        new V3QuoteFeeHook{salt: bytes32(i)}(manager, address(this), IV3HookFeeLedger(address(ledger)));
    }

    function testOnlyStrategyFundedInitialPositionMayBeAdded() public {
        _register(0);
        manager.initialize(keys[0], uint160(1 << 96));
        vm.expectRevert();
        positions.add{value: 1e25}(keys[0], _params());
        initialPositionContext[PoolId.unwrap(keys[0].toId())] = keccak256(abi.encode(_params()));
        vm.deal(address(44), 1e26);
        vm.prank(address(44));
        vm.expectRevert();
        positions.add{value: 1e25}(keys[0], _params());
        positions.add{value: 1e25}(keys[0], _params());
        vm.expectRevert();
        positions.add{value: 1e25}(keys[0], _params());
    }

    function testFactoryRegistrationEnablesOnlyRecordedInitializerAndPrice() public {
        _register(0);
        vm.prank(address(55));
        vm.expectRevert();
        manager.initialize(keys[0], uint160(1 << 96));
        vm.expectRevert();
        manager.initialize(keys[0], uint160((1 << 96) + 1));
        manager.initialize(keys[0], uint160(1 << 96));
        vm.expectRevert();
        hook.registerPool(keys[0], _registration(0));
    }

    function testMinedAddressHasExactlySixPermissions() public {
        bytes memory init = abi.encodePacked(
            type(V3QuoteFeeHook).creationCode,
            abi.encode(IPoolManager(address(1)), address(this), IV3HookFeeLedger(address(2)))
        );
        bytes32 hash = keccak256(init);
        (address expected, bytes32 salt) = V3HookMiner.find(address(this), hash, 0, 1_000_000);
        V3QuoteFeeHook hook =
            new V3QuoteFeeHook{salt: salt}(IPoolManager(address(1)), address(this), IV3HookFeeLedger(address(2)));
        assertEq(address(hook), expected);
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta
                && p.afterSwapReturnDelta
        );
        Hooks.validateHookPermissions(hook, p);
    }
}

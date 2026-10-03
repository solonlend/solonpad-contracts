// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {HookFixture} from "./helpers/HookFixture.sol";
import {HookToken, HookFeeReceiver} from "./helpers/HookHarness.sol";
import {V3Router, IV3TradeEligibility} from "../../src/v3/V3Router.sol";
import {V3Quoter} from "../../src/v3/V3Quoter.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V3QuoteFeeHook} from "../../src/v3/V3QuoteFeeHook.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract V3RouterTest is HookFixture {
    V3Router internal official;
    address internal recipient = address(0xCAFE);

    function setUp() public {
        _setUp();
        official = new V3Router(manager, hook, IV3TradeEligibility(address(0)));
        for (uint256 i; i < 3; ++i) {
            _launch(i);
            HookToken(memes[i]).approve(address(official), type(uint256).max);
            if (quotes[i] != address(0)) HookToken(quotes[i]).approve(address(official), type(uint256).max);
        }
    }

    function _request(uint256 layout, bool buy, int256 specified) internal view returns (V3Router.SwapRequest memory) {
        return V3Router.SwapRequest(keys[layout], buy, specified, 0, 1, 1e24, recipient, block.timestamp);
    }

    function testQuoteMatchesExecutionWithoutChangingBalancesOrFees() public {
        V3Quoter quoter = new V3Quoter(official);
        uint256 beforeBalance = address(this).balance;
        V3Router.SwapRequest memory r = _request(0, true, -10001);
        V3Quoter.Quote memory q = quoter.quote{value: 10001}(r, address(this));
        assertEq(q.hookFee, 101, "real simulated quote must charge the hook fee");
        assertEq(address(this).balance, beforeBalance);
        assertEq(address(ledger).balance, 0);
        assertEq(HookToken(memes[0]).balanceOf(recipient), 0);
        BalanceDelta delta = official.swap{value: 10001}(r);
        assertEq(q.minOut, uint256(uint128(delta.amount1())));
        assertEq(q.maxIn, 10001);
        assertEq(q.grossQuote, 10001);
        assertEq(q.netQuote, 9900);
        assertEq(q.quoteDecimals, 18);
        assertEq(q.poolId, PoolId.unwrap(keys[0].toId()));
        assertTrue(q.fullFillOnly);
    }

    function testNativeExactInputBuyDeliversToRecipient() public {
        BalanceDelta delta = official.swap{value: 10001}(_request(0, true, -10001));
        assertGt(HookToken(memes[0]).balanceOf(recipient), 0, "recipient must receive real swap output");
        assertEq(delta.amount0(), -10001);
        assertEq(address(ledger).balance, 101);
    }

    function _balance(address asset, address who) private view returns (uint256) {
        return asset == address(0) ? who.balance : HookToken(asset).balanceOf(who);
    }

    function testAllFourModesQuotesMatchExecutionForNativeAndBothStockSorts() public {
        V3Quoter quoter = new V3Quoter(official);
        for (uint256 layout; layout < 3; ++layout) {
            for (uint256 mode; mode < 4; ++mode) {
                bool buy = mode == 0 || mode == 3;
                bool exactIn = mode == 0 || mode == 2;
                V3Router.SwapRequest memory r = _request(layout, buy, exactIn ? -int256(10001) : int256(10001));
                uint256 value = layout == 0 && buy ? (exactIn ? 10001 : r.maxIn) : 0;
                uint256 payerQuoteBefore = _balance(quotes[layout], address(this));
                uint256 recipientBefore = _balance(buy ? memes[layout] : quotes[layout], recipient);
                uint256 feeBefore = ledger.totalReceived(PoolId.unwrap(keys[layout].toId()));
                V3Quoter.Quote memory q = quoter.quote{value: value}(r, address(this));
                assertEq(_balance(quotes[layout], address(this)), payerQuoteBefore);
                assertEq(_balance(buy ? memes[layout] : quotes[layout], recipient), recipientBefore);
                assertEq(ledger.totalReceived(q.poolId), feeBefore);
                assertEq(q.quoteKind, layout == 0 ? 0 : 1);
                assertEq(q.quoteAsset, quotes[layout]);
                assertEq(q.quoteDecimals, 18);
                assertEq(q.grossQuote - q.netQuote, q.hookFee);
                bool q0 = Currency.unwrap(keys[layout].currency0) == quotes[layout];
                BalanceDelta d = official.swap{value: value}(r);
                int256 quoteDelta = q0 ? d.amount0() : d.amount1();
                int256 memeDelta = q0 ? d.amount1() : d.amount0();
                assertEq(q.hookFee, ledger.totalReceived(q.poolId) - feeBefore);
                assertEq(q.minOut, uint256(buy ? memeDelta : quoteDelta));
                assertEq(q.maxIn, uint256(buy ? -quoteDelta : -memeDelta));
                assertEq(_balance(buy ? memes[layout] : quotes[layout], recipient) - recipientBefore, q.minOut);
                if (exactIn) assertEq(q.maxIn, 10001);
                else assertEq(q.minOut, 10001);
                if (!buy && !exactIn) {
                    assertEq(q.netQuote, 10001);
                    assertEq(q.hookFee, (uint256(10001) + 98) / 99);
                }
                assertEq(address(official).balance, 0);
                assertEq(address(quoter).balance, 0);
            }
        }
    }

    function testPriceLimitPartialFillRejectsAllModesAndLeavesNoFees() public {
        V3Quoter quoter = new V3Quoter(official);
        for (uint256 layout; layout < 3; ++layout) {
            for (uint256 mode; mode < 4; ++mode) {
                bool buy = mode == 0 || mode == 3;
                bool exactIn = mode == 0 || mode == 2;
                V3Router.SwapRequest memory r = _request(layout, buy, exactIn ? -int256(1e20) : int256(1e20));
                bool zeroForOne = buy == (Currency.unwrap(keys[layout].currency0) == quotes[layout]);
                r.sqrtPriceLimitX96 = uint160(zeroForOne ? (1 << 96) - 1 : (1 << 96) + 1);
                uint256 value = layout == 0 && buy ? (exactIn ? 1e20 : r.maxIn) : 0;
                uint256 beforeBalance = _balance(quotes[layout], address(this));
                vm.expectRevert();
                quoter.quote{value: value}(r, address(this));
                vm.expectRevert();
                official.swap{value: value}(r);
                assertEq(_balance(quotes[layout], address(this)), beforeBalance);
                assertEq(ledger.totalReceived(PoolId.unwrap(keys[layout].toId())), 0);
                assertEq(_balance(quotes[layout], address(hook)), 0);
            }
        }
    }

    function testSlippageBoundsDeadlineAndUnknownPoolReject() public {
        V3Router.SwapRequest memory r = _request(0, true, -10001);
        r.minOut = 1e30;
        vm.expectRevert(V3Router.SlippageExceeded.selector);
        official.swap{value: 10001}(r);
        r.minOut = 1;
        r.maxIn = 10000;
        vm.expectRevert(V3Router.SlippageExceeded.selector);
        official.swap{value: 10001}(r);
        r.maxIn = 1e24;
        r.deadline = block.timestamp - 1;
        vm.expectRevert(V3Router.DeadlineExpired.selector);
        official.swap{value: 10001}(r);
        r.deadline = block.timestamp;
        r.key.fee = 3000;
        vm.expectRevert(V3Router.UnknownPool.selector);
        official.swap{value: 10001}(r);
        assertEq(address(ledger).balance, 0);
    }

    function testCallbacksAndSimulationBodyCannotBeCalledByStranger() public {
        vm.expectRevert(V3Router.UnauthorizedCallback.selector);
        official.unlockCallback("");
        vm.expectRevert(V3Router.OnlySelf.selector);
        official.simulationBody(_request(0, true, -10001), address(this));
    }

    function testNativeOverpaymentRefundDoesNotSweepOldFunds() public {
        vm.deal(address(official), 777);
        uint256 beforeBalance = address(this).balance;
        official.swap{value: 20002}(_request(0, true, -10001));
        assertEq(beforeBalance - address(this).balance, 10001);
        assertEq(address(official).balance, 777);
        V3Quoter quoter = new V3Quoter(official);
        vm.deal(address(quoter), 333);
        quoter.quote{value: 20002}(_request(0, true, -10001), address(this));
        assertEq(address(quoter).balance, 333);
        assertEq(address(official).balance, 777);
    }

    function testFutureEligibilityChecksRealPayerAndRecipient() public {
        RouterIdentityPolicy policy = new RouterIdentityPolicy(address(this), recipient);
        V3Router guarded = new V3Router(manager, hook, policy);
        V3Quoter quoter = new V3Quoter(guarded);
        V3Router.SwapRequest memory r = _request(0, true, -10001);
        quoter.quote{value: 10001}(r, address(this));
        guarded.swap{value: 10001}(r);
        r.recipient = address(0xBAD);
        vm.expectRevert("identity");
        guarded.swap{value: 10001}(r);
        r.recipient = recipient;
        vm.expectRevert("identity");
        quoter.quote{value: 10001}(r, address(0xBAD));
    }

    function testQuoteCannotPersistTransfersFromAnotherApprovedPayer() public {
        V3Quoter quoter = new V3Quoter(official);
        uint256 beforeBalance = HookToken(quotes[1]).balanceOf(address(this));
        HookToken(quotes[1]).approve(address(official), 10001);
        uint256 beforeAllowance = HookToken(quotes[1]).allowance(address(this), address(official));
        V3Router.SwapRequest memory r = _request(1, true, -10001);
        r.recipient = address(0xBAD);
        vm.prank(address(0xBAD));
        quoter.quote(r, address(this));
        assertEq(HookToken(quotes[1]).balanceOf(address(this)), beforeBalance);
        assertEq(HookToken(quotes[1]).balanceOf(address(0xBAD)), 0);
        assertEq(HookToken(memes[1]).balanceOf(address(0xBAD)), 0);
        assertEq(HookToken(quotes[1]).allowance(address(this), address(official)), beforeAllowance);
    }

    function testForgedResultFromInputTokenCannotProduceSuccessfulQuote() public {
        V3Quoter quoter = new V3Quoter(official);
        bytes memory forged = abi.encodeWithSelector(V3Router.SimulationResult.selector, int256(123), uint256(456));
        vm.mockCallRevert(
            quotes[1],
            abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), address(manager), 10001),
            forged
        );
        vm.expectRevert(abi.encodeWithSelector(V3Router.SimulationFailure.selector, forged));
        quoter.quote(_request(1, true, -10001), address(this));
    }

    function testNativePaymentClearsPriorSyncedERC20() public {
        RouterSyncCaller caller = new RouterSyncCaller();
        caller.syncThenSwap{value: 10001}(manager, official, Currency.wrap(quotes[1]), _request(0, true, -10001));
        assertGt(HookToken(memes[0]).balanceOf(recipient), 0);
    }

    function testTaxedOutputRevertsInsteadOfViolatingNetMinOut() public {
        HookToken(memes[1]).mint(recipient, 1000000);
        HookToken(memes[1]).setTaxRoute(address(manager), recipient);
        vm.expectRevert(bytes4(keccak256("InexactOutput()")));
        official.swap(_request(1, true, -10001));
        assertEq(HookToken(memes[1]).balanceOf(recipient), 1000000);
    }

    function testTaxedUnusedBudgetRefundCannotHideBehindOldPayerBalance() public {
        HookToken(quotes[1]).setTaxRoute(address(manager), address(this));
        uint256 beforeBalance = HookToken(quotes[1]).balanceOf(address(this));
        vm.expectRevert(bytes4(keccak256("InexactOutput()")));
        official.swap(_request(1, true, 10001));
        assertEq(HookToken(quotes[1]).balanceOf(address(this)), beforeBalance);
    }

    function testInexactInputCannotSpendOldManagerReserves() public {
        HookToken(quotes[1]).setTaxRoute(address(this), address(manager));
        uint256 beforeBalance = HookToken(quotes[1]).balanceOf(address(this));
        vm.expectRevert(V3Router.InexactInput.selector);
        official.swap(_request(1, true, -10001));
        assertEq(HookToken(quotes[1]).balanceOf(address(this)), beforeBalance);
        assertEq(ledger.totalReceived(PoolId.unwrap(keys[1].toId())), 0);
    }

    function testExactOutputRefundsUnusedStockInputBudget() public {
        uint256 beforeBalance = HookToken(quotes[1]).balanceOf(address(this));
        BalanceDelta d = official.swap(_request(1, true, 10001));
        assertEq(beforeBalance - HookToken(quotes[1]).balanceOf(address(this)), uint256(-int256(d.amount0())));
        assertEq(HookToken(quotes[1]).balanceOf(address(official)), 0);
        assertEq(HookToken(memes[1]).balanceOf(recipient), 10001);
    }
}

contract RouterIdentityPolicy is IV3TradeEligibility {
    address private immutable expectedPayer;
    address private immutable expectedRecipient;

    constructor(address payer, address recipient) {
        expectedPayer = payer;
        expectedRecipient = recipient;
    }

    function checkTrade(bytes32, address, address payer, address recipient, bool) external view {
        require(payer == expectedPayer && recipient == expectedRecipient, "identity");
    }
}

/// @dev Real one-sided initial positions with zero quote in the PoolManager.
contract V3RouterFirstBuyTest is HookFixture {
    V3Router internal official;
    V3Quoter internal quoter;

    function setUp() public {
        _setUp();
        official = new V3Router(manager, hook, IV3TradeEligibility(address(0)));
        quoter = new V3Quoter(official);
        for (uint256 i; i < 3; ++i) {
            V3QuoteFeeHook.PoolRegistration memory r = _registration(i);
            r.initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(i == 2 ? int24(-10000) : int24(10000));
            hook.registerPool(keys[i], r);
            address receiver = address(new HookFeeReceiver());
            address[6] memory recipients = [receiver, address(12), receiver, receiver, address(15), address(16)];
            ledger.registerPool(PoolId.unwrap(keys[i].toId()), quotes[i], i == 0 ? 0 : 1, address(hook), recipients);
            manager.initialize(keys[i], r.initialSqrtPriceX96);
            initialPositionContext[PoolId.unwrap(keys[i].toId())] = keccak256(abi.encode(_params()));
            positions.add(keys[i], _params());
            delete initialPositionContext[PoolId.unwrap(keys[i].toId())];
            if (quotes[i] != address(0)) HookToken(quotes[i]).approve(address(official), type(uint256).max);
        }
    }

    function testFundedFirstBuyQuoteAndExecutionWithEmptyQuoteReserves() public {
        for (uint256 i; i < 3; ++i) {
            assertEq(
                quotes[i] == address(0) ? address(manager).balance : HookToken(quotes[i]).balanceOf(address(manager)), 0
            );
            V3Router.SwapRequest memory r =
                V3Router.SwapRequest(keys[i], true, -int256(10001), 0, 1, 10001, address(this), block.timestamp);
            (uint160 beforePrice,,,) = StateLibrary.getSlot0(manager, keys[i].toId());
            V3Quoter.Quote memory q = quoter.quote{value: i == 0 ? 10001 : 0}(r, address(this));
            (uint160 afterPrice,,,) = StateLibrary.getSlot0(manager, keys[i].toId());
            assertEq(beforePrice, afterPrice);
            assertEq(ledger.totalReceived(q.poolId), 0);
            BalanceDelta delta = official.swap{value: i == 0 ? 10001 : 0}(r);
            assertEq(q.maxIn, 10001);
            assertEq(q.hookFee, 101);
            assertEq(q.minOut, uint256(uint128(i == 2 ? delta.amount0() : delta.amount1())));
            assertEq(ledger.totalReceived(q.poolId), 101);
        }
    }
}

contract RouterSyncCaller {
    function syncThenSwap(IPoolManager manager, V3Router router, Currency token, V3Router.SwapRequest calldata request)
        external
        payable
    {
        manager.sync(token);
        router.swap{value: msg.value}(request);
    }
}

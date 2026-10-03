// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {HookFixture} from "./helpers/HookFixture.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {V3QuoteFeeHook} from "../../src/v3/V3QuoteFeeHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookToken, HookBatchRouter} from "./helpers/HookHarness.sol";

contract V3PoolManagerIntegrationTest is HookFixture {
    function setUp() public {
        _setUp();
        for (uint256 i; i < 3; ++i) {
            _launch(i);
        }
    }

    function _swap(uint256 layout, bool buy, int256 amount) internal returns (BalanceDelta d) {
        d = _swapPending(layout, buy, amount);
        ledger.redeemClaims(PoolId.unwrap(keys[layout].toId()));
    }

    function _swapPending(uint256 layout, bool buy, int256 amount) internal returns (BalanceDelta d) {
        bool z = (Currency.unwrap(keys[layout].currency0) == quotes[layout]) == buy;
        return router.swap{value: layout == 0 && buy ? 1e23 : 0}(
            keys[layout],
            SwapParams(z, amount, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _balance(address asset, address who) internal view returns (uint256) {
        return asset == address(0) ? who.balance : HookToken(asset).balanceOf(who);
    }

    function _checkMode(uint256 layout, uint256 mode, uint256 amount) internal {
        bool buy = mode == 0 || mode == 3;
        bool exactIn = mode == 0 || mode == 2;
        address quote = quotes[layout];
        uint256 ledgerBefore = _balance(quote, address(ledger));
        uint256 userBefore = _balance(quote, address(this));
        uint256 managerBefore = _balance(quote, address(manager));
        BalanceDelta d = _swap(layout, buy, exactIn ? -int256(amount) : int256(amount));
        bool q0 = Currency.unwrap(keys[layout].currency0) == quote;
        int256 q = q0 ? d.amount0() : d.amount1();
        int256 m = q0 ? d.amount1() : d.amount0();
        uint256 fee = _balance(quote, address(ledger)) - ledgerBefore;
        if (mode == 0) {
            assertEq(q, -int256(amount));
            assertEq(fee, (amount + 99) / 100);
        }
        if (mode == 1) {
            assertEq(q, int256(amount));
            assertEq(fee, (amount + 98) / 99);
        }
        if (mode == 2) {
            assertEq(m, -int256(amount));
            assertEq(fee, (uint256(q) + fee + 99) / 100);
        }
        if (mode == 3) {
            assertEq(m, int256(amount));
            assertEq(fee, (uint256(-q) - fee + 98) / 99);
        }
        assertEq(int256(_balance(quote, address(this))) - int256(userBefore), q);
        assertEq(int256(_balance(quote, address(manager))) - int256(managerBefore) + q + int256(fee), 0);
        assertEq(_balance(quote, address(hook)), 0);
        bytes32 id = PoolId.unwrap(keys[layout].toId());
        uint256 scaled;
        for (uint256 b; b < 6; ++b) {
            scaled += ledger.accrued(id, b) * 10000 + ledger.remainder(id, b);
        }
        assertEq(scaled, ledger.totalReceived(id) * 10000);
    }

    function testConsecutiveSwapsWithinOneUnlockClearReceipt() public {
        HookBatchRouter batch = new HookBatchRouter(manager);
        for (uint256 layout; layout < 3; ++layout) {
            bool z = Currency.unwrap(keys[layout].currency0) == quotes[layout];
            if (quotes[layout] != address(0)) HookToken(quotes[layout]).approve(address(batch), type(uint256).max);
            BalanceDelta d = batch.swapTwice{value: layout == 0 ? 20002 : 0}(
                keys[layout], SwapParams(z, -10001, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
            );
            assertEq(z ? d.amount0() : d.amount1(), -20002);
            ledger.redeemClaims(PoolId.unwrap(keys[layout].toId()));
            assertEq(_balance(quotes[layout], address(ledger)), 202);
            assertEq(_balance(quotes[layout], address(hook)), 0);
        }
    }

    function testAllFourModesAcrossNativeAndBothStockOrderings() public {
        for (uint256 layout; layout < 3; ++layout) {
            for (uint256 mode; mode < 4; ++mode) {
                _checkMode(layout, mode, 10001);
            }
        }
    }

    function testFuzzFourModesConserveQuoteAndFee(uint128 seed, uint8 layout, uint8 mode) public {
        _checkMode(uint256(layout) % 3, uint256(mode) % 4, bound(seed, 1000, 1e21));
    }

    function _expectPartial() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")),
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(V3QuoteFeeHook.PartialFillUnsupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function testPriceLimitPartialFillRollsBackAllFourModesAndThreeLayouts() public {
        for (uint256 layout; layout < 3; ++layout) {
            for (uint256 mode; mode < 4; ++mode) {
                bool buy = mode == 0 || mode == 3;
                bool z = (Currency.unwrap(keys[layout].currency0) == quotes[layout]) == buy;
                uint256 userBefore = _balance(quotes[layout], address(this));
                uint256 managerBefore = _balance(quotes[layout], address(manager));
                uint256 ledgerBefore = _balance(quotes[layout], address(ledger));
                _expectPartial();
                router.swap{value: layout == 0 && buy ? 1e23 : 0}(
                    keys[layout],
                    SwapParams(
                        z,
                        mode == 0 || mode == 2 ? -int256(1e20) : int256(1e20),
                        uint160(z ? (1 << 96) - 1 : (1 << 96) + 1)
                    ),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                );
                assertEq(_balance(quotes[layout], address(this)), userBefore);
                assertEq(_balance(quotes[layout], address(manager)), managerBefore);
                assertEq(_balance(quotes[layout], address(ledger)), ledgerBefore);
                assertEq(ledger.totalReceived(PoolId.unwrap(keys[layout].toId())), 0);
                assertEq(_balance(quotes[layout], address(hook)), 0);
            }
        }
        _checkMode(0, 0, 10001);
    }

    function testOldDonationsCannotCoverInexactClaimRedemption() public {
        HookToken quote = HookToken(quotes[1]);
        quote.mint(address(ledger), 1000);
        quote.setTaxRoute(address(manager), address(ledger));
        bytes32 id = PoolId.unwrap(keys[1].toId());
        for (uint256 mode; mode < 4; ++mode) {
            _swapPending(1, mode == 0 || mode == 3, mode == 0 || mode == 2 ? -int256(10001) : int256(10001));
            uint256 pending = ledger.pendingClaims(id);
            vm.expectRevert("Inexact redemption");
            ledger.redeemClaims(id);
            assertEq(quote.balanceOf(address(ledger)), 1000);
            assertEq(ledger.pendingClaims(id), pending);
            assertEq(manager.balanceOf(address(ledger), Currency.wrap(address(quote)).toId()), pending);
        }
        quote.setTaxRoute(address(0), address(0));
        ledger.redeemClaims(id);
        assertEq(quote.balanceOf(address(ledger)), 1000 + ledger.totalReceived(id));
    }

    function testFrozenStockRedemptionRetainsBackingUntilUnfrozen() public {
        for (uint256 layout = 1; layout < 3; ++layout) {
            HookToken quote = HookToken(quotes[layout]);
            quote.blockRecipient(address(ledger));
            bytes32 id = PoolId.unwrap(keys[layout].toId());
            for (uint256 mode; mode < 4; ++mode) {
                bool buy = mode == 0 || mode == 3;
                _swapPending(layout, buy, mode == 0 || mode == 2 ? -int256(10001) : int256(10001));
                uint256 pending = ledger.pendingClaims(id);
                vm.expectRevert();
                ledger.redeemClaims(id);
                assertEq(quote.balanceOf(address(ledger)), 0);
                assertEq(ledger.pendingClaims(id), pending);
                assertEq(ledger.totalReceived(id), pending);
                assertEq(manager.balanceOf(address(ledger), Currency.wrap(address(quote)).toId()), pending);
            }
            quote.blockRecipient(address(0));
            ledger.redeemClaims(id);
            _checkMode(layout, 0, 10001);
        }
    }

    function testExactOutputBuyAddsCeilPoolInput() public {
        uint256 beforeLedger = address(ledger).balance;
        BalanceDelta d = _swap(0, true, 10001);
        uint256 fee = address(ledger).balance - beforeLedger;
        uint256 coreInput = uint256(-int256(d.amount0())) - fee;
        assertEq(d.amount1(), 10001);
        assertEq(fee, (coreInput + 98) / 99);
        assertEq(address(hook).balance, 0);
    }

    function testExactInputSellChargesGrossOutput() public {
        uint256 beforeLedger = address(ledger).balance;
        BalanceDelta d = _swap(0, false, -10001);
        uint256 fee = address(ledger).balance - beforeLedger;
        uint256 gross = uint256(int256(d.amount0())) + fee;
        assertEq(d.amount1(), -10001);
        assertEq(fee, (gross + 99) / 100);
        assertEq(address(hook).balance, 0);
    }

    function testExactOutputSellGrossesUpNetQuote() public {
        uint256 net = 10001;
        uint256 beforeLedger = address(ledger).balance;
        BalanceDelta d = _swap(0, false, int256(net));
        assertEq(d.amount0(), int256(net));
        assertLt(d.amount1(), 0);
        assertEq(address(ledger).balance - beforeLedger, (net + 98) / 99);
        assertEq(address(hook).balance, 0);
    }

    function testExactInputBuyChargesCeilGrossQuote() public {
        uint256 gross = 10001;
        uint256 beforeLedger = address(ledger).balance;
        BalanceDelta d = _swap(0, true, -int256(gross));
        assertEq(d.amount0(), -int256(gross));
        assertGt(d.amount1(), 0);
        assertEq(address(ledger).balance - beforeLedger, 101);
        assertEq(address(hook).balance, 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {HookFixture} from "./helpers/HookFixture.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookToken, HookFeeReceiver} from "./helpers/HookHarness.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

contract SingleSidedTest is HookFixture {
    function setUp() public virtual {
        _setUp();
        for (uint256 i; i < 3; ++i) {
            _launch(i);
        }
    }

    function _paramsFor(uint256 layout) internal pure override returns (ModifyLiquidityParams memory) {
        return layout == 2
            ? ModifyLiquidityParams(100, 10000, 1e24, bytes32(uint256(1)))
            : ModifyLiquidityParams(-10000, -100, 1e24, bytes32(uint256(1)));
    }

    function _buy(uint256 layout, int256 amt) internal virtual returns (bool ok) {
        bool z = Currency.unwrap(keys[layout].currency0) == quotes[layout];
        assertEq(
            quotes[layout] == address(0)
                ? address(manager).balance
                : HookToken(quotes[layout]).balanceOf(address(manager)),
            0,
            "single-sided launch has no quote"
        );
        router.swap{value: layout == 0 ? 1e23 : 0}(
            keys[layout],
            SwapParams(z, amt, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        ok = true;
    }

    function testFirstBuyExactInNative() public {
        assertTrue(_buy(0, -10001), "first exact-in buy must succeed");
    }

    function testFirstBuyExactOutNative() public {
        assertTrue(_buy(0, 10001), "first exact-out buy must succeed");
    }

    function testFirstBuyExactInStock0() public {
        assertTrue(_buy(1, -10001), "first exact-in buy must succeed");
    }

    function testFirstBuyExactOutStock0() public {
        assertTrue(_buy(1, 10001), "first exact-out buy must succeed");
    }

    function testFirstBuyExactInStock1() public {
        assertTrue(_buy(2, -10001), "first exact-in buy must succeed");
    }

    function testFirstBuyExactOutStock1() public {
        assertTrue(_buy(2, 10001), "first exact-out buy must succeed");
    }
}

/// @dev Same six first-buy cases with the real token both in the pool and as fee receiver.
contract SingleRealRewardTest is SingleSidedTest {
    V3RewardToken[3] internal rewards;

    function setUp() public override {
        vm.warp(10 days);
        _setUp();
        for (uint256 i; i < 3; ++i) {
            address[] memory excluded = new address[](3);
            excluded[0] = address(manager);
            excluded[1] = address(positions);
            excluded[2] = address(hook);
            V3RewardToken reward = new V3RewardToken("Real reward", "REAL", address(this), address(ledger), excluded);
            rewards[i] = reward;
            memes[i] = address(reward);
            if (i != 0) {
                address quote = i == 1 ? address(0x1000) : address(type(uint160).max - 1);
                vm.etch(quote, quotes[i].code);
                quotes[i] = quote;
                HookToken(quote).mint(address(this), 1e30);
                HookToken(quote).approve(address(router), type(uint256).max);
            }
            keys[i].currency0 = Currency.wrap(i == 2 ? memes[i] : quotes[i]);
            keys[i].currency1 = Currency.wrap(i == 2 ? quotes[i] : memes[i]);
            bytes32 id = PoolId.unwrap(keys[i].toId());
            if (i == 0) reward.setDefaultRewardAsset(address(new HookToken()));
            reward.configurePool(id, quotes[i], i == 0 ? 0 : 1);
            reward.approve(address(positions), type(uint256).max);
            reward.approve(address(router), type(uint256).max);
            hook.registerPool(keys[i], _registration(i));
            address receiver = address(new HookFeeReceiver());
            address[6] memory recipients = [address(reward), address(12), receiver, receiver, address(15), address(16)];
            ledger.registerPool(id, quotes[i], i == 0 ? 0 : 1, address(hook), recipients);
            manager.initialize(keys[i], uint160(1 << 96));
            initialPositionContext[id] = keccak256(abi.encode(_paramsFor(i)));
            positions.add(keys[i], _paramsFor(i));
            delete initialPositionContext[id];
        }
    }

    function _buy(uint256 layout, int256 amt) internal override returns (bool ok) {
        ok = super._buy(layout, amt);
        if (ok) {
            bytes32 id = PoolId.unwrap(keys[layout].toId());
            assertGt(rewards[layout].totalCredited(), 0);
            assertEq(rewards[layout].totalCredited(), ledger.accrued(id, 0));
            assertEq(manager.balanceOf(address(ledger), Currency.wrap(quotes[layout]).toId()), ledger.totalReceived(id));
            ledger.redeemClaims(id);
            assertEq(manager.balanceOf(address(ledger), Currency.wrap(quotes[layout]).toId()), 0);
            assertEq(
                quotes[layout] == address(0)
                    ? address(ledger).balance
                    : HookToken(quotes[layout]).balanceOf(address(ledger)),
                ledger.totalReceived(id)
            );
        }
    }

    function testZeroWeightRealCallbackSwapGas() public {
        for (uint256 i; i < 3; ++i) {
            bool z = i != 2;
            SwapParams memory p = SwapParams(z, -10001, z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
            router.swap{value: i == 0 ? 10001 : 0}(keys[i], p, PoolSwapTest.TestSettings(false, false), "");
            vm.warp(block.timestamp + 5);
            vm.cool(address(rewards[i]));
            vm.cool(address(ledger));
            vm.cool(address(hook));
            vm.cool(address(manager));
            uint256 beforeGas = gasleft();
            router.swap{value: i == 0 ? 10001 : 0}(keys[i], p, PoolSwapTest.TestSettings(false, false), "");
            uint256 used = beforeGas - gasleft();
            emit log_named_uint("cold second zero-weight swap gas", used);
            assertLt(used, 500_000, "full fee-accounting swap must stay bounded");
            assertEq(rewards[i].totalEligible(), 0);
            assertEq(rewards[i].totalCredited(), ledger.accrued(PoolId.unwrap(keys[i].toId()), 0));
        }
    }
}

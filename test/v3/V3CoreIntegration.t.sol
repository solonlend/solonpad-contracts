// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookToken} from "./helpers/HookHarness.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {IV3FeeReceiver} from "../../src/v3/interfaces/IV3FeeLedger.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract CoreFutureBucket is IV3FeeReceiver {
    function onFeeCredit(bytes32, address, uint8, uint256) external {}
    receive() external payable {}
}

/// @dev Uses actual phase-one contracts and actual v4-core PoolManager.
/// Future Desk/staking recipients are fixed inert accounting modules in this fixture.
contract V3CoreIntegrationTest is HookFixture {
    V3RewardToken internal reward;
    bytes32 internal rewardPool;
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);
    address internal carol = address(0xca401);
    uint256 internal constant GROSS = 100 ether;
    uint256 internal constant HOLDER_FEE = 0.575 ether;

    function setUp() public {
        vm.warp(10 days);
        _setUp();
        address[] memory excluded = new address[](3);
        excluded[0] = address(manager);
        excluded[1] = address(positions);
        excluded[2] = address(hook);
        reward = new V3RewardToken("V3 integration", "V3I", address(this), address(ledger), excluded);
        memes[1] = address(reward);
        address low = quotes[1] < address(reward) ? quotes[1] : address(reward);
        address high = quotes[1] < address(reward) ? address(reward) : quotes[1];
        keys[1].currency0 = Currency.wrap(low);
        keys[1].currency1 = Currency.wrap(high);
        reward.approve(address(positions), type(uint256).max);
        reward.approve(address(router), type(uint256).max);
        rewardPool = PoolId.unwrap(keys[1].toId());
        reward.configurePool(rewardPool, quotes[1], 1);
        hook.registerPool(keys[1], _registration(1));
        address[6] memory recipients;
        recipients[0] = address(reward);
        for (uint256 i = 1; i < 6; ++i) {
            recipients[i] = address(new CoreFutureBucket());
        }
        ledger.registerPool(rewardPool, quotes[1], 1, address(hook), recipients);
        manager.initialize(keys[1], uint160(1 << 96));
        initialPositionContext[rewardPool] = keccak256(abi.encode(_params()));
        positions.add(keys[1], _params());
        delete initialPositionContext[rewardPool];
    }

    function _seedHolders() internal {
        reward.transfer(alice, 75 ether);
        reward.transfer(bob, 25 ether);
    }

    function _buy() internal {
        bool z = Currency.unwrap(keys[1].currency0) == quotes[1];
        router.swap(
            keys[1],
            SwapParams(z, -int256(GROSS), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _claim(address account, uint256 epoch) internal {
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epoch;
        address[] memory assets = new address[](1);
        assets[0] = quotes[1];
        vm.prank(account);
        reward.claim(epochs, assets);
    }

    function testSwapCreditsHoldersBeforeAnyKeeperOrPull() public {
        _seedHolders();
        _buy();
        assertEq(ledger.accrued(rewardPool, 0), HOLDER_FEE);
        assertEq(reward.rawLiability(quotes[1]), HOLDER_FEE);
        assertLe(
            reward.rawLiability(quotes[1]),
            ledger.accrued(rewardPool, 0) + HookToken(quotes[1]).balanceOf(address(reward))
        );
        assertEq(HookToken(quotes[1]).balanceOf(address(reward)), 0);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        _claim(alice, epoch);
        _claim(bob, epoch);
        assertEq(HookToken(quotes[1]).balanceOf(alice), HOLDER_FEE * 3 / 4);
        assertEq(HookToken(quotes[1]).balanceOf(bob), HOLDER_FEE / 4);
        assertEq(ledger.accrued(rewardPool, 0), 0);
        assertEq(reward.rawLiability(quotes[1]), 0);
    }

    function testSameSecondSwapCoalescesIndexGasWithoutLosingCredit() public {
        _seedHolders();
        _buy();
        uint256 beforeGas = gasleft();
        _buy();
        uint256 sameSecondGas = beforeGas - gasleft();
        vm.warp(vm.getBlockTimestamp() + 1);
        beforeGas = gasleft();
        _buy();
        uint256 nextSecondGas = beforeGas - gasleft();
        emit log_named_uint("same-second real swap gas (warm)", sameSecondGas);
        emit log_named_uint("new-second real swap gas (warm)", nextSecondGas);
        assertLt(sameSecondGas + 40_000, nextSecondGas, "same-second fees must reuse the index point");
        assertLt(sameSecondGas, 410_000, "same-second full swap gas regression");
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        _claim(alice, epoch);
        _claim(bob, epoch);
        assertEq(HookToken(quotes[1]).balanceOf(alice), HOLDER_FEE * 9 / 4);
        assertEq(HookToken(quotes[1]).balanceOf(bob), HOLDER_FEE * 3 / 4);
    }

    function testTransferredTokensDoNotTransferOldFeeRights() public {
        _seedHolders();
        _buy();
        vm.prank(alice);
        reward.transfer(carol, 75 ether);
        _buy();
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        _claim(alice, epoch);
        _claim(bob, epoch);
        _claim(carol, epoch);
        // The receiver earns from the next swap only; the first fee stays with alice.
        assertEq(HookToken(quotes[1]).balanceOf(alice), HOLDER_FEE * 3 / 4);
        assertEq(HookToken(quotes[1]).balanceOf(bob), HOLDER_FEE * 2 / 4);
        assertEq(HookToken(quotes[1]).balanceOf(carol), HOLDER_FEE * 3 / 4);
        assertEq(ledger.accrued(rewardPool, 0), 0);
    }

    function testBlockedHolderDoesNotBlockFeesOrLoseDebt() public {
        _seedHolders();
        _buy();
        HookToken(quotes[1]).blockRecipient(alice);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epoch;
        address[] memory assets = new address[](1);
        assets[0] = quotes[1];
        vm.prank(alice);
        vm.expectRevert();
        reward.claim(epochs, assets);
        assertEq(ledger.accrued(rewardPool, 0), HOLDER_FEE);
        _buy();
        _claim(bob, epoch);
        HookToken(quotes[1]).blockRecipient(address(0));
        _claim(alice, epoch);
        assertEq(HookToken(quotes[1]).balanceOf(alice), HOLDER_FEE * 3 / 2);
        assertEq(HookToken(quotes[1]).balanceOf(bob), HOLDER_FEE / 2);
    }

    function testFeeWithoutHoldersWaitsSevenActiveDays() public {
        _buy();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        _seedHolders();
        _claim(alice, vm.getBlockTimestamp() / 1 days);
        assertEq(HookToken(quotes[1]).balanceOf(alice), 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        _claim(alice, epoch);
        _claim(bob, epoch);
        assertEq(HookToken(quotes[1]).balanceOf(alice), HOLDER_FEE * 3 / 4);
        assertEq(HookToken(quotes[1]).balanceOf(bob), HOLDER_FEE / 4);
    }

    function testFirstBuyerEarnsFromNextSwapButNotOwnBuy() public {
        _seedHolders();
        HookToken(quotes[1]).mint(carol, 1000 ether);
        vm.prank(carol);
        HookToken(quotes[1]).approve(address(router), type(uint256).max);
        _swapAs(carol, true, GROSS);
        uint256 held = reward.balanceOf(carol);
        assertGt(held, 0);
        assertEq(reward.eligible(carol), held, "buyer must earn without activation");
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        assertEq(reward.epochCredit27(carol, epoch), 0, "buyer earned its own buy fee");
        _buy();
        uint256 expected = HOLDER_FEE * 1e27 / (100 ether + held) * held;
        assertApproxEqAbs(reward.epochCredit27(carol, epoch), expected, held);
    }

    function _swapAs(address who, bool buyQuote, uint256 amount) internal returns (uint256 used) {
        bool quoteIs0 = Currency.unwrap(keys[1].currency0) == quotes[1];
        bool zeroForOne = buyQuote ? quoteIs0 : !quoteIs0;
        SwapParams memory p = SwapParams(
            zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.prank(who);
        uint256 g = gasleft();
        router.swap(keys[1], p, PoolSwapTest.TestSettings(false, false), "");
        used = g - gasleft();
    }

    function testHolderSwapGas() public {
        _seedHolders();
        _buy();
        HookToken(quotes[1]).mint(carol, 1000 ether);
        vm.prank(carol);
        HookToken(quotes[1]).approve(address(router), type(uint256).max);
        vm.prank(alice);
        reward.approve(address(router), type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 newHolderBuy = _swapAs(carol, true, GROSS);
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 holderSell = _swapAs(alice, false, 10 ether);
        emit log_named_uint("new-holder buy gas (real path)", newHolderBuy);
        emit log_named_uint("holder sell gas (real path)", holderSell);
    }
}

contract V3NativeCoreIntegrationTest is HookFixture {
    V3RewardToken internal reward;
    HookToken internal stock;
    bytes32 internal rewardPool;
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);

    function setUp() public {
        vm.warp(10 days);
        _setUp();
        stock = new HookToken();
        address[] memory excluded = new address[](3);
        excluded[0] = address(manager);
        excluded[1] = address(positions);
        excluded[2] = address(hook);
        reward = new V3RewardToken("Native integration", "NVI", address(this), address(ledger), excluded);
        memes[0] = address(reward);
        keys[0].currency1 = Currency.wrap(address(reward));
        reward.approve(address(positions), type(uint256).max);
        reward.approve(address(router), type(uint256).max);
        rewardPool = PoolId.unwrap(keys[0].toId());
        reward.setDefaultRewardAsset(address(stock));
        reward.configurePool(rewardPool, address(0), 0);
        hook.registerPool(keys[0], _registration(0));
        address[6] memory recipients;
        recipients[0] = address(reward);
        for (uint256 i = 1; i < 6; ++i) {
            recipients[i] = address(new CoreFutureBucket());
        }
        ledger.registerPool(rewardPool, address(0), 0, address(hook), recipients);
        manager.initialize(keys[0], uint160(1 << 96));
        initialPositionContext[rewardPool] = keccak256(abi.encode(_params()));
        positions.add{value: 1e25}(keys[0], _params());
        delete initialPositionContext[rewardPool];
    }

    function testNativeFeesKeepOriginalHolderRightsUntilStockDelivery() public {
        reward.transfer(alice, 100 ether);
        router.swap{value: 100 ether}(
            keys[0],
            SwapParams(true, -100 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        assertEq(ledger.accrued(rewardPool, 0), 0.575 ether);
        assertEq(reward.epochCredit27(alice, epoch), 0.575 ether * 1e27);
        vm.prank(alice);
        reward.transfer(bob, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        stock.mint(address(this), 7 ether);
        stock.approve(address(reward), 7 ether);
        reward.deliver(epoch, address(stock), 7 ether);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epoch;
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        vm.prank(alice);
        reward.claim(epochs, assets);
        vm.prank(bob);
        reward.claim(epochs, assets);
        assertEq(stock.balanceOf(alice), 7 ether);
        assertEq(stock.balanceOf(bob), 0);
        assertEq(reward.rawLiability(address(stock)), 0);
    }
}

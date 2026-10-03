// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {V3Carry} from "../../src/v3/libraries/V3Carry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract RewardAsset is ERC20 {
    constructor() ERC20("Stock", "STK") {}

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }
}

contract InexactPayoutAsset is RewardAsset {
    address public taxedSender;
    uint8 public mode;

    function setTax(address sender, uint8 mode_) external {
        taxedSender = sender;
        mode = mode_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == taxedSender && amount != 0) {
            if (mode == 1) {
                super._update(from, to, amount - 1);
                super._update(from, address(0xdead), 1);
            } else {
                super._update(from, to, amount);
                super._update(from, address(0xdead), 1);
            }
        } else {
            super._update(from, to, amount);
        }
    }
}

contract CarryHarness {
    using V3Carry for V3Carry.Stream;
    V3Carry.Stream private stream;

    function tick(bool running) external returns (uint256) {
        return stream.checkpoint(running);
    }

    function deposit(uint256 amount) external {
        stream.deposit(amount);
    }

    function released() external view returns (uint256) {
        return stream.released;
    }
}

contract V3RewardTokenTest is Test {
    V3RewardToken token;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    function setUp() public {
        vm.warp(10 days);
        token = new V3RewardToken("Reward", "RWD", address(this), address(this), new address[](0));
    }

    function testFixedSupplyAndTransferInIsImmediatelyEligible() public {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        token.transfer(alice, 100 ether);
        assertEq(token.eligible(alice), 100 ether);
        assertEq(token.totalEligible(), 100 ether);
        assertEq(token.effectiveEligible(), 100 ether);
    }

    function testTransferInEarnsFromNextFeeOnly() public {
        RewardAsset stock = _direct();
        stock.mint(address(token), 30);
        _hold(bob, 100);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 10);
        token.transfer(alice, 100);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        assertEq(token.epochCredit27(alice, epoch), 0, "earned a fee credited before receipt");
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 20);
        assertEq(token.epochCredit27(alice, epoch), 10e27);
        assertEq(token.epochCredit27(bob, epoch), 20e27);
    }

    function testSameTransactionBuyThenSellEarnsZero() public {
        RewardAsset stock = _direct();
        stock.mint(address(token), 20);
        _hold(bob, 100);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        // Official router order: buy fee is credited before output is taken, sell
        // input is settled before the sell fee is credited. address(this) is the pool.
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 10);
        token.transfer(alice, 1_000_000 ether);
        vm.prank(alice);
        token.transfer(address(this), 1_000_000 ether);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 10);
        assertEq(token.epochCredit27(alice, epoch), 0, "flash holder earned");
        assertEq(token.epochCredit27(bob, epoch), 20e27);
        assertEq(token.eligible(alice), 0);
        assertEq(token.totalEligible(), 100);
        _claim(alice, epoch, address(stock));
        assertEq(stock.balanceOf(alice), 0);
    }

    function testExcludedAddressesEarnZero() public {
        address pool = address(0x9001);
        address[] memory excludedList = new address[](1);
        excludedList[0] = pool;
        token = new V3RewardToken("Reward", "RWD", address(this), address(this), excludedList);
        RewardAsset stock = _direct();
        stock.mint(address(token), 10);
        token.transfer(pool, 1000);
        token.transfer(address(0xdead), 1000);
        token.transfer(address(token), 1000);
        _hold(alice, 100);
        assertEq(token.eligible(pool), 0);
        assertEq(token.eligible(address(0xdead)), 0);
        assertEq(token.eligible(address(token)), 0);
        assertEq(token.eligible(address(this)), 0);
        assertEq(token.totalEligible(), 100);
        vm.prank(pool);
        token.transfer(address(0xdead), 500);
        assertEq(token.totalEligible(), 100);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 10);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        assertEq(token.epochCredit27(pool, epoch), 0);
        assertEq(token.epochCredit27(address(this), epoch), 0);
        assertEq(token.epochCredit27(alice, epoch), 10e27);
    }

    function testActivationAbiIsRemoved() public {
        _hold(alice, 100);
        bytes[5] memory calls = [
            abi.encodeWithSignature("activate(uint256)", 100),
            abi.encodeWithSignature("deactivate(uint256)", 100),
            abi.encodeWithSignature("matureAt(address)", alice),
            abi.encodeWithSignature("pending(address)", alice),
            abi.encodeWithSignature("MATURITY()")
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "activation ABI still present");
        }
    }

    function testFuzzEligibleAlwaysEqualsHolderBalance(uint8[16] memory ops, uint96[16] memory values) public {
        address[3] memory holders = [alice, bob, address(0xca401)];
        token.transfer(alice, 1_000 ether);
        for (uint256 i; i < ops.length; ++i) {
            uint256 op = ops[i] % 4;
            address from = op == 3 ? address(this) : holders[op];
            address to =
                op == 3 ? holders[values[i] % 3] : (ops[i] / 4) % 2 == 0 ? holders[(op + 1) % 3] : address(this);
            uint256 amount = bound(values[i], 0, token.balanceOf(from) < 1e24 ? token.balanceOf(from) : 1e24);
            vm.prank(from);
            token.transfer(to, amount);
            if (i % 3 == 0) vm.warp(vm.getBlockTimestamp() + 1);
            uint256 sum;
            for (uint256 h; h < 3; ++h) {
                assertEq(token.eligible(holders[h]), token.balanceOf(holders[h]));
                sum += token.balanceOf(holders[h]);
            }
            assertEq(token.totalEligible(), sum);
            assertEq(token.eligible(address(this)), 0);
        }
    }

    function testDirectFeeBelongsToSeller() public {
        RewardAsset stock = new RewardAsset();
        token.configurePool(bytes32(uint256(1)), address(stock), 1);
        token.transfer(alice, 100 ether);
        stock.mint(address(token), 10 ether);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 10 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = vm.getBlockTimestamp() / 1 days;
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        vm.prank(alice);
        token.claim(epochs, assets);
        assertEq(stock.balanceOf(alice), 10 ether);
        vm.prank(alice);
        token.claim(epochs, assets);
        assertEq(stock.balanceOf(alice), 10 ether);
    }

    function testCarryPausesUntilWeightExists() public {
        RewardAsset stock = new RewardAsset();
        token.configurePool(bytes32(uint256(1)), address(stock), 1);
        stock.mint(address(token), 7 ether);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 7 ether);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        token.transfer(alice, 100 ether);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = vm.getBlockTimestamp() / 1 days;
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        vm.prank(alice);
        token.claim(epochs, assets);
        assertEq(stock.balanceOf(alice), 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        epochs[0] = vm.getBlockTimestamp() / 1 days;
        vm.prank(alice);
        token.claim(epochs, assets);
        assertEq(stock.balanceOf(alice), 7 ether);
    }

    function testPurchaseDeliveredAfterSaleKeepsOriginalCredit() public {
        RewardAsset stock = new RewardAsset();
        token.setDefaultRewardAsset(address(stock));
        token.configurePool(bytes32(uint256(1)), address(0), 0);
        token.transfer(alice, 100 ether);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        token.onFeeCredit(bytes32(uint256(1)), address(0), 0, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        stock.mint(address(this), 20 ether);
        stock.approve(address(token), 20 ether);
        token.deliver(epoch, address(stock), 10 ether);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = epoch;
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        vm.prank(alice);
        token.claim(epochs, assets);
        assertEq(stock.balanceOf(alice), 10 ether);
        token.deliver(epoch, address(stock), 10 ether);
        vm.prank(alice);
        token.claim(epochs, assets);
        assertEq(stock.balanceOf(alice), 20 ether);
        vm.prank(bob);
        token.claim(epochs, assets);
        assertEq(stock.balanceOf(bob), 0);
    }

    function _direct() internal returns (RewardAsset stock) {
        stock = new RewardAsset();
        token.configurePool(bytes32(uint256(1)), address(stock), 1);
    }

    function _hold(address who, uint256 amount) internal {
        token.transfer(who, amount);
    }

    function _claim(address who, uint256 epoch, address asset) internal {
        uint256[] memory es = new uint256[](1);
        es[0] = epoch;
        address[] memory assets = new address[](1);
        assets[0] = asset;
        vm.prank(who);
        token.claim(es, assets);
    }

    function testContractWalletEarnsButStrategyDoesNot() public {
        address wallet = address(new RewardAsset());
        _hold(wallet, 10 ether);
        assertEq(token.eligible(wallet), 10 ether);
        assertEq(token.eligible(address(this)), 0);
        assertEq(token.totalEligible(), 10 ether);
    }

    function testCarryAdditionDoesNotResetExistingEndpoint() public {
        RewardAsset stock = _direct();
        stock.mint(address(token), 14 ether);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 7 ether);
        _hold(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(alice);
        token.transfer(address(this), 100 ether);
        (, uint256 released,,) = token.carryState();
        assertEq(released, 3 ether);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 7 ether);
        _hold(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 4 days);
        token.releaseCarry();
        (, released,,) = token.carryState();
        assertEq(released, 11 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        token.releaseCarry();
        (, released,,) = token.carryState();
        assertEq(released, 14 ether);
    }

    function testPausedDepositsCoalesceWithoutEarningIdleTime() public {
        RewardAsset stock = _direct();
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 7 ether);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 14 ether);
        (uint256 deposited, uint256 released, uint256 clock,) = token.carryState();
        assertEq(deposited, 21 ether);
        assertEq(released, 0);
        assertEq(clock, 0);
        vm.warp(vm.getBlockTimestamp() + 20 days);
        _hold(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        token.releaseCarry();
        (, released, clock,) = token.carryState();
        assertEq(released, 3 ether);
        assertEq(clock, 1 days);
        vm.prank(alice);
        token.transfer(address(this), 100 ether);
        vm.warp(vm.getBlockTimestamp() + 90 days);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 7 ether);
        token.transfer(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        token.releaseCarry();
        (deposited, released, clock,) = token.carryState();
        assertEq(deposited, 28 ether);
        assertEq(released, 27 ether);
        assertEq(clock, 7 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        token.releaseCarry();
        (, released,,) = token.carryState();
        assertEq(released, deposited);
    }

    function testOneRawCarryDoesNotUnlockBeforeFullSevenDays() public {
        RewardAsset stock = _direct();
        stock.mint(address(token), 1);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 1);
        _hold(alice, 1);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        token.releaseCarry();
        (, uint256 released,,) = token.carryState();
        assertEq(released, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        token.releaseCarry();
        (, released,,) = token.carryState();
        assertEq(released, 1);
    }

    function testDailyHistoryAcrossEmptyDaysAndPartialSale() public {
        RewardAsset stock = _direct();
        _hold(alice, 100);
        uint256 first = vm.getBlockTimestamp() / 1 days;
        stock.mint(address(token), 100);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 20);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        token.transfer(bob, 50);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 30);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 50);
        assertEq(token.epochCredit27(alice, first), 20 * 1e27);
        assertEq(token.epochCredit27(alice, first + 1), 15 * 1e27);
        assertEq(token.epochCredit27(bob, first + 1), 15 * 1e27);
        assertEq(token.epochCredit27(alice, first + 5), 0);
        _claim(alice, first, address(stock));
        _claim(alice, first + 1, address(stock));
        _claim(alice, first + 11, address(stock));
        assertEq(stock.balanceOf(alice), 60);
    }

    function testRepeatedTinyFeesAccumulateIndexAndAccountRemainders() public {
        RewardAsset stock = _direct();
        _hold(alice, 3);
        _hold(bob, 7);
        stock.mint(address(token), 100);
        for (uint256 i; i < 100; ++i) {
            token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 1);
            _claim(alice, vm.getBlockTimestamp() / 1 days, address(stock));
        }
        _claim(bob, vm.getBlockTimestamp() / 1 days, address(stock));
        assertEq(stock.balanceOf(alice), 30);
        assertEq(stock.balanceOf(bob), 70);
        assertEq(stock.balanceOf(address(token)), 0);
    }

    function testPurchaseSupportsMoreThanFourHistoricalAssets() public {
        RewardAsset[5] memory stocks;
        for (uint256 i; i < 5; ++i) {
            stocks[i] = new RewardAsset();
        }
        token.setDefaultRewardAsset(address(stocks[0]));
        token.configurePool(bytes32(uint256(1)), address(0), 0);
        _hold(alice, 100);
        uint256 start = vm.getBlockTimestamp() / 1 days;
        for (uint256 i; i < 5; ++i) {
            if (i != 0) token.declareEpochAsset(start + i, address(stocks[i]));
            vm.warp((start + i) * 1 days + 7200);
            token.onFeeCredit(bytes32(uint256(1)), address(0), 0, 100);
        }
        vm.warp((start + 6) * 1 days);
        for (uint256 i; i < 5; ++i) {
            stocks[i].mint(address(this), 10);
            stocks[i].approve(address(token), 10);
            token.deliver(start + i, address(stocks[i]), 10);
            _claim(alice, start + i, address(stocks[i]));
            assertEq(stocks[i].balanceOf(alice), 10);
        }
    }

    function testUnauthorizedAndBoundedClaim() public {
        RewardAsset stock = _direct();
        vm.prank(alice);
        vm.expectRevert(V3RewardToken.Unauthorized.selector);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 1);
        vm.expectRevert(V3RewardToken.PageTooLarge.selector);
        token.claim(new uint256[](21), new address[](1));
        vm.expectRevert(V3RewardToken.PageTooLarge.selector);
        token.claim(new uint256[](1), new address[](5));
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.configurePool(bytes32(uint256(2)), address(stock), 1);
    }

    function testFuzzRewardsNeverExceedFees(uint96 a0, uint96 b0, uint96 fee0) public {
        uint256 a = bound(a0, 1, 1e24);
        uint256 b = bound(b0, 1, 1e24);
        uint256 fee = bound(fee0, 1, 1e24);
        RewardAsset stock = _direct();
        _hold(alice, a);
        _hold(bob, b);
        stock.mint(address(token), fee);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, fee);
        _claim(alice, vm.getBlockTimestamp() / 1 days, address(stock));
        _claim(bob, vm.getBlockTimestamp() / 1 days, address(stock));
        assertLe(stock.balanceOf(alice) + stock.balanceOf(bob), fee);
        assertEq(stock.balanceOf(address(token)), token.rawLiability(address(stock)));
    }

    function testNativeUsdcPurchaseConfigurationAndNoDailyKeeper() public {
        RewardAsset stock = new RewardAsset();
        token.setDefaultRewardAsset(address(stock));
        token.configurePool(bytes32(uint256(1)), address(0), 0);
        _hold(alice, 100);
        vm.warp(vm.getBlockTimestamp() + 40 days);
        token.onFeeCredit(bytes32(uint256(1)), address(0), 0, 100);
        assertEq(token.epochBudget(vm.getBlockTimestamp() / 1 days), 100);
        assertEq(token.epochAsset(vm.getBlockTimestamp() / 1 days), address(stock));
    }
    event WeightChanged(address indexed account, uint256 previousWeight, uint256 newWeight, uint256 totalWeight);

    function testTransfersPublishWeightChanges() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit WeightChanged(alice, 0, 100, 100);
        token.transfer(alice, 100);
        vm.expectEmit(true, false, false, true, address(token));
        emit WeightChanged(alice, 100, 60, 60);
        vm.expectEmit(true, false, false, true, address(token));
        emit WeightChanged(bob, 0, 40, 100);
        vm.prank(alice);
        token.transfer(bob, 40);
    }

    function testRejectsRewardAssetWithoutCode() public {
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.setDefaultRewardAsset(alice);
    }

    function testFuzzCarryTreeMatchesIndependentStreams(uint64 a, uint64 b, uint64 c, uint32 t1, uint32 t2, uint32 t3)
        public
    {
        CarryHarness harness = new CarryHarness();
        harness.tick(false);
        harness.deposit(a);
        uint256 x = bound(t1, 0, 7 days);
        uint256 y = bound(t2, 0, 7 days);
        uint256 z = bound(t3, 0, 7 days);
        vm.warp(vm.getBlockTimestamp() + x);
        harness.tick(true);
        harness.deposit(b);
        vm.warp(vm.getBlockTimestamp() + y);
        harness.tick(true);
        harness.deposit(c);
        vm.warp(vm.getBlockTimestamp() + z);
        harness.tick(true);
        uint256 expected =
            (uint256(a)
                    * Math.min(x + y + z, 7 days)
                    + uint256(b)
                    * Math.min(y + z, 7 days)
                    + uint256(c)
                    * Math.min(z, 7 days)) / 7 days;
        assertEq(harness.released(), expected);
    }

    function testPurchaseQuoteMustBeNativeUsdc() public {
        RewardAsset stock = new RewardAsset();
        token.setDefaultRewardAsset(address(stock));
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.configurePool(bytes32(uint256(1)), address(stock), 0);
    }

    function testDirectQuoteMustBeAContract() public {
        vm.expectRevert(V3RewardToken.InvalidConfiguration.selector);
        token.configurePool(bytes32(uint256(1)), alice, 1);
    }

    function testSellingOutPreservesCreditAndRebuyCannotTakeIdleCarry() public {
        RewardAsset stock = _direct();
        _hold(alice, 100);
        stock.mint(address(token), 80);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 10);
        uint256 earnedEpoch = vm.getBlockTimestamp() / 1 days;
        vm.prank(alice);
        token.transfer(address(this), 100);
        assertEq(token.totalEligible(), 0);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 70);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        token.transfer(alice, 100);
        _claim(alice, earnedEpoch, address(stock));
        assertEq(stock.balanceOf(alice), 10);
        _claim(alice, vm.getBlockTimestamp() / 1 days, address(stock));
        assertEq(stock.balanceOf(alice), 10);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _claim(alice, vm.getBlockTimestamp() / 1 days, address(stock));
        assertEq(stock.balanceOf(alice), 80);
    }

    function _assertInexactPayoutRollsBack(uint8 mode) internal {
        InexactPayoutAsset stock = new InexactPayoutAsset();
        token.configurePool(bytes32(uint256(1)), address(stock), 1);
        _hold(alice, 100);
        stock.mint(address(token), 101);
        token.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 100);
        stock.setTax(address(token), mode);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        uint256[] memory es = new uint256[](1);
        es[0] = epoch;
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        vm.prank(alice);
        vm.expectRevert(bytes("payout delta"));
        token.claim(es, assets);
        assertEq(token.paidTotal(address(stock)), 0);
        assertEq(token.creditedToPayout(epoch, alice), 0);
        assertEq(stock.balanceOf(address(token)), 101);
        assertEq(stock.balanceOf(alice), 0);
        assertEq(token.rawLiability(address(stock)), 100);
    }

    function testShortPaymentPreservesOriginalDebt() public {
        _assertInexactPayoutRollsBack(1);
    }

    function testExtraSenderTaxPreservesOriginalDebt() public {
        _assertInexactPayoutRollsBack(2);
    }
}

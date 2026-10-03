// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {RewardAsset} from "./V3RewardToken.t.sol";

contract V3RewardHandler is Test {
    V3RewardToken public direct;
    V3RewardToken public purchase;
    RewardAsset public stockA;
    RewardAsset public stockB;
    RewardAsset public stockC;
    address[3] public actors;
    uint256[] public epochs;
    mapping(uint256 => bool) private seen;
    uint256 public deliveries;
    uint256 public fees;
    bytes32 constant POOL = bytes32(uint256(1));

    constructor() {
        stockA = new RewardAsset();
        stockB = new RewardAsset();
        stockC = new RewardAsset();
        direct = new V3RewardToken("Direct", "DIR", address(this), address(this), new address[](0));
        direct.configurePool(POOL, address(stockC), 1);
        purchase = new V3RewardToken("Purchase", "PUR", address(this), address(this), new address[](0));
        purchase.setDefaultRewardAsset(address(stockA));
        purchase.configurePool(POOL, address(0), 0);
        actors = [address(0x1001), address(0x1002), address(0x1003)];
        for (uint256 i; i < 3; ++i) {
            direct.transfer(actors[i], 1_000 ether);
            purchase.transfer(actors[i], 1_000 ether);
        }
        stockA.approve(address(purchase), type(uint256).max);
        stockB.approve(address(purchase), type(uint256).max);
    }

    function advance(uint32 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 6 hours));
    }

    function move(uint8 which, uint8 fromId, uint8 toId, uint96 value) external {
        V3RewardToken t = which % 2 == 0 ? direct : purchase;
        address from = actors[fromId % 3];
        address to = actors[toId % 3];
        uint256 b = t.balanceOf(from);
        if (b == 0) return;
        vm.prank(from);
        t.transfer(to, bound(value, 0, b));
    }

    /// @dev The handler is the excluded strategy/pool: buys and sells change the
    /// eligible denominator, including back to zero (carry) and out again.
    function buy(uint8 which, uint8 actorId, uint96 value) external {
        V3RewardToken t = which % 2 == 0 ? direct : purchase;
        t.transfer(actors[actorId % 3], bound(value, 0, 1_000 ether));
    }

    function sell(uint8 which, uint8 actorId, uint96 value) external {
        V3RewardToken t = which % 2 == 0 ? direct : purchase;
        address who = actors[actorId % 3];
        uint256 b = t.balanceOf(who);
        if (b == 0) return;
        vm.prank(who);
        t.transfer(address(this), bound(value, 0, b));
    }

    /// @dev Same-timestamp buy then full sell; the flash holder must gain no credit.
    function flash(uint8 which, uint96 value) external {
        V3RewardToken t = which % 2 == 0 ? direct : purchase;
        address flasher = address(0x1f1a5);
        uint256 amount = bound(value, 1, 1_000_000 ether);
        t.transfer(flasher, amount);
        vm.prank(flasher);
        t.transfer(address(this), amount);
    }

    function fee(uint96 raw) external {
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        if (!seen[epoch]) {
            if (epochs.length == 16) return;
            seen[epoch] = true;
            epochs.push(epoch);
            if (epoch % 2 != 0 && purchase.epochAsset(epoch) == address(0)) {
                purchase.declareEpochAsset(epoch, address(stockB));
            }
        }
        uint256 amount = bound(raw, 1, 1e20);
        stockC.mint(address(direct), amount);
        direct.onFeeCredit(POOL, address(stockC), 1, amount);
        purchase.onFeeCredit(POOL, address(0), 0, amount);
        ++fees;
    }

    function deliver(uint8 seed, uint96 raw) external {
        if (epochs.length == 0) return;
        uint256 epoch = epochs[seed % epochs.length];
        if (epoch >= vm.getBlockTimestamp() / 1 days || purchase.epochBudget(epoch) == 0) return;
        RewardAsset asset = RewardAsset(purchase.epochAsset(epoch));
        uint256 amount = bound(raw, 1, 1e20);
        asset.mint(address(this), amount);
        purchase.deliver(epoch, address(asset), amount);
        ++deliveries;
    }

    function claim(uint8 which, uint8 actorId, uint8 seed) external {
        if (epochs.length == 0) return;
        V3RewardToken t = which % 2 == 0 ? direct : purchase;
        uint256 epoch = epochs[seed % epochs.length];
        address asset = t.epochAsset(epoch);
        if (asset == address(0)) return;
        uint256[] memory es = new uint256[](1);
        es[0] = epoch;
        address[] memory assets = new address[](1);
        assets[0] = asset;
        vm.prank(actors[actorId % 3]);
        t.claim(es, assets);
    }

    function epochCount() external view returns (uint256) {
        return epochs.length;
    }
}

contract V3RewardInvariantTest is StdInvariant, Test {
    V3RewardHandler public handler;

    function setUp() public {
        vm.warp(10 days);
        handler = new V3RewardHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.move.selector;
        selectors[2] = handler.buy.selector;
        selectors[3] = handler.fee.selector;
        selectors[4] = handler.deliver.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.sell.selector;
        selectors[7] = handler.flash.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_AllThreeAssetsCoverEveryRawLiability() public view {
        V3RewardToken p = handler.purchase();
        V3RewardToken d = handler.direct();
        assertEq(handler.stockA().balanceOf(address(p)), p.rawLiability(address(handler.stockA())));
        assertEq(handler.stockB().balanceOf(address(p)), p.rawLiability(address(handler.stockB())));
        assertEq(handler.stockC().balanceOf(address(d)), d.rawLiability(address(handler.stockC())));
    }

    function invariant_EligibleMatchesBalancesAndFlashEarnsNothing() public view {
        for (uint256 j; j < 2; ++j) {
            V3RewardToken t = j == 0 ? handler.direct() : handler.purchase();
            uint256 sum;
            for (uint256 i; i < 3; ++i) {
                address who = handler.actors(i);
                uint256 e = t.eligible(who);
                assertEq(t.balanceOf(who), e);
                sum += e;
            }
            assertEq(t.totalEligible(), sum);
            assertEq(t.eligible(address(handler)), 0);
            assertEq(t.eligible(address(0x1f1a5)), 0);
            assertEq(t.totalSupply(), 1_000_000_000 ether);
            for (uint256 i; i < handler.epochCount(); ++i) {
                assertEq(t.epochCredit27(address(0x1f1a5), handler.epochs(i)), 0, "flash holder earned");
            }
        }
    }

    function invariant_TotalHistoricalEntitlementsNeverExceedEpochBudget() public view {
        for (uint256 j; j < 2; ++j) {
            V3RewardToken t = j == 0 ? handler.direct() : handler.purchase();
            for (uint256 i; i < handler.epochCount(); ++i) {
                uint256 epoch = handler.epochs(i);
                uint256 credit;
                for (uint256 a; a < 3; ++a) {
                    credit += t.epochCredit27(handler.actors(a), epoch);
                }
                assertLe(credit, t.epochBudget(epoch) * 1e27);
            }
        }
    }
}

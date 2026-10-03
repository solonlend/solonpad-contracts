// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FloatRebalancer} from "../../src/v3/stock/FloatRebalancer.sol";
import {MockLzEndpoint, MockTokenMessenger, MockMessageTransmitter} from "./helpers/StockMocks.sol";
import {NativeViewUSDC} from "./helpers/NativeViewUSDC.sol";

/// @dev The hub's float payout: SolonStockHub.withdrawFloat -> _send = to.call{value}("") or TransferFailed.
contract HubFloatSender {
    error TransferFailed();

    function withdrawFloat(address to, uint256 amount) external {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}

/// @notice Decimals fix M3 (docs/PLAN-v3-contracts.md "位数修复"): FloatRebalancer is documented as one of the hub's
///         float recipients, but the hub pays NATIVE USDC (18 dp) while the rebalancer spends the 0x3600 view (6 dp).
///         With a shared-balance 0x3600 double: the hub payout must land, the rebalance spends whole 6-dp units, and
///         the sub-1e12 tail the view cannot move is sweepable by the owner (it was stranded forever).
contract DecimalsFloatRebalancerTest is Test {
    uint256 constant SIGNER = 0xF10A7;
    NativeViewUSDC usdc;
    MockTokenMessenger messenger;
    FloatRebalancer rebalancer;
    HubFloatSender hub;
    address owner = address(0xA11CE);
    address guardian = address(0x6A2D);

    function setUp() public {
        usdc = new NativeViewUSDC();
        messenger = new MockTokenMessenger();
        rebalancer = new FloatRebalancer(
            FloatRebalancer.Config(
                address(new MockLzEndpoint(30417)),
                owner,
                guardian,
                address(usdc),
                address(messenger),
                address(new MockMessageTransmitter()),
                0,
                address(0xE7),
                address(0xADA),
                30416,
                vm.addr(SIGNER)
            )
        );
        hub = new HubFloatSender();
        vm.deal(address(hub), 10_000 ether);
        vm.prank(owner);
        rebalancer.proposeEnable();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        rebalancer.enable();
    }

    function testHubNativeFloatPayoutLandsAsSixDpView() public {
        hub.withdrawFloat(address(rebalancer), 2_000 ether + 1); // 2000.000000000000000001
        assertEq(address(rebalancer).balance, 2_000 ether + 1, "native view");
        assertEq(usdc.balanceOf(address(rebalancer)), 2_000e6, "0x3600 view");
        (bool ok, uint256 free,) = rebalancer.previewRebalance(2_000e6);
        assertTrue(ok);
        assertEq(free, 2_000e6);
    }

    function testRebalanceSpendsWholeUnitsAndOwnerSweepsOnlyTheTail() public {
        hub.withdrawFloat(address(rebalancer), 2_000 ether + 1);
        FloatRebalancer.StartQuote memory q =
            FloatRebalancer.StartQuote(bytes32("r1"), 2_000e6, 1_990e6, block.timestamp + 1 hours, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER, rebalancer.quoteDigest(q));
        rebalancer.start(q, abi.encodePacked(r, s, v));
        assertEq(address(messenger).balance, 2_000 ether, "CCTP burned exactly the 6-dp amount");
        assertEq(address(rebalancer).balance, 1, "1 wei tail the view cannot move");
        assertEq(rebalancer.inFlight(), 2_000e6);

        vm.expectRevert();
        rebalancer.sweepDust(address(0xD057)); // owner only
        vm.prank(owner);
        rebalancer.sweepDust(address(0xD057));
        assertEq(address(0xD057).balance, 1);
        assertEq(address(rebalancer).balance, 0);
    }

    function testSweepNeverTouchesWholeUnits() public {
        hub.withdrawFloat(address(rebalancer), 5 ether + 999_999_999_999);
        vm.prank(owner);
        rebalancer.sweepDust(owner);
        assertEq(owner.balance, 999_999_999_999);
        assertEq(usdc.balanceOf(address(rebalancer)), 5e6, "float untouched");
        assertEq(address(rebalancer).balance, 5 ether);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CanonicalGate} from "../../../../src/v3/stock/CanonicalGate.sol";
import {Messages} from "../../../../src/v3/stock/libs/Messages.sol";
import {MockUSDG, MockTokenMessenger, MockMessageTransmitter} from "../../helpers/StockMocks.sol";

/// @dev Gate in isolation; this test contract plays the hub.
contract CovDCanonicalGateTest is Test {
    MockUSDG usdc;
    MockTokenMessenger messenger;
    MockMessageTransmitter transmitter;
    CanonicalGate gate;
    address owner = address(0xA11CE);
    address funds = address(0x6F);
    address ethMessenger = address(0xE7);
    address bridger = address(0xB41D);

    function setUp() public {
        usdc = new MockUSDG();
        messenger = new MockTokenMessenger();
        transmitter = new MockMessageTransmitter();
        gate = _gate(address(this), funds);
    }

    function _gate(address hub, address f) internal returns (CanonicalGate) {
        return new CanonicalGate(
            address(messenger), address(transmitter), address(usdc), 0, ethMessenger, hub, f, owner
        );
    }

    function _d() internal pure returns (Messages.Deliver memory) {
        return Messages.Deliver(bytes32(uint256(7)), address(0x1234), 1e18, address(0xCAFE), Messages.DeliverMode.Stock);
    }

    /// L77: hub and funds recipient must be set.
    function testCovD_ConstructorRejectsZeroHubOrRecipient() public {
        vm.expectRevert(CanonicalGate.ZeroAddress.selector);
        _gate(address(0), funds);
        vm.expectRevert(CanonicalGate.ZeroAddress.selector);
        _gate(address(this), address(0));
    }

    /// L96 hub only; L97 needs a bridger; L99 needs the 1 USDC hook float; then burns exactly 1 USDC.
    function testCovD_SendDeliverGuardsThenBurnsOneUsdc() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(CanonicalGate.NotHub.selector);
        gate.sendDeliver(_d());
        vm.expectRevert(CanonicalGate.ZeroAddress.selector);
        gate.sendDeliver(_d());
        vm.prank(owner);
        gate.setBridger(bridger);
        vm.expectRevert(abi.encodeWithSelector(CanonicalGate.InsufficientUsdc.selector, uint256(0), uint256(1e6)));
        gate.sendDeliver(_d());
        // fund() pulls from the caller
        usdc.mint(address(this), 1e6 - 1);
        usdc.approve(address(gate), type(uint256).max);
        gate.fund(1e6 - 1);
        vm.expectRevert(abi.encodeWithSelector(CanonicalGate.InsufficientUsdc.selector, uint256(1e6 - 1), uint256(1e6)));
        gate.sendDeliver(_d());
        usdc.mint(address(this), 2);
        gate.fund(2);
        assertEq(usdc.balanceOf(address(gate)), 1e6 + 1);
        gate.sendDeliver(_d());
        assertEq(messenger.burnCount(), 1);
        assertEq(usdc.balanceOf(address(gate)), 1);
        assertEq(usdc.balanceOf(address(messenger)), 1e6);
        assertEq(keccak256(messenger.hookOf(0)), keccak256(Messages.encode(_d())));
    }

    /// L148 zero bridger; first set immediate; later changes wait 48h (L160 both conditions).
    function testCovD_BridgerChangeTimelock() public {
        vm.startPrank(owner);
        vm.expectRevert(CanonicalGate.ZeroAddress.selector);
        gate.setBridger(address(0));
        vm.expectRevert(CanonicalGate.Timelocked.selector);
        gate.executeBridger(); // nothing proposed
        gate.setBridger(bridger);
        assertEq(gate.bridger(), bridger);
        gate.setBridger(address(0xB2));
        assertEq(gate.bridger(), bridger, "a change is only proposed");
        assertEq(gate.pendingBridger(), address(0xB2));
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(CanonicalGate.Timelocked.selector);
        gate.executeBridger();
        vm.warp(block.timestamp + 1);
        gate.executeBridger();
        vm.stopPrank();
        assertEq(gate.bridger(), address(0xB2));
        assertEq(gate.pendingBridger(), address(0));
        assertEq(gate.pendingBridgerEta(), 0);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        gate.executeBridger();
    }

    /// setKeeper owner-only; the keeper withdraws, only ever to the fixed recipient.
    function testCovD_KeeperWithdrawsToFixedRecipient() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        gate.setKeeper(address(0x4EE));
        vm.prank(owner);
        gate.setKeeper(address(0x4EE));
        assertEq(gate.keeper(), address(0x4EE));
        usdc.mint(address(gate), 5e6);
        vm.prank(address(0x4EE));
        gate.withdraw(2e6);
        assertEq(usdc.balanceOf(funds), 2e6);
        vm.prank(address(0xBAD));
        vm.expectRevert(CanonicalGate.NotKeeper.selector);
        gate.withdraw(1);
        // native hook payments are accepted
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(gate).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(gate).balance, 1 ether);
    }
}

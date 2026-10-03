// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FloatReceiver} from "../../../../src/v3/stock/robinhood/FloatReceiver.sol";
import {MockLzEndpoint, MockUSDG} from "../../helpers/StockMocks.sol";

contract CovDFloatReceiverTest is Test {
    uint32 constant ARC_EID = 30417;
    uint32 constant RH_EID = 30416;

    MockLzEndpoint rhEp;
    MockUSDG usdg;
    FloatReceiver receiver;
    address owner = address(0xA11CE);
    address oft = address(0x0F7);
    address adapter = address(0xADA);
    address vault = address(0x7A017);
    address rebalancer = address(0x4EB);

    function setUp() public {
        rhEp = new MockLzEndpoint(RH_EID);
        usdg = new MockUSDG();
        receiver = new FloatReceiver(address(rhEp), owner, address(usdg), oft, adapter, vault, ARC_EID);
        vm.prank(owner);
        receiver.setPeer(ARC_EID, bytes32(uint256(uint160(rebalancer))));
    }

    function _compose(uint256 amount, bytes32 from, bytes32 id) internal pure returns (bytes memory) {
        return abi.encodePacked(uint64(1), uint32(30101), amount, from, abi.encode(id));
    }

    function _adapter() internal view returns (bytes32) {
        return bytes32(uint256(uint160(adapter)));
    }

    function testCovD_constructorRejectsZeroAddresses() public {
        vm.expectRevert();
        new FloatReceiver(address(rhEp), owner, address(0), oft, adapter, vault, ARC_EID);
        vm.expectRevert();
        new FloatReceiver(address(rhEp), owner, address(usdg), address(0), adapter, vault, ARC_EID);
        vm.expectRevert();
        new FloatReceiver(address(rhEp), owner, address(usdg), oft, address(0), vault, ARC_EID);
        vm.expectRevert();
        new FloatReceiver(address(rhEp), owner, address(usdg), oft, adapter, address(0), ARC_EID);
    }

    function testCovD_composeForwardsToVaultAndReportsReceiptOnce() public {
        (bool ok,) = address(receiver).call{value: 1 ether}(""); // receive(): gas for receipts
        assertTrue(ok);
        usdg.mint(address(receiver), 500e6); // the OFT credit
        bytes32 id = keccak256("leg-1");
        bytes32 guid = keccak256("guid-1");
        rhEp.composeTo(address(receiver), oft, guid, _compose(500e6, _adapter(), id));
        assertEq(usdg.balanceOf(vault), 500e6);
        assertEq(usdg.balanceOf(address(receiver)), 0);
        assertTrue(receiver.guidUsed(guid));
        assertEq(receiver.received(id), 500e6);
        assertEq(rhEp.packetCount(), 1);
        assertEq(rhEp.packetMessage(0), abi.encode(id, guid, uint256(500e6)));
        assertEq(address(receiver).balance, 1 ether - 0.01 ether);

        usdg.mint(address(receiver), 500e6);
        vm.expectRevert(FloatReceiver.Duplicate.selector);
        rhEp.composeTo(address(receiver), oft, guid, _compose(500e6, _adapter(), keccak256("leg-2")));
        vm.expectRevert(FloatReceiver.Duplicate.selector);
        rhEp.composeTo(address(receiver), oft, keccak256("guid-2"), _compose(500e6, _adapter(), id));
        assertEq(usdg.balanceOf(vault), 500e6);
    }

    function testCovD_shortComposeMessageRejected() public {
        vm.deal(address(receiver), 1 ether);
        usdg.mint(address(receiver), 1e6);
        bytes memory m = _compose(1e6, _adapter(), bytes32(uint256(1)));
        bytes memory short_ = new bytes(107);
        for (uint256 i; i < 107; ++i) {
            short_[i] = m[i];
        }
        vm.expectRevert(FloatReceiver.WrongComposer.selector);
        rhEp.composeTo(address(receiver), oft, bytes32(uint256(9)), short_);
        assertEq(usdg.balanceOf(vault), 0);
    }

    function testCovD_composeFromOtherSenderRejected() public {
        vm.deal(address(receiver), 1 ether);
        usdg.mint(address(receiver), 1e6);
        vm.expectRevert(FloatReceiver.WrongComposer.selector);
        rhEp.composeTo(
            address(receiver), oft, bytes32(uint256(9)), _compose(1e6, bytes32(uint256(0xBAD)), bytes32(uint256(1)))
        );
        assertEq(usdg.balanceOf(vault), 0);
        assertFalse(receiver.guidUsed(bytes32(uint256(9))));
    }

    function testCovD_noGasForReceiptRevertsWholeCompose() public {
        usdg.mint(address(receiver), 1e6);
        vm.expectRevert(abi.encodeWithSignature("NotEnoughNative(uint256)", uint256(0)));
        rhEp.composeTo(address(receiver), oft, bytes32(uint256(9)), _compose(1e6, _adapter(), bytes32(uint256(1))));
        assertEq(usdg.balanceOf(vault), 0, "credit stays here for a retried compose");
        assertFalse(receiver.guidUsed(bytes32(uint256(9))));
        assertEq(receiver.received(bytes32(uint256(1))), 0);
    }

    function testCovD_inboundLzMessagesAlwaysRejected() public {
        vm.expectRevert(FloatReceiver.WrongComposer.selector);
        rhEp.inject(ARC_EID, rebalancer, address(receiver), abi.encode(uint256(1)));
    }

    function testCovD_ownershipIsTwoStep() public {
        address n = address(0x0E2);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        receiver.transferOwnership(n);
        vm.prank(owner);
        receiver.transferOwnership(n);
        assertEq(receiver.owner(), owner);
        assertEq(receiver.pendingOwner(), n);
        vm.prank(n);
        receiver.acceptOwnership();
        assertEq(receiver.owner(), n);
    }
}

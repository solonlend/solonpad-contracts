// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CanonicalBase} from "../../Canonical.t.sol";
import {EthereumBridger} from "../../../../src/v3/stock/ethereum/EthereumBridger.sol";
import {Messages} from "../../../../src/v3/stock/libs/Messages.sol";
import {CctpV2} from "../../../../src/v3/stock/libs/CctpV2.sol";

/// @notice Branch coverage for the canonical Ethereum relay: constructor guard, relay source checks,
///         checkpoint acceptance without hook USDC, manual forward, funding, views and native receive.
contract CovDEthereumBridgerTest is CanonicalBase {
    function _deliverHook(bytes32 ref) internal view returns (bytes memory) {
        return Messages.encode(Messages.Deliver(ref, address(stock), 1e18, rhUser, Messages.DeliverMode.Stock));
    }

    function _accept(uint256 root) internal {
        Messages.Checkpoint memory c = Messages.Checkpoint(bytes32(root), uint64(root), uint64(root));
        l1Bridge.executeCall(address(vault), address(bridger), abi.encodeCall(bridger.acceptCheckpoint, (c)));
    }

    // L78 both arms
    function test_constructor_zeroFundsRecipient_reverts() public {
        vm.expectRevert();
        new EthereumBridger(
            address(ethTransmitter),
            address(ethMessenger),
            address(ethUsdc),
            address(inbox),
            address(l1Bridge),
            ARC_DOMAIN,
            address(arcMessenger),
            address(gate),
            address(vault),
            address(0),
            owner
        );
        EthereumBridger ok = new EthereumBridger(
            address(ethTransmitter),
            address(ethMessenger),
            address(ethUsdc),
            address(inbox),
            address(l1Bridge),
            ARC_DOMAIN,
            address(arcMessenger),
            address(gate),
            address(vault),
            bridgerFunds,
            owner
        );
        assertEq(ok.fundsRecipient(), bridgerFunds);
    }

    // L102/L104/L105 + deliveryOf
    function test_relay_rejectsUnattestedWrongSourceAndNotFromGate() public {
        bytes32 ref = bytes32(uint256(77));
        bytes memory hook = _deliverHook(ref);
        bytes memory good = _cctp(ARC_DOMAIN, ETH_DOMAIN, address(arcMessenger), address(gate), hook);
        vm.expectRevert(EthereumBridger.ReceiveFailed.selector);
        bridger.relay(good, "forged", 1e6, 1);
        bytes memory badDomain = _cctp(7, ETH_DOMAIN, address(arcMessenger), address(gate), hook);
        vm.expectRevert(
            abi.encodeWithSelector(EthereumBridger.WrongSource.selector, uint32(7), CctpV2.toBytes32(address(arcMessenger)))
        );
        bridger.relay(badDomain, "valid", 1e6, 1);
        bytes memory badMessenger = _cctp(ARC_DOMAIN, ETH_DOMAIN, address(0xE7), address(gate), hook);
        vm.expectRevert(
            abi.encodeWithSelector(EthereumBridger.WrongSource.selector, ARC_DOMAIN, CctpV2.toBytes32(address(0xE7)))
        );
        bridger.relay(badMessenger, "valid", 1e6, 1);
        bytes memory notGate = _cctp(ARC_DOMAIN, ETH_DOMAIN, address(arcMessenger), address(0xBAD), hook);
        vm.expectRevert(abi.encodeWithSelector(EthereumBridger.NotFromGate.selector, CctpV2.toBytes32(address(0xBAD))));
        bridger.relay(notGate, "valid", 1e6, 1);
        // a gate burn whose hook is not a Deliver (a shape-compatible Result, so only the type check fails)
        bytes memory wrongType = _cctp(
            ARC_DOMAIN,
            ETH_DOMAIN,
            address(arcMessenger),
            address(gate),
            Messages.encode(Messages.Result(ref, address(stock), Messages.Outcome.Bought, 5, 0, 1))
        );
        vm.expectRevert(abi.encodeWithSelector(Messages.BadMessageType.selector, uint8(2), uint8(3)));
        bridger.relay(wrongType, "valid", 1e6, 1);
        assertFalse(bridger.relayed(ref));
        assertEq(inbox.ticketCount(), 0);
        // the genuine one goes through and is kept for retries
        uint256 ticket = bridger.relay(good, "valid", 1e6, 1);
        assertEq(ticket, 1);
        assertTrue(bridger.relayed(ref));
        Messages.Deliver memory d = bridger.deliveryOf(ref);
        assertEq(d.ref, ref);
        assertEq(d.underlying, address(stock));
        assertEq(d.shares, 1e18);
        assertEq(d.to, rhUser);
        assertEq(uint8(d.mode), uint8(Messages.DeliverMode.Stock));
    }

    // L139 false arm, L144 both arms, L186, fund, checkpointCount/At
    function test_checkpointsWaitForHookUsdcThenForwardInOrder() public {
        vm.prank(owner);
        bridger.withdraw(10e6); // no hook float
        assertEq(ethUsdc.balanceOf(address(bridger)), 0);
        uint256 burns = ethMessenger.burnCount();
        vm.expectRevert(EthereumBridger.NothingToForward.selector);
        bridger.forward();
        _accept(1); // accepted, not forwarded
        _accept(2);
        assertEq(bridger.checkpointCount(), 2);
        assertEq(bridger.forwardedThrough(), 0);
        assertEq(ethMessenger.burnCount(), burns);
        Messages.Checkpoint memory c1 = bridger.checkpointAt(1);
        assertEq(c1.root, bytes32(uint256(2)));
        assertEq(c1.fromSeq, 2);
        vm.expectRevert(abi.encodeWithSelector(EthereumBridger.InsufficientUsdc.selector, uint256(0), uint256(1e6)));
        bridger.forward();
        // anyone funds the hook float
        ethUsdc.mint(address(this), 2e6);
        ethUsdc.approve(address(bridger), 2e6);
        bridger.fund(1e6);
        // one USDC for two pending checkpoints: all-or-nothing, the second iteration reverts
        vm.expectRevert(abi.encodeWithSelector(EthereumBridger.InsufficientUsdc.selector, uint256(0), uint256(1e6)));
        bridger.forward();
        assertEq(bridger.forwardedThrough(), 0);
        bridger.fund(1e6);
        bridger.forward();
        assertEq(bridger.forwardedThrough(), 2);
        assertEq(ethMessenger.burnCount(), burns + 2);
        assertEq(ethMessenger.hookOf(burns + 1), Messages.encode(c1), "in order");
        assertEq(ethUsdc.balanceOf(address(bridger)), 0);
        vm.expectRevert(EthereumBridger.NothingToForward.selector);
        bridger.forward();
    }

    /// Liveness observation: with 1 <= USDC < pending checkpoints, `acceptCheckpoint` itself reverts
    /// (the auto-forward loops over every pending checkpoint). The outbox call can be re-executed after
    /// anyone tops the float up, so nothing is lost, but the checkpoint is delayed until then.
    function test_acceptCheckpoint_revertsWhileFloatCoversOnlySomePending() public {
        vm.prank(owner);
        bridger.withdraw(10e6);
        _accept(1); // pending, no USDC
        ethUsdc.mint(address(this), 2e6);
        ethUsdc.approve(address(bridger), 2e6);
        bridger.fund(1e6);
        Messages.Checkpoint memory c = Messages.Checkpoint(bytes32(uint256(2)), 2, 2);
        bytes memory call_ = abi.encodeCall(bridger.acceptCheckpoint, (c));
        vm.expectRevert(abi.encodeWithSelector(EthereumBridger.InsufficientUsdc.selector, uint256(0), uint256(1e6)));
        l1Bridge.executeCall(address(vault), address(bridger), call_);
        assertEq(bridger.checkpointCount(), 1);
        bridger.fund(1e6);
        l1Bridge.executeCall(address(vault), address(bridger), call_); // re-executed: accepted and both forwarded
        assertEq(bridger.checkpointCount(), 2);
        assertEq(bridger.forwardedThrough(), 2);
    }

    // receive(): the bridger accepts ETH (ticket refunds / gas float)
    function test_receive_acceptsEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = payable(address(bridger)).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(bridger).balance, 1 ether);
    }
}

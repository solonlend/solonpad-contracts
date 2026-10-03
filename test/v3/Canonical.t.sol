// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StockSystemBase} from "./ReserveVault.t.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {HubSettlement} from "../../src/v3/stock/HubSettlement.sol";
import {CanonicalGate} from "../../src/v3/stock/CanonicalGate.sol";
import {EthereumBridger} from "../../src/v3/stock/ethereum/EthereumBridger.sol";
import {Messages} from "../../src/v3/stock/libs/Messages.sol";
import {CctpV2} from "../../src/v3/stock/libs/CctpV2.sol";
import {AddressAlias} from "../../src/v3/stock/libs/Arbitrum.sol";
import {MockUSDG, MockTokenMessenger, MockMessageTransmitter, MockArbBridge, MockInbox} from "./helpers/StockMocks.sol";

contract RejectingHolder {
    receive() external payable {
        revert("no native");
    }
}

abstract contract CanonicalBase is StockSystemBase {
    uint32 constant ETH_DOMAIN = 0;
    uint32 constant ARC_DOMAIN = 26;

    MockUSDG arcUsdc;
    MockUSDG ethUsdc;
    MockTokenMessenger arcMessenger;
    MockTokenMessenger ethMessenger;
    MockMessageTransmitter arcTransmitter;
    MockMessageTransmitter ethTransmitter;
    MockArbBridge l1Bridge;
    MockInbox inbox;
    CanonicalGate gate;
    EthereumBridger bridger;
    address gateFunds = address(0x6F);
    address bridgerFunds = address(0xBF);
    address rhUser = address(0xCAFE);
    uint256 cctpNonce;

    function setUp() public virtual override {
        super.setUp();
        arcUsdc = new MockUSDG();
        ethUsdc = new MockUSDG();
        arcMessenger = new MockTokenMessenger();
        ethMessenger = new MockTokenMessenger();
        arcTransmitter = new MockMessageTransmitter();
        ethTransmitter = new MockMessageTransmitter();
        l1Bridge = new MockArbBridge();
        inbox = new MockInbox();
        gate = new CanonicalGate(
            address(arcMessenger),
            address(arcTransmitter),
            address(arcUsdc),
            ETH_DOMAIN,
            address(ethMessenger),
            address(hub),
            gateFunds,
            owner
        );
        bridger = new EthereumBridger(
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
        vm.startPrank(owner);
        hub.setCanonicalGate(address(gate));
        gate.setBridger(address(bridger));
        vault.setBridger(address(bridger)); // replaces the placeholder: waits 48h
        vm.warp(block.timestamp + 48 hours);
        vault.executeBridger();
        vm.stopPrank();
        arcUsdc.mint(address(gate), 10e6);
        ethUsdc.mint(address(bridger), 10e6);
    }

    // ---------------------------------------------------------------- lane helpers

    /// RH checkpoint -> outbox -> Ethereum bridger -> CCTP hook -> Arc gate. Returns the gate index.
    function _checkpointToArc() internal returns (uint256 index) {
        vault.checkpoint();
        uint256 n = arbSys.callCount();
        (address dest,) = arbSys.calls(n - 1);
        assertEq(dest, address(bridger));
        l1Bridge.executeCall(address(vault), address(bridger), arbSys.callData(n - 1));
        uint256 b = ethMessenger.burnCount() - 1;
        assertEq(ethMessenger.finalityOf(b), CctpV2.FINALITY_FINALIZED, "checkpoint burns wait for finality");
        gate.relay(
            _cctp(ETH_DOMAIN, ARC_DOMAIN, address(ethMessenger), address(bridger), ethMessenger.hookOf(b)), "valid"
        );
        index = gate.checkpointCount() - 1;
    }

    /// Arc gate burn -> Ethereum bridger relay -> retryable ticket -> vault.deliver on RH.
    function _deliverToReserve() internal {
        uint256 b = arcMessenger.burnCount() - 1;
        assertEq(arcMessenger.finalityOf(b), CctpV2.FINALITY_FINALIZED, "deliveries burn with finality");
        bridger.relay(
            _cctp(ARC_DOMAIN, ETH_DOMAIN, address(arcMessenger), address(gate), arcMessenger.hookOf(b)), "valid", 1e6, 1
        );
        (address to, bytes memory data) = inbox.ticketData(inbox.ticketCount() - 1);
        assertEq(to, address(vault));
        vm.prank(AddressAlias.applyL1ToL2Alias(address(bridger)));
        (bool ok,) = address(vault).call(data);
        assertTrue(ok);
    }

    function _cctp(uint32 src, uint32 dst, address messenger, address messageSender, bytes memory hook)
        internal
        returns (bytes memory)
    {
        return CctpV2.build(
            src,
            dst,
            bytes32(++cctpNonce),
            CctpV2.toBytes32(messenger),
            bytes32(0),
            bytes32(0),
            CctpV2.FINALITY_FINALIZED,
            CctpV2.FINALITY_FINALIZED,
            bytes32(0),
            bytes32(0),
            1e6,
            CctpV2.toBytes32(messageSender),
            hook
        );
    }

    function _proof(uint256 fromSeq, uint256 toSeq, uint256 seq) internal view returns (bytes32[] memory proof) {
        uint256 n = toSeq - fromSeq + 1;
        bytes32[] memory level = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            level[i] = Messages.leaf(vault.resultAt(fromSeq + i));
        }
        bytes32[] memory tmp = new bytes32[](32);
        uint256 depth;
        uint256 idx = seq - fromSeq;
        while (n > 1) {
            uint256 sib = idx ^ 1;
            if (sib < n) tmp[depth++] = level[sib];
            uint256 m = (n + 1) / 2;
            for (uint256 i; i < m; ++i) {
                uint256 a = 2 * i;
                level[i] = a + 1 < n ? _hash(level[a], level[a + 1]) : level[a];
            }
            idx /= 2;
            n = m;
        }
        proof = new bytes32[](depth);
        for (uint256 i; i < depth; ++i) {
            proof[i] = tmp[i];
        }
    }

    function _hash(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _reconcile(uint256 seq, uint256 index) internal {
        Messages.Checkpoint memory c = gate.checkpointAt(index);
        hub.reconcile(vault.resultAt(seq), index, _proof(c.fromSeq, c.toSeq, seq));
    }
}

contract CanonicalTest is CanonicalBase {
    function testCheckpointConfirmsTheFastLaneAndReleasesUnreviewedExposure() public {
        _boughtOrder(1_000e18);
        _boughtOrder(500e18);
        assertEq(hub.unreconciledCount(), 2);
        assertEq(capacity.unreviewedUsd(), 997.5e18 + 498.75e18);
        uint256 index = _checkpointToArc();
        _reconcile(0, index);
        _reconcile(1, index);
        assertEq(capacity.unreviewedUsd(), 0, "canonical review frees the $10k unreviewed budget");
        hub.checkStale();
        assertEq(hub.unreconciledCount(), 0);
        assertFalse(hub.mintsHalted());
        Messages.Result memory r = vault.resultAt(0);
        bytes32[] memory p = _proof(0, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(SolonStockHub.AlreadyReconciled.selector, r.ref));
        hub.reconcile(r, index, p);
    }

    function testForgedProofsSourcesAndReplaysAreRejected() public {
        _boughtOrder(1_000e18);
        _boughtOrder(1_000e18);
        uint256 index = _checkpointToArc();
        Messages.Result memory r = vault.resultAt(0);
        bytes32[] memory p = _proof(0, 1, 0);
        r.amountOut += 1;
        vm.expectRevert(CanonicalGate.BadProof.selector);
        hub.reconcile(r, index, p);
        r = vault.resultAt(0);
        r.seq = 5;
        vm.expectRevert(abi.encodeWithSelector(CanonicalGate.BadCheckpoint.selector, index, uint64(5)));
        hub.reconcile(r, index, p);
        // Gate: wrong source domain, wrong Ethereum sender, not from the bridger, replayed message.
        bytes memory hook = ethMessenger.hookOf(0);
        bytes memory m1 = _cctp(7, ARC_DOMAIN, address(ethMessenger), address(bridger), hook);
        bytes memory m2 = _cctp(ETH_DOMAIN, ARC_DOMAIN, address(0xE7), address(bridger), hook);
        bytes memory m3 = _cctp(ETH_DOMAIN, ARC_DOMAIN, address(ethMessenger), address(0xE8), hook);
        vm.expectRevert();
        gate.relay(m1, "valid");
        vm.expectRevert();
        gate.relay(m2, "valid");
        vm.expectRevert();
        gate.relay(m3, "valid");
        bytes memory m = _cctp(ETH_DOMAIN, ARC_DOMAIN, address(ethMessenger), address(bridger), hook);
        gate.relay(m, "valid");
        vm.expectRevert(CanonicalGate.ReceiveFailed.selector);
        gate.relay(m, "valid");
        // Bridger: only the rollup outbox, only for the vault as L2 sender.
        Messages.Checkpoint memory c = Messages.Checkpoint(bytes32(uint256(1)), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(EthereumBridger.NotOutbox.selector, address(this)));
        bridger.acceptCheckpoint(c);
        bytes memory call_ = abi.encodeCall(bridger.acceptCheckpoint, (c));
        vm.expectRevert(abi.encodeWithSelector(EthereumBridger.NotFromVault.selector, address(0xBAD)));
        l1Bridge.executeCall(address(0xBAD), address(bridger), call_);
    }

    function testMismatchHaltsMintingMarksDisputedAndVoidStaysInTheHub() public {
        // A holder contract that refuses native, so its payout waits per order.
        RejectingHolder holder = new RejectingHolder();
        _boughtOrder(1_000e18);
        vm.prank(user);
        token.transfer(address(holder), 5e18);
        vm.prank(owner);
        hub.setFloatEnabled(true);
        hub.fundFloat{value: 2_000 ether}();
        vm.deal(address(holder), 1 ether);
        vm.prank(address(holder));
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 5e18, 1);
        // A forged Sold result is verified by a compromised DVN set and applied first ...
        Messages.Result memory forged =
            Messages.Result(bytes32(id), address(stock), Messages.Outcome.Sold, 5e18, 900e6, 0);
        arcEp.inject(RH_EID, address(vault), address(hub), Messages.encode(forged));
        uint256 owed = hub.getOrder(id).owed;
        assertGt(owed, 0, "float advanced a payout the holder could not take");
        // ... while the reserve really failed that sale (the venue was down).
        venue.setFail(true);
        _deliverLatestOrder();
        _deliverLatestResult(); // real Failed result: ignored by the hub (order no longer open)
        uint256 index = _checkpointToArc();
        uint256 seq = vault.resultCount() - 1;
        _reconcile(seq, index);
        assertTrue(hub.mintsHalted(), "a mismatch halts minting");
        assertTrue(hub.getOrder(id).disputed);
        uint256 treasuryBefore = treasury.balance;
        uint256 availableBefore = hub.available();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hub.voidClaimable(id, owed, keccak256("case-1"));
        vm.prank(owner);
        hub.voidClaimable(id, owed, keccak256("case-1"));
        assertEq(hub.getOrder(id).owed, 0);
        assertEq(treasury.balance, treasuryBefore, "never to the treasury");
        assertEq(hub.available(), availableBefore + owed, "back to the reserve float");
        // New fast-lane mints stop until the timelock resumes them.
        venue.setFail(false);
        _buy(1_000e18, 1);
        route.fill(route.sentCount() - 1, 997_500_000);
        _deliverLatestOrder();
        uint256 last = rhEp.packetCount() - 1;
        vm.expectRevert();
        rhEp.deliver(last);
        vm.prank(owner);
        hub.resumeMints();
        rhEp.redeliver(rhEp.packetCount() - 1);
    }

    function testCanonicalLaneAppliesAResultTheFastLaneNeverDeliveredWithoutRateLimit() public {
        vm.prank(owner);
        hub.setMintFloor(address(stock), 1e18);
        uint256 id = _buy(1_000e18, 1);
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        uint256 last = rhEp.packetCount() - 1;
        vm.expectRevert(); // 9.975 shares > the 1-share LayerZero window allowance
        rhEp.deliver(last);
        uint256 index = _checkpointToArc();
        _reconcile(0, index);
        assertEq(token.balanceOf(user), 9.975e18);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
        assertEq(capacity.unreviewedUsd(), 0, "a canonical settlement is already reviewed");
    }

    function testAutonomousRedeemDeliversStockOnTheReserveChainAndClosesOnProof() public {
        _boughtOrder(1_000e18);
        vm.prank(user);
        uint256 id = hub.canonicalRedeem{value: 1 ether}(address(stock), 4e18, rhUser, Messages.DeliverMode.Stock);
        assertEq(token.balanceOf(user), 5.975e18);
        assertEq(token.balanceOf(treasury), 0.01e18, "25 bps kept in shares, like every other exit");
        _deliverToReserve();
        assertEq(stock.balanceOf(rhUser), 3.99e18, "the holder has the RH stock without any operator");
        uint256 index = _checkpointToArc();
        uint256 seq = vault.resultCount() - 1;
        assertEq(vault.resultAt(seq).ref, bytes32(id));
        _reconcile(0, index);
        _reconcile(seq, index);
        assertEq(uint8(hub.getOrder(id).status), uint8(HubSettlement.Status.Filled));
        assertEq(capacity.redeemingUsd(), 0, "final canonical delivery releases the exposure");
        assertEq(stock.balanceOf(address(vault)), vault.entitledOf(address(stock)));
        assertEq(token.totalSupply(), vault.entitledOf(address(stock)), "1:1: the fee shares stay backed");
    }

    /// Review #6: each canonical send pays the gate's 1 USDC hook, so free 1-wei redemptions can no
    /// longer drain the gate float and block the self-custody exit.
    function testCanonicalSendsPayTheirOwnHookSoTheGateCannotBeDrained() public {
        _boughtOrder(1_000e18);
        vm.startPrank(user);
        vm.expectRevert();
        hub.canonicalRedeem(address(stock), 1, rhUser, Messages.DeliverMode.Stock);
        vm.expectRevert();
        hub.canonicalRedeem{value: 1 ether - 1}(address(stock), 1e18, rhUser, Messages.DeliverMode.Stock);
        // On Arc native USDC and the gate's USDC ERC20 float are one balance; the mock ERC20 here is not,
        // so the test checks the native hook payment reaches the gate for every burn.
        uint256 gateNative = address(gate).balance;
        for (uint256 i; i < 5; ++i) {
            hub.canonicalRedeem{value: 1 ether}(address(stock), 1e15, rhUser, Messages.DeliverMode.Stock);
        }
        vm.stopPrank();
        assertEq(address(gate).balance, gateNative + 5 ether, "every hook burned was paid for");
        assertEq(arcMessenger.burnCount(), 5);
    }

    function testGuardianHaltsMintingInstantlyAndOnlyTheTimelockResumes() public {
        vm.prank(owner);
        hub.setGuardian(guardian);
        _buy(1_000e18, 1);
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hub.haltMints();
        vm.prank(guardian);
        hub.haltMints();
        assertTrue(hub.mintsHalted());
        uint256 last = rhEp.packetCount() - 1;
        vm.expectRevert(); // the LayerZero result waits (retryable) instead of minting
        rhEp.deliver(last);
        vm.prank(guardian);
        vm.expectRevert();
        hub.resumeMints();
        vm.prank(owner);
        hub.resumeMints();
        rhEp.redeliver(last);
        assertEq(token.balanceOf(user), 9.975e18);
    }

    function testStaleUnreconciledSettlementHaltsTheNextFastMint() public {
        _boughtOrder(1_000e18);
        vm.warp(block.timestamp + 8 days + 1);
        _buy(1_000e18, 1);
        route.fill(route.sentCount() - 1, 997_500_000);
        _deliverLatestOrder();
        uint256 last = rhEp.packetCount() - 1;
        vm.expectRevert();
        rhEp.deliver(last);
        hub.checkStale();
        assertTrue(hub.mintsHalted());
    }

    function testEscalatedSellIsDeliveredCanonicallyAndTheLateOrderIsIgnored() public {
        _boughtOrder(1_000e18);
        vm.prank(user);
        uint256 id = hub.requestSell{value: 0.01 ether}(address(stock), 9.975e18, 1);
        vm.warp(block.timestamp + 6 hours - 1);
        vm.prank(user);
        vm.expectRevert();
        hub.escalate{value: 1 ether}(id, rhUser);
        vm.warp(block.timestamp + 1);
        vm.deal(address(0x1234), 1 ether);
        vm.prank(address(0x1234)); // a helper may escalate only to the seller's own (EOA) address
        vm.expectRevert();
        hub.escalate{value: 1 ether}(id, rhUser);
        vm.prank(user);
        vm.expectRevert(); // the hook is paid by the escalation
        hub.escalate(id, rhUser);
        vm.prank(user);
        hub.escalate{value: 1 ether}(id, rhUser);
        _deliverToReserve();
        assertEq(usdg.balanceOf(rhUser), 997_500_000);
        uint256 results = rhEp.packetCount();
        _deliverLatestOrder(); // the stuck LayerZero order finally arrives
        assertEq(rhEp.packetCount(), results, "already settled canonically");
    }

    function testEscalateFundsTakesAStuckRefundOnTheReserveChain() public {
        venue.setFail(true);
        uint256 before = user.balance;
        uint256 id = _buy(1_000e18, 1);
        route.fill(0, 997_500_000);
        _deliverLatestOrder();
        _deliverLatestResult();
        vm.prank(user);
        vm.expectRevert();
        hub.escalateFunds{value: 1 ether}(id, rhUser);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user);
        hub.escalateFunds{value: 1 ether}(id, rhUser);
        assertEq(user.balance, before - 1_002 ether + 2.5e18 + 0.49 ether, "Arc-held fee and reserve come back");
        _deliverToReserve();
        assertEq(usdg.balanceOf(rhUser), 997_500_000);
        assertEq(vault.settlementLiabilities(), 0);
    }

    function testBridgerRetryAndFixedWithdrawDestinations() public {
        _boughtOrder(1_000e18);
        vm.prank(user);
        uint256 id = hub.canonicalRedeem{value: 1 ether}(address(stock), 1e18, rhUser, Messages.DeliverMode.Stock);
        _deliverToReserve();
        uint256 tickets = inbox.ticketCount();
        bridger.retry(bytes32(id), 1e6, 1);
        assertEq(inbox.ticketCount(), tickets + 1);
        vm.expectRevert();
        bridger.retry(bytes32(uint256(999)), 1e6, 1);
        // the re-created ticket is a harmless no-op on the vault
        (, bytes memory data) = inbox.ticketData(tickets);
        vm.prank(AddressAlias.applyL1ToL2Alias(address(bridger)));
        (bool ok,) = address(vault).call(data);
        assertTrue(ok);
        assertEq(stock.balanceOf(rhUser), 0.9975e18);
        vm.prank(owner);
        bridger.withdraw(1e6);
        assertEq(ethUsdc.balanceOf(bridgerFunds), 1e6);
        vm.prank(owner);
        gate.withdraw(1e6);
        assertEq(arcUsdc.balanceOf(gateFunds), 1e6);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        gate.withdraw(1);
    }
}

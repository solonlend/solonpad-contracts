// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RewardRoundManager} from "../../../../src/v3/RewardRoundManager.sol";
import {RewardBatcher} from "../../../../src/v3/RewardBatcher.sol";
import {RoundSource, RoundStock, RoundRegistry, RoundAdapter, RoundCapacity} from "../../RewardRounds.t.sol";

/// @notice Entry source without its own per-epoch close guard: only the manager's sealedSource key stops a reseal.
contract CovBResealSource {
    uint256 public lastFeeAt = block.timestamp;

    function sealReward(uint256, uint8) external returns (uint256 budget, uint256 total, uint8 kind) {
        budget = address(this).balance;
        total = 100;
        kind = 0;
        (bool ok,) = msg.sender.call{value: budget}("");
        require(ok);
    }

    function rewardPolicy(uint256, uint8) external pure returns (bytes32, uint32, bytes32, uint8) {
        return (bytes32("NVDA"), 1, bytes32("price"), 0);
    }

    function queueSnapshot(uint256) external pure returns (uint256, uint256) {
        return (0, 1);
    }

    receive() external payable {}
}

/// @notice Adapter that reports results it never delivered (a misbehaving/compromised adapter).
contract CovBLyingAdapter {
    uint8 public status;
    uint256 public raw;
    uint256 public refund;

    function set(uint8 s, uint256 r, uint256 f) external {
        (status, raw, refund) = (s, r, f);
    }

    function startFunding(bytes32, uint256, uint256, uint256, address, bytes calldata) external payable {}

    function funded(bytes32) external pure returns (bool) {
        return true;
    }

    function submit(bytes32) external {}

    function requestCancel(bytes32) external {}

    function consumeResult(bytes32, bytes calldata) external view returns (uint8, uint256, uint256) {
        return (status, raw, refund);
    }

    receive() external payable {}
}

contract CovBRewardBatcherTest is Test {
    RewardRoundManager manager;
    RewardBatcher batcher;
    RoundStock stock;
    RoundRegistry registry;
    RoundAdapter adapter;

    function setUp() public {
        stock = new RoundStock();
        adapter = new RoundAdapter(stock);
        registry = new RoundRegistry(address(stock), address(adapter));
        manager = new RewardRoundManager(address(this), address(registry), address(0xBEEF), address(0xFEE));
        batcher = new RewardBatcher(manager);
        manager.configureExecution(address(batcher), address(new RoundCapacity()));
    }

    function _seal(uint256 amount, uint256 epoch) internal returns (uint256 id) {
        RoundSource source = new RoundSource();
        manager.registerSource(address(source), bytes32(uint256(uint160(address(source)))));
        vm.deal(address(source), amount);
        id = manager.seal(address(source), epoch, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
    }

    function _entry(uint256 amount, uint256 epoch) internal returns (uint256 id) {
        id = _seal(amount, epoch);
        batcher.enqueue(id);
    }

    /// line 19: enqueue only in seal order and only for existing entries.
    function testEnqueueRequiresNextSealedId() public {
        vm.expectRevert();
        batcher.enqueue(1); // nothing sealed yet: entry(1).source == 0
        uint256 a = _seal(200 ether, 1);
        uint256 b = _seal(200 ether, 2);
        vm.expectRevert();
        batcher.enqueue(b); // skips a
        assertEq(batcher.nextToEnqueue(), 1);
        batcher.enqueue(a);
        batcher.enqueue(b);
        assertEq(batcher.nextToEnqueue(), 3);
        assertTrue(batcher.enqueued(a) && batcher.enqueued(b));
    }

    /// line 32: preview budget must be in (0, runLimit].
    function testPreviewBudgetBounds() public {
        uint256 e = _entry(200 ether, 1);
        bytes32 group = manager.groupKey(e);
        vm.expectRevert();
        batcher.previewBatch(group, 0);
        vm.expectRevert();
        batcher.previewBatch(group, 1000 ether + 1); // RoundCapacity.lRun = 1000 ether
        (uint256[] memory ids,, uint256 total) = batcher.previewBatch(group, 1000 ether);
        assertEq(ids.length, 1);
        assertEq(total, 200 ether);
    }

    /// line 41 (available==0 -> skip) and line 73 (settled exhausted entry is not rewound).
    function testFullySettledEntryIsSkippedAndNotRewound() public {
        uint256 first = _entry(200 ether, 1);
        bytes32 group = manager.groupKey(first);
        uint256[] memory ids = new uint256[](1);
        ids[0] = first;
        uint256 r = batcher.executeAndStart(ids, 200 ether, 1, block.timestamp + 1 hours, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        batcher.advance(group, 64);
        assertEq(batcher.cursor(group), 1);
        adapter.setResult(1, 10, 0);
        manager.finalize(r, ""); // onRoundFinalized: pending 0, available 0 -> continue
        assertEq(batcher.cursor(group), 1, "exhausted entry must not rewind the cursor");
        assertEq(manager.available(first), 0);
        assertEq(manager.pending(first), 0);
        uint256 second = _entry(200 ether, 2);
        (uint256[] memory preview,,)= batcher.previewBatch(group, 1000 ether);
        assertEq(preview.length, 1);
        assertEq(preview[0], second);
    }

    /// line 41 with the exhausted entry still inside the scan window (cursor never advanced).
    function testPreviewSkipsExhaustedEntryInsideWindow() public {
        uint256 first = _entry(200 ether, 1);
        bytes32 group = manager.groupKey(first);
        uint256[] memory ids = new uint256[](1);
        ids[0] = first;
        uint256 r = batcher.executeAndStart(ids, 200 ether, 1, block.timestamp + 1 hours, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        adapter.setResult(1, 10, 0);
        manager.finalize(r, "");
        assertEq(batcher.cursor(group), 0);
        uint256 second = _entry(200 ether, 2);
        (uint256[] memory preview, uint256[] memory budgets, uint256 total) = batcher.previewBatch(group, 1000 ether);
        assertEq(preview.length, 1);
        assertEq(preview[0], second);
        assertEq(budgets[0], 200 ether);
        assertEq(total, 200 ether);
    }

    /// line 68: only the manager may report a finalized round.
    function testOnRoundFinalizedOnlyManager() public {
        uint256 e = _entry(200 ether, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = e;
        uint256 r = batcher.executeAndStart(ids, 200 ether, 1, block.timestamp + 1 hours, "");
        vm.expectRevert();
        batcher.onRoundFinalized(r);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        batcher.onRoundFinalized(r);
    }

    /// lines 94, 97: request must be non-empty, <= 64 and exactly the FIFO preview.
    function testExecuteRequiresExactFifoPage() public {
        uint256 a = _entry(200 ether, 1);
        uint256 b = _entry(200 ether, 2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = b;
        vm.expectRevert(bytes("FIFO"));
        batcher.executeAndStart(ids, 400 ether, 1, block.timestamp + 1 hours, "");
        vm.expectRevert();
        batcher.executeAndStart(new uint256[](0), 400 ether, 1, block.timestamp + 1 hours, "");
        vm.expectRevert();
        batcher.executeAndStart(new uint256[](65), 400 ether, 1, block.timestamp + 1 hours, "");
        assertEq(manager.nextRoundId(), 0);
        ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
        uint256 r = batcher.executeAndStart(ids, 400 ether, 1, block.timestamp + 1 hours, "");
        assertEq(manager.round(r).budget18, 400 ether);
    }
}

contract CovBRoundManagerTest is Test {
    RewardRoundManager manager;
    RoundSource source;
    RoundStock stock;
    RoundRegistry registry;
    RoundAdapter adapter;
    RoundCapacity capacity;

    function onRoundFinalized(uint256) external {}

    function setUp() public {
        stock = new RoundStock();
        adapter = new RoundAdapter(stock);
        registry = new RoundRegistry(address(stock), address(adapter));
        manager = new RewardRoundManager(address(this), address(registry), address(0xBEEF), address(0xFEE));
        capacity = new RoundCapacity();
        manager.configureExecution(address(this), address(capacity));
        source = new RoundSource();
        manager.registerSource(address(source), bytes32("pool"));
        vm.deal(address(source), 200 ether);
    }

    function _reserve(RewardRoundManager m, address src) internal returns (uint256 roundId, uint256 entryId) {
        entryId = m.seal(src, 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200 ether;
        roundId = m.reserveBatch(ids, amounts, 5, block.timestamp + 1 hours);
    }

    /// line 152: unregistered source cannot seal; its budget stays put.
    function testSealRequiresRegisteredSource() public {
        RoundSource stranger = new RoundSource();
        vm.deal(address(stranger), 50 ether);
        vm.expectRevert();
        manager.seal(address(stranger), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        assertEq(address(stranger).balance, 50 ether);
        assertEq(manager.nextEntryId(), 0);
    }

    /// line 162: the manager's (source, epoch, cohort) key alone blocks a second seal even if the source would pay.
    function testSealKeyBlocksResealOfSameEpoch() public {
        CovBResealSource s = new CovBResealSource();
        manager.registerSource(address(s), bytes32("reseal"));
        vm.deal(address(s), 150 ether);
        uint256 id = manager.seal(address(s), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        assertEq(manager.available(id), 150 ether);
        vm.deal(address(s), 120 ether);
        vm.expectRevert();
        manager.seal(address(s), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        assertEq(address(s).balance, 120 ether);
        assertEq(manager.nextEntryId(), 1);
        // Same source, other epoch: allowed.
        uint256 id2 = manager.seal(address(s), 8, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        assertEq(manager.available(id2), 120 ether);
    }

    /// line 278: status of an unknown entry reverts.
    function testEntryStatusUnknownReverts() public {
        vm.expectRevert();
        manager.entryStatus(1);
        uint256 e = manager.seal(address(source), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        (,,, RewardRoundManager.DeferReason reason) = manager.entryStatus(e);
        assertEq(uint8(reason), uint8(RewardRoundManager.DeferReason.Ready));
    }

    /// lines 373-374: poke only from Funding (Quarantined is never assigned) and only once the adapter is funded.
    function testPokeRequiresFundingAndAdapterFunded() public {
        (uint256 r,) = _reserve(manager, address(source));
        vm.expectRevert();
        manager.poke(r); // Reserved
        vm.expectRevert();
        manager.poke(99); // None
        manager.start(r, "");
        vm.expectRevert();
        manager.poke(r); // Funding but adapter not funded
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Funding));
        adapter.verifyFunding();
        manager.poke(r);
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Funded));
        vm.expectRevert();
        manager.poke(r); // Funded
    }

    /// line 381: submit only from Funded.
    function testSubmitRequiresFunded() public {
        (uint256 r,) = _reserve(manager, address(source));
        vm.expectRevert();
        manager.submit(r); // Reserved
        manager.start(r, "");
        adapter.verifyFunding();
        vm.expectRevert();
        manager.submit(r); // Funding (not poked)
        manager.poke(r);
        manager.submit(r);
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Submitted));
        assertEq(manager.round(r).submittedAt, block.timestamp);
    }

    /// line 391: cancelUnsent only from Reserved; funds and capacity stay with the live order otherwise.
    function testCancelUnsentRequiresReserved() public {
        (uint256 r, uint256 e) = _reserve(manager, address(source));
        manager.start(r, "");
        vm.expectRevert();
        manager.cancelUnsent(r);
        vm.expectRevert();
        manager.cancelUnsent(42);
        assertEq(manager.pending(e), 200 ether);
        assertEq(capacity.reserved(manager.round(r).orderId), 200 ether);
    }

    /// line 415: applyResult only for known orders.
    function testApplyResultUnknownOrderReverts() public {
        vm.expectRevert();
        manager.applyResult(bytes32(0), "");
        (uint256 r,) = _reserve(manager, address(source));
        manager.start(r, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        adapter.setResult(1, 9, 0);
        manager.applyResult(manager.round(r).orderId, "");
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Settled));
        assertEq(manager.delivered(1), 9);
    }

    /// line 428: an adapter that reports stock/refund it never delivered cannot settle or refund.
    function testFinalizeRejectsUnbackedAdapterReceipt() public {
        CovBLyingAdapter liar = new CovBLyingAdapter();
        RoundRegistry reg = new RoundRegistry(address(stock), address(liar));
        RewardRoundManager m = new RewardRoundManager(address(this), address(reg), address(0xBEEF), address(0xFEE));
        m.configureExecution(address(this), address(capacity));
        RoundSource s = new RoundSource();
        m.registerSource(address(s), bytes32("pool"));
        vm.deal(address(s), 200 ether);
        (uint256 r, uint256 e) = _reserve(m, address(s));
        m.start(r, "");
        m.poke(r);
        m.submit(r);
        liar.set(1, 10, 0); // claims 10 raw, mints nothing
        vm.expectRevert(bytes("receipt delta"));
        m.finalize(r, "");
        liar.set(2, 0, 200 ether); // claims refund, sends nothing
        vm.expectRevert(bytes("receipt delta"));
        m.finalize(r, "");
        assertEq(uint8(m.round(r).status), uint8(RewardRoundManager.Status.Submitted));
        assertEq(m.pending(e), 200 ether);
        assertEq(m.available(e), 0);
        assertEq(m.delivered(e), 0);
        assertEq(address(m).balance, 0);
    }
}

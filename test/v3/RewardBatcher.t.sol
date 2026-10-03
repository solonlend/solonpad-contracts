// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {RewardBatcher} from "../../src/v3/RewardBatcher.sol";
import {RoundStock, RoundSource, RoundRegistry, RoundAdapter, RoundCapacity} from "./RewardRounds.t.sol";

contract RewardBatcherTest is Test {
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

    function _entry(uint256 amount, uint256 epoch) internal returns (uint256 id) {
        RoundSource source = new RoundSource();
        manager.registerSource(address(source), bytes32(uint256(uint160(address(source)))));
        vm.deal(address(source), amount);
        id = manager.seal(address(source), epoch, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        batcher.enqueue(id);
    }

    function testPublicReserveOnlyCannotPinFifo() public {
        uint256 e = _entry(200 ether, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = e;
        vm.prank(address(0xBAD));
        (bool ok,) = address(batcher)
            .call(
                abi.encodeWithSignature(
                    "executeBatch(uint256[],uint256,uint256,uint256)", ids, 200 ether, 1, block.timestamp + 1 hours
                )
            );
        assertFalse(ok, "untrusted caller reserved without funding");
        assertEq(manager.pending(e), 0);
        assertEq(manager.nextRoundId(), 0);
    }

    function testPendingHeadIsIsolatedAndRefundRestoresOriginalPriority() public {
        uint256 first = _entry(1500 ether, 1);
        uint256 second = _entry(200 ether, 2);
        bytes32 group = manager.groupKey(first);
        uint256[] memory ids = new uint256[](1);
        ids[0] = first;
        uint256 r = batcher.executeAndStart(ids, 1000 ether, 1, block.timestamp + 1 hours, "");
        vm.expectRevert();
        batcher.executeAndStart(ids, 500 ether, 1, block.timestamp + 1 hours, "");
        (uint256[] memory preview,,) = batcher.previewBatch(group, 200 ether);
        assertEq(preview.length, 1, "pending head blocks ready entry");
        assertEq(preview[0], second);
        ids[0] = second;
        batcher.executeAndStart(ids, 200 ether, 1, block.timestamp + 1 hours, "");
        batcher.advance(group, 64);
        assertEq(batcher.cursor(group), 2);
        assertEq(manager.pending(first), 1000 ether);
        assertEq(manager.available(first), 500 ether);
        adapter.setResult(2, 0, 1000 ether);
        manager.finalize(r, "");
        assertEq(batcher.cursor(group), 0, "refund must recover original FIFO priority");
        (preview,,) = batcher.previewBatch(group, 1000 ether);
        assertEq(preview.length, 1);
        assertEq(preview[0], first);
        assertEq(manager.pending(second), 200 ether);
        ids[0] = first;
        batcher.executeAndStart(ids, 1000 ether, 1, block.timestamp + 1 hours, "");
    }

    function testSettledPartialSliceRestoresRemainderPriority() public {
        uint256 first = _entry(1500 ether, 1);
        uint256 second = _entry(200 ether, 2);
        bytes32 group = manager.groupKey(first);
        uint256[] memory ids = new uint256[](1);
        ids[0] = first;
        uint256 r = batcher.executeAndStart(ids, 1000 ether, 1, block.timestamp + 1 hours, "");
        batcher.advance(group, 64);
        assertEq(batcher.cursor(group), 1);
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        adapter.setResult(1, 7, 0);
        manager.finalize(r, "");
        assertEq(batcher.cursor(group), 0, "settled remainder lost FIFO position");
        (uint256[] memory preview, uint256[] memory budgets, uint256 total) = batcher.previewBatch(group, 1000 ether);
        assertEq(preview.length, 2);
        assertEq(preview[0], first);
        assertEq(preview[1], second);
        assertEq(budgets[0], 500 ether);
        assertEq(total, 700 ether);
    }

    function testLargestRemainderTieUsesEntryIdAndConservesRaw() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = _entry(40 ether, 1);
        ids[1] = _entry(40 ether, 2);
        ids[2] = _entry(40 ether, 3);
        uint256 r = batcher.executeAndStart(ids, 120 ether, 1, block.timestamp + 1 hours, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        adapter.setResult(1, 5, 0);
        manager.finalize(r, "");
        assertEq(manager.delivered(ids[0]), 2);
        assertEq(manager.delivered(ids[1]), 2);
        assertEq(manager.delivered(ids[2]), 1);
        assertEq(stock.balanceOf(address(manager.vault())), 5);
    }

    function testBounded64EntryPageAdvancesPastSettledEntries() public {
        uint256[] memory ids = new uint256[](64);
        for (uint256 i; i < 64; ++i) {
            ids[i] = _entry(2 ether, i + 1);
        }
        uint256 last = _entry(120 ether, 65);
        bytes32 group = manager.groupKey(last);
        (uint256[] memory preview,,) = batcher.previewBatch(group, 1000 ether);
        assertEq(preview.length, 64);
        uint256 r = batcher.executeAndStart(ids, 128 ether, 1, block.timestamp + 1 hours, "");
        adapter.verifyFunding();
        manager.poke(r);
        manager.submit(r);
        adapter.setResult(1, 64, 0);
        manager.finalize(r, "");
        batcher.advance(group, 64);
        (preview,,) = batcher.previewBatch(group, 1000 ether);
        assertEq(preview.length, 1);
        assertEq(preview[0], last);
    }

    function testBoundedPendingPageAdvancesAndRefundRewindsAllSlices() public {
        uint256[] memory ids = new uint256[](64);
        for (uint256 i; i < 64; ++i) {
            ids[i] = _entry(2 ether, i + 1);
        }
        uint256 last = _entry(120 ether, 65);
        bytes32 group = manager.groupKey(last);
        uint256 r = batcher.executeAndStart(ids, 128 ether, 1, block.timestamp + 1 hours, "");
        (uint256[] memory preview,,) = batcher.previewBatch(group, 1000 ether);
        assertEq(preview.length, 0, "preview must scan at most 64 positions");
        batcher.advance(group, 64);
        assertEq(batcher.cursor(group), 64);
        (preview,,) = batcher.previewBatch(group, 1000 ether);
        assertEq(preview.length, 1);
        assertEq(preview[0], last);
        vm.expectRevert();
        batcher.onRoundFinalized(r);
        manager.finalize(r, "");
        assertEq(batcher.cursor(group), 64, "empty proof must not requeue pending slices");
        adapter.setResult(2, 0, 128 ether);
        manager.finalize(r, "");
        assertEq(batcher.cursor(group), 0);
        (preview,,) = batcher.previewBatch(group, 1000 ether);
        assertEq(preview.length, 64);
        for (uint256 i; i < 64; ++i) {
            assertEq(preview[i], ids[i]);
            assertEq(manager.pending(ids[i]), 0);
            assertEq(manager.available(ids[i]), 2 ether);
        }
    }

    function testDynamicMinimumAndHardRunCapCannotBeBypassed() public {
        uint256 e = _entry(1000 ether, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = e;
        registry.setCost(0.55 ether);
        vm.expectRevert();
        batcher.executeAndStart(ids, 100 ether, 1, block.timestamp + 1 hours, "");
        registry.setCost(6 ether);
        vm.expectRevert();
        batcher.executeAndStart(ids, 1000 ether, 1, block.timestamp + 1 hours, "");
        vm.expectRevert();
        batcher.executeAndStart(ids, 1001 ether, 1, block.timestamp + 1 hours, "");
        registry.setCost(0.5 ether);
        assertGt(batcher.executeAndStart(ids, 100 ether, 1, block.timestamp + 1 hours, ""), 0);
    }

    function testSliceRefundReturnsBudgetOnceToEveryOriginalEntry() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = _entry(75 ether, 1);
        ids[1] = _entry(125 ether, 2);
        uint256 r = batcher.executeAndStart(ids, 200 ether, 1, block.timestamp + 1 hours, "");
        adapter.setResult(2, 0, 200 ether);
        manager.finalize(r, "");
        assertEq(manager.available(ids[0]), 75 ether);
        assertEq(manager.available(ids[1]), 125 ether);
        vm.expectRevert();
        manager.finalize(r, "");
        assertEq(address(manager).balance, 200 ether);
        assertEq(manager.entry(ids[0]).creditTotal, 100);
    }

    function testAtomicExecuteStartsFundingAndInvalidQuoteRollsBackReservations() public {
        uint256 e = _entry(200 ether, 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = e;
        vm.expectRevert();
        batcher.executeAndStart(ids, 200 ether, 1, block.timestamp + 1 hours, hex"01");
        assertEq(manager.available(e), 200 ether);
        assertEq(manager.pending(e), 0);
        assertEq(manager.nextRoundId(), 0);
        uint256 r = batcher.executeAndStart(ids, 200 ether, 1, block.timestamp + 1 hours, "");
        assertEq(uint8(manager.round(r).status), uint8(RewardRoundManager.Status.Funding));
        assertEq(address(adapter).balance, 200 ether);
    }

    function testOldestCompatibleFifoRejectsKeeperSelection() public {
        uint256 first = _entry(60 ether, 1);
        uint256 second = _entry(60 ether, 2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = second;
        vm.expectRevert();
        batcher.executeAndStart(ids, 120 ether, 1, block.timestamp + 1 hours, "");
        ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;
        uint256 r = batcher.executeAndStart(ids, 120 ether, 1, block.timestamp + 1 hours, "");
        assertEq(manager.round(r).budget18, 120 ether);
        vm.expectRevert();
        batcher.enqueue(first);
    }

    // ---- decimals (AGENTS.md §4.6): the hub funds whole 6-dp USDC only (HubSettlement.beginReward budget18 % 1e12).
    //      Sealed budgets are arbitrary wei; the batch the batcher hands to reserveBatch must already be on the grid,
    //      the sub-1e12 tail staying available in its entry.

    function testBatchTotalIsAlignedTo6dpAndTailStaysAvailable() public {
        uint256 a = 100 ether + 1; // 100.000000000000000001
        uint256 b = 50 ether + 999_999_999_998; // a + b = 150 ether + (1e12 - 1)
        uint256 first = _entry(a, 1);
        uint256 second = _entry(b, 2);
        bytes32 group = manager.groupKey(first);
        (uint256[] memory ids, uint256[] memory budgets, uint256 total) = batcher.previewBatch(group, a + b);
        assertEq(total % 1e12, 0, "batch total on the 6-dp grid");
        assertEq(total, 150 ether, "only the sub-1e12 tail is held back");
        assertEq(ids.length, 2);
        assertEq(budgets[0] + budgets[1], total);
        uint256 r = batcher.executeAndStart(ids, a + b, 1, block.timestamp + 1 hours, "");
        assertEq(manager.round(r).budget18, 150 ether);
        assertEq(manager.available(first) + manager.available(second), a + b - 150 ether, "tail stays in the entries");
    }

    function testUnalignedMaxBudgetIsRoundedDown() public {
        uint256 e = _entry(300 ether, 1);
        uint256 maxBudget = 200 ether + 1;
        (, uint256[] memory budgets, uint256 total) = batcher.previewBatch(manager.groupKey(e), maxBudget);
        assertEq(total, 200 ether);
        assertEq(budgets[0], 200 ether);
    }

    function testTinyTrailingSliceIsDroppedWhenItIsAllTail() public {
        uint256 first = _entry(100 ether + 5e11, 1);
        uint256 second = _entry(4e11, 2); // smaller than the batch tail (9e11): dropped, first trimmed by the rest
        bytes32 group = manager.groupKey(first);
        (uint256[] memory ids, uint256[] memory budgets, uint256 total) = batcher.previewBatch(group, 1000 ether);
        assertEq(total, 100 ether);
        assertEq(ids.length, 1, "trailing dust-only slice dropped");
        assertEq(ids[0], first);
        assertEq(budgets[0], 100 ether);
        assertEq(manager.available(second), 4e11);
    }

    function testFuzzBatchTotalAligned(uint96 x, uint96 y, uint96 cap) public {
        uint256 a = 1 ether + uint256(x);
        uint256 b = 1 + uint256(y);
        uint256 first = _entry(a, 1);
        _entry(b, 2);
        uint256 maxBudget = bound(uint256(cap), 1, manager.runLimit());
        (, uint256[] memory budgets, uint256 total) = batcher.previewBatch(manager.groupKey(first), maxBudget);
        assertEq(total % 1e12, 0);
        assertLe(total, maxBudget);
        uint256 sum;
        for (uint256 i; i < budgets.length; ++i) {
            assertGt(budgets[i], 0);
            sum += budgets[i];
        }
        assertEq(sum, total);
        uint256 cap6 = (a + b < maxBudget ? a + b : maxBudget);
        assertEq(total, cap6 - cap6 % 1e12, "nothing aligned is held back");
    }
}

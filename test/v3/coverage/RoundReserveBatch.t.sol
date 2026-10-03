// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RewardRoundManager} from "../../../src/v3/RewardRoundManager.sol";
import {RoundSource, RoundStock, RoundRegistry, RoundAdapter, RoundCapacity} from "../RewardRounds.t.sol";

/// @dev Minimal source with a different pricePolicy, so its entries form a different batch group.
contract OtherPolicySource {
    uint256 public lastFeeAt = block.timestamp;

    function sealReward(uint256, uint8) external returns (uint256 budget, uint256 total, uint8 kind) {
        budget = address(this).balance;
        total = 100;
        (bool ok,) = msg.sender.call{value: budget}("");
        require(ok);
        kind = 0;
    }

    function rewardPolicy(uint256, uint8) external pure returns (bytes32, uint32, bytes32, uint8) {
        return (bytes32("NVDA"), 1, bytes32("other"), 0);
    }

    function queueSnapshot(uint256) external pure returns (uint256, uint256) {
        return (0, 1);
    }

    receive() external payable {}
}

/// @notice Pins every branch of `RewardRoundManager.reserveBatch` and its `_reserveSlices` loop (split out of
///         `reserveBatch` for coverage; production bytecode is byte-identical to 5f81a74, see PLAN).
contract RoundReserveBatchTest is Test {
    RewardRoundManager manager;
    RoundStock stock;
    RoundRegistry registry;
    RoundAdapter adapter;
    RoundCapacity capacity;
    RoundSource source;

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
    }

    function _seal(uint256 epoch, uint256 budget) internal returns (uint256) {
        vm.deal(address(source), budget);
        return manager.seal(address(source), epoch, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
    }

    function _one(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _two(uint256 x, uint256 y) internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = x;
        a[1] = y;
    }

    /// Multi-entry batch: slice order, epoch bounds, budget sum, entriesHash chain and orderId formula.
    function testMultiEntryBatchStateMatchesSpec() public {
        uint256 e1 = _seal(9, 300 ether);
        uint256 e2 = _seal(4, 500 ether);
        uint256 e3 = _seal(12, 100 ether);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (e1, e2, e3);
        uint256[] memory amounts = new uint256[](3);
        (amounts[0], amounts[1], amounts[2]) = (250 ether, 500 ether, 1);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 id = manager.reserveBatch(ids, amounts, 7, deadline);

        RewardRoundManager.Round memory r = manager.round(id);
        assertEq(id, 1);
        assertEq(r.entryCount, 3);
        assertEq(r.epochMin, 4);
        assertEq(r.epochMax, 12);
        assertEq(r.budget18, 750 ether + 1);
        assertEq(r.asset, address(stock));
        assertEq(r.adapter, address(adapter));
        assertEq(r.minRawOut, 7);
        assertEq(r.deadline, deadline);
        assertEq(uint8(r.status), uint8(RewardRoundManager.Status.Reserved));
        bytes32 h;
        for (uint256 i; i < 3; ++i) {
            h = keccak256(abi.encode(h, manager.entry(ids[i]), amounts[i]));
        }
        assertEq(r.entriesHash, h);
        assertEq(r.sourceNonce, 0);
        assertEq(r.orderId, keccak256(abi.encode(block.chainid, address(manager), h, uint256(7), deadline, uint256(0))));
        assertEq(manager.orderRound(r.orderId), id);
        assertEq(capacity.reserved(r.orderId), 750 ether + 1);

        RewardRoundManager.Slice[] memory s = manager.roundSlices(id);
        assertEq(s.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(s[i].entryId, ids[i]);
            assertEq(s[i].budget18, amounts[i]);
            assertEq(manager.pending(ids[i]), amounts[i]);
        }
        assertEq(manager.available(e1), 50 ether);
        assertEq(manager.available(e2), 0);
        assertEq(manager.available(e3), 100 ether - 1);
    }

    function testRejectsNonBatcherAndMalformedArguments() public {
        uint256 e = _seal(7, 200 ether);
        uint256 d = block.timestamp + 1;
        vm.prank(address(0xBAD));
        vm.expectRevert();
        manager.reserveBatch(_one(e), _one(200 ether), 5, d);
        vm.expectRevert(); // empty
        manager.reserveBatch(new uint256[](0), new uint256[](0), 5, d);
        vm.expectRevert(); // length mismatch
        manager.reserveBatch(_one(e), _two(100 ether, 100 ether), 5, d);
        vm.expectRevert(); // minRaw == 0
        manager.reserveBatch(_one(e), _one(200 ether), 0, d);
        vm.expectRevert(); // deadline not in the future
        manager.reserveBatch(_one(e), _one(200 ether), 5, block.timestamp);
        uint256[] memory many = new uint256[](65);
        vm.expectRevert(); // > 64 entries
        manager.reserveBatch(many, many, 5, d);
        assertEq(manager.nextRoundId(), 0);
    }

    function testExactly64EntriesAccepted() public {
        uint256[] memory ids = new uint256[](64);
        uint256[] memory amounts = new uint256[](64);
        for (uint256 i; i < 64; ++i) {
            ids[i] = _seal(100 + i, 2 ether);
            amounts[i] = 2 ether;
        }
        uint256 id = manager.reserveBatch(ids, amounts, 1, block.timestamp + 1);
        assertEq(manager.round(id).budget18, 128 ether);
        assertEq(manager.roundSlices(id).length, 64);
    }

    function testRejectsDisabledOrMissingRoute() public {
        uint256 e = _seal(7, 200 ether);
        registry.clearRoute();
        vm.expectRevert();
        manager.reserveBatch(_one(e), _one(200 ether), 5, block.timestamp + 1);
        assertEq(manager.available(e), 200 ether);
    }

    function testSliceLoopRejections() public {
        uint256 e1 = _seal(1, 200 ether);
        uint256 e2 = _seal(2, 200 ether);
        OtherPolicySource other = new OtherPolicySource();
        manager.registerSource(address(other), bytes32("pool2"));
        vm.deal(address(other), 200 ether);
        uint256 eo = manager.seal(address(other), 3, 0, bytes32("NVDA"), 1, bytes32("other"), 0);
        uint256 d = block.timestamp + 1;

        vm.expectRevert(); // unknown entry
        manager.reserveBatch(_two(e1, 99), _two(100 ether, 100 ether), 5, d);
        vm.expectRevert(); // different group key
        manager.reserveBatch(_two(e1, eo), _two(100 ether, 100 ether), 5, d);
        vm.expectRevert(); // zero slice
        manager.reserveBatch(_two(e1, e2), _two(200 ether, 0), 5, d);
        vm.expectRevert(); // more than available
        manager.reserveBatch(_one(e1), _one(200 ether + 1), 5, d);
        // duplicate id: the second slice already fails `pending == 0` (amounts > 0), so the explicit
        // `ids[j] != eid` check is defence in depth and its revert is unreachable.
        vm.expectRevert();
        manager.reserveBatch(_two(e1, e1), _two(100 ether, 100 ether), 5, d);

        // pending entry cannot join a second round
        manager.reserveBatch(_one(e1), _one(150 ether), 5, d);
        vm.expectRevert();
        manager.reserveBatch(_two(e2, e1), _two(100 ether, 50 ether), 5, d);
        assertEq(manager.available(e2), 200 ether);
        assertEq(manager.pending(e2), 0);
    }

    function testBudgetMustBeWithinMinimumAndRunLimit() public {
        uint256 e = _seal(7, 2000 ether);
        uint256 d = block.timestamp + 1;
        vm.expectRevert(bytes("cost or run limit")); // default minimum 100 USDC
        manager.reserveBatch(_one(e), _one(100 ether - 1), 5, d);
        vm.expectRevert(bytes("cost or run limit")); // capacity lRun = 1000
        manager.reserveBatch(_one(e), _one(1000 ether + 1), 5, d);
        registry.setCost(1 ether); // > 0.5: minimum = 200 x cost
        vm.expectRevert(bytes("cost or run limit"));
        manager.reserveBatch(_one(e), _one(200 ether - 1), 5, d);
        uint256 id = manager.reserveBatch(_one(e), _one(200 ether), 5, d);
        assertEq(manager.round(id).budget18, 200 ether);
        registry.setCost(0.5 ether); // boundary: not > 0.5, so flat 100 minimum
        assertEq(manager.minimumBudget(e), 100 ether);
        registry.setCost(0.5 ether + 1);
        assertEq(manager.minimumBudget(e), 100 ether + 200);
    }

    function testRunLimitBoundaryAccepted() public {
        uint256 e = _seal(7, 1000 ether);
        uint256 id = manager.reserveBatch(_one(e), _one(1000 ether), 5, block.timestamp + 1);
        assertEq(manager.round(id).budget18, 1000 ether);
        assertEq(manager.available(e), 0);
    }
}

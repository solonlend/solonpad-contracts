// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {RewardRoundManager} from "./RewardRoundManager.sol";

/// @notice Permissionless, bounded FIFO admission and execution. IDs follow immutable seal order.
contract RewardBatcher {
    RewardRoundManager public immutable manager;
    uint256 public nextToEnqueue = 1;
    mapping(uint256 => bool) public enqueued;
    mapping(bytes32 => uint256[]) private queues;
    mapping(bytes32 => uint256) public cursor;
    mapping(uint256 => uint256) private queueIndex;

    constructor(RewardRoundManager manager_) {
        manager = manager_;
    }

    function enqueue(uint256 id) public {
        require(id == nextToEnqueue && manager.entry(id).source != address(0));
        ++nextToEnqueue;
        enqueued[id] = true;
        bytes32 group = manager.groupKey(id);
        queueIndex[id] = queues[group].length;
        queues[group].push(id);
    }

    function previewBatch(bytes32 group, uint256 maxBudget)
        public
        view
        returns (uint256[] memory ids, uint256[] memory budgets, uint256 total)
    {
        require(maxBudget > 0 && maxBudget <= manager.runLimit());
        uint256[] storage q = queues[group];
        ids = new uint256[](64);
        budgets = new uint256[](64);
        uint256 count;
        for (uint256 i = cursor[group]; i < q.length && count < 64 && i < cursor[group] + 64 && total < maxBudget; ++i) {
            uint256 id = q[i];
            if (manager.pending(id) > 0) continue;
            uint256 available = manager.available(id);
            if (available == 0) continue;
            uint256 amount = available < maxBudget - total ? available : maxBudget - total;
            ids[count] = id;
            budgets[count] = amount;
            total += amount;
            ++count;
        }
        // The hub funds whole 6-dp USDC only (budget18 % 1e12 == 0): trim the sub-1e12 tail off the last slices; it
        // stays available in its entries for a later round.
        uint256 tail = total % 1e12;
        while (tail != 0) {
            uint256 last = budgets[count - 1];
            if (last > tail) {
                budgets[count - 1] = last - tail;
                total -= tail;
                tail = 0;
            } else {
                total -= last;
                tail -= last;
                --count;
            }
        }
        assembly ("memory-safe") {
            mstore(ids, count)
            mstore(budgets, count)
        }
    }

    function advance(bytes32 group, uint256 max) public {
        require(max > 0 && max <= 64);
        uint256 head = cursor[group];
        uint256 end = head + max;
        uint256[] storage q = queues[group];
        // Pending entries remain reserved, but do not block unrelated ready entries.
        while (head < q.length && head < end && (manager.available(q[head]) == 0 || manager.pending(q[head]) > 0)) {
            ++head;
        }
        cursor[group] = head;
    }

    /// @notice Restore immutable FIFO priority when a terminal result makes an old slice available.
    function onRoundFinalized(uint256 roundId) external {
        require(msg.sender == address(manager));
        RewardRoundManager.Slice[] memory items = manager.roundSlices(roundId);
        for (uint256 i; i < items.length; ++i) {
            uint256 id = items[i].entryId;
            require(enqueued[id]);
            if (manager.pending(id) != 0 || manager.available(id) == 0) continue;
            bytes32 group = manager.groupKey(id);
            if (queueIndex[id] < cursor[group]) cursor[group] = queueIndex[id];
        }
    }

    function executeAndStart(
        uint256[] calldata ids,
        uint256 maxBudget,
        uint256 minRaw,
        uint256 deadline,
        bytes calldata quoteData
    ) external returns (uint256 id) {
        id = _executeBatch(ids, maxBudget, minRaw, deadline);
        manager.start(id, quoteData);
    }

    function _executeBatch(uint256[] calldata requested, uint256 maxBudget, uint256 minRaw, uint256 deadline)
        internal
        returns (uint256 id)
    {
        require(requested.length > 0 && requested.length <= 64);
        bytes32 group = manager.groupKey(requested[0]);
        (uint256[] memory ids, uint256[] memory amounts,) = previewBatch(group, maxBudget);
        require(keccak256(abi.encode(ids)) == keccak256(abi.encode(requested)), "FIFO");
        id = manager.reserveBatch(ids, amounts, minRaw, deadline);
    }
}

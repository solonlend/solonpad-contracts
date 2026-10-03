// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CapacityController} from "./CapacityController.sol";

interface IScheduledHub {
    function scheduleInfo(uint256 id) external view returns (bool pending, uint8 lane, uint256 usd, bytes32 key);
    function launch(uint256 id, bytes calldata routeData) external;
}

/// @title OrderScheduler — two FIFO queues, 3 public : 1 reward
/// @notice New in Solon (design r5 §8.3 A10, approved 07:05). ArcStocks executes an order when its
///         message reaches the vault; Solon first funds each order on the reserve chain, so new buys
///         wait here in two first-in-first-out queues. Every fourth launch slot belongs to the reward
///         queue. A queue with nothing launchable lends its slot to the other; lending a slot never lends
///         the reward capacity reserve (the controller enforces that). A public head blocked by the
///         public cap waits — it is neither skipped nor reordered. Cancelled/refunded entries are skipped.
///         Anyone may launch; the caller names the id it prepared route data for, so a keeper cannot be
///         surprised into funding a different order.
contract OrderScheduler {
    uint8 public constant PUBLIC_PER_REWARD = 3;

    IScheduledHub public immutable hub;
    CapacityController public immutable capacity;

    uint256[] private _queue0;
    uint256[] private _queue1;
    uint256 public head0;
    uint256 public head1;
    /// @notice Public launches since the last reward launch.
    uint8 public publicStreak;

    event Enqueued(uint8 indexed lane, uint256 indexed id, uint256 position);
    event Launched(uint8 indexed lane, uint256 indexed id);

    error NotHub();
    error NotNext();
    error BadLane();

    constructor(address hub_, CapacityController capacity_) {
        require(hub_ != address(0) && address(capacity_) != address(0));
        hub = IScheduledHub(hub_);
        capacity = capacity_;
    }

    function enqueue(uint8 lane, uint256 id) external {
        if (msg.sender != address(hub)) revert NotHub();
        if (lane > 1) revert BadLane();
        uint256[] storage q = lane == 0 ? _queue0 : _queue1;
        q.push(id);
        emit Enqueued(lane, id, q.length - 1);
    }

    /// @notice The order the next `launchNext` will fund, if any.
    function nextLaunch() public view returns (bool found, uint8 lane, uint256 id) {
        (bool p, uint256 pid,) = _head(0);
        (bool r, uint256 rid,) = _head(1);
        bool rewardTurn = publicStreak >= PUBLIC_PER_REWARD;
        if (rewardTurn ? r : !p && r) return (true, 1, rid);
        if (p) return (true, 0, pid);
        return (false, 0, 0);
    }

    function launchNext(uint256 expectedId, bytes calldata routeData) external {
        (bool found, uint8 lane, uint256 id) = nextLaunch();
        if (!found || id != expectedId) revert NotNext();
        (,, uint256 at) = _head(lane);
        if (lane == 0) {
            head0 = at + 1;
            if (publicStreak < type(uint8).max) ++publicStreak;
        } else {
            head1 = at + 1;
            publicStreak = 0;
        }
        emit Launched(lane, id);
        hub.launch(id, routeData);
    }

    /// @notice Drop closed entries at the queue heads (anyone; bounded by `max`).
    function skipClosed(uint8 lane, uint256 max) external {
        uint256[] storage q = lane == 0 ? _queue0 : _queue1;
        uint256 h = lane == 0 ? head0 : head1;
        for (uint256 i; i < max && h < q.length; ++i) {
            (bool pending,,,) = hub.scheduleInfo(q[h]);
            if (pending) break;
            ++h;
        }
        if (lane == 0) head0 = h;
        else head1 = h;
    }

    function queueLength(uint8 lane) external view returns (uint256 total, uint256 waiting) {
        uint256[] storage q = lane == 0 ? _queue0 : _queue1;
        uint256 h = lane == 0 ? head0 : head1;
        return (q.length, q.length - h);
    }

    function queued(uint8 lane, uint256 position) external view returns (uint256) {
        return lane == 0 ? _queue0[position] : _queue1[position];
    }

    /// @dev First pending entry of a queue (bounded scan of 64 closed entries; call `skipClosed` beyond),
    ///      and whether it can launch now: public needs capacity, reward reserved it already.
    function _head(uint8 lane) private view returns (bool ready, uint256 id, uint256 at) {
        uint256[] storage q = lane == 0 ? _queue0 : _queue1;
        uint256 h = lane == 0 ? head0 : head1;
        for (uint256 n; n < 64 && h < q.length; ++n) {
            (bool pending,, uint256 usd,) = hub.scheduleInfo(q[h]);
            if (pending) {
                ready = lane == 1 || capacity.canReserve(0, usd);
                return (ready, q[h], h);
            }
            ++h;
        }
    }
}

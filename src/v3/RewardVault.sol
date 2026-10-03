// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
/// @notice Fixed reward custody. Verified delivery accounting is controlled only by RoundManager.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IVaultRewardSource {
    function queueSnapshot(uint256) external view returns (uint256, uint256);
    function participantAt(uint256) external view returns (address);
    function creditOf(address, uint256, uint8) external view returns (uint256);
    function deliveryAllowed(address, address) external view returns (bool);
}

contract RewardVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable manager;
    address public immutable payout;

    constructor(address payout_) {
        manager = msg.sender;
        payout = payout_;
    }

    function returnRefund(uint256 amount) external {
        require(msg.sender == manager);
        (bool ok,) = payable(manager).call{value: amount}("");
        require(ok);
    }

    function sendOrphan(address asset, address treasury, uint256 raw) external {
        require(msg.sender == manager);
        uint256 beforeSelf = IERC20(asset).balanceOf(address(this));
        uint256 beforeBalance = IERC20(asset).balanceOf(treasury);
        IERC20(asset).safeTransfer(treasury, raw);
        require(
            IERC20(asset).balanceOf(treasury) == beforeBalance + raw
                && IERC20(asset).balanceOf(address(this)) + raw == beforeSelf,
            "orphan delta"
        );
    }

    struct Allocation {
        address source;
        uint256 epoch;
        uint8 cohort;
        address asset;
        uint256 creditTotal;
        uint256 cumulativeDelivered;
        uint256 revision;
    }
    mapping(uint256 => Allocation) public allocations;
    mapping(uint256 => mapping(address => uint256)) public creditedToPayout;
    mapping(uint256 => uint256) public allocationStaged;
    mapping(address => uint256) public totalDelivered;
    mapping(address => uint256) public totalStaged;
    event CreditStaged(uint256 indexed allocationId, address indexed account, address indexed asset, uint256 amount);

    function registerAllocation(uint256 id, address source, uint256 epoch, uint8 cohort, address asset, uint256 total)
        external
    {
        require(msg.sender == manager && allocations[id].source == address(0) && total > 0);
        allocations[id] = Allocation(source, epoch, cohort, asset, total, 0, 0);
        (uint256 bound,) = IVaultRewardSource(source).queueSnapshot(epoch);
        sourceBounds[id] = bound;
        knownSource[source] = true;
        if (bound > requiredSourceBound[source]) requiredSourceBound[source] = bound;
    }

    function recordDelivery(uint256 id, uint256 raw) external {
        require(msg.sender == manager);
        Allocation storage a = allocations[id];
        require(a.source != address(0));
        a.cumulativeDelivered += raw;
        ++a.revision;
        totalDelivered[a.asset] += raw;
        require(
            IERC20(a.asset).balanceOf(address(this)) >= totalDelivered[a.asset] - totalStaged[a.asset], "stock coverage"
        );
    }

    function stageCredit(address account, uint256[] calldata ids, address asset)
        external
        nonReentrant
        returns (uint256 amount)
    {
        require(msg.sender == payout && ids.length <= 20);
        for (uint256 i; i < ids.length; ++i) {
            Allocation storage a = allocations[ids[i]];
            require(a.source != address(0));
            if (a.asset != asset) continue;
            uint256 credit = IVaultRewardSource(a.source).creditOf(account, a.epoch, a.cohort);
            require(credit <= a.creditTotal);
            uint256 owed = Math.mulDiv(credit, a.cumulativeDelivered, a.creditTotal);
            uint256 delta = owed - creditedToPayout[ids[i]][account];
            allocationStaged[ids[i]] += delta;
            require(allocationStaged[ids[i]] <= a.cumulativeDelivered, "allocation coverage");
            creditedToPayout[ids[i]][account] = owed;
            amount += delta;
            if (delta > 0) emit CreditStaged(ids[i], account, asset, delta);
        }
        if (amount > 0) {
            totalStaged[asset] += amount;
            uint256 beforeSelf = IERC20(asset).balanceOf(address(this));
            uint256 beforeTo = IERC20(asset).balanceOf(payout);
            IERC20(asset).safeTransfer(payout, amount);
            require(
                IERC20(asset).balanceOf(payout) == beforeTo + amount
                    && IERC20(asset).balanceOf(address(this)) + amount == beforeSelf,
                "stage delta"
            );
        }
    }
    mapping(address => address[]) private participants;
    mapping(address => bool) public knownSource;
    mapping(address => uint256) public sourceCursor;
    mapping(address => uint256) public requiredSourceBound;
    mapping(uint256 => uint256) public sourceBounds;
    mapping(uint256 => uint256) public participantUpperBound;
    mapping(uint256 => bool) public participantIndexSealed;

    function registerParticipants(address source, uint256 max) external {
        require(knownSource[source] && max > 0 && max <= 64);
        uint256 cursor = sourceCursor[source];
        uint256 end = Math.min(cursor + max, requiredSourceBound[source]);
        for (; cursor < end; ++cursor) {
            address account = IVaultRewardSource(source).participantAt(cursor);
            // Preserve the source's participant IDs and snapshot prefix exactly.
            participants[source].push(account);
        }
        sourceCursor[source] = end;
    }

    function sealParticipantIndex(uint256 id) external {
        require(allocations[id].source != address(0) && sourceCursor[allocations[id].source] >= sourceBounds[id]);
        if (!participantIndexSealed[id]) {
            participantIndexSealed[id] = true;
            participantUpperBound[id] = sourceBounds[id];
        }
    }

    function queueSnapshot(uint256 id) external view returns (uint256, uint256) {
        require(participantIndexSealed[id], "source enumeration incomplete");
        return (participantUpperBound[id], allocations[id].revision);
    }

    function scopedParticipantIndex() external pure returns (bool) {
        return true;
    }

    function participantAt(uint256 id, uint256 i) external view returns (address) {
        require(participantIndexSealed[id] && i < participantUpperBound[id], "participant bound");
        return participants[allocations[id].source][i];
    }

    function participantCount(address source) external view returns (uint256) {
        return participants[source].length;
    }

    function queueAsset(uint256 id) external view returns (address) {
        return allocations[id].asset;
    }

    function poolId() external view returns (bytes32) {
        return keccak256(abi.encode(address(this)));
    }

    function settlementKind() external pure returns (uint8) {
        return 0;
    }
    receive() external payable {}
}

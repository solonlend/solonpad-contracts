// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {RewardPayoutVault, IRewardPayoutSource} from "./RewardPayoutVault.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IRewardPrice {
    function priceUSD18(address asset) external view returns (uint256 price, uint256 updatedAt);
}

/// @notice Permissionless, bounded service over source-owned participant and entitlement indexes.
contract RewardDistributor is ReentrancyGuard {
    RewardPayoutVault public immutable payout;
    address public immutable oracle;
    address public immutable governance;
    uint256 public estimatedCostPerRecipient;
    /// @dev r7: 2h so an hourly SolonStockOracle relay (design §12.2) never leaves pushes without a price.
    uint256 public oracleMaxAge = 2 hours;
    uint256 public pendingCost;
    uint256 public pendingMaxAge;
    uint256 public policyReadyAt;
    event PolicyScheduled(uint256 cost, uint256 maxAge, uint256 readyAt);
    event PolicyApplied(uint256 cost, uint256 maxAge);

    struct Queue {
        address source;
        address asset;
        uint256 epoch;
        uint256 revision;
        uint256 upperBound;
        uint256 cursor;
    }
    enum Outcome {
        Staged,
        Paid,
        SkippedSmall,
        DeliveryBlocked,
        StageBlocked
    }
    event AccountProcessed(uint256 indexed queueId, address indexed account, Outcome outcome, bytes reason);
    Queue[] public queues;
    mapping(uint256 => uint256) public nextScanAt;
    mapping(uint256 => uint256) public scanDay;
    event CycleComplete(uint256 indexed queueId, uint256 day, uint256 nextScanAt);
    /// @notice r7 (design §12.3): one line per batch so reports can total pushes without joining every
    ///         `AccountProcessed` (raw amounts are exact; the per-account events remain the source of truth).
    event BatchSummary(
        uint256 indexed queueId,
        address indexed asset,
        uint256 indexed epoch,
        uint256 cursorStart,
        uint256 cursorEnd,
        uint256 accountsPaid,
        uint256 rawPaid
    );
    mapping(bytes32 => bool) public queued;
    mapping(address => bool) public scopedParticipantIndex;

    constructor(RewardPayoutVault p, address o) {
        payout = p;
        oracle = o;
        governance = msg.sender;
    }

    /// @dev Estimate includes cumulative staging plus final transfer, not transfer alone.
    function schedulePolicy(uint256 cost, uint256 maxAge) external {
        require(msg.sender == governance && maxAge > 0 && cost <= type(uint256).max / 200, "policy");
        pendingCost = cost;
        pendingMaxAge = maxAge;
        policyReadyAt = block.timestamp + 48 hours;
        emit PolicyScheduled(cost, maxAge, policyReadyAt);
    }

    function applyPolicy() external {
        require(policyReadyAt != 0 && block.timestamp >= policyReadyAt, "timelock");
        estimatedCostPerRecipient = pendingCost;
        oracleMaxAge = pendingMaxAge;
        policyReadyAt = 0;
        emit PolicyApplied(estimatedCostPerRecipient, oracleMaxAge);
    }

    function minimumUSD18() public view returns (uint256) {
        return Math.max(2 ether, 200 * estimatedCostPerRecipient);
    }

    function openQueue(address source, uint256 epoch, address asset) external returns (uint256 id) {
        require(payout.trustedSource(source), "source");
        require(asset != address(0) && IRewardPayoutSource(source).queueAsset(epoch) == asset, "queue asset");
        (uint256 upper, uint256 revision) = IRewardPayoutSource(source).queueSnapshot(epoch);
        bytes32 key = keccak256(
            abi.encode(
                source,
                IRewardPayoutSource(source).poolId(),
                IRewardPayoutSource(source).settlementKind(),
                epoch,
                asset,
                revision
            )
        );
        require(!queued[key] && revision != 0, "queue");
        queued[key] = true;
        (bool scoped, bytes memory capability) = source.staticcall(abi.encodeWithSignature("scopedParticipantIndex()"));
        if (scoped && capability.length == 32 && abi.decode(capability, (bool))) {
            scopedParticipantIndex[source] = true;
        }
        id = queues.length;
        queues.push(Queue(source, asset, epoch, revision, upper, 0));
    }

    function previewBatch(uint256 id) external view returns (Queue memory queue, uint256 nextScan, uint256 day) {
        return (queues[id], nextScanAt[id], scanDay[id]);
    }

    /// @dev A queue is one sealed epoch/allocation. maxEpochs is a conservative
    /// upper bound; manual claim can stage up to twenty epochs in one call.
    function batchDistribute(uint256 id, uint256 maxAccounts, uint256 maxEpochs, uint256 gasBudget)
        external
        nonReentrant
    {
        require(
            maxAccounts != 0 && maxAccounts <= 32 && maxEpochs != 0 && maxEpochs <= 20 && gasBudget >= 300000
                && gasBudget <= 2000000,
            "page/gas"
        );
        require(block.timestamp % 1 days >= 10 minutes && block.timestamp >= nextScanAt[id], "scan schedule");
        Queue storage q = queues[id];
        // Reserve both bounded child calls plus cursor/events; zero progress must
        // not let low-gas callers postpone the next legitimate scan.
        if (gasleft() < 2 * gasBudget + 100000) return;
        if (q.cursor == q.upperBound) q.cursor = 0;
        scanDay[id] = block.timestamp / 1 days;
        uint256 initialCursor = q.cursor;
        uint256 end = Math.min(q.cursor + maxAccounts, q.upperBound);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = q.epoch;
        uint256 paidCount;
        uint256 rawPaid;
        bool blocked;
        while (q.cursor < end) {
            if (gasleft() < 2 * gasBudget + 100000) break;
            address account = _participantAt(q.source, q.epoch, q.cursor);
            try payout.stageCredit{gas: gasBudget}(q.source, account, epochs, q.asset) returns (uint256) {
                emit AccountProcessed(id, account, Outcome.Staged, "");
            } catch (bytes memory reason) {
                emit AccountProcessed(id, account, Outcome.StageBlocked, reason);
                blocked = true;
                break;
            }
            ++q.cursor;
            try this.attempt{gas: gasBudget}(account, q.asset) returns (uint256 paid) {
                emit AccountProcessed(id, account, paid != 0 ? Outcome.Paid : Outcome.SkippedSmall, "");
                if (paid != 0) {
                    ++paidCount;
                    rawPaid += paid;
                }
            } catch (bytes memory reason) {
                emit AccountProcessed(id, account, Outcome.DeliveryBlocked, reason);
            }
        }
        if (q.cursor != initialCursor) emit BatchSummary(id, q.asset, q.epoch, initialCursor, q.cursor, paidCount, rawPaid);
        if (blocked || (q.cursor == initialCursor && q.upperBound != 0)) return;
        nextScanAt[id] = block.timestamp + 15 minutes;
        if (q.cursor == q.upperBound) emit CycleComplete(id, scanDay[id], nextScanAt[id]);
    }

    function _participantAt(address source, uint256 epoch, uint256 index) internal view returns (address) {
        if (!scopedParticipantIndex[source]) return IRewardPayoutSource(source).participantAt(index);
        // A declared scoped source must never fall back to the legacy global index.
        (bool ok, bytes memory data) =
            source.staticcall(abi.encodeWithSignature("participantAt(uint256,uint256)", epoch, index));
        require(ok && data.length == 32, "scoped participant");
        return abi.decode(data, (address));
    }

    uint256 public constant CLAIM_STAGE_GAS = 2000000;
    uint256 public constant CLAIM_PAYMENT_GAS = 500000;
    uint256 private constant CLAIM_GAS_RESERVE = 100000;
    event ClaimEpochBlocked(
        address indexed source, address indexed account, address indexed asset, uint256 epoch, bytes reason
    );
    event ClaimPageStopped(
        address indexed source,
        address indexed account,
        address indexed asset,
        uint256 assetIndex,
        uint256 nextEpochIndex
    );

    /// @notice Manual claims ignore automatic service price, threshold and schedule.
    /// Each epoch is isolated so deep histories cannot exhaust a whole twenty-epoch
    /// page. Partial completion retains beneficiary debt; callers resume from the
    /// ClaimPageStopped asset/epoch indexes. Retrying a full page is idempotent,
    /// but a minimum-gas estimate may fund only a prefix, so resume or add gas.
    function claim(address source, uint256[] calldata epochs, address[] calldata assets) external nonReentrant {
        require(payout.trustedSource(source) && epochs.length <= 20 && assets.length <= 4, "claim page/source");
        if (assets.length != 0) {
            uint256 firstCallGas = epochs.length == 0 ? CLAIM_PAYMENT_GAS : CLAIM_STAGE_GAS;
            require(gasleft() >= firstCallGas + firstCallGas / 63 + CLAIM_GAS_RESERVE + 20000, "claim gas");
        }
        uint256[] memory singleEpoch = new uint256[](1);
        for (uint256 i; i < assets.length; ++i) {
            for (uint256 j; j < epochs.length; ++j) {
                // EIP-150 forwarding headroom plus enough gas to return and emit
                // progress without rolling back already staged beneficiary debt.
                if (gasleft() < CLAIM_STAGE_GAS + CLAIM_STAGE_GAS / 63 + CLAIM_GAS_RESERVE) {
                    emit ClaimPageStopped(source, msg.sender, assets[i], i, j);
                    return;
                }
                singleEpoch[0] = epochs[j];
                try payout.stageCredit{gas: CLAIM_STAGE_GAS}(source, msg.sender, singleEpoch, assets[i]) {}
                catch (bytes memory reason) {
                    emit ClaimEpochBlocked(source, msg.sender, assets[i], epochs[j], reason);
                }
            }
            if (gasleft() < CLAIM_PAYMENT_GAS + CLAIM_PAYMENT_GAS / 63 + CLAIM_GAS_RESERVE) {
                emit ClaimPageStopped(source, msg.sender, assets[i], i, epochs.length);
                return;
            }
            try payout.claimFor{gas: CLAIM_PAYMENT_GAS}(msg.sender, assets[i]) returns (uint256) {}
            catch (bytes memory reason) {
                emit AccountProcessed(type(uint256).max, msg.sender, Outcome.DeliveryBlocked, reason);
            }
        }
    }

    /// @return paid Raw pushed to `account` (0 = skipped: price unusable or below the minimum).
    function attempt(address account, address asset) external returns (uint256 paid) {
        require(msg.sender == address(this), "self");
        (uint256 price, uint256 updatedAt) = IRewardPrice(oracle).priceUSD18(asset);
        if (price == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > oracleMaxAge) return 0;
        if (Math.mulDiv(payout.readyRaw(account, asset), price, 1 ether) < minimumUSD18()) return 0;
        return payout.claimFor(account, asset);
    }
}

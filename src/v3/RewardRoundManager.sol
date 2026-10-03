// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRewardEntrySource {
    function lastFeeAt() external view returns (uint256);
    function rewardPolicy(uint256 epoch, uint8 cohort)
        external
        view
        returns (bytes32 assetId, uint32 version, bytes32 pricePolicy, uint8 mode);
    function sealReward(uint256 epoch, uint8 cohort)
        external
        returns (uint256 budget18, uint256 creditTotal, uint8 kind);
    function creditOf(address account, uint256 epoch, uint8 cohort) external view returns (uint256);
    function deliveryAllowed(address account, address asset) external view returns (bool);
}
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RewardVault} from "./RewardVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRoundRegistry {
    struct Route {
        address asset;
        address underlying;
        address hub;
        address adapter;
        bytes32 path;
        uint256 chainId;
        bool enabled;
        uint256 fixedCost18;
    }
    function resolve(bytes32 assetId, uint32 version) external view returns (Route memory);
}

interface IRoundStockAdapter {
    function startFunding(
        bytes32 orderId,
        uint256 budget,
        uint256 minRaw,
        uint256 deadline,
        address vault,
        bytes calldata quoteData
    ) external payable;
    function funded(bytes32 orderId) external view returns (bool);
    function submit(bytes32 orderId) external;
    function requestCancel(bytes32 orderId) external;
    function consumeResult(bytes32 orderId, bytes calldata proof)
        external
        returns (uint8 status, uint256 raw, uint256 refund18);
}

/// @dev Phase-five capacity implementation must enforce global and reward-lane caps. No local timeout release.
interface IRoundCapacity {
    /// @dev r7: per-asset cap; `asset` = the route's RH underlying.
    function reserveFor(bytes32 orderId, address asset, uint256 budget18) external;
    function releaseUnsent(bytes32 orderId) external;
    function releaseFinalized(bytes32 orderId) external;
    function lRun() external view returns (uint256);
}

interface IRoundBatcher {
    function onRoundFinalized(uint256 roundId) external;
}

contract RewardRoundManager is ReentrancyGuard {
    struct Entry {
        address source;
        bytes32 pool;
        uint256 epoch;
        uint8 cohort;
        uint256 budget18;
        uint256 creditTotal;
        uint256 allocationId;
        bytes32 assetId;
        uint32 adapterVersion;
        bytes32 pricePolicy;
        uint8 eligibilityMode;
    }
    address public immutable governor;
    address public immutable registry;
    address public immutable payout;
    address public immutable treasury;
    uint256 public nextEntryId;
    mapping(address => bytes32) public sourcePool;
    mapping(uint256 => Entry) private entries;
    mapping(bytes32 => bool) public sealedSource;
    mapping(uint256 => uint256) public available;
    mapping(uint256 => uint256) public pending;
    event EntrySealed(
        uint256 indexed entryId,
        address indexed source,
        uint256 indexed epoch,
        uint8 cohort,
        uint256 budget18,
        uint256 creditTotal
    );

    constructor(address governor_, address registry_, address payout_, address treasury_) {
        require(governor_ != address(0) && registry_ != address(0) && payout_ != address(0) && treasury_ != address(0));
        governor = governor_;
        registry = registry_;
        payout = payout_;
        treasury = treasury_;
        vault = new RewardVault(payout_);
    }
    address public sourceFactory;
    address public deskModule;
    address public stakingModule;
    bool public rewardModulesConfigured;
    event RewardModulesConfigured(address indexed desk, address indexed staking);

    function configureRewardModules(address desk, address staking) external {
        require(
            msg.sender == governor && !rewardModulesConfigured && (desk != address(0) || staking != address(0)),
            "modules"
        );
        require(
            (desk == address(0) || desk.code.length != 0) && (staking == address(0) || staking.code.length != 0),
            "module code"
        );
        rewardModulesConfigured = true;
        deskModule = desk;
        stakingModule = staking;
        emit RewardModulesConfigured(desk, staking);
    }

    function configureSourceFactory(address factory_) external {
        require(msg.sender == governor && sourceFactory == address(0) && factory_.code.length > 0);
        sourceFactory = factory_;
    }

    function registerSource(address source, bytes32 pool) external {
        require(
            (msg.sender == governor
                    || msg.sender == sourceFactory
                    || msg.sender == deskModule
                    || msg.sender == stakingModule) && msg.sender != address(0) && source.code.length > 0
                && pool != bytes32(0) && sourcePool[source] == bytes32(0)
        );
        sourcePool[source] = pool;
    }

    function seal(
        address source,
        uint256 epoch,
        uint8 cohort,
        bytes32 assetId,
        uint32 version,
        bytes32 pricePolicy,
        uint8 mode
    ) external nonReentrant returns (uint256 id) {
        require(sourcePool[source] != bytes32(0));
        (bytes32 actualAsset, uint32 actualVersion, bytes32 actualPolicy, uint8 actualMode) =
            IRewardEntrySource(source).rewardPolicy(epoch, cohort);
        require(
            actualAsset == assetId && actualVersion == version && actualPolicy == pricePolicy && actualMode == mode,
            "source policy"
        );
        IRoundRegistry.Route memory route = IRoundRegistry(registry).resolve(assetId, version);
        require(route.asset.code.length != 0 && route.adapter.code.length != 0, "missing asset route");
        bytes32 key = keccak256(abi.encode(source, epoch, cohort));
        require(!sealedSource[key]);
        sealedSource[key] = true;
        uint256 beforeBalance = address(this).balance;
        (uint256 budget, uint256 total, uint8 kind) = IRewardEntrySource(source).sealReward(epoch, cohort);
        require(
            kind == 0 && budget > 0 && total > 0 && address(this).balance - beforeBalance == budget, "invalid receipt"
        );
        id = ++nextEntryId;
        entries[id] =
            Entry(source, sourcePool[source], epoch, cohort, budget, total, id, assetId, version, pricePolicy, mode);
        available[id] = budget;
        vault.registerAllocation(id, source, epoch, cohort, route.asset, total);
        emit EntrySealed(id, source, epoch, cohort, budget, total);
    }

    function entry(uint256 id) external view returns (Entry memory) {
        return entries[id];
    }
    RewardVault public immutable vault;
    mapping(uint256 => uint256) public delivered;
    enum Status {
        None,
        Reserved,
        Funding,
        Funded,
        Submitted,
        Settled,
        Quarantined,
        Refunded,
        CancelledUnsent
    }

    /// @dev Quotes bind the source's immutable pricePolicy and this round's sourceNonce.
    /// There is no synthetic oracle round. Cross-entry user payments are tracked by
    /// RewardPayoutVault.paidTotal, never inferred from staging or reported per round.
    struct Round {
        bytes32 entriesHash;
        uint256 entryCount;
        uint256 epochMin;
        uint256 epochMax;
        bytes32 assetId;
        uint32 adapterVersion;
        address asset;
        address adapter;
        uint256 budget18;
        uint256 minRawOut;
        uint256 deadline;
        bytes32 orderId;
        uint256 sourceNonce;
        uint256 delivered;
        uint256 refunded;
        Status status;
        uint256 submittedAt;
        bool cancelRequested;
    }

    struct Slice {
        uint256 entryId;
        uint256 budget18;
    }
    mapping(uint256 => Round) private rounds;
    mapping(uint256 => Slice[]) private slices;
    uint256 public nextRoundId;
    mapping(bytes32 => uint256) public orderRound;
    mapping(bytes32 => uint256) public executionNonce;
    address public batcher;
    address public capacity;
    event RoundState(uint256 indexed roundId, Status status);
    /// @notice r7 (design §12.3): links a reward round to its stock-layer order for the public payout reports.
    ///         The hub's reward order carries `orderId` as its capacity key; its uint id and funding transfer are
    ///         in the hub's `BuyRequested`/`Launched` events of the same order.
    event RoundLinked(
        uint256 indexed roundId,
        bytes32 indexed orderId,
        address indexed adapter,
        address asset,
        address underlying,
        uint256 budget18,
        uint256 minRawOut,
        uint256 entryCount
    );

    function configureExecution(address batcher_, address capacity_) external {
        require(msg.sender == governor && batcher == address(0) && batcher_ != address(0) && capacity_.code.length > 0);
        batcher = batcher_;
        capacity = capacity_;
    }

    function round(uint256 id) external view returns (Round memory) {
        return rounds[id];
    }

    function roundSlices(uint256 id) external view returns (Slice[] memory) {
        return slices[id];
    }

    function groupKey(uint256 id) public view returns (bytes32) {
        Entry storage e = entries[id];
        return keccak256(abi.encode(e.assetId, e.adapterVersion, e.pricePolicy, e.eligibilityMode));
    }

    enum DeferReason {
        Ready,
        BelowMinimum,
        CostLimit,
        Pending
    }

    /// @notice Read-only per-entry scheduling hints; Ready does not attest market/cap/route availability.
    /// A small entry can still join a larger compatible batch. Check times are service targets, not guarantees.
    function entryStatus(uint256 id)
        external
        view
        returns (uint256 age, bool dormant, uint256 nextCheck, DeferReason reason)
    {
        Entry storage e = entries[id];
        require(e.source != address(0));
        uint256 end = (e.epoch + 1) * 1 days;
        age = block.timestamp > end ? block.timestamp - end : 0;
        uint256 feeAt = IRewardEntrySource(e.source).lastFeeAt();
        dormant = feeAt != 0 && block.timestamp >= feeAt + 30 days;
        uint256 first = (block.timestamp / 1 days) * 1 days + 10 minutes;
        nextCheck = block.timestamp < first ? first : first + ((block.timestamp - first) / 15 minutes + 1) * 15 minutes;
        uint256 minimum = minimumBudget(id);
        reason = pending[id] > 0
            ? DeferReason.Pending
            : minimum > runLimit()
                ? DeferReason.CostLimit
                : available[id] < minimum ? DeferReason.BelowMinimum : DeferReason.Ready;
    }

    /// @notice Single-order limit: the stock layer's CapacityController `lRun` (governance-adjustable).
    function runLimit() public view returns (uint256) {
        return capacity == address(0) ? 0 : IRoundCapacity(capacity).lRun();
    }

    function minimumBudget(uint256 id) public view returns (uint256) {
        Entry storage e = entries[id];
        uint256 cost = IRoundRegistry(registry).resolve(e.assetId, e.adapterVersion).fixedCost18;
        return cost > 0.5 ether ? cost * 200 : 100 ether;
    }

    function reserveBatch(uint256[] calldata ids, uint256[] calldata amounts, uint256 minRaw, uint256 deadline)
        external
        nonReentrant
        returns (uint256 id)
    {
        require(
            msg.sender == batcher && ids.length > 0 && ids.length <= 64 && ids.length == amounts.length && minRaw > 0
                && deadline > block.timestamp
        );
        Entry storage first = entries[ids[0]];
        IRoundRegistry.Route memory route = IRoundRegistry(registry).resolve(first.assetId, first.adapterVersion);
        require(route.enabled && route.adapter.code.length > 0 && route.asset.code.length > 0);
        id = ++nextRoundId;
        Round storage r = rounds[id];
        r.assetId = first.assetId;
        r.adapterVersion = first.adapterVersion;
        r.asset = route.asset;
        r.adapter = route.adapter;
        r.minRawOut = minRaw;
        r.deadline = deadline;
        r.epochMin = type(uint256).max;
        r.entryCount = ids.length;
        _reserveSlices(id, r, ids, amounts);
        require(r.budget18 >= minimumBudget(ids[0]) && r.budget18 <= runLimit(), "cost or run limit");
        r.sourceNonce = executionNonce[r.entriesHash];
        r.orderId = keccak256(abi.encode(block.chainid, address(this), r.entriesHash, minRaw, deadline, r.sourceNonce));
        orderRound[r.orderId] = id;
        r.status = Status.Reserved;
        IRoundCapacity(capacity).reserveFor(r.orderId, route.underlying, r.budget18);
        emit RoundState(id, r.status);
        emit RoundLinked(id, r.orderId, r.adapter, r.asset, route.underlying, r.budget18, minRaw, ids.length);
    }

    /// @dev Body of `reserveBatch`'s slice loop, split out only to keep `forge coverage --ir-minimum`
    ///      within the stack limit (no behaviour change; see PLAN "覆盖率" record).
    function _reserveSlices(uint256 id, Round storage r, uint256[] calldata ids, uint256[] calldata amounts) private {
        for (uint256 i; i < ids.length; ++i) {
            uint256 eid = ids[i];
            Entry storage e = entries[eid];
            require(
                e.source != address(0) && groupKey(eid) == groupKey(ids[0]) && amounts[i] > 0
                    && amounts[i] <= available[eid] && pending[eid] == 0
            );
            for (uint256 j; j < i; ++j) {
                require(ids[j] != eid);
            }
            available[eid] -= amounts[i];
            pending[eid] += amounts[i];
            r.budget18 += amounts[i];
            slices[id].push(Slice(eid, amounts[i]));
            r.entriesHash = keccak256(abi.encode(r.entriesHash, e, amounts[i]));
            if (e.epoch < r.epochMin) r.epochMin = e.epoch;
            if (e.epoch > r.epochMax) r.epochMax = e.epoch;
        }
    }

    function start(uint256 id, bytes calldata quoteData) external nonReentrant {
        Round storage r = rounds[id];
        require(r.status == Status.Reserved && block.timestamp <= r.deadline);
        r.status = Status.Funding;
        ++executionNonce[r.entriesHash];
        IRoundStockAdapter(r.adapter).startFunding{value: r.budget18}(
            r.orderId, r.budget18, r.minRawOut, r.deadline, address(vault), quoteData
        );
        emit RoundState(id, r.status);
    }

    function poke(uint256 id) external nonReentrant {
        Round storage r = rounds[id];
        require(r.status == Status.Funding || (r.status == Status.Quarantined && r.submittedAt == 0));
        require(IRoundStockAdapter(r.adapter).funded(r.orderId));
        r.status = Status.Funded;
        emit RoundState(id, r.status);
    }

    function submit(uint256 id) external nonReentrant {
        Round storage r = rounds[id];
        require(r.status == Status.Funded);
        r.status = Status.Submitted;
        r.submittedAt = block.timestamp;
        IRoundStockAdapter(r.adapter).submit(r.orderId);
        emit RoundState(id, r.status);
    }
    mapping(uint256 => bool) public orphanConsumed;

    function cancelUnsent(uint256 id) external nonReentrant {
        Round storage r = rounds[id];
        require(r.status == Status.Reserved);
        r.status = Status.CancelledUnsent;
        for (uint256 i; i < slices[id].length; ++i) {
            Slice storage s = slices[id][i];
            available[s.entryId] += s.budget18;
            pending[s.entryId] -= s.budget18;
        }
        IRoundCapacity(capacity).releaseUnsent(r.orderId);
        IRoundBatcher(batcher).onRoundFinalized(id);
        emit RoundState(id, r.status);
    }

    function requestCancel(uint256 id) external nonReentrant {
        Round storage r = rounds[id];
        require(
            (r.status == Status.Submitted || r.status == Status.Quarantined) && r.submittedAt != 0
                && block.timestamp >= r.submittedAt + 30 minutes && !r.cancelRequested
        );
        r.cancelRequested = true;
        IRoundStockAdapter(r.adapter).requestCancel(r.orderId);
    }

    function applyResult(bytes32 orderId, bytes calldata proof) external {
        uint256 id = orderRound[orderId];
        require(id != 0);
        finalize(id, proof);
    }

    function finalize(uint256 id, bytes calldata proof) public nonReentrant {
        Round storage r = rounds[id];
        require(
            r.status == Status.Submitted || r.status == Status.Quarantined || r.status == Status.Funding
                || r.status == Status.Funded || (r.status == Status.Refunded && !orphanConsumed[id])
        );
        uint256 beforeStock = IERC20(r.asset).balanceOf(address(vault));
        uint256 beforeNative = address(vault).balance;
        (uint8 outcome, uint256 raw, uint256 refund) = IRoundStockAdapter(r.adapter).consumeResult(r.orderId, proof);
        require(
            IERC20(r.asset).balanceOf(address(vault)) == beforeStock + raw
                && address(vault).balance == beforeNative + refund,
            "receipt delta"
        );
        if (outcome == 0) {
            require(raw == 0 && refund == 0 && r.status != Status.Refunded);
            // Status 0 means no verified result, not authenticated uncertainty.
            // Anyone may relay a proof; an empty result must not change the lifecycle.
            return;
        }
        if (outcome == 2) {
            require(r.status != Status.Refunded && raw == 0 && refund == r.budget18, "invalid refund");
            r.refunded = refund;
            r.status = Status.Refunded;
            for (uint256 i; i < slices[id].length; ++i) {
                available[slices[id][i].entryId] += slices[id][i].budget18;
                pending[slices[id][i].entryId] -= slices[id][i].budget18;
            }
            vault.returnRefund(refund);
            IRoundCapacity(capacity).releaseFinalized(r.orderId);
            IRoundBatcher(batcher).onRoundFinalized(id);
        } else {
            require(outcome == 1 && r.submittedAt != 0 && raw >= r.minRawOut && refund == 0, "unverified result");
            if (r.status == Status.Refunded) {
                orphanConsumed[id] = true;
                vault.sendOrphan(r.asset, treasury, raw);
            } else {
                r.delivered = raw;
                r.status = Status.Settled;
                for (uint256 i; i < slices[id].length; ++i) {
                    pending[slices[id][i].entryId] -= slices[id][i].budget18;
                }
                _allocate(id, raw);
                IRoundCapacity(capacity).releaseFinalized(r.orderId);
                IRoundBatcher(batcher).onRoundFinalized(id);
            }
        }
        emit RoundState(id, r.status);
    }

    function _allocate(uint256 id, uint256 raw) internal {
        Slice[] storage items = slices[id];
        uint256 total = rounds[id].budget18;
        uint256[] memory amounts = new uint256[](items.length);
        uint256[] memory remainders = new uint256[](items.length);
        uint256 allocated;
        for (uint256 i; i < items.length; ++i) {
            amounts[i] = Math.mulDiv(raw, items[i].budget18, total);
            remainders[i] = mulmod(raw, items[i].budget18, total);
            allocated += amounts[i];
        }
        bool[] memory awarded = new bool[](items.length);
        for (uint256 k; k < raw - allocated; ++k) {
            uint256 best = type(uint256).max;
            for (uint256 i; i < items.length; ++i) {
                if (
                    !awarded[i]
                        && (best == type(uint256).max
                            || remainders[i] > remainders[best]
                            || (remainders[i] == remainders[best] && items[i].entryId < items[best].entryId))
                ) best = i;
            }
            ++amounts[best];
            awarded[best] = true;
        }
        for (uint256 i; i < items.length; ++i) {
            delivered[items[i].entryId] += amounts[i];
            vault.recordDelivery(items[i].entryId, amounts[i]);
        }
    }
    receive() external payable {}
}

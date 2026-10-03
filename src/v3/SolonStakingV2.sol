// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {EligibilityController} from "./EligibilityController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EligibilityRegistry} from "./EligibilityRegistry.sol";
import {ExpirySumTree} from "./libraries/ExpirySumTree.sol";
import {StakingRewardSource, StakingRewardSourceFactory} from "./StakingRewardSource.sol";
import {IV3FeeLedger} from "./interfaces/IV3FeeLedger.sol";
import {RewardRoundManager} from "./RewardRoundManager.sol";
import {RewardPayoutVault} from "./RewardPayoutVault.sol";

/// @notice SOLON principal with independent fee-time stock reward sources.
/// @dev Principal mutations append weight checkpoints without iterating reward sources.
/// Each lane lazily merges those checkpoints with its own fee events to replay carry
/// allocations at their ORIGINAL sequence and denominator. releaseCarry is permissionless
/// and paginated; a long backlog must be checkpointed before sealing or staging rewards.
/// PurchaseStock settles through RewardRoundManager/RewardVault; DirectStock settles
/// through immutable StakingRewardSource adapters into the same RewardPayoutVault.
/// Stake earns from the next fee after it lands: no activation, maturity or pending bucket.
/// For every staker eligible is either zero (system address / not A-qualified) or stakedOf.
contract SolonStakingV2 is ReentrancyGuard {
    event Staked(address indexed sponsor, address indexed beneficiary, uint256 amount);
    event Unstaked(address indexed account, address indexed recipient, uint256 amount);
    event WeightChanged(address indexed account, uint256 weight, uint256 sequence);
    event SourceRegistered(bytes32 indexed key, bytes32 indexed source, address indexed asset, uint8 kind);
    event CreditNotified(bytes32 indexed key, uint256 indexed epoch, uint256 amount27, bool carryLocked);
    event CarryReleased(bytes32 indexed key, uint256 indexed epoch, uint256 sequence, uint256 amount27);
    event SourceFunded(bytes32 indexed key, uint256 amount);

    using SafeERC20 for IERC20;
    error AmountError();
    error BasketFrozenError();
    error BeneficiaryConsentError();
    error BeneficiaryError();
    error BudgetUnfundedError();
    error CarryPageError();
    error CheckpointCarryFirstError();
    error ConfiguratorError();
    error ConfiguredError();
    error ConsentExpiredError();
    error EligibilityError();
    error EmptyBudgetError();
    error FundingAmountError();
    error LedgerClaimError();
    error LedgerDeltaError();
    error LedgerError();
    error NativeDeltaError();
    error PrincipalDeltaError();
    error PrincipalError();
    error ProtocolConfigurationError();
    error ProtocolFundingError();
    error ProtocolNotifyError();
    error RawSourcePageError();
    error RegistryError();
    error RewardConfigurationError();
    error SealStateError();
    error SourceCoverageError();
    error SourceError();
    error SourceFundingError();
    error StageDeltaError();
    error StockDeltaError();
    error StockFundingError();
    error UnsealedEpochError();
    error V2BudgetError();
    error V2ConfigurationError();

    address[] private participants;
    uint256[] private participantSince;
    mapping(address => bool) private participated;
    mapping(bytes32 => uint256) public lastFeeAt;
    mapping(bytes32 => mapping(uint256 => bool)) public rewardSealed;

    function participantCount() external view returns (uint256) {
        return participants.length;
    }

    function participantAt(uint256 i) external view returns (address) {
        return participants[i];
    }

    struct EpochPolicy {
        address asset;
        bytes32 assetId;
        uint32 version;
        bytes32 policy;
    }
    mapping(bytes32 => mapping(uint256 => EpochPolicy)) private epochPolicies;

    function _policy(bytes32 key, uint256 epoch) internal view returns (EpochPolicy memory p) {
        p = epochPolicies[key][epoch];
        if (p.asset != address(0)) return p;
        Lane storage l = lanes[key];
        if (l.kind == 0 && automaticPool[l.source]) {
            (p.asset, p.assetId, p.version, p.policy) =
                sourceFactory.resolvePool(ledger, l.source, address(0), 0, epoch);
        } else {
            if (l.kind == 0 && !ledgerLane[key]) {
                (p.asset, p.assetId, p.version, p.policy) =
                    sourceFactory.resolveExternal(key == v2Lane, protocolDesk, epoch);
            }
            if (p.asset == address(0)) p = EpochPolicy(l.asset, l.assetId, l.version, l.policy);
        }
    }

    function _stampPolicy(bytes32 key, uint256 epoch) internal {
        if (epochPolicies[key][epoch].asset == address(0)) {
            EpochPolicy memory p = _policy(key, epoch);
            uint16 id = controller.assetIds(p.asset);
            if (controller.enabled()) {
                require(id != 0 && (requiredAssetMask & (uint256(1) << (id - 1))) != 0, BasketFrozenError());
            } else if (id != 0) {
                requiredAssetMask |= uint256(1) << (id - 1);
            }
            epochPolicies[key][epoch] = p;
        }
    }

    function sourceAsset(bytes32 key, uint256 epoch) external view returns (address) {
        return _policy(key, epoch).asset;
    }

    function sourcePolicy(bytes32 key, uint256 epoch) external view returns (bytes32, uint32, bytes32, uint8) {
        EpochPolicy memory p = _policy(key, epoch);
        return (p.assetId, p.version, p.policy, controller.enabled() && epoch >= controller.effectiveEpoch() ? 1 : 0);
    }

    function sourceQueueSnapshot(bytes32 key, uint256 epoch) external view returns (uint256 upper, uint256 revision) {
        require(epoch < block.timestamp / 1 days, UnsealedEpochError());
        uint256 lo;
        uint256 hi = participants.length;
        uint256 end = (epoch + 1) * 1 days;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (participantSince[mid] < end) lo = mid + 1;
            else hi = mid;
        }
        return (lo, creditTotal27[key][epoch] + 1);
    }

    function sealSource(bytes32 key, uint256 epoch)
        external
        nonReentrant
        returns (uint256 budget, uint256 total, uint8 kind)
    {
        Lane storage l = lanes[key];
        require(
            msg.sender == entrySource[key] && msg.sender != address(0) && l.kind == 0
                && epoch < block.timestamp / 1 days && !rewardSealed[key][epoch],
            SealStateError()
        );
        require(_processCarry(key, 256), CheckpointCarryFirstError());
        total = creditTotal27[key][epoch];
        budget = total / PRECISION;
        require(budget != 0, EmptyBudgetError());
        rewardSealed[key][epoch] = true;
        if (ledgerLane[key]) {
            uint256 beforeBalance = address(this).balance;
            require(IV3FeeLedger(ledger).claim(l.source, 3, budget), LedgerClaimError());
            require(address(this).balance == beforeBalance + budget, LedgerDeltaError());
            nativeAvailable[key] += budget;
        }
        require(nativeAvailable[key] >= budget, BudgetUnfundedError());
        nativeAvailable[key] -= budget;
        (bool ok,) = msg.sender.call{value: budget}("");
        require(ok, SourceFundingError());
        return (budget, total, 0);
    }

    receive() external payable {
        require(msg.sender == ledger, LedgerError());
    }
    StakingRewardSourceFactory public immutable sourceFactory;
    address public payout;
    address public roundsManager;
    mapping(bytes32 => address) public entrySource;
    mapping(bytes32 => mapping(uint256 => mapping(address => uint256))) public creditedToPayout;
    mapping(bytes32 => uint256) public totalStaged;

    function configureRewards(address manager, address payout_) external {
        require(
            msg.sender == configurator && roundsManager == address(0) && manager.code.length != 0
                && payout_.code.length != 0,
            RewardConfigurationError()
        );
        roundsManager = manager;
        payout = payout_;
    }

    function createEntrySource(bytes32 key) external returns (address source) {
        require(lanes[key].exists, SourceError());
        source = entrySource[key];
        if (source == address(0)) {
            source = sourceFactory.create(key);
            entrySource[key] = source;
        }
        if (roundsManager != address(0)) registerEntrySource(key);
    }

    function registerEntrySource(bytes32 key) public {
        address source = entrySource[key];
        require(source != address(0) && roundsManager != address(0), SourceError());
        if (lanes[key].kind == 0 && RewardRoundManager(payable(roundsManager)).sourcePool(source) == 0) {
            RewardRoundManager(payable(roundsManager)).registerSource(source, lanes[key].source);
        }
        if (!RewardPayoutVault(payout).trustedSource(source)) RewardPayoutVault(payout).registerSource(source);
    }

    function sourceInfo(bytes32 key) external view returns (bytes32, address, uint8, bytes32, uint32, bytes32) {
        Lane storage l = lanes[key];
        return (l.source, l.asset, l.kind, l.assetId, l.version, l.policy);
    }

    function sourceCredit(bytes32 key, address account, uint256 epoch) external view returns (uint256) {
        return _credit(indexHistory[key], epoch, account) + _credit(carryHistory[key], epoch, account);
    }

    function stageSource(bytes32 key, address account, uint256[] calldata epochs, address asset)
        external
        nonReentrant
        returns (uint256 payment)
    {
        require(msg.sender == entrySource[key] && msg.sender != address(0) && payout != address(0), SourceError());
        Lane storage l = lanes[key];
        require(l.kind == 1 && asset == l.asset && epochs.length <= 20, RawSourcePageError());
        _syncMode();
        laneEvents[key].push(CarryEvent(++sequence, block.timestamp, effectiveEligible(), weightRevision, 0));
        require(_processCarry(key, 256), CheckpointCarryFirstError());
        for (uint256 i; i < epochs.length; ++i) {
            uint256 epoch = epochs[i];
            uint256 owed =
                (_credit(indexHistory[key], epoch, account) + _credit(carryHistory[key], epoch, account)) / PRECISION;
            uint256 old = creditedToPayout[key][epoch][account];
            creditedToPayout[key][epoch][account] = owed;
            payment += owed - old;
        }
        if (payment != 0) {
            if (ledgerLane[key]) {
                uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
                (bytes32 fundingPool, uint8 bucket) = sourceFactory.ledgerPosition(ledger, l.source);
                require(IV3FeeLedger(ledger).claim(fundingPool, bucket, payment), LedgerClaimError());
                require(IERC20(asset).balanceOf(address(this)) == beforeBalance + payment, LedgerDeltaError());
                fundedAmount[key] += payment;
            }
            require(totalStaged[key] + payment <= fundedAmount[key], SourceCoverageError());
            totalStaged[key] += payment;
            uint256 beforeSelf = IERC20(asset).balanceOf(address(this));
            uint256 beforePayout = IERC20(asset).balanceOf(payout);
            IERC20(asset).safeTransfer(payout, payment);
            require(
                IERC20(asset).balanceOf(address(this)) + payment == beforeSelf
                    && IERC20(asset).balanceOf(payout) == beforePayout + payment,
                StageDeltaError()
            );
        }
    }

    using ExpirySumTree for ExpirySumTree.Tree;
    ExpirySumTree.Tree private expiryWeights;
    uint8 public modeGeneration;
    uint256 public requiredAssetMask;
    mapping(address => uint8) public accountGeneration;
    mapping(address => uint32) public accountExpiry;

    function effectiveEligible() public view returns (uint256) {
        return controller.enabled() ? expiryWeights.suffixSum(block.timestamp) : totalEligible;
    }

    function deliveryAllowed(address account, address asset) external view returns (bool) {
        return controller.canReceiveStock(asset, account);
    }

    function _syncMode() internal {
        if (controller.enabled() && modeGeneration == 0) {
            weightEvents.push(CarryEvent(++sequence, block.timestamp, 0, ++weightRevision, 0));
            totalEligible = 0;
            modeGeneration = 1;
        }
    }

    function _syncAccount(address account) internal {
        _syncMode();
        bool migrated = accountGeneration[account] != modeGeneration;
        uint256 amount = eligible[account];
        if (migrated || (modeGeneration == 1 && amount != 0 && accountExpiry[account] <= block.timestamp)) {
            if (!migrated && amount != 0) {
                expiryWeights.sub(accountExpiry[account], amount);
                totalEligible -= amount;
            }
            eligible[account] = 0;
            accountGeneration[account] = modeGeneration;
            accountExpiry[account] = 0;
            _weightPoint(account);
        }
    }

    function onEligibilityChange(address account) external {
        require(msg.sender == controller.registry(), RegistryError());
        _syncAccount(account);
        _checkpointWeight();
        uint256 amount = eligible[account];
        if (amount != 0) {
            if (modeGeneration == 1) expiryWeights.sub(accountExpiry[account], amount);
            eligible[account] = 0;
            totalEligible -= amount;
            accountExpiry[account] = 0;
            _weightPoint(account);
        }
    }

    /// @notice Permissionless re-evaluation of one staker, e.g. after an A-mode
    /// credential is registered or renewed. Never needed in default B mode.
    function syncEligibility(address account) external {
        _syncAccount(account);
        _checkpointWeight();
        _reweigh(account);
    }

    /// @dev Whether a zero-weight staker may earn now; system addresses and
    /// unqualified A-mode accounts keep principal without weight.
    function _qualify(address account) internal returns (bool) {
        if (
            account == address(this) || account == ledger || account == address(solon)
                || controller.systemVaultMask(account) != 0
        ) return false;
        if (modeGeneration == 0) return true;
        uint32 expiry = sourceFactory.eligibilityExpiry(address(controller), account, requiredAssetMask);
        if (expiry == 0) return false;
        accountExpiry[account] = expiry;
        return true;
    }

    /// @dev Set weight to the current stake (or zero). Callers checkpoint the carry
    /// clock first, so new stake earns only from later fee events.
    function _reweigh(address account) internal {
        uint256 previous = eligible[account];
        uint256 staked = stakedOf[account];
        uint256 next;
        if (staked != 0 && (previous != 0 || _qualify(account))) next = staked;
        if (next == previous) return;
        eligible[account] = next;
        totalEligible = totalEligible + next - previous;
        if (modeGeneration == 1) {
            if (previous != 0) expiryWeights.sub(accountExpiry[account], previous);
            if (next != 0) expiryWeights.add(accountExpiry[account], next);
        }
        if (previous == 0 && !participated[account]) {
            participated[account] = true;
            participants.push(account);
            participantSince.push(block.timestamp);
        }
        _weightPoint(account);
    }

    struct CarryEvent {
        uint256 seq;
        uint256 time;
        uint256 denominator;
        uint256 revision;
        uint256 deposit27;
    }
    CarryEvent[] private weightEvents;
    mapping(bytes32 => CarryEvent[]) private laneEvents;

    struct CarryState {
        uint256 weightCursor;
        uint256 laneCursor;
        uint256 index;
        uint256 remainder;
        uint256 denominator;
        uint256 revision;
        uint256 epoch;
    }
    mapping(bytes32 => CarryState) private carries;
    mapping(bytes32 => IndexPoint[]) private carryHistory;

    function _checkpointWeight() internal {
        _syncMode();
        weightEvents.push(CarryEvent(++sequence, block.timestamp, effectiveEligible(), weightRevision, 0));
    }

    function releaseCarry(bytes32 key, uint256 maxSteps) external returns (bool complete) {
        require(lanes[key].exists && maxSteps > 0 && maxSteps <= 256, CarryPageError());
        _syncMode();
        laneEvents[key].push(CarryEvent(++sequence, block.timestamp, effectiveEligible(), weightRevision, 0));
        return _processCarry(key, maxSteps);
    }

    function _processCarry(bytes32 key, uint256 maxSteps) internal returns (bool complete) {
        CarryState storage c = carries[key];
        CarryEvent[] storage own = laneEvents[key];
        for (uint256 n; n < maxSteps; ++n) {
            bool hasWeight = c.weightCursor < weightEvents.length;
            bool hasOwn = c.laneCursor < own.length;
            if (!hasWeight && !hasOwn) return true;
            CarryEvent memory e;
            if (hasWeight && (!hasOwn || weightEvents[c.weightCursor].seq < own[c.laneCursor].seq)) {
                e = weightEvents[c.weightCursor++];
            } else {
                e = own[c.laneCursor++];
            }
            uint256 unlocked = sourceFactory.checkpointCarry(key, e.denominator != 0, e.time, e.deposit27);
            if (unlocked != 0) {
                uint256 epoch = e.time / 1 days;
                if (c.revision != e.revision || c.denominator != e.denominator || c.epoch != epoch) {
                    dust27[key][c.epoch] += c.remainder;
                    c.remainder = 0;
                }
                uint256 numerator = unlocked + c.remainder;
                c.index += numerator / e.denominator;
                c.remainder = numerator % e.denominator;
                c.denominator = e.denominator;
                c.revision = e.revision;
                c.epoch = epoch;
                _stampPolicy(key, epoch);
                creditTotal27[key][epoch] += unlocked;
                emit CarryReleased(key, epoch, e.seq, unlocked);
                carryHistory[key].push(IndexPoint(e.seq, e.time, c.index));
            }
        }
        return c.weightCursor == weightEvents.length && c.laneCursor == own.length;
    }

    function carryState(bytes32 key)
        external
        view
        returns (uint256 deposited27, uint256 released27, uint256 clock, uint256 last, uint256 pendingEvents)
    {
        CarryState storage c = carries[key];
        (deposited27, released27, clock, last) = sourceFactory.carryState(key);
        pendingEvents = weightEvents.length - c.weightCursor + laneEvents[key].length - c.laneCursor;
    }

    IERC20 public immutable solon;
    address public immutable ledger;
    address public immutable configurator;
    EligibilityController public immutable controller;
    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;

    mapping(address => uint256) public eligible;
    uint256 public totalEligible;
    uint256 public constant PRECISION = 1e27;
    uint256 public sequence;
    uint256 private weightRevision;

    struct WeightPoint {
        uint256 seq;
        uint256 time;
        uint256 weight;
        uint32 expiry;
        uint8 generation;
    }
    mapping(address => WeightPoint[]) private weights;

    struct IndexPoint {
        uint256 seq;
        uint256 time;
        uint256 index;
    }

    struct Lane {
        bytes32 source;
        address asset;
        address quote;
        uint8 kind;
        bool exists;
        uint256 index;
        uint256 remainder;
        uint256 denominator;
        uint256 revision;
        uint256 lastEpoch;
        bytes32 assetId;
        uint32 version;
        bytes32 policy;
    }
    mapping(bytes32 => Lane) private lanes;
    mapping(bytes32 => IndexPoint[]) private indexHistory;
    mapping(bytes32 => mapping(uint256 => uint256)) public creditTotal27;
    mapping(bytes32 => mapping(uint256 => uint256)) public dust27;
    mapping(bytes32 => bytes32) public poolLane;
    mapping(bytes32 => bool) private automaticPool;

    function laneKey(bytes32 source, address asset, uint8 kind) public pure returns (bytes32) {
        return keccak256(abi.encode(source, kind == 0 ? address(0) : asset, kind));
    }

    function configureSource(
        bytes32 source,
        address quote,
        uint8 kind,
        address asset,
        bytes32 assetId,
        uint32 version,
        bytes32 policy
    ) external {
        require(msg.sender == configurator, ConfiguratorError());
        require(poolLane[source] == 0, ConfiguredError());
        bytes32 key = _registerLane(source, quote, kind, asset, assetId, version, policy);
        poolLane[source] = key;
        ledgerLane[key] = true;
    }

    function _registerLane(
        bytes32 source,
        address quote,
        uint8 kind,
        address asset,
        bytes32 assetId,
        uint32 version,
        bytes32 policy
    ) internal returns (bytes32 key) {
        require(
            source != 0 && kind <= 1 && asset.code.length != 0 && asset != address(solon)
                && (kind == 0 ? quote == address(0) : quote == asset),
            SourceError()
        );
        key = laneKey(source, asset, kind);
        require(!lanes[key].exists, ConfiguredError());
        Lane storage l = lanes[key];
        uint16 id = controller.assetIds(asset);
        if (controller.enabled()) {
            require(id != 0 && (requiredAssetMask & (uint256(1) << (id - 1))) != 0, BasketFrozenError());
        } else if (id != 0) {
            requiredAssetMask |= uint256(1) << (id - 1);
        }
        l.source = source;
        l.asset = asset;
        l.quote = quote;
        l.kind = kind;
        l.exists = true;
        l.assetId = assetId;
        l.version = version;
        l.policy = policy;
        carries[key].weightCursor = weightEvents.length;
        emit SourceRegistered(key, source, asset, kind);
    }
    mapping(bytes32 => bool) public ledgerLane;
    bytes32 public constant SOLON_V2_STAKING = keccak256("SOLON_V2_STAKING");
    address public v2Notifier;
    bytes32 public v2Lane;
    mapping(bytes32 => bool) public consumedV2Lot;

    function configureEligibilityAssets(address[] calldata assets) external {
        require(msg.sender == configurator && !controller.enabled(), RewardConfigurationError());
        requiredAssetMask |= sourceFactory.assetMask(address(controller), assets);
    }

    function configureRewardSchedules(address v2, address protocol) external {
        require(msg.sender == configurator && sequence == 0, RewardConfigurationError());
        requiredAssetMask |= sourceFactory.configureSchedules(v2, protocol, address(controller));
    }

    function configureV2(address notifier, address asset, bytes32 assetId, uint32 version, bytes32 policy) external {
        require(
            msg.sender == configurator && v2Notifier == address(0) && notifier.code.length != 0 && assetId != 0
                && version != 0 && policy != 0,
            V2ConfigurationError()
        );
        v2Notifier = notifier;
        v2Lane = _registerLane(SOLON_V2_STAKING, address(0), 0, asset, assetId, version, policy);
    }

    function notifyV2Budget(bytes32 lotId, uint256 actualUSDC18) external payable {
        require(
            msg.sender == v2Notifier && lotId != 0 && !consumedV2Lot[lotId] && msg.value == actualUSDC18,
            V2BudgetError()
        );
        consumedV2Lot[lotId] = true;
        _notify(v2Lane, actualUSDC18 * PRECISION);
        fundedAmount[v2Lane] += actualUSDC18;
        nativeAvailable[v2Lane] += actualUSDC18;
    }
    bytes32 public constant PROTOCOL_DESK_STAKING = keccak256("PROTOCOL_DESK_STAKING");
    address public protocolDesk;
    address private protocolAsset;
    bytes32 private protocolAssetId;
    uint32 private protocolVersion;
    bytes32 private protocolPricePolicy;
    mapping(bytes32 => uint256) public totalNotified27;
    mapping(bytes32 => uint256) public fundedAmount;
    mapping(bytes32 => uint256) public nativeAvailable;

    function configureProtocolDesk(address notifier, address asset, bytes32 assetId, uint32 version, bytes32 policy)
        external
    {
        require(
            msg.sender == configurator && !controller.enabled() && protocolDesk == address(0)
                && notifier.code.length != 0 && asset.code.length != 0 && asset != address(solon) && assetId != 0
                && version != 0 && policy != 0,
            ProtocolConfigurationError()
        );
        protocolDesk = notifier;
        protocolAsset = asset;
        protocolAssetId = assetId;
        protocolVersion = version;
        protocolPricePolicy = policy;
        uint16 id = controller.assetIds(asset);
        if (id != 0) requiredAssetMask |= uint256(1) << (id - 1);
    }

    function protocolSource(bytes32 pool) public pure returns (bytes32) {
        return keccak256(abi.encode(PROTOCOL_DESK_STAKING, pool));
    }

    function notifyProtocolDeskCredit(bytes32 pool, uint256 epoch, address asset, uint8 kind, uint256 amount27)
        external
        returns (uint256 assigned27)
    {
        require(msg.sender == protocolDesk && epoch == block.timestamp / 1 days, ProtocolNotifyError());
        if (kind == 0) asset = protocolAsset;
        bytes32 source = protocolSource(pool);
        bytes32 key = laneKey(source, asset, kind);
        if (!lanes[key].exists) {
            _registerLane(
                source,
                kind == 0 ? address(0) : asset,
                kind,
                asset,
                protocolAssetId,
                protocolVersion,
                protocolPricePolicy
            );
        }
        assigned27 = _notify(key, amount27);
    }

    function _notify(bytes32 key, uint256 amount27) internal returns (uint256 assigned27) {
        require(amount27 != 0, AmountError());
        _syncMode();
        uint256 denominator = effectiveEligible();
        uint256 seq = ++sequence;
        laneEvents[key].push(
            CarryEvent(seq, block.timestamp, denominator, weightRevision, denominator == 0 ? amount27 : 0)
        );
        totalNotified27[key] += amount27;
        emit CreditNotified(key, block.timestamp / 1 days, amount27, denominator == 0);
        lastFeeAt[key] = block.timestamp;
        if (denominator != 0) {
            _distribute(key, amount27, seq, block.timestamp);
            assigned27 = amount27;
        }
    }

    function fundProtocolDesk(bytes32 pool, uint256 epoch, address asset, uint8 kind, uint256 amount)
        external
        payable
        nonReentrant
    {
        require(msg.sender == protocolDesk && epoch <= block.timestamp / 1 days, ProtocolFundingError());
        if (kind == 0) asset = protocolAsset;
        bytes32 key = laneKey(protocolSource(pool), asset, kind);
        require(
            lanes[key].exists && amount != 0 && fundedAmount[key] + amount <= totalNotified27[key] / PRECISION,
            FundingAmountError()
        );
        fundedAmount[key] += amount;
        emit SourceFunded(key, amount);
        if (kind == 0) {
            require(msg.value == amount, NativeDeltaError());
            nativeAvailable[key] += amount;
        } else {
            require(msg.value == 0, StockFundingError());
            uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            require(IERC20(asset).balanceOf(address(this)) == beforeBalance + amount, StockDeltaError());
        }
    }

    function feeCustodyMode() external pure returns (uint256) {
        return 3;
    }

    function onFeeCredit(bytes32 pool, address quote, uint8 kind, uint256 amount) external {
        require(msg.sender == ledger, LedgerError());
        bytes32 key = poolLane[pool];
        if (key == 0) {
            (address asset, bytes32 id, uint32 version, bytes32 policy) =
                sourceFactory.resolvePool(ledger, pool, quote, kind, block.timestamp / 1 days);
            key = laneKey(pool, asset, kind);
            if (!lanes[key].exists) _registerLane(pool, quote, kind, asset, id, version, policy);
            automaticPool[pool] = true;
            poolLane[pool] = key;
            ledgerLane[key] = true;
        }
        Lane storage l = lanes[key];
        require(l.exists && l.quote == quote && l.kind == kind, SourceError());
        _notify(key, amount * PRECISION);
    }

    function _distribute(bytes32 key, uint256 amount27, uint256 seq, uint256 time) internal {
        Lane storage l = lanes[key];
        uint256 denominator = effectiveEligible();
        uint256 epoch = time / 1 days;
        if (l.revision != weightRevision || l.denominator != denominator || l.lastEpoch != epoch) {
            dust27[key][l.lastEpoch] += l.remainder;
            l.remainder = 0;
        }
        uint256 numerator = amount27 + l.remainder;
        l.index += numerator / denominator;
        l.remainder = numerator % denominator;
        l.denominator = denominator;
        l.revision = weightRevision;
        l.lastEpoch = epoch;
        _stampPolicy(key, epoch);
        creditTotal27[key][epoch] += amount27;
        indexHistory[key].push(IndexPoint(seq, time, l.index));
    }

    function _weightPoint(address account) internal {
        weights[account].push(
            WeightPoint(
                ++sequence, block.timestamp, eligible[account], accountExpiry[account], accountGeneration[account]
            )
        );
        ++weightRevision;
        emit WeightChanged(account, eligible[account], sequence);
    }

    function _indexBefore(IndexPoint[] storage h, uint256 seq, uint256 time) internal view returns (uint256) {
        uint256 lo;
        uint256 hi = h.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (h[mid].seq < seq && h[mid].time < time) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : h[lo - 1].index;
    }

    function creditOf(bytes32 source, uint256 epoch, address asset, uint8 kind, address account)
        public
        view
        returns (uint256 credit)
    {
        bytes32 key = laneKey(source, asset, kind);
        if (kind == 0 && _policy(key, epoch).asset != asset) return 0;
        return _credit(indexHistory[key], epoch, account) + _credit(carryHistory[key], epoch, account);
    }

    function _credit(IndexPoint[] storage h, uint256 epoch, address account) internal view returns (uint256 credit) {
        WeightPoint[] storage w = weights[account];
        uint256 start = epoch * 1 days;
        uint256 end = start + 1 days;
        uint256 lo;
        uint256 hi = w.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (w[mid].time < start) lo = mid + 1;
            else hi = mid;
        }
        if (lo != 0) --lo;
        uint256 lowerEpoch = _indexBefore(h, type(uint256).max, start);
        for (uint256 i = lo; i < w.length && w[i].time < end; ++i) {
            uint256 upperSeq = i + 1 < w.length ? w[i + 1].seq : type(uint256).max;
            uint256 cap = end;
            if (w[i].generation == 0 && controller.enabled()) {
                cap = Math.min(cap, controller.effectiveEpoch() * 1 days);
            }
            if (w[i].generation == 1) cap = Math.min(cap, w[i].expiry);
            uint256 upper = _indexBefore(h, upperSeq, cap);
            uint256 lower = Math.max(lowerEpoch, _indexBefore(h, w[i].seq, type(uint256).max));
            if (upper > lower) credit += w[i].weight * (upper - lower);
        }
    }

    constructor(address solon_, address ledger_, EligibilityController controller_) {
        require(solon_.code.length != 0 && ledger_ != address(0) && address(controller_).code.length != 0);
        solon = IERC20(solon_);
        ledger = ledger_;
        controller = controller_;
        configurator = msg.sender;
        sourceFactory = new StakingRewardSourceFactory(address(this));
    }

    function stake(uint256 amount) external nonReentrant {
        _stake(msg.sender, amount);
    }
    mapping(address => uint256) public consentNonces;

    function stake(uint256 amount, address beneficiary, uint256 deadline, bytes calldata consent)
        external
        nonReentrant
    {
        require(beneficiary != address(0), BeneficiaryError());
        if (beneficiary != msg.sender) {
            require(block.timestamp <= deadline, ConsentExpiredError());
            require(
                sourceFactory.validStakeConsent(
                    msg.sender, beneficiary, amount, consentNonces[beneficiary]++, deadline, consent
                ),
                BeneficiaryConsentError()
            );
        }
        _stake(beneficiary, amount);
    }

    function _stake(address beneficiary, uint256 amount) internal {
        require(amount != 0, AmountError());
        _syncAccount(beneficiary);
        _checkpointWeight();
        uint256 beforeBalance = solon.balanceOf(address(this));
        solon.safeTransferFrom(msg.sender, address(this), amount);
        require(solon.balanceOf(address(this)) == beforeBalance + amount, PrincipalDeltaError());
        stakedOf[beneficiary] += amount;
        totalStaked += amount;
        _reweigh(beneficiary);
        emit Staked(msg.sender, beneficiary, amount);
    }

    function unstake(uint256 amount, address to) external nonReentrant {
        require(amount != 0 && amount <= stakedOf[msg.sender] && to != address(0), PrincipalError());
        _syncAccount(msg.sender);
        _checkpointWeight();
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        _reweigh(msg.sender);
        solon.safeTransfer(to, amount);
        emit Unstaked(msg.sender, to, amount);
    }
}

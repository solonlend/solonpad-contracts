// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {V3Carry} from "./libraries/V3Carry.sol";
import {RewardAssetSchedule} from "./RewardAssetSchedule.sol";
import {EligibilityController} from "./EligibilityController.sol";
import {EligibilityRegistry} from "./EligibilityRegistry.sol";
import {ExpirySumTree} from "./libraries/ExpirySumTree.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IV3Payout {
    function stageCredit(address source, address account, uint256[] calldata epochs, address asset)
        external
        returns (uint256);
    function claimFor(address account, address asset) external returns (uint256);
}

interface IV3RewardLedger {
    function claim(bytes32 pool, uint8 bucket, uint256 amount) external returns (bool);
}

/// @notice Fixed-supply holder token with default B and one-way, lazy A eligibility.
/// @dev One immutable fee source per launch token; historical reward assets remain unbounded.
/// A qualifying balance earns from the first fee credited after it is received: every
/// transfer checkpoints the index before weights change, so there is no activation step,
/// no maturity wait and no pending bucket. For any non-excluded account eligible is
/// either zero (excluded, system vault, or not A-qualified) or exactly its balance.
contract V3RewardToken is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ExpirySumTree for ExpirySumTree.Tree;
    ExpirySumTree.Tree private expiryWeights;
    EligibilityController public eligibilityController;
    bool public configured;
    uint256 public modeGeneration;
    uint256 public sequence;
    mapping(address => uint256) public accountGeneration;
    mapping(address => uint32) public accountExpiry;
    mapping(uint256 => uint256) public expiryIndex;
    mapping(uint256 => uint256) public expiryCarryIndex;
    mapping(uint256 => bool) public expiryCheckpointed;
    RewardAssetSchedule public assetSchedule;

    function configureAssetSchedule(address schedule_) external {
        if (msg.sender != configurator) revert Unauthorized();
        require(
            address(assetSchedule) == address(0) && schedule_.code.length != 0 && roundsManager != address(0)
                && participants.length == 0 && totalCredited == 0,
            "schedule configuration"
        );
        assetSchedule = RewardAssetSchedule(schedule_);
        uint256 count = assetSchedule.policyCount();
        require(count != 0, "empty schedule");
        for (uint256 i; i < count; ++i) {
            (address asset,,,) = assetSchedule.policyAt(i);
            require(asset != address(this) && asset.code.length != 0, "schedule asset");
            _includeRewardAsset(asset);
        }
    }

    function roundInterval() external view returns (uint256) {
        return address(assetSchedule) == address(0) ? 1 days : assetSchedule.roundInterval();
    }

    function rotationIndex(uint256 epoch) external view returns (uint256) {
        return address(assetSchedule) == address(0) ? 0 : assetSchedule.rotationIndex(epoch);
    }

    function nextRoundAt(uint256 epoch) public view returns (uint256) {
        return address(assetSchedule) == address(0) ? (epoch + 1) * 1 days : assetSchedule.nextRoundAt(epoch);
    }

    function _scheduledAsset(uint256 epoch) internal view returns (address asset) {
        if (address(assetSchedule) == address(0)) return defaultRewardAsset;
        (asset,,,) = assetSchedule.resolve(epoch);
    }
    uint256 public requiredAssetMask;
    address[] private rewardBasket;
    mapping(address => bool) public inRewardBasket;

    function _includeRewardAsset(address asset) internal {
        if (inRewardBasket[asset]) return;
        if (address(eligibilityController) != address(0)) {
            require(participants.length == 0 && totalCredited == 0, "basket frozen");
        }
        inRewardBasket[asset] = true;
        rewardBasket.push(asset);
        if (address(eligibilityController) != address(0)) _addAssetMask(asset);
    }

    function _addAssetMask(address asset) internal {
        uint16 id = eligibilityController.assetIds(asset);
        require(id != 0, "unbound eligibility asset");
        requiredAssetMask |= uint256(1) << (id - 1);
    }
    address public roundsManager;

    struct PurchasePolicy {
        bytes32 assetId;
        uint32 version;
        bytes32 pricePolicy;
    }
    PurchasePolicy public defaultPurchasePolicy;
    mapping(uint256 => PurchasePolicy) public epochPurchasePolicy;
    mapping(uint256 => bool) public rewardSealed;

    function configureRounds(address manager, bytes32 assetId, uint32 version, bytes32 pricePolicy) external {
        if (msg.sender != configurator) revert Unauthorized();
        require(
            roundsManager == address(0) && manager.code.length != 0 && totalCredited == 0 && settlementKind == 0
                && assetId != 0 && version != 0 && pricePolicy != 0,
            "round configuration"
        );
        roundsManager = manager;
        defaultPurchasePolicy = PurchasePolicy(assetId, version, pricePolicy);
    }

    function declareEpochRewardPolicy(
        uint256 epoch,
        address asset,
        bytes32 assetId,
        uint32 version,
        bytes32 pricePolicy
    ) external {
        if (msg.sender != configurator) revert Unauthorized();
        require(
            roundsManager != address(0) && epoch >= block.timestamp / 1 days && epochBudget[epoch] == 0
                && epochAsset[epoch] == address(0) && asset.code.length != 0 && asset != address(this) && assetId != 0
                && version != 0 && pricePolicy != 0,
            "epoch policy"
        );
        _includeRewardAsset(asset);
        epochAsset[epoch] = asset;
        epochPurchasePolicy[epoch] = PurchasePolicy(assetId, version, pricePolicy);
    }

    function rewardPolicy(uint256 epoch, uint8 cohort)
        external
        view
        returns (bytes32 assetId, uint32 version, bytes32 pricePolicy, uint8 mode)
    {
        require(cohort == 0, "holder cohort");
        PurchasePolicy memory p = epochPurchasePolicy[epoch];
        if (p.assetId == 0) {
            if (address(assetSchedule) == address(0)) p = defaultPurchasePolicy;
            else (, p.assetId, p.version, p.pricePolicy) = assetSchedule.resolve(epoch);
        }
        mode = _enabled() && epoch >= eligibilityController.effectiveEpoch() ? 1 : 0;
        return (p.assetId, p.version, p.pricePolicy, mode);
    }

    function creditOf(address account, uint256 epoch, uint8 cohort) external view returns (uint256) {
        require(cohort == 0, "holder cohort");
        return epochCredit27(account, epoch);
    }

    function sealReward(uint256 epoch, uint8 cohort)
        external
        nonReentrant
        returns (uint256 budget18, uint256 creditTotal, uint8 kind)
    {
        require(msg.sender == roundsManager && roundsManager != address(0), "round manager");
        require(
            settlementKind == 0 && cohort == 0 && epoch < block.timestamp / 1 days && !rewardSealed[epoch], "seal state"
        );
        require(block.timestamp >= nextRoundAt(epoch), "round interval");
        budget18 = epochBudget[epoch];
        require(budget18 != 0, "empty budget");
        rewardSealed[epoch] = true;
        creditTotal = budget18 * PRECISION;
        // Ledger ownership already fixes pool + holder bucket; keeper cannot
        // invent a budget or select a new recipient.
        uint256 beforeBalance = address(this).balance;
        if (beforeBalance < budget18) {
            uint256 needed = budget18 - beforeBalance;
            require(IV3RewardLedger(ledger).claim(poolId, 0, needed), "ledger claim");
            require(address(this).balance == beforeBalance + needed, "budget delta");
        }
        (bool ok,) = roundsManager.call{value: budget18}("");
        require(ok, "round funding");
        return (budget18, creditTotal, 0);
    }

    receive() external payable {
        if (msg.sender != ledger) revert Unauthorized();
    }
    address public payout;

    /// @dev One slot per first-time earner; holders now join on their first
    /// qualifying receipt (usually a buy), so the entry is packed.
    struct Participant {
        address account;
        uint64 since;
    }
    Participant[] private participants;

    function participantCount() external view returns (uint256) {
        return participants.length;
    }

    function participantAt(uint256 index) external view returns (address) {
        return participants[index].account;
    }

    function queueAsset(uint256 epoch) external view returns (address) {
        return epochAsset[epoch];
    }

    function queueSnapshot(uint256 epoch) external view returns (uint256 upperBound, uint256 revision) {
        require(epoch < block.timestamp / 1 days, "unsealed epoch");
        uint256 end = (epoch + 1) * 1 days;
        uint256 lo;
        uint256 hi = participants.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (participants[mid].since < end) lo = mid + 1;
            else hi = mid;
        }
        return (lo, cumulativeDelivered[epoch] + 1);
    }

    function configurePayout(address payout_) external {
        if (msg.sender != configurator) revert Unauthorized();
        if (payout != address(0) || payout_.code.length == 0 || totalCredited != 0) revert InvalidConfiguration();
        payout = payout_;
    }

    function configureEligibility(EligibilityController controller_) external {
        if (msg.sender != configurator) revert Unauthorized();
        if (address(eligibilityController) != address(0) || address(controller_).code.length == 0 || totalCredited != 0)
        {
            revert InvalidConfiguration();
        }
        eligibilityController = controller_;
        for (uint256 i; i < rewardBasket.length; ++i) {
            _addAssetMask(rewardBasket[i]);
        }
    }

    function deliveryAllowed(address account, address asset) public view returns (bool) {
        return address(eligibilityController) == address(0) || eligibilityController.canReceiveStock(asset, account);
    }

    function _enabled() internal view returns (bool) {
        return address(eligibilityController) != address(0) && eligibilityController.enabled();
    }

    function _registry() internal view returns (EligibilityRegistry) {
        return EligibilityRegistry(eligibilityController.registry());
    }

    function _syncMode() internal {
        if (_enabled() && modeGeneration == 0) {
            // Pause the same carry clock across a lazy mode boundary; never release
            // the no-A-weight interval against stale B weights.
            carry.checkpoint(false);
            _freezeRemainders();
            totalEligible = 0;
            modeGeneration = 1;
        }
    }

    /// @notice Permissionless re-evaluation of one holder, e.g. after an A-mode
    /// credential is registered or renewed. Never needed in default B mode.
    function syncEligibility(address account) public {
        releaseCarry();
        _reweigh(account, balanceOf(account));
    }

    /// @dev Retire a weight from an older mode generation or past its credential expiry.
    function _syncAccount(address account) internal {
        bool migrated = accountGeneration[account] != modeGeneration;
        uint256 amount = eligible[account];
        if (migrated || (modeGeneration == 1 && amount != 0 && accountExpiry[account] <= block.timestamp)) {
            if (!migrated && amount != 0) {
                expiryWeights.sub(accountExpiry[account], amount);
                totalEligible -= amount;
                _registry().unbindRewardPool(account);
            }
            eligible[account] = 0;
            accountGeneration[account] = modeGeneration;
            accountExpiry[account] = 0;
            // An account that never earned has nothing to cap; keeping its history
            // empty also marks it as not yet a participant.
            if (accountHistory[account].length != 0) _save(account);
        }
    }

    /// @dev Whether an account with zero weight may start earning now. In A mode this
    /// also fixes the credential expiry and binds the pool; a full binding table or
    /// any registry failure leaves the balance non-earning instead of blocking the transfer.
    function _qualify(address account) internal returns (bool) {
        if (excluded[account]) return false;
        if (address(eligibilityController) == address(0)) return true;
        if (eligibilityController.systemVaultMask(account) != 0) return false;
        if (modeGeneration == 0) return true;
        // canReceiveStock covers credential status, expiry and jurisdiction policy.
        EligibilityRegistry registry = _registry();
        if (
            !deliveryAllowed(account, settlementKind == 1 ? quote : defaultRewardAsset)
                || (registry.assetMaskOf(account) & requiredAssetMask) != requiredAssetMask
        ) return false;
        try registry.bindRewardPool(account) {}
        catch {
            return false;
        }
        accountExpiry[account] = registry.validUntil(account);
        return true;
    }

    /// @dev Set an account's weight to its post-transfer balance (or zero). The caller
    /// has already released carry, so the index is checkpointed before the change.
    function _reweigh(address account, uint256 newBalance) internal {
        _syncAccount(account);
        uint256 previous = eligible[account];
        uint256 next;
        if (newBalance != 0 && (previous != 0 || _qualify(account))) next = newBalance;
        if (next == previous) return;
        _freezeRemainders();
        eligible[account] = next;
        totalEligible = totalEligible + next - previous;
        if (modeGeneration == 1) {
            uint32 expiry = accountExpiry[account];
            if (previous != 0) expiryWeights.sub(expiry, previous);
            if (next != 0) expiryWeights.add(expiry, next);
            else _registry().unbindRewardPool(account);
        }
        // History is written only once an account has had weight, so an empty
        // history identifies a first-time participant without a separate flag.
        if (accountHistory[account].length == 0) participants.push(Participant(account, uint64(block.timestamp)));
        _save(account);
        emit WeightChanged(account, previous, next, totalEligible);
    }

    function onEligibilityChange(address account) external {
        if (msg.sender != address(_registry())) revert Unauthorized();
        releaseCarry();
        _syncAccount(account);
        uint256 amount = eligible[account];
        if (amount != 0) {
            _freezeRemainders();
            expiryWeights.sub(accountExpiry[account], amount);
            totalEligible -= amount;
            eligible[account] = 0;
            _save(account);
            emit WeightChanged(account, amount, 0, totalEligible);
        }
        _registry().unbindRewardPool(account);
    }

    function checkpointExpiry(uint32 time) external returns (uint256 ordinary, uint256 carryIndex) {
        require(time <= block.timestamp, "future expiry");
        if (!expiryCheckpointed[time]) {
            uint256 combined = _indexBefore(time);
            carryIndex = _carryBefore(time);
            expiryIndex[time] = combined - carryIndex;
            expiryCarryIndex[time] = carryIndex;
            expiryCheckpointed[time] = true;
        }
        return (expiryIndex[time], expiryCarryIndex[time]);
    }

    using V3Carry for V3Carry.Stream;
    V3Carry.Stream private carry;
    uint256 public carryPerEligibleToken;
    uint256 public carryIndexRemainder;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    address public immutable ledger;
    address public immutable configurator;
    mapping(address => bool) public excluded;
    mapping(address => uint256) public eligible;
    uint256 public totalEligible;

    constructor(string memory n, string memory s, address strategy, address ledger_, address[] memory excluded_)
        ERC20(n, s)
    {
        require(strategy != address(0) && ledger_ != address(0));
        ledger = ledger_;
        configurator = msg.sender;
        excluded[address(this)] = true;
        excluded[strategy] = true;
        excluded[ledger_] = true;
        excluded[address(0xdead)] = true;
        for (uint256 i; i < excluded_.length; ++i) {
            excluded[excluded_[i]] = true;
        }
        _mint(strategy, SUPPLY);
    }
    uint256 public constant PRECISION = 1e27;
    bytes32 public poolId;
    address public quote;
    uint8 public settlementKind;
    uint256 public rewardPerEligibleToken;
    uint256 public indexRemainder;
    uint256 private lastDenominator;
    uint256 private indexEpoch;

    struct IndexPoint {
        uint256 time;
        uint256 index;
        uint256 carryIndex;
        uint256 sequence;
    }

    /// @dev Weight <= SUPPLY < 2^90 and the mode generation is 0/1, so the header
    /// packs into one slot; a weight change in a new second writes three slots.
    struct AccountPoint {
        uint40 time;
        uint32 validUntil;
        uint8 generation;
        uint128 weight;
        uint256 index;
        uint256 earned27;
    }
    IndexPoint[] private indexHistory;
    mapping(address => AccountPoint[]) private accountHistory;
    mapping(uint256 => uint256) public epochBudget;
    mapping(uint256 => mapping(address => uint256)) public creditedToPayout;
    mapping(address => uint256) public paidTotal;
    mapping(address => uint256) public stagedTotal;
    address public defaultRewardAsset;
    mapping(uint256 => address) public epochAsset;
    mapping(uint256 => uint256) public cumulativeDelivered;
    mapping(address => uint256) public deliveredTotal;
    mapping(uint256 => uint256) public epochDust27;
    event WeightChanged(address indexed account, uint256 previousWeight, uint256 newWeight, uint256 totalWeight);
    event EpochCredited(uint256 indexed epoch, address indexed asset, uint256 amount, bool carryRelease);
    event StockDelivered(uint256 indexed epoch, address indexed asset, uint256 amount);
    event RewardPaid(address indexed account, address indexed asset, uint256 amount);

    uint256 public totalCredited;
    uint256 public lastFeeAt;
    error Unauthorized();
    error InvalidConfiguration();
    error PageTooLarge();

    function configurePool(bytes32 pool, address quote_, uint8 kind) external {
        if (msg.sender != configurator) revert Unauthorized();
        if (
            configured || (kind == 0 && quote_ != address(0)) || (kind == 1 && quote_.code.length == 0)
                || quote_ == address(this) || kind > 1 || (kind == 0 && defaultRewardAsset == address(0))
        ) revert InvalidConfiguration();
        configured = true;
        poolId = pool;
        quote = quote_;
        settlementKind = kind;
        _includeRewardAsset(kind == 1 ? quote_ : defaultRewardAsset);
    }

    function effectiveEligible() public view returns (uint256) {
        return _enabled() ? expiryWeights.suffixSum(block.timestamp) : totalEligible;
    }

    function onFeeCredit(bytes32 pool, address quote_, uint8 kind, uint256 amount) external {
        if (msg.sender != ledger) revert Unauthorized();
        if (!configured || pool != poolId || quote_ != quote || kind != settlementKind) revert InvalidConfiguration();
        _syncMode();
        if (effectiveEligible() == 0) {
            // No effective time passes while empty. Every transfer checkpoints the
            // paused clock before adding weight, so deposits need no clock write.
            carry.deposit(amount);
        } else {
            releaseCarry();
            _distribute(amount, false);
        }
        totalCredited += amount;
        if (amount != 0) lastFeeAt = block.timestamp;
    }

    function releaseCarry() public {
        _syncMode();
        uint256 unlocked = carry.checkpoint(effectiveEligible() != 0);
        if (unlocked != 0) _distribute(unlocked, true);
    }

    function carryState() external view returns (uint256 deposited, uint256 released, uint256 clock, uint256 last) {
        return (carry.deposited + carry.pendingDeposit, carry.released, carry.clock, carry.last);
    }

    function _distribute(uint256 amount, bool fromCarry) internal {
        uint256 denominator = effectiveEligible();
        if (denominator != lastDenominator) {
            _freezeRemainders();
            lastDenominator = denominator;
        }
        uint256 epoch = block.timestamp / 1 days;
        if (indexEpoch != epoch) {
            _freezeRemainders();
            indexEpoch = epoch;
        }
        if (epochAsset[epoch] == address(0)) {
            epochAsset[epoch] = settlementKind == 1 ? quote : _scheduledAsset(epoch);
            require(epochAsset[epoch] != address(0), "asset policy missing");
        }
        emit EpochCredited(epoch, epochAsset[epoch], amount, fromCarry);
        uint256 numerator = amount * PRECISION + (fromCarry ? carryIndexRemainder : indexRemainder);
        uint256 delta = numerator / denominator;
        rewardPerEligibleToken += delta;
        if (fromCarry) {
            carryPerEligibleToken += delta;
            carryIndexRemainder = numerator % denominator;
        } else {
            indexRemainder = numerator % denominator;
        }
        epochBudget[epoch] += amount;
        uint256 n = indexHistory.length;
        IndexPoint memory point = IndexPoint(block.timestamp, rewardPerEligibleToken, carryPerEligibleToken, ++sequence);
        // Historical lookups use strict timestamp boundaries. Account checkpoints
        // retain intrasecond ownership changes, so only the final index is needed.
        if (n != 0 && indexHistory[n - 1].time == block.timestamp) indexHistory[n - 1] = point;
        else indexHistory.push(point);
    }

    function _save(address account) internal {
        AccountPoint[] storage h = accountHistory[account];
        uint256 n = h.length;
        uint256 earned27;
        if (n != 0) {
            AccountPoint storage last = h[n - 1];
            earned27 = last.earned27 + last.weight * (_pointIndex(last, block.timestamp, true) - last.index);
        }
        AccountPoint memory point = AccountPoint(
            uint40(block.timestamp),
            accountExpiry[account],
            uint8(accountGeneration[account]),
            uint128(eligible[account]),
            rewardPerEligibleToken,
            earned27
        );
        if (n != 0 && h[n - 1].time == block.timestamp) h[n - 1] = point;
        else h.push(point);
    }

    function _indexBefore(uint256 t) internal view returns (uint256) {
        uint256 lo;
        uint256 hi = indexHistory.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (indexHistory[mid].time < t) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : indexHistory[lo - 1].index;
    }

    function _carryBefore(uint256 t) internal view returns (uint256) {
        uint256 lo;
        uint256 hi = indexHistory.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (indexHistory[mid].time < t) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : indexHistory[lo - 1].carryIndex;
    }

    function _pointIndex(AccountPoint storage p, uint256 t, bool inclusiveNow) internal view returns (uint256) {
        uint256 end = t;
        if (p.generation == 0 && _enabled()) end = Math.min(end, eligibilityController.effectiveEpoch() * 1 days);
        if (p.generation == 1 && p.validUntil != 0) end = Math.min(end, p.validUntil);
        uint256 result = inclusiveNow && end == t && (p.generation == 0 ? !_enabled() : p.validUntil > t)
            ? rewardPerEligibleToken
            : _indexBefore(end);
        return Math.max(result, p.index);
    }

    function _earnedBefore(address account, uint256 t) internal view returns (uint256) {
        AccountPoint[] storage h = accountHistory[account];
        uint256 lo;
        uint256 hi = h.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (h[mid].time < t) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return 0;
        AccountPoint storage p = h[lo - 1];
        return p.earned27 + p.weight * (_pointIndex(p, t, false) - p.index);
    }

    function epochCredit27(address account, uint256 epoch) public view returns (uint256) {
        return _earnedBefore(account, (epoch + 1) * 1 days) - _earnedBefore(account, epoch * 1 days);
    }

    /// @notice Fixed-recipient source pull. Payout's reentrancy lock also protects
    /// callbacks reached through the legacy claim convenience entrypoint.
    function stageCredit(address account, uint256[] calldata epochs, address asset) external returns (uint256 payment) {
        if (msg.sender != payout || payout == address(0)) revert Unauthorized();
        require(epochs.length <= 20, "epoch page");
        require(roundsManager == address(0) || settlementKind == 1, "claim through reward vault");
        releaseCarry();
        for (uint256 i; i < epochs.length; ++i) {
            uint256 epoch = epochs[i];
            if (epochAsset[epoch] != asset) continue;
            uint256 credit = epochCredit27(account, epoch);
            uint256 owed = settlementKind == 1
                ? credit / PRECISION
                : (epochBudget[epoch] == 0
                        ? 0
                        : Math.mulDiv(credit, cumulativeDelivered[epoch], epochBudget[epoch] * PRECISION));
            uint256 prior = creditedToPayout[epoch][account];
            creditedToPayout[epoch][account] = owed;
            payment += owed - prior;
        }
        if (payment != 0) {
            uint256 balance = IERC20(asset).balanceOf(address(this));
            if (balance < payment && settlementKind == 1) {
                require(IV3RewardLedger(ledger).claim(poolId, 0, payment - balance));
            }
            uint256 beforeSelf = IERC20(asset).balanceOf(address(this));
            uint256 beforePayout = IERC20(asset).balanceOf(payout);
            stagedTotal[asset] += payment;
            IERC20(asset).safeTransfer(payout, payment);
            require(
                IERC20(asset).balanceOf(address(this)) + payment == beforeSelf
                    && IERC20(asset).balanceOf(payout) == beforePayout + payment,
                "stage delta"
            );
        }
    }

    function claim(uint256[] calldata epochs, address[] calldata assets) external nonReentrant {
        require(roundsManager == address(0) || settlementKind == 1, "claim through reward vault");
        releaseCarry();
        if (epochs.length > 20 || assets.length > 4) revert PageTooLarge();
        if (payout != address(0)) {
            for (uint256 i; i < assets.length; ++i) {
                IV3Payout(payout).stageCredit(address(this), msg.sender, epochs, assets[i]);
                IV3Payout(payout).claimFor(msg.sender, assets[i]);
            }
            return;
        }
        for (uint256 a; a < assets.length; ++a) {
            address asset = assets[a];
            require(deliveryAllowed(msg.sender, asset), "ineligible delivery");
            uint256 payment;
            for (uint256 i; i < epochs.length; ++i) {
                uint256 epoch = epochs[i];
                if (asset != epochAsset[epoch]) continue;
                uint256 credit27 = epochCredit27(msg.sender, epoch);
                uint256 owed = settlementKind == 1
                    ? credit27 / PRECISION
                    : (epochBudget[epoch] == 0
                            ? 0
                            : Math.mulDiv(credit27, cumulativeDelivered[epoch], epochBudget[epoch] * PRECISION));
                uint256 prior = creditedToPayout[epoch][msg.sender];
                creditedToPayout[epoch][msg.sender] = owed;
                payment += owed - prior;
            }
            if (payment != 0) {
                uint256 balance = IERC20(asset).balanceOf(address(this));
                if (balance < payment && settlementKind == 1) {
                    require(IV3RewardLedger(ledger).claim(poolId, 0, payment - balance));
                }
                uint256 selfBefore = IERC20(asset).balanceOf(address(this));
                uint256 recipientBefore = IERC20(asset).balanceOf(msg.sender);
                paidTotal[asset] += payment;
                IERC20(asset).safeTransfer(msg.sender, payment);
                require(
                    IERC20(asset).balanceOf(address(this)) + payment == selfBefore
                        && IERC20(asset).balanceOf(msg.sender) == recipientBefore + payment,
                    "payout delta"
                );
                emit RewardPaid(msg.sender, asset, payment);
            }
        }
    }

    /// @notice Deployment-time policy, required before configuring a PurchaseStock pool.
    function setDefaultRewardAsset(address asset) external {
        if (msg.sender != configurator) revert Unauthorized();
        if (defaultRewardAsset != address(0) || asset.code.length == 0 || asset == address(this) || totalCredited != 0)
        {
            revert InvalidConfiguration();
        }
        defaultRewardAsset = asset;
    }

    /// @notice Prebind a future rotation. Unspecified epochs inherit the fixed default.
    function declareEpochAsset(uint256 epoch, address asset) external {
        require(roundsManager == address(0), "declare full reward policy");
        if (msg.sender != configurator) revert Unauthorized();
        if (
            epoch < block.timestamp / 1 days || epochBudget[epoch] != 0 || epochAsset[epoch] != address(0)
                || asset.code.length == 0 || asset == address(this) || settlementKind == 1
        ) revert InvalidConfiguration();
        _includeRewardAsset(asset);
        epochAsset[epoch] = asset;
    }

    /// @notice Trusted deployment coordinator must verify order/result provenance before calling.
    /// @dev Phase-one boundary only: this function is not a cross-chain proof verifier.
    function deliver(uint256 epoch, address asset, uint256 amount) external nonReentrant {
        require(roundsManager == address(0), "deliver through reward vault");
        if (msg.sender != configurator) revert Unauthorized();
        if (
            settlementKind != 0 || epoch >= block.timestamp / 1 days || epochBudget[epoch] == 0
                || epochAsset[epoch] != asset || amount == 0
        ) revert InvalidConfiguration();
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        require(IERC20(asset).balanceOf(address(this)) - beforeBalance == amount, "delivery delta");
        cumulativeDelivered[epoch] += amount;
        deliveredTotal[asset] += amount;
        emit StockDelivered(epoch, asset, amount);
    }

    /// @notice Total stock debt including assets still held for this token by FeeLedger.
    /// @dev DirectStock coverage is local balance + ledger.accrued(poolId,0); PurchaseStock coverage is local balance.
    function rawLiability(address asset) external view returns (uint256) {
        return (settlementKind == 1 && asset == quote ? totalCredited : deliveredTotal[asset]) - paidTotal[asset]
            - stagedTotal[asset];
    }

    function _freezeRemainders() internal {
        epochDust27[indexEpoch] += indexRemainder + carryIndexRemainder;
        indexRemainder = 0;
        carryIndexRemainder = 0;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == to || amount == 0) {
            super._update(from, to, amount);
            return;
        }
        // Checkpoint carry and index before any weight moves: value received now
        // earns only from the next fee, so same-transaction flash holding earns nothing.
        // Weight history is independent of ERC20 balances, so balances may move first.
        releaseCarry();
        super._update(from, to, amount);
        if (from != address(0) && !excluded[from]) _reweigh(from, balanceOf(from));
        if (to != address(0) && !excluded[to]) _reweigh(to, balanceOf(to));
    }
}

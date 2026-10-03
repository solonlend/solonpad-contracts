// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CapacityController — the Solon stock layer's issuance caps
/// @notice New in Solon (no ArcStocks original; design r5 §8.3 A10, caps approved 07:05 and raised by the
///         owner 2026-09-30 23:11 JST): single order <= `lRun` ($10,000), unreviewed-by-canonical exposure <=
///         `uRun` ($1,000,000, equal to the total), total issuance exposure <= `totalCap` ($1,000,000) with 20%
///         reserved for reward orders, i.e. public orders need `U_after <= totalCap - 20%` ($800,000) and
///         reward orders `U_after <= totalCap`. The unreviewed cap is split the same way (review #4): public
///         orders and all redemptions may hold at most 80% of `uRun` unreviewed ($800,000); the reward lane
///         always keeps its own 20% ($200,000) and may also use whatever room `uRun` still has. USD amounts
///         are 18-dp notional at order time; raw liabilities are tracked separately by the hub and the vault.
///
///         Every cap is a governance parameter: the guardian (or owner) lowers at once; a raise is proposed by
///         the owner and takes effect only `LIMIT_DELAY` (48h) later. `type(uint256).max` is a valid raise
///         (caps effectively lifted) without removing the mechanism.
///
///         Exposure is the sum of mutually exclusive states: inflight (reserved, not yet issued),
///         issued (minted), redeeming (burned, not yet finally settled). Only a final delivery or a proven
///         "RH owes nothing" refund releases a reservation; there is no timeout release. Returns of a
///         failed sell restore the previous reservation without a new cap check (A03), and finalize paths
///         never revert, so a cross-chain result can always be applied.
contract CapacityController {
    uint256 public constant DEFAULT_L_RUN = 10_000e18;
    uint256 public constant DEFAULT_U_RUN = 1_000_000e18;
    uint256 public constant DEFAULT_TOTAL_CAP = 1_000_000e18;
    /// @notice Smallest public buy principal (re-review L3). A return is recognised as the principal or the
    ///         proceeds once at least half of it is back; below that the order waits 6h for `escalateFunds`.
    ///         Measured Relay cost is about $0.04 fixed + ~0.09% ($500 order), 0.68% on a $10 test; a Relay
    ///         leg on $20 is ~$0.06 (~0.3%), and even ten times that (3%) stays far below 50%. LayerZero and
    ///         route fees are paid from the order's separate reserve, not its principal. At $20 the 25 bps
    ///         fee ($0.05) also roughly covers the per-order keeper gas on both chains.
    uint256 public constant DEFAULT_MIN_ORDER = 20e18;
    /// @notice Share of the total cap and of the unreviewed cap kept for the reward lane.
    uint256 public constant REWARD_SHARE_BPS = 2_000;
    uint64 public constant LIMIT_DELAY = 48 hours;

    enum State {
        None,
        Reserved,
        Issued,
        Redeeming,
        Closed
    }

    struct Ticket {
        State state;
        uint8 lane; // 0 public, 1 reward
        bool sent; // principal left the source chain: no unsent release any more
        bool unreviewed; // counted in unreviewedUsd until canonical review
        address asset;
        uint256 usd;
        uint256 raw;
    }

    address public immutable owner; // the stock layer timelock
    address public immutable guardian; // may only tighten
    address public hub;
    address public rewardManager;

    uint256 public lRun = DEFAULT_L_RUN;
    uint256 public uRun = DEFAULT_U_RUN;
    uint256 public totalCap = DEFAULT_TOTAL_CAP;
    /// @notice Minimum public buy principal (18-dp USD); owner (timelock) sets it, never above `lRun`.
    uint256 public minOrderUsd = DEFAULT_MIN_ORDER;

    struct Limits {
        uint256 lRun;
        uint256 uRun;
        uint256 totalCap;
        uint64 eta; // 0 = no proposal
    }

    /// @notice A proposed raise, effective at `eta`.
    Limits public pendingLimits;

    uint256 public inflightUsd;
    uint256 public issuedUsd;
    uint256 public redeemingUsd;
    /// @notice All unreviewed exposure (both lanes, buys and redemptions).
    uint256 public unreviewedUsd;
    /// @notice The reward lane's part of `unreviewedUsd`.
    uint256 public unreviewedRewardUsd;
    mapping(address asset => uint256) public issuedRaw;
    mapping(address asset => uint256) public issuedUsdOf;
    mapping(bytes32 key => Ticket) private _tickets;

    // ---- r7 per-asset caps (design §12.5; 2026-10-01: NVDA $400k, AAPL $300k, TSLA $300k).
    // Keyed by the RH underlying, as `issuedUsdOf`. Every reservation carries its asset (r11: the asset-less
    // `reserve`/`reservePublic` entries are gone); an asset without a cap set is limited by the global caps alone.
    struct AssetCap {
        uint256 cap;
        bool set;
    }

    struct PendingAssetCap {
        uint256 cap;
        uint64 eta;
    }

    mapping(address asset => AssetCap) public assetCap;
    mapping(address asset => PendingAssetCap) public pendingAssetCap;
    mapping(address asset => uint256) public inflightUsdOf;
    mapping(address asset => uint256) public redeemingUsdOf;
    address[] private _cappedAssets;

    event AssetCapSet(address indexed asset, uint256 cap);
    event AssetCapProposed(address indexed asset, uint256 cap, uint64 eta);

    error AssetLimit();

    event Bound(address hub, address rewardManager);
    event Reserved(bytes32 indexed key, uint8 lane, uint256 usd);
    event Sent(bytes32 indexed key);
    event Released(bytes32 indexed key, uint256 usd, bool unsent);
    event Issued(bytes32 indexed key, address indexed asset, uint256 raw, uint256 usd);
    event RedeemStarted(bytes32 indexed key, address indexed asset, uint256 raw, uint256 usd);
    event RedeemFinalized(bytes32 indexed key, uint256 usd, bool reviewed);
    event RedeemReverted(bytes32 indexed key, uint256 raw, uint256 usd);
    event Reviewed(bytes32 indexed key, uint256 usd);
    event LimitsSet(uint256 lRun, uint256 uRun, uint256 totalCap);
    event LimitsProposed(uint256 lRun, uint256 uRun, uint256 totalCap, uint64 eta);
    event LimitsProposalCancelled();
    event MinOrderSet(uint256 usd);
    event UnmatchedIssue(bytes32 indexed key, address indexed asset, uint256 raw);

    error RunLimit();
    error UnreviewedLimit();
    error PublicLimit();
    error TotalLimit();
    error AlreadySent();
    error AlreadyReserved();
    error NotReserved();
    error NotHub();
    error NotRewardManager();
    error NotOwner();
    error OnlyLower();
    error ZeroAmount();
    error AlreadyBound();
    error Timelocked();
    error NotFinalized();
    error BadLimits();
    error BelowMinOrder();

    constructor(address owner_, address guardian_) {
        require(owner_ != address(0) && guardian_ != address(0));
        owner = owner_;
        guardian = guardian_;
    }

    modifier onlyHub() {
        if (msg.sender != hub) revert NotHub();
        _;
    }

    /// @notice One-time wiring of the hub and the RewardRoundManager (the only reward-lane entry).
    function bind(address hub_, address rewardManager_) external {
        if (msg.sender != owner) revert NotOwner();
        if (hub != address(0)) revert AlreadyBound();
        require(hub_ != address(0) && rewardManager_ != address(0));
        hub = hub_;
        rewardManager = rewardManager_;
        emit Bound(hub_, rewardManager_);
    }

    // ------------------------------------------------------------------ limits

    /// @notice Tighten any cap at once (guardian or owner). Never raises, and cancels any pending proposal
    ///         so an older raise cannot take effect after the tightening (re-review L4); the owner proposes
    ///         again if still wanted. Lowering is not sanity-checked: zero caps are a valid stop.
    function lowerLimits(uint256 lRun_, uint256 uRun_, uint256 totalCap_) external {
        if (msg.sender != guardian && msg.sender != owner) revert NotOwner();
        if (lRun_ > lRun || uRun_ > uRun || totalCap_ > totalCap) revert OnlyLower();
        if (pendingLimits.eta != 0) {
            delete pendingLimits;
            emit LimitsProposalCancelled();
        }
        _setLimits(lRun_, uRun_, totalCap_);
    }

    /// @notice Propose new caps (`type(uint256).max` = lifted); effective after `LIMIT_DELAY`. Sanity
    ///         bounds (re-review L4): `minOrderUsd <= lRun <= uRun <= totalCap` and `lRun > 0`. The reward
    ///         shares are derived (20% of `uRun` and of `totalCap`), so the reward floor is always within
    ///         `uRun` and the public cap is always `totalCap - rewardReserve()`.
    function proposeLimits(uint256 lRun_, uint256 uRun_, uint256 totalCap_) external {
        if (msg.sender != owner) revert NotOwner();
        _checkLimits(lRun_, uRun_, totalCap_);
        uint64 eta = uint64(block.timestamp) + LIMIT_DELAY;
        pendingLimits = Limits(lRun_, uRun_, totalCap_, eta);
        emit LimitsProposed(lRun_, uRun_, totalCap_, eta);
    }

    function executeLimits() external {
        if (msg.sender != owner) revert NotOwner();
        Limits memory p = pendingLimits;
        if (p.eta == 0 || block.timestamp < p.eta) revert Timelocked();
        _checkLimits(p.lRun, p.uRun, p.totalCap); // the minimum order may have moved since the proposal
        delete pendingLimits;
        _setLimits(p.lRun, p.uRun, p.totalCap);
    }

    /// @notice Owner (timelock): the minimum public buy principal, at most the single-order limit.
    function setMinOrder(uint256 usd) external {
        if (msg.sender != owner) revert NotOwner();
        if (usd > lRun) revert BadLimits();
        minOrderUsd = usd;
        emit MinOrderSet(usd);
    }

    /// @notice Hub: a new public buy's principal must be within `[minOrderUsd, lRun]`.
    function checkRun(uint256 usd) external view {
        if (usd > lRun) revert RunLimit();
        if (usd < minOrderUsd) revert BelowMinOrder();
    }

    function _checkLimits(uint256 lRun_, uint256 uRun_, uint256 totalCap_) private view {
        if (lRun_ == 0 || lRun_ < minOrderUsd || lRun_ > uRun_ || uRun_ > totalCap_) revert BadLimits();
    }

    function _setLimits(uint256 lRun_, uint256 uRun_, uint256 totalCap_) private {
        lRun = lRun_;
        uRun = uRun_;
        totalCap = totalCap_;
        emit LimitsSet(lRun_, uRun_, totalCap_);
    }

    // ------------------------------------------------------------------ per-asset caps

    /// @notice First cap of an asset (owner = timelock). Later raises go through `proposeAssetCap`.
    function setAssetCap(address asset, uint256 cap) external {
        if (msg.sender != owner) revert NotOwner();
        if (assetCap[asset].set) revert Timelocked();
        require(asset != address(0));
        _cappedAssets.push(asset);
        _setAssetCap(asset, cap);
    }

    /// @notice Tighten an asset's cap at once (guardian or owner). Never raises.
    function lowerAssetCap(address asset, uint256 cap) external {
        if (msg.sender != guardian && msg.sender != owner) revert NotOwner();
        AssetCap memory c = assetCap[asset];
        if (!c.set || cap > c.cap) revert OnlyLower();
        _setAssetCap(asset, cap);
    }

    /// @notice Propose a new cap for a capped asset (any value, `type(uint256).max` = lifted); 48h later.
    function proposeAssetCap(address asset, uint256 cap) external {
        if (msg.sender != owner) revert NotOwner();
        if (!assetCap[asset].set) revert NotReserved();
        uint64 eta = uint64(block.timestamp) + LIMIT_DELAY;
        pendingAssetCap[asset] = PendingAssetCap(cap, eta);
        emit AssetCapProposed(asset, cap, eta);
    }

    function executeAssetCap(address asset) external {
        if (msg.sender != owner) revert NotOwner();
        PendingAssetCap memory p = pendingAssetCap[asset];
        if (p.eta == 0 || block.timestamp < p.eta) revert Timelocked();
        delete pendingAssetCap[asset];
        _setAssetCap(asset, p.cap);
    }

    function _setAssetCap(address asset, uint256 cap) private {
        assetCap[asset] = AssetCap(cap, true);
        emit AssetCapSet(asset, cap);
    }

    function cappedAssets() external view returns (address[] memory) {
        return _cappedAssets;
    }

    /// @notice This asset's exposure (inflight + issued + redeeming), in USD at order time.
    function assetExposureUsd(address asset) public view returns (uint256) {
        return inflightUsdOf[asset] + issuedUsdOf[asset] + redeemingUsdOf[asset];
    }

    /// @notice What a new order in `asset` may still add under the asset cap alone (max when uncapped).
    function assetRoomUsd(address asset) external view returns (uint256) {
        AssetCap memory c = assetCap[asset];
        if (!c.set) return type(uint256).max;
        uint256 e = assetExposureUsd(asset);
        return e >= c.cap ? 0 : c.cap - e;
    }

    /// @notice The part of `totalCap` only reward orders may use (20%).
    function rewardReserve() public view returns (uint256) {
        return totalCap / 10_000 * REWARD_SHARE_BPS + (totalCap % 10_000) * REWARD_SHARE_BPS / 10_000;
    }

    /// @notice Total exposure a new public order may bring the layer to.
    function publicCap() public view returns (uint256) {
        return totalCap - rewardReserve();
    }

    /// @notice The part of `uRun` kept for the reward lane (20%).
    function rewardUnreviewedShare() public view returns (uint256) {
        return uRun / 10_000 * REWARD_SHARE_BPS + (uRun % 10_000) * REWARD_SHARE_BPS / 10_000;
    }

    // ------------------------------------------------------------------ reservations

    /// @notice Reward lane (IRoundCapacity) with the per-asset cap: only the fixed RewardRoundManager may
    ///         reserve here. `asset` = the RH underlying.
    function reserveFor(bytes32 key, address asset, uint256 usd) external {
        if (msg.sender != rewardManager) revert NotRewardManager();
        _reserve(key, 1, asset, usd);
    }

    /// @notice Public lane with the per-asset cap (r7). `asset` = the RH underlying.
    function reservePublicFor(bytes32 key, address asset, uint256 usd) external onlyHub {
        _reserve(key, 0, asset, usd);
    }

    function canReserve(uint8 lane, uint256 usd) public view returns (bool) {
        return _check(lane, usd) == bytes4(0);
    }

    function canReserveFor(uint8 lane, address asset, uint256 usd) external view returns (bool) {
        return _checkAsset(lane, asset, usd) == bytes4(0);
    }

    function _checkAsset(uint8 lane, address asset, uint256 usd) private view returns (bytes4 err) {
        err = _check(lane, usd);
        if (err != bytes4(0)) return err;
        AssetCap memory c = assetCap[asset];
        if (c.set && assetExposureUsd(asset) + usd > c.cap) return AssetLimit.selector;
    }

    function _check(uint8 lane, uint256 usd) private view returns (bytes4) {
        if (usd == 0) return ZeroAmount.selector;
        if (usd > lRun) return RunLimit.selector;
        uint256 publicUnreviewed = unreviewedUsd - unreviewedRewardUsd;
        if (lane == 0) {
            // Public buys (and, after the fact, all redemptions) share 80% of U_run, within U_run overall.
            if (publicUnreviewed + usd > uRun - rewardUnreviewedShare() || unreviewedUsd + usd > uRun) {
                return UnreviewedLimit.selector;
            }
        } else if (unreviewedRewardUsd + usd > rewardUnreviewedShare() && unreviewedUsd + usd > uRun) {
            // Rewards always have their own 20%, and any room U_run still has beyond it.
            return UnreviewedLimit.selector;
        }
        uint256 after_ = exposureUsd() + usd;
        if (lane == 0 && after_ > publicCap()) return PublicLimit.selector;
        if (after_ > totalCap) return TotalLimit.selector;
        return bytes4(0);
    }

    function _reserve(bytes32 key, uint8 lane, address asset, uint256 usd) private {
        require(asset != address(0)); // r11: no reservation bypasses the per-asset cap
        Ticket storage t = _tickets[key];
        if (t.state != State.None && t.state != State.Closed) revert AlreadyReserved();
        if (t.state == State.Closed && t.sent) revert AlreadySent();
        bytes4 err = _checkAsset(lane, asset, usd);
        if (err != bytes4(0)) {
            assembly ("memory-safe") {
                mstore(0, err)
                revert(0, 4)
            }
        }
        _tickets[key] = Ticket(State.Reserved, lane, false, true, asset, usd, 0);
        inflightUsd += usd;
        inflightUsdOf[asset] += usd;
        _addUnreviewed(lane, usd);
        emit Reserved(key, lane, usd);
    }

    /// @notice The principal left the source chain; the reservation now waits for a proven outcome.
    function markSent(bytes32 key) external onlyHub {
        Ticket storage t = _tickets[key];
        if (t.state != State.Reserved) revert NotReserved();
        t.sent = true;
        emit Sent(key);
    }

    /// @notice Release a reservation whose principal never left (RoundManager `cancelUnsent`, or a
    ///         queued public order the hub refunded from its own escrow).
    function releaseUnsent(bytes32 key) external {
        if (msg.sender != rewardManager && msg.sender != hub) revert NotRewardManager();
        Ticket storage t = _tickets[key];
        if (t.state != State.Reserved) revert NotReserved();
        if (t.sent) revert AlreadySent();
        _drop(key, t, true);
    }

    /// @notice Release after the hub proved the reserve chain owes nothing (Failed result and the
    ///         principal actually refunded). A local cancel request alone never reaches here.
    function release(bytes32 key) external onlyHub {
        Ticket storage t = _tickets[key];
        if (t.state != State.Reserved) return;
        _drop(key, t, false);
    }

    /// @notice RewardRoundManager: the round finalized on the hub's result. The hub already moved the
    ///         ticket (Issued on Bought, Closed/None on a proven refund), so this only confirms that; it is
    ///         idempotent and never releases a reservation the hub has not finalized.
    function releaseFinalized(bytes32 key) external view {
        if (msg.sender != rewardManager) revert NotRewardManager();
        if (_tickets[key].state == State.Reserved) revert NotFinalized();
    }

    function _drop(bytes32 key, Ticket storage t, bool unsent) private {
        inflightUsd -= t.usd;
        inflightUsdOf[t.asset] -= t.usd;
        if (t.unreviewed) _subUnreviewed(t.lane, t.usd);
        emit Released(key, t.usd, unsent);
        if (unsent) {
            delete _tickets[key];
        } else {
            t.state = State.Closed;
            t.unreviewed = false;
        }
    }

    // ------------------------------------------------------------------ issuance and redemption

    /// @notice A verified Bought result minted `raw`. Never reverts: an unknown key (e.g. a late orphan
    ///         whose ticket closed) still records the raw issued, with no USD basis.
    function finalizeBuy(bytes32 key, address asset, uint256 raw) external onlyHub {
        Ticket storage t = _tickets[key];
        issuedRaw[asset] += raw;
        if (t.state != State.Reserved) {
            emit UnmatchedIssue(key, asset, raw);
            return;
        }
        inflightUsd -= t.usd;
        inflightUsdOf[t.asset] -= t.usd;
        issuedUsd += t.usd;
        issuedUsdOf[asset] += t.usd;
        t.state = State.Issued;
        t.asset = asset;
        t.raw = raw;
        emit Issued(key, asset, raw, t.usd);
    }

    /// @notice Move burned supply from issued to redeeming at the asset's average USD cost basis
    ///         (rounded up so the exposure released later is never understated).
    function beginRedeem(bytes32 key, address asset, uint256 raw) external onlyHub returns (uint256 usd) {
        if (_tickets[key].state != State.None) revert AlreadyReserved();
        uint256 totalRaw = issuedRaw[asset];
        uint256 basis = issuedUsdOf[asset];
        if (raw >= totalRaw) {
            usd = basis;
            raw = totalRaw;
        } else if (totalRaw != 0) {
            usd = (basis * raw + totalRaw - 1) / totalRaw;
            if (usd > basis) usd = basis;
        }
        issuedRaw[asset] = totalRaw - raw;
        issuedUsdOf[asset] = basis - usd;
        issuedUsd -= usd;
        redeemingUsd += usd;
        redeemingUsdOf[asset] += usd;
        _tickets[key] = Ticket(State.Redeeming, 0, true, false, asset, usd, raw);
        emit RedeemStarted(key, asset, raw, usd);
    }

    /// @notice The redemption finally settled. Over LayerZero it stays unreviewed until canonical review.
    function finalizeRedeem(bytes32 key, bool reviewed) external onlyHub {
        Ticket storage t = _tickets[key];
        if (t.state != State.Redeeming) return;
        redeemingUsd -= t.usd;
        redeemingUsdOf[t.asset] -= t.usd;
        t.state = State.Closed;
        if (!reviewed) {
            t.unreviewed = true;
            _addUnreviewed(t.lane, t.usd);
        }
        emit RedeemFinalized(key, t.usd, reviewed);
    }

    /// @notice Nothing was sold: the burn is undone, restoring the old basis without a new cap check.
    function revertRedeem(bytes32 key) external onlyHub {
        Ticket storage t = _tickets[key];
        if (t.state != State.Redeeming) return;
        redeemingUsd -= t.usd;
        redeemingUsdOf[t.asset] -= t.usd;
        issuedUsd += t.usd;
        issuedRaw[t.asset] += t.raw;
        issuedUsdOf[t.asset] += t.usd;
        t.state = State.Closed;
        emit RedeemReverted(key, t.raw, t.usd);
    }

    /// @notice A canonical checkpoint confirmed this key's result.
    function markReviewed(bytes32 key) external onlyHub {
        Ticket storage t = _tickets[key];
        if (!t.unreviewed) return;
        t.unreviewed = false;
        _subUnreviewed(t.lane, t.usd);
        emit Reviewed(key, t.usd);
    }

    function _addUnreviewed(uint8 lane, uint256 usd) private {
        unreviewedUsd += usd;
        if (lane == 1) unreviewedRewardUsd += usd;
    }

    function _subUnreviewed(uint8 lane, uint256 usd) private {
        unreviewedUsd -= usd;
        if (lane == 1) unreviewedRewardUsd -= usd;
    }

    // ------------------------------------------------------------------ views

    function exposureUsd() public view returns (uint256) {
        return inflightUsd + issuedUsd + redeemingUsd;
    }

    function ticket(bytes32 key) external view returns (Ticket memory) {
        return _tickets[key];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OApp, Origin, MessagingFee} from "../lz/OApp.sol";
import {IExecutionVenue} from "../interfaces/IExecutionVenue.sol";
import {IFundingRoute} from "../interfaces/IFundingRoute.sol";
import {Messages} from "../libs/Messages.sol";
import {Guarded} from "../libs/Guarded.sol";
import {IArbSys, AddressAlias} from "../libs/Arbitrum.sol";
import {IBridgerCheckpoint} from "../interfaces/IArcStocksV2.sol";

interface IStockMultiplier {
    function uiMultiplier() external view returns (uint256);
}

/// @title ReserveVault — the Solon reserve on Robinhood Chain
/// @notice Forked from ArcStocks v2 `ReserveVaultV2` (MIT, verified RH 0xe77b3b55…1bcd). Holds the stock
///         tokens behind every `.sol` token. Nobody operates it: orders arrive from the hub as LayerZero
///         messages and are executed against the venue; results go back the same way and, once an hour,
///         as a Merkle root through the canonical outbox so the hub can check the fast path against the
///         slow one. Stock leaves only two ways — a verified sell order, or `deliver` from the Ethereum
///         bridger through a retryable ticket. There is no admin withdrawal of backed stock.
///
///         Solon changes (design r5 §8.3/§8.6; recorded in docs/PLAN-v3-contracts.md phase 5):
///         - A09/A14 zero float: a buy executes only against the settlement token actually paid in for its
///           own ref (`fund`), in whichever order the money and the message arrive, exactly once. Unspent
///           funding and sale proceeds are per-ref USDG liabilities that go back to Arc through the fixed
///           return route, or to the holder here through the canonical lane. An optional acceleration float
///           (default off) may advance a buy; the late funding then refills the float.
///         - A07/A11: raw `claimable` is tracked in `claimableTotal`; `skimExcess` and the reserve view
///           deduct it, and skims go only to the fixed treasury.
///         - A06 narrowed: float withdrawals only to two fixed destinations and never below liabilities;
///           venue/bridger/peer/route changes wait 48h in-contract.
///         - A canonical `deliver` also appends a zero-proceeds `Sold` result to the checkpointed log so the
///           hub can close the escalated order and release its capacity on canonical proof (the Result wire
///           format is unchanged).
contract ReserveVault is OApp, Ownable2Step, Guarded, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant CONFIG_DELAY = 48 hours;

    struct Listing {
        address underlying;
        string ticker;
        bool enabled;
    }

    struct Pending {
        address value;
        uint64 eta;
    }

    IERC20 public immutable settlement;
    /// @notice ArbSys precompile (0x64 on the rollup); injectable so tests can mock it.
    IArbSys public immutable arbSys;
    /// @notice The hub's LayerZero endpoint id; results only go here and orders only come from here.
    uint32 public immutable hubEid;
    /// @notice Fixed destinations of skims and float withdrawals (A06/A07 narrowed).
    address public immutable treasury;
    address public immutable floatRecipientA;
    address public immutable floatRecipientB;

    IExecutionVenue public venue;
    /// @notice The Ethereum bridger. `deliver` accepts calls only from its L2 alias.
    address public bridger;
    /// @notice Route that carries USDG back to the Arc hub (refunds of unfilled buys, sale proceeds).
    IFundingRoute public returnRoute;
    /// @notice May move the free settlement float and the gas balance. Never stock, never a liability.
    address public keeper;
    /// @notice LayerZero executor options used when sending results (gas on the hub side).
    bytes public resultOptions;
    /// @notice Optional acceleration float (default off): a buy may be advanced from free settlement.
    bool public floatEnabled;

    Pending public pendingVenue;
    Pending public pendingBridger;
    Pending public pendingReturnRoute;
    mapping(uint32 eid => bytes32) public pendingPeer;
    mapping(uint32 eid => uint64) public pendingPeerEta;

    address[] private _underlyings;
    mapping(address underlying => Listing) private _listings;
    /// @notice Stock bought for Arc minus stock sold or delivered: what Arc may have in circulation.
    mapping(address underlying => uint256) public entitledOf;

    /// @notice Every executed order, in sequence. Checkpoints cover ranges of this array.
    Messages.Result[] private _results;
    /// @notice Number of results already covered by a checkpoint.
    uint64 public checkpointedThrough;
    /// @notice One settlement per ref, whichever lane gets there first.
    mapping(bytes32 ref => bool) public settled;
    /// @notice v1 → v2 migration switch kept from the original; closed once, forever.
    bool public migrationOpen = true;
    mapping(address underlying => uint64) public migrationNonce;
    /// @notice What a transfer could not deliver (e.g. a recipient that rejects tokens), claimable later.
    mapping(address token => mapping(address to => uint256)) public claimable;
    mapping(address token => uint256) public claimableTotal;

    // ---- sequential funding
    /// @notice Settlement token paid in for `ref` and not yet spent or returned (a liability to Arc).
    mapping(bytes32 ref => uint256) public funding;
    /// @notice Sale proceeds of `ref` not yet returned (a liability to Arc).
    mapping(bytes32 ref => uint256) public proceeds;
    /// @notice Buy orders that arrived before their money.
    mapping(bytes32 ref => Messages.Order) private _waiting;
    /// @notice Amount the acceleration float advanced for `ref`; its late funding refills the float.
    mapping(bytes32 ref => uint256) public advanced;
    uint256 public fundingTotal;
    uint256 public proceedsTotal;

    event StockListed(address indexed underlying, string ticker);
    event StockEnabled(address indexed underlying, bool enabled);
    event VenueSet(address venue);
    event BridgerSet(address bridger);
    event ReturnRouteSet(address route);
    event ConfigProposed(bytes32 indexed what, address value, uint64 eta);
    event KeeperSet(address keeper);
    event ResultOptionsSet(bytes options);
    event FloatEnabled(bool enabled);
    event OrderExecuted(
        bytes32 indexed ref,
        address indexed underlying,
        Messages.Outcome outcome,
        uint128 amountIn,
        uint128 amountOut,
        uint64 seq,
        string reason
    );
    event OrderIgnored(bytes32 indexed ref, string why);
    event OrderWaitingFunds(bytes32 indexed ref, uint256 needed, uint256 funded);
    event Funded(bytes32 indexed ref, address indexed payer, uint256 amount, uint256 toFloat);
    event FundsReturned(bytes32 indexed ref, uint256 amount, bytes32 transferId);
    event Checkpointed(uint64 fromSeq, uint64 toSeq, bytes32 root);
    event Delivered(
        bytes32 indexed ref, address indexed underlying, address indexed to, Messages.DeliverMode mode, uint256 amount
    );
    event Claimable(address indexed token, address indexed to, uint256 amount);
    event Claimed(address indexed token, address indexed to, uint256 amount);
    event FloatWithdrawn(address indexed token, address indexed to, uint256 amount);
    event ExcessSkimmed(address indexed underlying, uint256 amount);
    event MigratedIn(bytes32 indexed ref, address indexed underlying, uint256 settlementIn, uint256 shares, uint64 seq);
    event MigrationClosed();

    error ZeroAddress();
    error ZeroAmount();
    error NotListed(address underlying);
    error AlreadyListed(address underlying);
    error VenueUnsupported(address underlying);
    error SettlementMismatch();
    error NotBridgerAlias(address sender);
    error NotKeeper();
    error NothingToCheckpoint();
    error NothingToSkim();
    error ExceedsEntitlement(uint256 requested, uint256 entitled);
    error OnlySelf();
    error MigrationIsClosed();
    error NotFloatRecipient();
    error InsufficientFloat(uint256 free, uint256 need);
    error Timelocked();
    error NotWaiting(bytes32 ref);
    error NotSettled(bytes32 ref);
    error NothingToReturn(bytes32 ref);

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(
        address endpoint,
        uint32 hubEid_,
        address settlement_,
        address venue_,
        address arbSys_,
        address bridger_,
        address owner_,
        address treasury_,
        address[2] memory floatRecipients
    ) OApp(endpoint, owner_) Ownable(owner_) {
        if (settlement_ == address(0) || venue_ == address(0) || arbSys_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0) || floatRecipients[0] == address(0) || floatRecipients[1] == address(0)) {
            revert ZeroAddress();
        }
        if (IExecutionVenue(venue_).settlementToken() != settlement_) revert SettlementMismatch();
        settlement = IERC20(settlement_);
        venue = IExecutionVenue(venue_);
        arbSys = IArbSys(arbSys_);
        hubEid = hubEid_;
        bridger = bridger_;
        treasury = treasury_;
        floatRecipientA = floatRecipients[0];
        floatRecipientB = floatRecipients[1];
        resultOptions = hex"000301001101000000000000000000000000000927c0"; // lzReceive gas 600k on the hub side, type-3 options
    }

    receive() external payable {}

    // ------------------------------------------------------------------ orders (LayerZero)

    /// @dev Called by the endpoint once the DVNs verified a packet from the hub. Never reverts on
    ///      business failures: those become a Failed result so the hub can refund or re-mint. A buy whose
    ///      money has not arrived yet waits (Solon sequential mode) instead of failing on "float".
    function _lzReceive(Origin calldata origin, bytes32, bytes calldata message, address, bytes calldata)
        internal
        override
        nonReentrant
    {
        if (origin.srcEid != hubEid) revert Ownable.OwnableUnauthorizedAccount(address(0));
        Messages.Order memory o = Messages.decodeOrder(message);
        if (settled[o.ref]) {
            emit OrderIgnored(o.ref, "already settled");
            return;
        }
        if (o.side == Messages.Side.Buy && o.amountIn == 0) {
            // Solon void (review #3/#8): the hub closes a buy this vault has not executed. The ref settles
            // as Failed ("zero amount") exactly once, so the real order can never execute afterwards, and
            // any funding for it becomes returnable.
            delete _waiting[o.ref];
            _settleAndSend(o);
            return;
        }
        if (_waiting[o.ref].underlying != address(0)) {
            emit OrderIgnored(o.ref, "already waiting");
            return;
        }
        if (o.side == Messages.Side.Buy && !_fundable(o)) {
            _waiting[o.ref] = o;
            emit OrderWaitingFunds(o.ref, o.amountIn, funding[o.ref]);
            return;
        }
        _settleAndSend(o);
    }

    /// @notice Pay `amount` of the settlement token for order `ref` (the funding route's solver, or anyone).
    ///         Counted by actual balance increase; money for a ref never serves another ref.
    function fund(bytes32 ref, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = settlement.balanceOf(address(this));
        settlement.safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = settlement.balanceOf(address(this)) - before;
        uint256 toFloat = advanced[ref] < got ? advanced[ref] : got;
        if (toFloat > 0) advanced[ref] -= toFloat; // refills the float that advanced this ref
        funding[ref] += got - toFloat;
        fundingTotal += got - toFloat;
        emit Funded(ref, msg.sender, got, toFloat);
    }

    /// @notice Execute a buy that arrived before its money, now that the money is here. Anyone; the vault
    ///         pays the result message from its own gas balance, as it does inside `_lzReceive`.
    function executeFunded(bytes32 ref) external nonReentrant {
        Messages.Order memory o = _waiting[ref];
        if (o.underlying == address(0) || settled[ref]) revert NotWaiting(ref);
        if (!_fundable(o)) revert NotWaiting(ref);
        delete _waiting[ref];
        _settleAndSend(o);
    }

    /// @notice Send the unspent funding and/or proceeds of a settled `ref` back to the Arc hub through the
    ///         fixed return route. `quote` is the route's signed quote; `minOut` what must arrive (18 dp).
    ///         Keeper/owner only: the route checks the quote signature but not which Relay order (recipient) the
    ///         opaque order id stands for, so a leaked quote key alone must not be able to redirect a return.
    function returnFunds(bytes32 ref, uint256 minOut, bytes calldata quote) external onlyKeeperOrOwner nonReentrant {
        if (!settled[ref]) revert NotSettled(ref);
        uint256 amount = _takeLiabilities(ref);
        if (amount == 0) revert NothingToReturn(ref);
        settlement.forceApprove(address(returnRoute), amount);
        bytes32 transferId = returnRoute.send(ref, amount, 0, minOut, quote);
        settlement.forceApprove(address(returnRoute), 0);
        emit FundsReturned(ref, amount, transferId);
    }

    function _fundable(Messages.Order memory o) private view returns (bool) {
        if (funding[o.ref] >= o.amountIn) return true;
        return floatEnabled && freeSettlement() >= o.amountIn;
    }

    function _settleAndSend(Messages.Order memory o) private {
        settled[o.ref] = true;
        (Messages.Outcome outcome, uint128 amountOut, string memory reason) = _execute(o);
        Messages.Result memory r = Messages.Result({
            ref: o.ref,
            underlying: o.underlying,
            outcome: outcome,
            amountIn: o.amountIn,
            amountOut: amountOut,
            seq: uint64(_results.length)
        });
        _results.push(r);
        emit OrderExecuted(o.ref, o.underlying, outcome, o.amountIn, amountOut, r.seq, reason);

        bytes memory payload = Messages.encode(r);
        MessagingFee memory fee = _quote(hubEid, payload, resultOptions, false);
        _lzSend(hubEid, payload, resultOptions, fee, payable(address(this)));
    }

    function _execute(Messages.Order memory o) private returns (Messages.Outcome, uint128, string memory) {
        Listing storage l = _listings[o.underlying];
        if (l.underlying == address(0)) return (Messages.Outcome.Failed, 0, "not listed");
        if (o.amountIn == 0) return (Messages.Outcome.Failed, 0, "zero amount");

        if (o.side == Messages.Side.Buy) {
            if (paused()) return (Messages.Outcome.Failed, 0, "paused");
            if (!l.enabled) return (Messages.Outcome.Failed, 0, "disabled");
            // Spend this ref's own money first; the optional float may advance the rest.
            uint256 own = funding[o.ref] < o.amountIn ? funding[o.ref] : o.amountIn;
            uint256 adv = o.amountIn - own;
            if (adv > 0 && (!floatEnabled || freeSettlement() < adv)) return (Messages.Outcome.Failed, 0, "funding");
            funding[o.ref] -= own;
            fundingTotal -= own;
            advanced[o.ref] += adv;
            try this.venueBuy(o.underlying, o.amountIn, o.minOut) returns (uint256 shares) {
                entitledOf[o.underlying] += shares;
                return (Messages.Outcome.Bought, uint128(shares), "");
            } catch {
                funding[o.ref] += own; // nothing was bought: the money is still this ref's
                fundingTotal += own;
                advanced[o.ref] -= adv;
                return (Messages.Outcome.Failed, 0, "venue buy");
            }
        }

        // Sell: the hub burned the tokens before sending, so entitlement covers it by construction.
        uint256 entitled = entitledOf[o.underlying];
        if (o.amountIn > entitled) return (Messages.Outcome.Failed, 0, "entitlement");
        try this.venueSell(o.underlying, o.amountIn, o.minOut) returns (uint256 out) {
            entitledOf[o.underlying] = entitled - o.amountIn;
            proceeds[o.ref] += out;
            proceedsTotal += out;
            return (Messages.Outcome.Sold, uint128(out), "");
        } catch {
            return (Messages.Outcome.Failed, 0, "venue sell");
        }
    }

    /// @dev External so it can be wrapped in try/catch; only the vault itself may call it.
    function venueBuy(address underlying, uint256 settlementIn, uint256 minSharesOut)
        external
        onlySelf
        returns (uint256 sharesOut)
    {
        uint256 before = IERC20(underlying).balanceOf(address(this));
        settlement.forceApprove(address(venue), settlementIn);
        sharesOut = venue.buy(underlying, settlementIn, minSharesOut, address(this));
        uint256 landed = IERC20(underlying).balanceOf(address(this)) - before;
        if (landed < sharesOut) sharesOut = landed;
        if (sharesOut < minSharesOut) revert ExceedsEntitlement(sharesOut, minSharesOut);
    }

    function venueSell(address underlying, uint256 sharesIn, uint256 minSettlementOut)
        external
        onlySelf
        returns (uint256 settlementOut)
    {
        uint256 before = settlement.balanceOf(address(this));
        IERC20(underlying).forceApprove(address(venue), sharesIn);
        settlementOut = venue.sell(underlying, sharesIn, minSettlementOut, address(this));
        uint256 landed = settlement.balanceOf(address(this)) - before;
        if (landed < settlementOut) settlementOut = landed; // Solon: count what actually arrived
        if (settlementOut < minSettlementOut) revert ExceedsEntitlement(settlementOut, minSettlementOut);
    }

    // ------------------------------------------------------------------ canonical lane

    /// @notice Sends the Merkle root of every result since the last checkpoint to the bridger on
    ///         Ethereum through the rollup's outbox. Anyone may call; the keeper does, hourly.
    function checkpoint() external returns (bytes32 root, uint64 fromSeq, uint64 toSeq) {
        uint64 from = checkpointedThrough;
        uint64 to = uint64(_results.length);
        if (to == from) revert NothingToCheckpoint();
        bytes32[] memory leaves = new bytes32[](to - from);
        for (uint64 i = from; i < to; ++i) {
            leaves[i - from] = Messages.leaf(_results[i]);
        }
        root = merkleRoot(leaves);
        checkpointedThrough = to;
        Messages.Checkpoint memory c = Messages.Checkpoint({root: root, fromSeq: from, toSeq: to - 1});
        arbSys.sendTxToL1(bridger, abi.encodeCall(IBridgerCheckpoint.acceptCheckpoint, (c)));
        emit Checkpointed(from, to - 1, root);
        return (root, from, to - 1);
    }

    /// @notice A holder burned on Arc and asked for the stock itself (or its proceeds) here. Only the
    ///         Ethereum bridger, through a retryable ticket, can say so. Never reverts on transfer
    ///         failures: what cannot be pushed becomes claimable. Solon: `shares == 0` for an already
    ///         settled ref hands over that ref's USDG liabilities (stuck refund or proceeds) instead; for an
    ///         unsettled ref it closes the ref as Failed first (a canonical void of an unexecuted buy).
    function deliver(Messages.Deliver calldata d) external nonReentrant {
        if (msg.sender != AddressAlias.applyL1ToL2Alias(bridger)) revert NotBridgerAlias(msg.sender);
        if (settled[d.ref]) {
            uint256 owed = d.shares == 0 ? _takeLiabilities(d.ref) : 0;
            if (owed == 0) {
                emit OrderIgnored(d.ref, "already settled");
                return;
            }
            _push(address(settlement), d.to, owed);
            emit Delivered(d.ref, address(settlement), d.to, Messages.DeliverMode.Settlement, owed);
            return;
        }
        settled[d.ref] = true;
        delete _waiting[d.ref];
        if (d.shares == 0) {
            // Solon: a canonical void of a buy the vault never answered (hub `escalateFunds`). Record it as
            // Failed for the checkpoint so the hub can prove it, and hand over whatever this ref was paid.
            _results.push(
                Messages.Result({
                    ref: d.ref,
                    underlying: d.underlying,
                    outcome: Messages.Outcome.Failed,
                    amountIn: 0,
                    amountOut: 0,
                    seq: uint64(_results.length)
                })
            );
            uint256 paid = _takeLiabilities(d.ref);
            _push(address(settlement), d.to, paid);
            emit Delivered(d.ref, address(settlement), d.to, Messages.DeliverMode.Settlement, paid);
            return;
        }
        Listing storage l = _listings[d.underlying];
        if (l.underlying == address(0)) revert NotListed(d.underlying);
        uint256 entitled = entitledOf[d.underlying];
        if (d.shares > entitled) revert ExceedsEntitlement(d.shares, entitled);
        entitledOf[d.underlying] = entitled - d.shares;
        // Canonical-only record so the hub closes the order on proof; Arc owes nothing for it.
        Messages.Result memory r = Messages.Result({
            ref: d.ref,
            underlying: d.underlying,
            outcome: Messages.Outcome.Sold,
            amountIn: d.shares,
            amountOut: 0,
            seq: uint64(_results.length)
        });
        _results.push(r);

        if (d.mode == Messages.DeliverMode.Settlement) {
            try this.venueSell(d.underlying, d.shares, 0) returns (uint256 out) {
                _push(address(settlement), d.to, out);
                emit Delivered(d.ref, d.underlying, d.to, d.mode, out);
                return;
            } catch {}
        }
        _push(d.underlying, d.to, d.shares);
        emit Delivered(d.ref, d.underlying, d.to, Messages.DeliverMode.Stock, d.shares);
    }

    function claim(address token) external nonReentrant {
        uint256 amount = claimable[token][msg.sender];
        if (amount == 0) revert ZeroAmount();
        claimable[token][msg.sender] = 0;
        claimableTotal[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(token, msg.sender, amount);
    }

    // ------------------------------------------------------------------ views

    function reserveOf(address underlying) public view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function backingOf(address underlying) external view returns (uint256 reserve, uint256 entitled) {
        return (reserveOf(underlying), entitledOf[underlying]);
    }

    /// @notice R ≥ E + C: the reserve covers what Arc may circulate (E, which includes bought-not-yet-minted
    ///         and burned-not-yet-delivered) plus raw deliveries that failed and wait here (C).
    function isFullyBacked(address underlying) external view returns (bool) {
        return reserveOf(underlying) >= entitledOf[underlying] + claimableTotal[underlying];
    }

    /// @notice USDG owed back to Arc or to holders: unspent funding + proceeds + claimable settlement.
    function settlementLiabilities() public view returns (uint256) {
        return fundingTotal + proceedsTotal + claimableTotal[address(settlement)];
    }

    /// @notice Settlement not owed to anyone: the optional float.
    function freeSettlement() public view returns (uint256) {
        uint256 bal = settlement.balanceOf(address(this));
        uint256 owed = settlementLiabilities();
        return bal > owed ? bal - owed : 0;
    }

    /// @notice Proof-of-reserve snapshot for one asset. `multiplier` is the issuer's display multiplier
    ///         (18 dp shares per raw token) when the token exposes `uiMultiplier()`, else 0; raw units never
    ///         change with it (design §8.4).
    function porSnapshot(address underlying)
        external
        view
        returns (
            uint256 reserveRaw,
            uint256 entitledRaw,
            uint256 claimableRaw,
            uint256 settlementBalance,
            uint256 settlementOwed,
            uint256 resultCount_,
            uint64 checkpointedThrough_,
            uint256 multiplier
        )
    {
        reserveRaw = reserveOf(underlying);
        entitledRaw = entitledOf[underlying];
        claimableRaw = claimableTotal[underlying];
        settlementBalance = settlement.balanceOf(address(this));
        settlementOwed = settlementLiabilities();
        resultCount_ = _results.length;
        checkpointedThrough_ = checkpointedThrough;
        try IStockMultiplier(underlying).uiMultiplier() returns (uint256 m) {
            multiplier = m;
        } catch {}
    }

    function waitingOrder(bytes32 ref) external view returns (Messages.Order memory) {
        return _waiting[ref];
    }

    function resultCount() external view returns (uint256) {
        return _results.length;
    }

    function resultAt(uint256 seq) external view returns (Messages.Result memory) {
        return _results[seq];
    }

    function getListing(address underlying) external view returns (Listing memory) {
        return _listings[underlying];
    }

    function underlyings() external view returns (address[] memory) {
        return _underlyings;
    }

    /// @notice Root of a tree over `leaves`, pairs hashed in sorted order, odd nodes carried up.
    ///         Matches OpenZeppelin's `MerkleProof.verify`; the keeper builds proofs the same way.
    function merkleRoot(bytes32[] memory leaves) public pure returns (bytes32) {
        uint256 n = leaves.length;
        if (n == 0) return bytes32(0);
        while (n > 1) {
            uint256 m = (n + 1) / 2;
            for (uint256 i; i < m; ++i) {
                uint256 a = 2 * i;
                uint256 b = a + 1;
                leaves[i] = b < n ? _hashPair(leaves[a], leaves[b]) : leaves[a];
            }
            n = m;
        }
        return leaves[0];
    }

    // ------------------------------------------------------------------ admin

    function listStock(address underlying, string calldata ticker) external onlyOwner {
        if (underlying == address(0)) revert ZeroAddress();
        if (_listings[underlying].underlying != address(0)) revert AlreadyListed(underlying);
        if (!venue.isSupported(underlying)) revert VenueUnsupported(underlying);
        _listings[underlying] = Listing({underlying: underlying, ticker: ticker, enabled: true});
        _underlyings.push(underlying);
        emit StockListed(underlying, ticker);
    }

    function setEnabled(address underlying, bool enabled) external onlyOwner {
        if (_listings[underlying].underlying == address(0)) revert NotListed(underlying);
        _listings[underlying].enabled = enabled;
        emit StockEnabled(underlying, enabled);
    }

    /// @notice Venue, bridger and return route: first value immediately, every change after 48h.
    function proposeVenue(address venue_) external onlyOwner {
        if (venue_ == address(0)) revert ZeroAddress();
        if (IExecutionVenue(venue_).settlementToken() != address(settlement)) revert SettlementMismatch();
        pendingVenue = _propose("venue", venue_);
    }

    function executeVenue() external onlyOwner {
        venue = IExecutionVenue(_matured(pendingVenue));
        delete pendingVenue;
        emit VenueSet(address(venue));
    }

    function setBridger(address bridger_) external onlyOwner {
        if (bridger_ == address(0)) revert ZeroAddress();
        if (bridger == address(0)) {
            bridger = bridger_;
            emit BridgerSet(bridger_);
        } else {
            pendingBridger = _propose("bridger", bridger_);
        }
    }

    function executeBridger() external onlyOwner {
        bridger = _matured(pendingBridger);
        delete pendingBridger;
        emit BridgerSet(bridger);
    }

    function setReturnRoute(address route) external onlyOwner {
        if (route == address(0)) revert ZeroAddress();
        if (IFundingRoute(route).asset() != address(settlement)) revert SettlementMismatch();
        if (address(returnRoute) == address(0)) {
            returnRoute = IFundingRoute(route);
            emit ReturnRouteSet(route);
        } else {
            pendingReturnRoute = _propose("returnRoute", route);
        }
    }

    function executeReturnRoute() external onlyOwner {
        returnRoute = IFundingRoute(_matured(pendingReturnRoute));
        delete pendingReturnRoute;
        emit ReturnRouteSet(address(returnRoute));
    }

    /// @notice The first peer per eid is set at deployment; any change waits 48h.
    function setPeer(uint32 eid, bytes32 peer) public override onlyOwner {
        if (peers[eid] != bytes32(0)) revert Timelocked();
        _setPeer(eid, peer);
    }

    function proposePeer(uint32 eid, bytes32 peer) external onlyOwner {
        pendingPeer[eid] = peer;
        pendingPeerEta[eid] = uint64(block.timestamp) + CONFIG_DELAY;
        emit ConfigProposed("peer", address(uint160(uint256(peer))), pendingPeerEta[eid]);
    }

    function executePeer(uint32 eid) external onlyOwner {
        uint64 eta = pendingPeerEta[eid];
        if (eta == 0 || block.timestamp < eta) revert Timelocked();
        _setPeer(eid, pendingPeer[eid]);
        delete pendingPeer[eid];
        delete pendingPeerEta[eid];
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setResultOptions(bytes calldata options) external onlyOwner {
        resultOptions = options;
        emit ResultOptionsSet(options);
    }

    function setFloatEnabled(bool enabled) external onlyOwner {
        floatEnabled = enabled;
        emit FloatEnabled(enabled);
    }

    /// @notice The free settlement float and the gas balance are operating capital; stock never moves here,
    ///         liabilities never, and only to the two fixed destinations.
    function withdrawFloat(address token, address to, uint256 amount) external onlyKeeperOrOwner nonReentrant {
        if (to != floatRecipientA && to != floatRecipientB) revert NotFloatRecipient();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert ZeroAmount();
        } else {
            if (_listings[token].underlying != address(0)) revert NotListed(token); // never a listed stock
            if (token == address(settlement)) {
                uint256 free = freeSettlement();
                if (amount > free) revert InsufficientFloat(free, amount);
            }
            IERC20(token).safeTransfer(to, amount);
        }
        emit FloatWithdrawn(token, to, amount);
    }

    // ------------------------------------------------------------------ migration (kept from the original)

    /// @notice Buy `settlementIn` worth of `underlying` into the reserve and record a migration result,
    ///         reaching the hub only canonically. Owner only (the timelock), while `migrationOpen`, and only
    ///         from free settlement (never a liability).
    function migrateIn(address underlying, uint256 settlementIn, uint256 minShares)
        external
        onlyOwner
        nonReentrant
        returns (bytes32 ref, uint256 shares)
    {
        if (!migrationOpen) revert MigrationIsClosed();
        if (_listings[underlying].underlying == address(0)) revert NotListed(underlying);
        if (settlementIn == 0) revert ZeroAmount();
        uint256 free = freeSettlement();
        if (settlementIn > free) revert InsufficientFloat(free, settlementIn);
        shares = this.venueBuy(underlying, settlementIn, minShares);
        entitledOf[underlying] += shares;
        uint64 nonce = migrationNonce[underlying]++;
        ref = Messages.migrationRef(underlying, nonce);
        Messages.Result memory r = Messages.Result({
            ref: ref,
            underlying: underlying,
            outcome: Messages.Outcome.Bought,
            amountIn: uint128(settlementIn),
            amountOut: uint128(shares),
            seq: uint64(_results.length)
        });
        _results.push(r);
        emit MigratedIn(ref, underlying, settlementIn, shares, r.seq);
    }

    /// @notice Ends the migration for good.
    function closeMigration() external onlyOwner {
        migrationOpen = false;
        emit MigrationClosed();
    }

    /// @notice Moves stock above the entitlement and raw claimables (donations, dust) to the fixed
    ///         treasury. Never the backing.
    function skimExcess(address underlying) external onlyOwner {
        if (_listings[underlying].underlying == address(0)) revert NotListed(underlying);
        uint256 owed = entitledOf[underlying] + claimableTotal[underlying];
        uint256 reserve = reserveOf(underlying);
        if (reserve <= owed) revert NothingToSkim();
        uint256 excess = reserve - owed;
        IERC20(underlying).safeTransfer(treasury, excess);
        emit ExcessSkimmed(underlying, excess);
    }

    // ------------------------------------------------------------------ internals

    function _takeLiabilities(bytes32 ref) private returns (uint256 amount) {
        uint256 f = funding[ref];
        uint256 p = proceeds[ref];
        amount = f + p;
        if (f > 0) {
            funding[ref] = 0;
            fundingTotal -= f;
        }
        if (p > 0) {
            proceeds[ref] = 0;
            proceedsTotal -= p;
        }
    }

    function _propose(bytes32 what, address value) private returns (Pending memory p) {
        p = Pending(value, uint64(block.timestamp) + CONFIG_DELAY);
        emit ConfigProposed(what, value, p.eta);
    }

    function _matured(Pending memory p) private view returns (address) {
        if (p.value == address(0) || block.timestamp < p.eta) revert Timelocked();
        return p.value;
    }

    function _push(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok && (ret.length == 0 || abi.decode(ret, (bool)))) return;
        claimable[token][to] += amount;
        claimableTotal[token] += amount;
        emit Claimable(token, to, amount);
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Results are sent from inside `_lzReceive`/`executeFunded`, so the fee comes from the vault's
    ///      own balance.
    function _payNative(uint256 nativeFee) internal view override returns (uint256) {
        if (address(this).balance < nativeFee) revert NotEnoughNative(address(this).balance);
        return nativeFee;
    }

    function _guardOwner() internal view override returns (address) {
        return owner();
    }

    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}

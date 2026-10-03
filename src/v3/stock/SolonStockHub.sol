// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    DoubleEndedQueue
} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/structs/DoubleEndedQueue.sol";
import {OApp, Origin, MessagingFee} from "./lz/OApp.sol";
import {SolonStockToken} from "./SolonStockToken.sol";
import {CanonicalGate} from "./CanonicalGate.sol";
import {HubSettlement} from "./HubSettlement.sol";
import {HubExits} from "./HubExits.sol";
import {CapacityController} from "./CapacityController.sol";
import {OrderScheduler} from "./OrderScheduler.sol";
import {Messages} from "./libs/Messages.sol";
import {Guarded} from "./libs/Guarded.sol";

/// @title SolonStockHub — the Arc side of the Solon stock layer
/// @notice Forked from ArcStocks v2 `ArcStocksHubV2` (MIT, verified Arc 0x55ef993b…7eaeb). Users live
///         here: USDC in, STOCK.sol out and back. An order is a LayerZero message to the reserve vault;
///         the vault's answer is the only thing that mints, pays or refunds. A holder who does not want
///         to wait for anyone burns and asks for the stock on the reserve chain through the canonical
///         lane (the gate → CCTP → Ethereum). Supply moves only inside `_lzReceive` (rate-limited) and
///         `reconcile` (a Merkle proof the gate verified against a canonical checkpoint). Every LayerZero
///         mint must be confirmed canonically within `RECONCILE_WINDOW`, or minting stops.
///
///         Solon changes (design r5 §8.3; each is recorded in docs/PLAN-v3-contracts.md phase 5):
///         - Zero operating float, sequential funding (A09/A14): buys queue in `OrderScheduler`
///           (public:reward = 3:1, A10), reserve `CapacityController` limits, then send their own
///           principal through a fixed funding route before the unchanged Order message goes out.
///         - A01: a dispatched buy's cancel waits for the money to actually come back unless the optional
///           acceleration float (default off) is enabled.
///         - Fees: 25 bps, locked per order, may only be lowered in place (raising = new version).
///         - Reward lane (`ISolonFundingHub`) for `SolonStockAdapter`/`RewardRoundManager`.
///         - A06 narrowed owner powers: void only disputed orders (money stays in the hub), float
///           withdrawals only to two fixed destinations, route/peer changes behind a 48h in-contract delay,
///           no arbitrary calls.
contract SolonStockHub is OApp, Ownable2Step, Guarded, ReentrancyGuard {
    using HubSettlement for HubSettlement.State;
    using HubExits for HubSettlement.State;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 100;
    uint64 public constant CANCEL_AFTER = 30 minutes;
    uint64 public constant ESCALATE_AFTER = 6 hours;
    uint64 public constant CONFIG_DELAY = 48 hours;

    HubSettlement.State private s;
    /// @notice The canonical gate. Set once, right after deployment; never changes afterwards.
    CanonicalGate public gate;
    OrderScheduler public scheduler;
    address public keeper;
    /// @notice LayerZero executor options for order sends (gas on the vault side).
    bytes public orderOptions;
    /// @notice The only two addresses the optional float may be withdrawn to (A06).
    address public immutable floatRecipientA;
    address public immutable floatRecipientB;
    mapping(address adapter => bool) public rewardAdapter;
    mapping(address token => address underlying) public underlyingOfToken;

    struct Pending {
        bytes32 value;
        uint64 eta;
    }

    mapping(address underlying => Pending) public pendingRoute;
    mapping(uint32 eid => Pending) public pendingPeer;

    // Emitted from inside HubSettlement (a delegatecall), declared here so they are part of the hub's ABI.
    event BuyFilled(
        uint256 indexed id, address indexed user, address indexed underlying, uint256 sharesOut, bool canonical
    );
    event SellFilled(
        uint256 indexed id,
        address indexed user,
        address indexed underlying,
        uint256 usdcOut,
        uint256 fee,
        bool canonical
    );
    event OrderCancelled(uint256 indexed id, HubSettlement.Reason reason);
    event Orphaned(uint256 indexed id, uint256 sharesToTreasury);
    event ResultIgnored(uint256 indexed id, HubSettlement.Reason why);
    event MintsHalted(uint8 why); // 0 = stale, 1 = mismatch, 2 = guardian
    event Claimable(address indexed to, uint256 amount);
    event Launched(uint256 indexed id, address indexed route, uint256 principal, uint256 routeFee, bytes32 transferId);
    event CancelRequested(uint256 indexed id);
    event AwaitingReturn(uint256 indexed id, HubSettlement.Status status, uint256 expected);
    event ReturnReceived(uint256 indexed id, uint256 amount, bool late);
    event OrderOwed(uint256 indexed id, address indexed to, uint256 amount);
    event RewardRefundReady(uint256 indexed id, uint256 amount, uint256 opsLeftover);

    event StockListed(address indexed underlying, address indexed token, string ticker, uint32 vaultEid);
    event StockEnabled(address indexed underlying, bool enabled);
    event BuyRequested(
        uint256 indexed id,
        address indexed user,
        address indexed underlying,
        uint256 usdcIn,
        uint256 fee,
        uint256 minSharesOut
    );
    event SellRequested(
        uint256 indexed id, address indexed user, address indexed underlying, uint256 sharesIn, uint256 minUsdcOut
    );
    event Dispatched(uint256 indexed id, bytes32 guid);
    event OrderEscalated(uint256 indexed id, address indexed to, Messages.DeliverMode mode);
    event Reconciled(uint256 indexed id, bool matched);
    event Disputed(uint256 indexed id);
    event MintsResumed();
    event Claimed(uint256 indexed id, address indexed to, uint256 amount);
    event FeesClaimed(address indexed to, uint256 amount);
    event FeesSet(uint16 buyFeeBps, uint16 sellFeeBps);
    event TreasurySet(address treasury);
    event KeeperSet(address keeper);
    event GateSet(address gate);
    event CapacitySet(address capacity, address scheduler);
    event OrderOptionsSet(bytes options);
    event MintLimitSet(uint16 bps);
    event PayLimitSet(uint256 floor, uint16 bps);
    event ClaimableVoided(uint256 indexed id, uint256 amount, bytes32 evidence);
    event MintFloorSet(address indexed underlying, uint128 floor);
    event FloatFunded(address indexed from, uint256 amount);
    event FloatWithdrawn(address indexed to, uint256 amount);
    event FloatEnabled(bool enabled);
    event RewardAdapterSet(address indexed adapter, bool allowed);
    event RouteProposed(address indexed underlying, address route, uint64 eta);
    event RouteSet(address indexed underlying, address route);
    event PeerProposed(uint32 indexed eid, bytes32 peer, uint64 eta);
    event TradingPausedSet(address indexed underlying, bool paused);
    event MultiplierVersionSet(address indexed underlying, uint64 version);

    error ZeroAddress();
    error ZeroAmount();
    error NotListed(address underlying);
    error AlreadyListed(address underlying);
    error StockDisabled(address underlying);
    error FeeTooHigh();
    error NoSuchOrder(uint256 id);
    error WrongStatus(uint256 id, HubSettlement.Status status);
    error WrongKind(uint256 id);
    error NotYours(uint256 id);
    error TooEarly(uint256 id, uint64 at);
    error InsufficientValue(uint256 got, uint256 need);
    error NotKeeper();
    error InsufficientFloat(uint256 available, uint256 need);
    error WrongSource(uint32 eid, bytes32 sender);
    error AlreadyReconciled(bytes32 ref);
    error GateAlreadySet();
    error TransferFailed();
    error NotRoute();
    error NotScheduler();
    error NotRewardAdapter();
    error BadRewardOrder();
    error NotFloatRecipient();
    error Timelocked();
    error NotGuardianOrOwner();
    error RunLimit();
    error BelowMinOrder();

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor(
        address endpoint,
        address treasury_,
        uint16 feeBps_,
        address owner_,
        address opsVault_,
        address[2] memory floatRecipients
    ) OApp(endpoint, owner_) Ownable(owner_) {
        if (treasury_ == address(0) || opsVault_ == address(0)) revert ZeroAddress();
        if (floatRecipients[0] == address(0) || floatRecipients[1] == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        s.treasury = treasury_;
        s.opsVault = opsVault_;
        s.payFloor = 10_000 ether; // 10,000 USDC a day at least
        s.payLimitBps = 2_000; // or 20% of the float
        s.buyFeeBps = feeBps_;
        s.sellFeeBps = feeBps_;
        s.mintLimitBps = 500;
        floatRecipientA = floatRecipients[0];
        floatRecipientB = floatRecipients[1];
        orderOptions = hex"0003010011010000000000000000000000000016e360"; // lzReceive gas 1.5M: the vault swaps and sends the result inside it
    }

    receive() external payable {}

    // ------------------------------------------------------------------ users

    /// @notice Deposit `usdcIn` (18 dp native) to buy `underlying`. Whatever `msg.value` exceeds `usdcIn`
    ///         is this order's reserve for the funding route and LayerZero fees; the unused part comes back.
    ///         The order waits in the public FIFO until the scheduler funds it on the reserve chain.
    function requestBuy(address underlying, uint256 usdcIn, uint256 minSharesOut)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        _live(underlying);
        if (usdcIn == 0) revert ZeroAmount();
        if (msg.value < usdcIn) revert InsufficientValue(msg.value, usdcIn);
        uint256 principal;
        uint256 fee;
        (id, principal, fee) = s.placeBuy(msg.sender, underlying, usdcIn, minSharesOut, msg.value - usdcIn, 0, 0);
        s.capacity.checkRun(principal); // single-order limit and minimum order size (re-review L3)
        emit BuyRequested(id, msg.sender, underlying, principal, fee, minSharesOut);
        scheduler.enqueue(0, id);
    }

    /// @notice Burn `sharesIn` of STOCK.sol now and ask the vault to sell the stock behind it. The
    ///         proceeds come back through the funding route; if the order is not executed, `escalate`
    ///         takes the canonical lane. `msg.value` pays the LayerZero fee (zero = wait for `dispatch`).
    function requestSell(address underlying, uint256 sharesIn, uint256 minUsdcOut)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        HubSettlement.Listing storage l = _listed(underlying);
        if (sharesIn == 0) revert ZeroAmount();
        l.arc.burn(msg.sender, sharesIn);
        id = s.place(
            msg.sender, underlying, HubSettlement.Kind.Sell, HubSettlement.Status.Pending, sharesIn, minUsdcOut, 0
        );
        s.capacity.beginRedeem(s.orders[id].capKey, underlying, sharesIn);
        emit SellRequested(id, msg.sender, underlying, sharesIn, minUsdcOut);
        if (msg.value > 0) _dispatch(id, l, msg.value, msg.sender, false);
    }

    /// @notice Scheduler only: fund queued buy `id` on the reserve chain. `routeData` =
    ///         abi.encode(routeFee, signedRouteQuote); the fee comes out of the order's own reserve.
    function launch(uint256 id, bytes calldata routeData) external nonReentrant whenNotPaused {
        if (msg.sender != address(scheduler)) revert NotScheduler();
        HubSettlement.Order storage o = _order(id);
        if (o.status != HubSettlement.Status.Pending || o.kind != HubSettlement.Kind.Buy) {
            revert WrongStatus(id, o.status);
        }
        (uint256 routeFee, bytes memory quote) = abi.decode(routeData, (uint256, bytes));
        if (!s.launch(id, routeFee, quote)) {
            if (o.status == HubSettlement.Status.Pending) scheduler.enqueue(1, id); // reward: re-queue
            return;
        }
        if (o.lane == 0) {
            HubSettlement.Listing storage l = s.listings[o.underlying];
            uint256 lzFee = _quoteFee(id, l);
            if (o.extra >= lzFee) _dispatchFromReserve(id, l, lzFee);
        }
    }

    /// @notice Send a funded order (or a pending sell) to the vault. Anyone may pay the fee.
    function dispatch(uint256 id) external payable nonReentrant {
        HubSettlement.Order storage o = _order(id);
        bool buy = o.kind == HubSettlement.Kind.Buy;
        bool ok = buy ? o.status == HubSettlement.Status.Funded : o.status == HubSettlement.Status.Pending;
        if (!ok) revert WrongStatus(id, o.status);
        if (buy && paused()) revert EnforcedPause(); // exits (sells) are never paused
        _dispatch(id, s.listings[o.underlying], msg.value, msg.sender, false);
    }

    /// @notice The LayerZero fee a new order on `underlying` needs.
    function quoteOrder(address underlying) external view returns (uint256) {
        Messages.Order memory o =
            Messages.Order({ref: 0, underlying: underlying, side: Messages.Side.Buy, amountIn: 0, minOut: 0});
        return _quote(s.listings[underlying].vaultEid, Messages.encode(o), orderOptions, false).nativeFee;
    }

    function quoteDispatch(uint256 id) external view returns (uint256) {
        HubSettlement.Order storage o = _order(id);
        return _quoteFee(id, s.listings[o.underlying]);
    }

    /// @notice Take a buy back after `CANCEL_AFTER`. A queued buy is refunded at once. A funded or
    ///         dispatched one is judged from the moment its principal left (no free look at the fill):
    ///         the refund follows when the principal actually comes back, or at once from the optional
    ///         acceleration float — in that case a late fill goes to the treasury (original A01).
    function cancel(uint256 id) external nonReentrant {
        _order(id);
        s.cancelBuy(id, msg.sender, CANCEL_AFTER);
    }

    /// @notice A sell the fast lane did not finish in `ESCALATE_AFTER` goes canonical: the vault will
    ///         hand the proceeds to `to` on the reserve chain. The seller picks `to`; anyone else may
    ///         escalate on the seller's behalf only to the seller's own address, and only if that address
    ///         is a plain account (a contract on Arc is not necessarily anyone's on Robinhood Chain).
    ///         Every canonical send pays its 1 USDC hook (`msg.value` >= 1e18, forwarded to the gate).
    function escalate(uint256 id, address to) external payable nonReentrant {
        _order(id);
        s.escalate(address(gate), id, to, ESCALATE_AFTER, msg.value);
    }

    /// @notice Solon addition: money for a public order that is stuck on the reserve chain (a failed
    ///         buy's principal, or a sell's proceeds) can be taken there as USDG through the canonical lane
    ///         after `ESCALATE_AFTER`, so exits never depend on the fast money route alone. A cancelled
    ///         (or already refunded) buy the vault never answered is closed on the vault the same way.
    function escalateFunds(uint256 id, address to) external payable nonReentrant {
        _order(id);
        s.escalateFunds(address(gate), id, to, ESCALATE_AFTER, msg.value);
    }

    /// @notice Burn now and receive the stock itself (or its proceeds) at `to` on the reserve chain,
    ///         through Circle and Ethereum only. Works while every bridge and this team are gone. The locked
    ///         sell fee is kept in shares; `msg.value` pays the 1 USDC hook.
    function canonicalRedeem(address underlying, uint256 sharesIn, address to, Messages.DeliverMode mode)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        _listed(underlying);
        return s.canonicalRedeem(address(gate), underlying, sharesIn, to, mode, msg.value);
    }

    /// @notice Close a buy the vault has not answered, over LayerZero: a zero-amount order for the same
    ///         ref settles it on the vault as Failed, so it can never execute; the Failed result then
    ///         releases its reservation and its money comes back (review #3/#8). Allowed once the owner
    ///         asked to cancel or the principal is already back (anyone may send it then), or for a reward
    ///         order by the operator, or for a buy the acceleration float already refunded (the caller
    ///         pays the LayerZero fee then; re-review N1). Works while paused. The LayerZero fee comes from `msg.value`, the rest
    ///         from the order's own reserve.
    function voidOrder(uint256 id) external payable nonReentrant {
        HubSettlement.Listing storage l = s.listings[_order(id).underlying];
        uint256 lzFee = _quoteFee(id, l);
        s.checkVoid(id, msg.sender == keeper || msg.sender == owner(), msg.value, lzFee);
        _dispatch(id, l, msg.value < lzFee ? lzFee : msg.value, msg.sender, true);
    }

    /// @notice Operator: refund a queued reward order exactly (to its adapter) and release its reservation,
    ///         e.g. when its fixed route can no longer launch (review #5).
    function cancelReward(uint256 id) external onlyKeeperOrOwner nonReentrant {
        _order(id);
        s.cancelReward(id);
    }

    /// @notice Take what the hub owes for order `id` (a payout its payee's address refused).
    function claim(uint256 id) external nonReentrant {
        HubSettlement.Order storage o = _order(id);
        address to = o.lane == 1 ? s.opsVault : o.user;
        uint256 paid = s.claimPay(id, to);
        emit Claimed(id, to, paid);
    }

    /// @notice The order's fixed funding route credits money that came back for it.
    function receiveReturn(bytes32 ref) external payable nonReentrant {
        uint256 id = uint256(ref);
        if (id >= s.orders.length || msg.sender != s.orders[id].route) revert NotRoute();
        s.receiveReturn(id, msg.value);
    }

    // ------------------------------------------------------------------ reward lane (ISolonFundingHub)

    /// @notice A registered `SolonStockAdapter` places a reward buy whose capacity the RewardRoundManager
    ///         already reserved under `orderId`. `msg.value` = budget + Ops fees; the 25 bps service fee
    ///         is taken from the fees so the budget buys stock in full.
    function beginFunding(
        bytes32 orderId,
        address underlying,
        uint256 budget18,
        uint256 minRawOut,
        address receiver,
        bytes32 path
    ) external payable nonReentrant whenNotPaused {
        if (!rewardAdapter[msg.sender] || receiver != msg.sender) revert NotRewardAdapter();
        _live(underlying);
        uint256 id = s.beginReward(orderId, underlying, budget18, minRawOut, receiver, path, msg.value);
        scheduler.enqueue(1, id);
    }

    function fundingReceived(bytes32 orderId) external view returns (uint256) {
        HubSettlement.Order storage o = _reward(orderId);
        return o.status == HubSettlement.Status.Pending || o.status == HubSettlement.Status.Cancelled ? 0 : o.amountIn;
    }

    function submitFundedBuy(bytes32 orderId) external nonReentrant whenNotPaused {
        HubSettlement.Order storage o = _reward(orderId);
        if (msg.sender != o.user) revert NotYours(0);
        if (o.status != HubSettlement.Status.Funded) revert WrongStatus(0, o.status);
        uint256 id = s.rewardOrder[orderId] - 1;
        HubSettlement.Listing storage l = s.listings[o.underlying];
        _dispatchFromReserve(id, l, _quoteFee(id, l));
    }

    function requestCancel(bytes32 orderId) external nonReentrant {
        HubSettlement.Order storage o = _reward(orderId);
        if (msg.sender != o.user) revert NotYours(0);
        if (
            (o.status != HubSettlement.Status.Dispatched && o.status != HubSettlement.Status.Funded)
                || o.cancelRequested
        ) {
            revert WrongStatus(0, o.status);
        }
        s.requestCancel(s.rewardOrder[orderId] - 1);
    }

    /// @notice Hand the adapter what its order produced: 1 = shares (raw), 2 = exact budget refund,
    ///         0 = nothing yet. Transfers happen inside this call so the adapter can check exact deltas.
    function claimResult(bytes32 orderId, bytes calldata)
        external
        nonReentrant
        returns (uint8 status, uint256 raw, uint256 refund18)
    {
        return s.takeReward(orderId, msg.sender);
    }

    /// @notice Add to a reward order's Ops fee reserve (e.g. to complete an exact refund). Anyone.
    function subsidize(uint256 id) external payable nonReentrant {
        _order(id);
        s.subsidize(id, msg.value);
    }

    // ------------------------------------------------------------------ scheduler view

    function scheduleInfo(uint256 id) external view returns (bool pending, uint8 lane, uint256 usd, bytes32 key) {
        HubSettlement.Order storage o = s.orders[id];
        pending = o.status == HubSettlement.Status.Pending && o.kind == HubSettlement.Kind.Buy;
        return (pending, o.lane, o.amountIn, o.capKey);
    }

    // ------------------------------------------------------------------ LayerZero lane

    function _lzReceive(Origin calldata origin, bytes32, bytes calldata message, address, bytes calldata)
        internal
        override
        nonReentrant
    {
        Messages.Result memory r = Messages.decodeResult(message);
        if (Messages.isMigrationRef(r.ref)) revert NoSuchOrder(uint256(r.ref)); // migration mints only canonically
        uint256 id = uint256(r.ref);
        if (id >= s.orders.length) revert NoSuchOrder(id);
        if (origin.srcEid != s.listings[s.orders[id].underlying].vaultEid) {
            revert WrongSource(origin.srcEid, origin.sender);
        }
        s.settle(id, r, false);
    }

    // ------------------------------------------------------------------ canonical lane

    /// @notice Prove one vault result against a checkpoint the gate received canonically. A result the
    ///         fast lane already applied is checked against it (a mismatch halts minting and marks the order
    ///         disputed); one it never delivered is applied here, with no rate limit.
    function reconcile(Messages.Result calldata r, uint256 checkpointIndex, bytes32[] calldata proof)
        external
        nonReentrant
    {
        gate.verify(r, checkpointIndex, proof);
        if (s.reconciled[r.ref]) revert AlreadyReconciled(r.ref);
        if (Messages.isMigrationRef(r.ref)) {
            s.reconciled[r.ref] = true;
            s.migrationMint(r);
            return;
        }
        uint256 id = uint256(r.ref);
        if (id >= s.orders.length) revert NoSuchOrder(id);
        HubSettlement.Order storage o = s.orders[id];
        if (o.lzSettled) {
            s.reconciled[r.ref] = true;
            bool matched = s.matches(id, r);
            emit Reconciled(id, matched);
            if (matched) {
                s.capacity.markReviewed(o.capKey);
            } else {
                o.disputed = true;
                emit Disputed(id);
                s.halt(1);
            }
            return;
        }
        // The proof is spent only if the result changed something; an ignored one may be presented again.
        bool applied = s.settle(id, r, true);
        emit Reconciled(id, applied);
    }

    /// @notice Stops minting if the oldest LayerZero settlement is still unconfirmed after the window.
    function checkStale() external {
        s.checkStale();
    }

    // ------------------------------------------------------------------ views

    function supplyOf(address underlying) public view returns (uint256) {
        return s.listings[underlying].arc.totalSupply();
    }

    function available() public view returns (uint256) {
        return s.available();
    }

    function mintAllowance(address underlying) external view returns (uint256) {
        return s.mintAllowance(underlying);
    }

    function getListing(address underlying) external view returns (HubSettlement.Listing memory) {
        return s.listings[underlying];
    }

    function underlyings() external view returns (address[] memory) {
        return s.underlyings;
    }

    function orderCount() external view returns (uint256) {
        return s.orders.length;
    }

    function getOrder(uint256 id) external view returns (HubSettlement.Order memory) {
        return s.orders[id];
    }

    function ordersOf(address user) external view returns (uint256[] memory) {
        return s.userOrders[user];
    }

    function openOrders() external view returns (uint256[] memory) {
        return s.open;
    }

    function unreconciledCount() external view returns (uint256) {
        return s.unreconciled.length();
    }

    function escrowed() external view returns (uint256) {
        return s.escrowed;
    }

    function accruedFees() external view returns (uint256) {
        return s.accruedFees;
    }

    function claimableTotal() external view returns (uint256) {
        return s.claimableTotal;
    }

    function reconciled(bytes32 ref) external view returns (bool) {
        return s.reconciled[ref];
    }

    function mintsHalted() external view returns (bool) {
        return s.mintsHalted;
    }

    function treasury() external view returns (address) {
        return s.treasury;
    }

    function capacity() external view returns (CapacityController) {
        return s.capacity;
    }

    function floatEnabled() external view returns (bool) {
        return s.floatEnabled;
    }

    function fees() external view returns (uint16 buyFeeBps, uint16 sellFeeBps, uint16 mintLimitBps) {
        return (s.buyFeeBps, s.sellFeeBps, s.mintLimitBps);
    }

    function payAllowance() external view returns (uint256) {
        return s.payAllowance();
    }

    /// @notice IV3LaunchStockStatus for the launch factory: keyed by the Arc token address.
    function stockState(address token)
        external
        view
        returns (bool marketOpen, bool transferable, uint256 multiplierVersion)
    {
        HubSettlement.Listing storage l = s.listings[underlyingOfToken[token]];
        if (address(l.arc) == address(0)) return (false, false, 0);
        // Pausing new subscriptions never stops trading of issued stock (design §10 "仅停铸仍可交易").
        transferable = !l.tradingPaused;
        marketOpen = transferable && l.enabled;
        multiplierVersion = l.multiplierVersion;
    }

    // ------------------------------------------------------------------ admin

    /// @notice Wires the canonical gate. Once. The gate's own `hub` is immutable, so the pair is fixed.
    function setCanonicalGate(address gate_) external onlyOwner {
        if (address(gate) != address(0)) revert GateAlreadySet();
        if (gate_ == address(0)) revert ZeroAddress();
        gate = CanonicalGate(payable(gate_));
        emit GateSet(gate_);
    }

    /// @notice Wires the capacity controller and scheduler. Once.
    function setCapacity(CapacityController capacity_, OrderScheduler scheduler_) external onlyOwner {
        if (address(s.capacity) != address(0)) revert GateAlreadySet();
        if (address(capacity_) == address(0) || address(scheduler_.hub()) != address(this)) revert ZeroAddress();
        s.capacity = capacity_;
        scheduler = scheduler_;
        emit CapacitySet(address(capacity_), address(scheduler_));
    }

    function listStock(
        address underlying,
        string calldata ticker,
        uint32 vaultEid,
        uint256 reserveChainId,
        uint128 mintFloor,
        address route,
        bytes32 routePath
    ) external onlyOwner returns (SolonStockToken arc) {
        if (underlying == address(0) || route == address(0) || routePath == 0) revert ZeroAddress();
        if (address(s.listings[underlying].arc) != address(0)) revert AlreadyListed(underlying);
        arc = s.list(underlying, ticker, vaultEid, reserveChainId, mintFloor, route, routePath);
        s.listings[underlying].multiplierVersion = 1;
        underlyingOfToken[address(arc)] = underlying;
        emit StockListed(underlying, address(arc), ticker, vaultEid);
    }

    function setEnabled(address underlying, bool enabled) external onlyOwner {
        _listed(underlying).enabled = enabled;
        emit StockEnabled(underlying, enabled);
    }

    /// @notice Guardian may pause stock-quote trading of an asset (design §3.4 TradingPaused); only the
    ///         owner (timelock) resumes it.
    function setTradingPaused(address underlying, bool paused_) external {
        if (paused_ ? msg.sender != guardian && msg.sender != owner() : msg.sender != owner()) {
            revert NotGuardianOrOwner();
        }
        _listed(underlying).tradingPaused = paused_;
        emit TradingPausedSet(underlying, paused_);
    }

    /// @notice Record a corporate-action multiplier version (display/audit only; raw units never change).
    function setMultiplierVersion(address underlying, uint64 version) external onlyOwner {
        _listed(underlying).multiplierVersion = version;
        emit MultiplierVersionSet(underlying, version);
    }

    function setMintFloor(address underlying, uint128 floor) external onlyOwner {
        _listed(underlying).mintFloor = floor;
        emit MintFloorSet(underlying, floor);
    }

    function setMintLimitBps(uint16 bps) external onlyOwner {
        s.mintLimitBps = bps;
        emit MintLimitSet(bps);
    }

    /// @notice Daily cap on payouts advanced from the optional float: max(`floor`, `bps` of the float).
    function setPayLimit(uint256 floor, uint16 bps) external onlyOwner {
        s.payFloor = floor;
        s.payLimitBps = bps;
        emit PayLimitSet(floor, bps);
    }

    /// @notice Strike what a disputed settlement of order `id` still owes (A06 narrowed): only an order a
    ///         canonical mismatch marked disputed, bounded by that order's own debt, with evidence. The
    ///         struck amount stays in the hub. Owner (timelock) only.
    function voidClaimable(uint256 id, uint256 amount, bytes32 evidence) external onlyOwner {
        _order(id);
        if (evidence == 0) revert ZeroAmount();
        s.voidClaimable(id, amount);
        emit ClaimableVoided(id, amount, evidence);
    }

    /// @notice Fees can only go down in place; a raise is a new versioned deployment.
    function lowerFees(uint16 buyFeeBps_, uint16 sellFeeBps_) external onlyOwner {
        if (buyFeeBps_ > s.buyFeeBps || sellFeeBps_ > s.sellFeeBps) revert FeeTooHigh();
        s.buyFeeBps = buyFeeBps_;
        s.sellFeeBps = sellFeeBps_;
        emit FeesSet(buyFeeBps_, sellFeeBps_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        s.treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setOrderOptions(bytes calldata options) external onlyOwner {
        orderOptions = options;
        emit OrderOptionsSet(options);
    }

    function setRewardAdapter(address adapter, bool allowed) external onlyOwner {
        rewardAdapter[adapter] = allowed;
        emit RewardAdapterSet(adapter, allowed);
    }

    /// @notice Optional acceleration float (default off). Owner (timelock) only.
    function setFloatEnabled(bool enabled) external onlyOwner {
        s.floatEnabled = enabled;
        emit FloatEnabled(enabled);
    }

    /// @notice New funding route for new orders of `underlying`; effective 48h after the proposal.
    function proposeRoute(address underlying, address route) external onlyOwner {
        _listed(underlying);
        if (route == address(0)) revert ZeroAddress();
        uint64 eta = uint64(block.timestamp) + CONFIG_DELAY;
        pendingRoute[underlying] = Pending(bytes32(uint256(uint160(route))), eta);
        emit RouteProposed(underlying, route, eta);
    }

    function executeRoute(address underlying) external onlyOwner {
        Pending memory p = pendingRoute[underlying];
        if (p.eta == 0 || block.timestamp < p.eta) revert Timelocked();
        delete pendingRoute[underlying];
        address route = address(uint160(uint256(p.value)));
        _listed(underlying).route = route;
        emit RouteSet(underlying, route);
    }

    /// @notice The first peer per eid is set at deployment; any change waits 48h.
    function setPeer(uint32 eid, bytes32 peer) public override onlyOwner {
        if (peers[eid] != bytes32(0)) revert Timelocked();
        _setPeer(eid, peer);
    }

    function proposePeer(uint32 eid, bytes32 peer) external onlyOwner {
        uint64 eta = uint64(block.timestamp) + CONFIG_DELAY;
        pendingPeer[eid] = Pending(peer, eta);
        emit PeerProposed(eid, peer, eta);
    }

    function executePeer(uint32 eid) external onlyOwner {
        Pending memory p = pendingPeer[eid];
        if (p.eta == 0 || block.timestamp < p.eta) revert Timelocked();
        delete pendingPeer[eid];
        _setPeer(eid, p.value);
    }

    /// @notice The guardian (or owner) stops all minting at once, e.g. on a suspected fast-lane fault.
    function haltMints() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        s.halt(2);
    }

    /// @notice Only the owner (timelock) restarts minting after a halt was investigated.
    function resumeMints() external onlyOwner {
        s.mintsHalted = false;
        s.resumedAt = uint64(block.timestamp);
        emit MintsResumed();
    }

    function claimFees() external nonReentrant {
        if (msg.sender != s.treasury && msg.sender != owner()) revert NotKeeper();
        uint256 amount = s.accruedFees;
        s.accruedFees = 0;
        _send(s.treasury, amount);
        emit FeesClaimed(s.treasury, amount);
    }

    function fundFloat() external payable {
        emit FloatFunded(msg.sender, msg.value);
    }

    /// @notice Free float (never escrow, fees or owed money) to one of the two fixed destinations only.
    function withdrawFloat(address to, uint256 amount) external onlyKeeperOrOwner nonReentrant {
        if (to != floatRecipientA && to != floatRecipientB) revert NotFloatRecipient();
        uint256 free = s.available();
        if (amount > free) revert InsufficientFloat(free, amount);
        _send(to, amount);
        emit FloatWithdrawn(to, amount);
    }

    // ------------------------------------------------------------------ internals

    function _quoteFee(uint256 id, HubSettlement.Listing storage l) private view returns (uint256) {
        return _quote(l.vaultEid, Messages.encode(_orderMessage(id, s.orders[id])), orderOptions, false).nativeFee;
    }

    function _dispatchFromReserve(uint256 id, HubSettlement.Listing storage l, uint256 lzFee) private {
        HubSettlement.Order storage o = s.orders[id];
        if (o.extra < lzFee) revert InsufficientValue(o.extra, lzFee);
        o.extra -= lzFee;
        s.escrowed -= lzFee;
        _dispatch(id, l, lzFee, address(this), false);
    }

    function _dispatch(uint256 id, HubSettlement.Listing storage l, uint256 valueForFee, address refundTo, bool void_)
        private
    {
        HubSettlement.Order storage o = s.orders[id];
        Messages.Order memory m = _orderMessage(id, o);
        if (void_) m.amountIn = 0; // closes the ref on the vault as Failed, unexecuted
        bytes memory payload = Messages.encode(m);
        MessagingFee memory fee = _quote(l.vaultEid, payload, orderOptions, false);
        if (valueForFee < fee.nativeFee) revert InsufficientValue(valueForFee, fee.nativeFee);
        // A void of a buy the float already refunded keeps it Cancelled (re-review N1).
        if (o.status != HubSettlement.Status.Cancelled) o.status = HubSettlement.Status.Dispatched;
        if (o.kind == HubSettlement.Kind.Sell) o.dispatchedAt = uint64(block.timestamp);
        bytes32 guid = _lzSend(l.vaultEid, payload, orderOptions, fee, payable(refundTo)).guid;
        if (valueForFee > fee.nativeFee) _send(refundTo, valueForFee - fee.nativeFee);
        emit Dispatched(id, guid);
    }

    function _orderMessage(uint256 id, HubSettlement.Order storage o) private view returns (Messages.Order memory) {
        bool buy = o.kind == HubSettlement.Kind.Buy;
        return Messages.Order({
            ref: bytes32(id),
            underlying: o.underlying,
            side: buy ? Messages.Side.Buy : Messages.Side.Sell,
            amountIn: uint128(buy ? o.amountIn / HubSettlement.SCALE : o.amountIn),
            minOut: uint128(buy ? o.minOut : o.minOut / HubSettlement.SCALE)
        });
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _order(uint256 id) private view returns (HubSettlement.Order storage o) {
        if (id >= s.orders.length) revert NoSuchOrder(id);
        o = s.orders[id];
    }

    function _reward(bytes32 orderId) private view returns (HubSettlement.Order storage) {
        uint256 idx = s.rewardOrder[orderId];
        if (idx == 0) revert BadRewardOrder();
        return s.orders[idx - 1];
    }

    function _listed(address underlying) private view returns (HubSettlement.Listing storage l) {
        l = s.listings[underlying];
        if (address(l.arc) == address(0)) revert NotListed(underlying);
    }

    function _live(address underlying) private view returns (HubSettlement.Listing storage l) {
        l = _listed(underlying);
        if (!l.enabled) revert StockDisabled(underlying);
    }

    /// @dev Sends happen with the fee already inside the hub (from `msg.value` or the order reserve).
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

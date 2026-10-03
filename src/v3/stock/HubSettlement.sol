// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    DoubleEndedQueue
} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/structs/DoubleEndedQueue.sol";
import {SolonStockToken} from "./SolonStockToken.sol";
import {CapacityController} from "./CapacityController.sol";
import {IFundingRoute} from "./interfaces/IFundingRoute.sol";
import {Messages} from "./libs/Messages.sol";

/// @title HubSettlement — the hub's order book and settlement rules, as an external library
/// @notice Forked from ArcStocks v2 `HubSettlement` (MIT, verified Arc 0x9dad0812…a33b). Everything that
///         decides what a vault result does to an order lives here: minting within the LayerZero
///         allowance, paying sells, refunds, orphans, the reconciliation queue and the stale check. The
///         hub delegates to it so the hub itself stays under the code size limit; a delegatecall'd
///         library has no storage or authority of its own.
///
///         Solon changes (design r5 §8.3, each also listed in docs/PLAN-v3-contracts.md phase 5):
///         - A09/A14 zero float, sequential funding: a buy's principal is sent to the reserve vault through
///           the order's fixed funding route before the unchanged Order message is dispatched; refunds and
///           sale proceeds come back through the route and are paid to that order only. The optional
///           acceleration float (default off) restores the original "pay from float now" behaviour.
///         - A01 a dispatched buy's cancel is a request; money moves only when it actually returns. A late
///           Bought for a requested-but-unrefunded order still belongs to the order; only an order the
///           float already refunded orphans to the treasury, as in the original.
///         - Fees are locked on the order (buy and sell), so a later fee change never re-prices it.
///         - A10 capacity: every order carries a CapacityController key; results finalize or release it.
///         - A15/A06 payouts that cannot be pushed wait per order (`owed`), so a disputed settlement can
///           be voided without touching the same user's other orders.
///         - Reward lane (RewardRoundManager via SolonStockAdapter): shares and exact refunds are held by the
///           hub until the adapter consumes the result.
library HubSettlement {
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;
    using SafeERC20 for IERC20;

    enum Kind {
        Buy,
        Sell
    }
    enum Status {
        Pending, // placed; buy principal still in hub escrow (queued for the scheduler)
        Dispatched, // order sent to the vault; waiting for the vault's result
        Filled,
        Cancelled,
        Escalated, // handed to the canonical lane
        Funded, // buy principal sent through the funding route; order message not yet dispatched
        Returning, // buy failed or cancelled after its principal left: waiting for the money to come back
        Proceeds // sell executed on the reserve chain: waiting for the proceeds to come back
    }
    /// @dev Why a result was ignored or an order cancelled (event payloads).
    enum Reason {
        User,
        Vault,
        NotOpen,
        WrongKind,
        Unfundable
    }

    struct Order {
        address user;
        address underlying;
        Kind kind;
        Status status;
        uint64 createdAt;
        uint64 settledAt;
        /// Buy: principal escrowed/sent (18 dp, native, multiple of SCALE). Sell: shares burned (18 dp).
        uint256 amountIn;
        /// Buy: min shares. Sell: min USDC (18 dp; carried as 6 dp to the vault).
        uint256 minOut;
        /// Buy: shares minted. Sell: USDC due/paid to the user, net (18 dp).
        uint256 amountOut;
        /// Service fee (18 dp): buy — escrowed at placement; sell — computed at settlement.
        uint256 fee;
        /// The vault's raw amountOut (shares, or settlement in 6 dp), kept to compare lanes.
        uint128 rawOut;
        bool lzSettled;
        bool orphaned;
        uint64 dispatchedAt;
        // ---- Solon
        uint8 lane; // 0 public, 1 reward
        uint16 feeBps; // locked at placement
        bool cancelRequested;
        bool disputed;
        bool advanced; // paid/refunded from the acceleration float; the return replenishes the float
        uint8 outcome; // 0 none, 1 Bought, 2 Sold, 3 Failed (the result that settled the order)
        address route; // funding route fixed at placement
        uint256 extra; // native held for route/LZ fees (public) or Ops fee reserve (reward)
        uint256 held; // native returned for this order, not yet paid out
        uint256 owed; // native owed to `user`, claimable by order
        uint256 custodyRaw; // reward lane: shares minted to the hub, awaiting the adapter
        uint256 refundReady; // reward lane: exact budget refund awaiting the adapter
        bytes32 capKey;
        bool voided; // a zero-amount order was sent for this ref (the reserve paid its fee once)
    }

    struct Listing {
        SolonStockToken arc;
        uint32 vaultEid;
        string ticker;
        bool enabled;
        /// Floor of the daily LayerZero mint allowance, in shares (18 dp).
        uint128 mintFloor;
        // ---- Solon
        address route; // current funding route for new orders
        bytes32 routePath; // route id the reward adapters bind (e.g. keccak256("RELAY"))
        bool tradingPaused; // guardian: stock-quote TradingPaused signal (§3.4)
        uint64 multiplierVersion;
    }

    struct State {
        Order[] orders;
        mapping(address user => uint256[]) userOrders;
        uint256[] open;
        mapping(uint256 id => uint256) openIndex; // index + 1
        address[] underlyings;
        mapping(address underlying => Listing) listings;
        mapping(address underlying => uint256) mintedInWindow;
        mapping(address underlying => uint64) windowStart;
        /// Native USDC held for open orders (principal before it leaves, fees, route/LZ reserves, returns
        /// awaiting payout). Everything not escrowed, fee or owed is the optional float.
        uint256 escrowed;
        uint256 accruedFees;
        uint256 claimableTotal;
        DoubleEndedQueue.Bytes32Deque unreconciled;
        mapping(bytes32 ref => uint64) lzSettledAt;
        mapping(bytes32 ref => bool) reconciled;
        bool mintsHalted;
        /// When the owner last resumed minting: settlements older than this are acknowledged.
        uint64 resumedAt;
        address treasury;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        /// Share of supply mintable through LayerZero per `MINT_WINDOW`, in bps of supply.
        uint16 mintLimitBps;
        /// Payouts from the float per `MINT_WINDOW` are capped at max(payFloor, payLimitBps × float).
        uint256 payFloor;
        uint16 payLimitBps;
        uint256 paidInWindow;
        uint64 payWindowStart;
        // ---- Solon
        CapacityController capacity;
        address opsVault; // reward-lane fee reserve leftovers go back here
        bool floatEnabled; // optional acceleration layer, default off
        mapping(bytes32 rewardOrderId => uint256) rewardOrder; // id + 1
    }

    uint16 internal constant BPS = 10_000;
    uint64 internal constant RECONCILE_WINDOW = 8 days;
    uint64 internal constant MINT_WINDOW = 1 days;
    /// @dev Native USDC has 18 dp on Arc; the vault settles in 6 dp.
    uint256 internal constant SCALE = 1e12;

    event MigrationMinted(bytes32 indexed ref, address indexed underlying, address indexed to, uint256 shares);
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
    event OrderCancelled(uint256 indexed id, Reason reason);
    event Orphaned(uint256 indexed id, uint256 sharesToTreasury);
    event ResultIgnored(uint256 indexed id, Reason why);
    event MintsHalted(uint8 why); // 0 = stale, 1 = mismatch, 2 = guardian
    event Claimable(address indexed to, uint256 amount);
    event Launched(uint256 indexed id, address indexed route, uint256 principal, uint256 routeFee, bytes32 transferId);
    event CancelRequested(uint256 indexed id);
    event AwaitingReturn(uint256 indexed id, Status status, uint256 expected);
    event ReturnReceived(uint256 indexed id, uint256 amount, bool late);
    event OrderOwed(uint256 indexed id, address indexed to, uint256 amount);
    event RewardRefundReady(uint256 indexed id, uint256 amount, uint256 opsLeftover);
    event BuyRequested(
        uint256 indexed id,
        address indexed user,
        address indexed underlying,
        uint256 usdcIn,
        uint256 fee,
        uint256 minSharesOut
    );

    error BadMigration(bytes32 ref);
    error BadRewardOrder();
    error WrongStatus(uint256 id, Status status);
    error WrongKind(uint256 id);
    error NotYours(uint256 id);
    error TooEarly(uint256 id, uint64 at);
    error InsufficientValue(uint256 got, uint256 need);
    error NotClaimable(uint256 id, uint256 amount);
    error NotListedHere(address underlying);
    error MintLimitExceeded(address underlying, uint256 shares, uint256 allowance);
    error MintsAreHalted();
    error TransferFailed();

    // ------------------------------------------------------------------ listings and orders

    /// @notice Deploys the `.sol` token for `underlying` with the hub as its minter (`address(this)` is
    ///         the hub inside a delegatecall) and records the listing.
    function list(
        State storage s,
        address underlying,
        string calldata ticker,
        uint32 vaultEid,
        uint256 reserveChainId,
        uint128 mintFloor,
        address route,
        bytes32 routePath
    ) external returns (SolonStockToken arc) {
        arc = new SolonStockToken(ticker, underlying, reserveChainId, address(this));
        Listing storage l = s.listings[underlying];
        l.arc = arc;
        l.vaultEid = vaultEid;
        l.ticker = ticker;
        l.enabled = true;
        l.mintFloor = mintFloor;
        l.route = route;
        l.routePath = routePath;
        s.underlyings.push(underlying);
    }

    function place(
        State storage s,
        address user,
        address underlying,
        Kind kind,
        Status status,
        uint256 amountIn,
        uint256 minOut,
        uint256 fee
    ) public returns (uint256 id) {
        id = s.orders.length;
        s.orders.push();
        Order storage o = s.orders[id];
        o.user = user;
        o.underlying = underlying;
        o.kind = kind;
        o.status = status;
        o.createdAt = uint64(block.timestamp);
        o.amountIn = amountIn;
        o.minOut = minOut;
        o.fee = fee;
        o.feeBps = kind == Kind.Buy ? s.buyFeeBps : s.sellFeeBps;
        o.route = s.listings[underlying].route;
        o.capKey = keccak256(abi.encode(address(this), id));
        s.userOrders[user].push(id);
        s.open.push(id);
        s.openIndex[id] = s.open.length;
    }

    /// @notice A buy: fee locked at the listing's current bps, rounded so the principal is a whole 6-dp
    ///         amount on the reserve chain (the sub-micro dust is part of the fee, never sent).
    function placeBuy(
        State storage s,
        address user,
        address underlying,
        uint256 usdcIn,
        uint256 minShares,
        uint256 extra,
        uint8 lane,
        uint256 feeFromExtra
    ) public returns (uint256 id, uint256 principal, uint256 fee) {
        if (lane == 0) {
            fee = (usdcIn * s.buyFeeBps) / BPS;
            principal = usdcIn - fee;
        } else {
            // Reward orders: the whole budget buys stock; the equal-price service fee is paid by Ops.
            principal = usdcIn;
            fee = feeFromExtra;
        }
        uint256 dust = principal % SCALE;
        principal -= dust;
        fee += dust;
        id = place(s, user, underlying, Kind.Buy, Status.Pending, principal, minShares, fee);
        Order storage o = s.orders[id];
        o.lane = lane;
        o.extra = extra;
        s.escrowed += principal + fee + extra;
    }

    /// @notice Reward lane: a buy whose capacity the RewardRoundManager reserved under `orderId`. The
    ///         budget buys stock in full; the 25 bps service fee comes out of the Ops fees sent with it.
    function beginReward(
        State storage s,
        bytes32 orderId,
        address underlying,
        uint256 budget18,
        uint256 minRawOut,
        address receiver,
        bytes32 path,
        uint256 value
    ) external returns (uint256 id) {
        CapacityController.Ticket memory t = s.capacity.ticket(orderId);
        if (
            path != s.listings[underlying].routePath || s.rewardOrder[orderId] != 0
                || t.state != CapacityController.State.Reserved || t.lane != 1 || t.sent || t.usd != budget18
                || budget18 % SCALE != 0 || value < budget18
        ) revert BadRewardOrder();
        uint256 fee = (budget18 * s.buyFeeBps) / BPS;
        if (value - budget18 < fee) revert InsufficientValue(value - budget18, fee);
        uint256 principal;
        (id, principal, fee) = placeBuy(s, receiver, underlying, budget18, minRawOut, value - budget18 - fee, 1, fee);
        s.orders[id].capKey = orderId;
        s.rewardOrder[orderId] = id + 1;
        emit BuyRequested(id, receiver, underlying, principal, fee, minRawOut);
    }

    /// @notice Hand the adapter what its order produced: 1 = shares (raw), 2 = exact budget refund,
    ///         0 = nothing yet. Transfers happen inside the call so the adapter can check exact deltas.
    function takeReward(State storage s, bytes32 orderId, address sender)
        external
        returns (uint8 status, uint256 raw, uint256 refund18)
    {
        uint256 idx = s.rewardOrder[orderId];
        if (idx == 0) revert BadRewardOrder();
        Order storage o = s.orders[idx - 1];
        if (sender != o.user) revert NotYours(idx - 1);
        if (o.custodyRaw != 0) {
            raw = o.custodyRaw;
            o.custodyRaw = 0;
            IERC20(address(s.listings[o.underlying].arc)).safeTransfer(o.user, raw);
            return (1, raw, 0);
        }
        if (o.refundReady != 0) {
            refund18 = o.refundReady;
            o.refundReady = 0;
            s.escrowed -= refund18;
            _transfer(o.user, refund18);
            return (2, 0, refund18);
        }
        return (0, 0, 0);
    }

    /// @notice A public buyer takes a buy back after `cancelAfter`. A queued buy is refunded at once; a
    ///         funded or dispatched one is judged from when its principal left (no free look at the fill).
    function cancelBuy(State storage s, uint256 id, address sender, uint64 cancelAfter) external {
        Order storage o = s.orders[id];
        if (o.user != sender || o.lane != 0) revert NotYours(id);
        if (o.kind != Kind.Buy) revert WrongKind(id);
        Status st = o.status;
        if (st == Status.Pending) {
            uint64 at = o.createdAt + cancelAfter;
            if (block.timestamp < at) revert TooEarly(id, at);
            refundBuy(s, id, Reason.User);
            return;
        }
        if ((st != Status.Funded && st != Status.Dispatched) || o.cancelRequested) revert WrongStatus(id, st);
        uint64 at2 = o.dispatchedAt + cancelAfter;
        if (block.timestamp < at2) revert TooEarly(id, at2);
        requestCancel(s, id);
    }

    function removeOpen(State storage s, uint256 id) public {
        uint256 idx = s.openIndex[id];
        if (idx == 0) return;
        uint256 last = s.open[s.open.length - 1];
        s.open[idx - 1] = last;
        s.openIndex[last] = idx;
        s.open.pop();
        s.openIndex[id] = 0;
    }

    // ------------------------------------------------------------------ sequential funding

    /// @notice Send a queued buy's principal through its fixed route. The route fee comes out of the
    ///         order's own reserve; if it cannot be paid (or the order no longer fits the single-order
    ///         limit) the order is refunded instead of blocking the queue.
    /// @return launched False when the order was refunded (public) or must be re-queued (reward, waiting
    ///         for Ops to top up its fee reserve with `subsidize`).
    function launch(State storage s, uint256 id, uint256 routeFee, bytes memory quote) external returns (bool) {
        Order storage o = s.orders[id];
        IFundingRoute route = IFundingRoute(o.route);
        uint256 minOut = o.amountIn / SCALE;
        route.validate(bytes32(id), o.amountIn, routeFee, minOut, quote);
        // r7: public buys also check the per-asset cap (design §12.5); a buy over its asset cap is refunded here.
        if (routeFee > o.extra || (o.lane == 0 && !s.capacity.canReserveFor(0, o.underlying, o.amountIn))) {
            if (o.lane == 0) refundBuy(s, id, Reason.Unfundable);
            else emit AwaitingReturn(id, Status.Pending, routeFee); // Deferred(OpsShortfall)
            return false;
        }
        if (o.lane == 0) s.capacity.reservePublicFor(o.capKey, o.underlying, o.amountIn);
        s.capacity.markSent(o.capKey);
        o.extra -= routeFee;
        s.escrowed -= o.amountIn + routeFee;
        o.status = Status.Funded;
        o.dispatchedAt = uint64(block.timestamp);
        bytes32 transferId = route.send{value: o.amountIn + routeFee}(bytes32(id), o.amountIn, routeFee, minOut, quote);
        emit Launched(id, address(route), o.amountIn, routeFee, transferId);
        return true;
    }

    /// @notice Give a buyer whose principal never left everything back and close the order, including
    ///         anything a route already credited to it (`held`, re-review L2).
    function refundBuy(State storage s, uint256 id, Reason reason) public {
        Order storage o = s.orders[id];
        o.status = Status.Cancelled;
        o.settledAt = uint64(block.timestamp);
        removeOpen(s, id);
        uint256 amount = o.amountIn + o.fee + o.extra + o.held;
        o.extra = 0;
        o.held = 0;
        s.escrowed -= amount;
        if (o.lane == 1) {
            // Reward principal back to the adapter as an exact refund; the Ops fee reserve to Ops.
            o.refundReady = o.amountIn;
            s.escrowed += o.amountIn;
            _pay(s, id, s.opsVault, amount - o.amountIn, false);
        } else {
            _pay(s, id, o.user, amount, false);
        }
        emit OrderCancelled(id, reason);
    }

    /// @notice A dispatched buy's owner asks for its money back. With the acceleration float the refund is
    ///         immediate (original A01); otherwise it waits for the principal to actually come back.
    function requestCancel(State storage s, uint256 id) public {
        Order storage o = s.orders[id];
        o.cancelRequested = true;
        emit CancelRequested(id);
        if (s.floatEnabled && o.lane == 0 && o.status == Status.Dispatched && o.held == 0 && available(s) >= o.amountIn)
        {
            // The float stands in for the principal still out on the reserve chain. Only for an order the
            // vault has been sent: an undispatched one could otherwise never be filled or returned.
            o.advanced = true;
            o.status = Status.Cancelled;
            o.settledAt = uint64(block.timestamp);
            removeOpen(s, id);
            uint256 amount = o.amountIn + o.fee + o.extra;
            s.escrowed -= o.fee + o.extra;
            o.extra = 0;
            _pay(s, id, o.user, amount, true);
            emit OrderCancelled(id, Reason.User);
        }
    }

    /// @notice Money for order `id` came back through its route. Review #2: a return is never evidence
    ///         of what the vault did — Relay settles in about a second, the vault's LayerZero result takes
    ///         minutes, and anyone can bounce dust through a settled ref. Until the order has the vault's
    ///         result, whatever comes back is only held for the order (`held`); the result decides.
    function receiveReturn(State storage s, uint256 id, uint256 amount) external {
        Order storage o = s.orders[id];
        Status st = o.status;
        bool closed = st == Status.Filled || st == Status.Cancelled;
        emit ReturnReceived(id, amount, closed || o.advanced);
        if (o.advanced) return; // replenishes the float that already paid this order
        if ((o.outcome == 0 && !closed) || st == Status.Returning || st == Status.Proceeds) {
            s.escrowed += amount;
            o.held += amount;
            if (st == Status.Returning) _closeReturnedBuy(s, id, false);
            else if (st == Status.Proceeds) _payHeldProceeds(s, id);
            return;
        }
        // Late money for an answered, closed order stays that order's (see `_lateTo`).
        _pay(s, id, _lateTo(s, o, amount), amount, false);
    }

    /// @dev True when `got` is at least half of `due`: a principal or proceeds return (route costs are
    ///      far below 50%), as opposed to dust or a surplus credit, which never decide an order.
    function isBack(uint256 got, uint256 due) internal pure returns (bool) {
        return got * 2 >= due && got != 0;
    }

    /// @dev Who money for an answered order belongs to. A principal-sized amount after a Bought is the
    ///      reserve's (its optional float bought for a ref whose funding came back here): to the treasury,
    ///      never to a user who already has the stock. Anything else (surplus funding, dust) is the
    ///      order's: its user, or Ops for the reward lane.
    function _lateTo(State storage s, Order storage o, uint256 amount) private view returns (address) {
        if (o.kind == Kind.Buy && o.outcome == 1 && isBack(amount, o.amountIn)) return s.treasury;
        return o.lane == 1 ? s.opsVault : o.user;
    }

    /// @notice Anyone may add native to a reward order's fee reserve so an exact refund can complete.
    function subsidize(State storage s, uint256 id, uint256 amount) external {
        Order storage o = s.orders[id];
        s.escrowed += amount;
        o.extra += amount;
        if (o.status == Status.Returning && o.held != 0) _closeReturnedBuy(s, id, false);
    }

    /// @dev A buy the vault answered Failed (reservation already released): close it once its principal is
    ///      back (`force`: it was delivered on the reserve chain instead). Until then it stays Returning,
    ///      keeping `escalateFunds` available.
    function _closeReturnedBuy(State storage s, uint256 id, bool force) private {
        Order storage o = s.orders[id];
        if (!force && !isBack(o.held, o.amountIn)) return;
        uint256 pool = o.held + o.fee + o.extra;
        if (o.lane == 1 && pool < o.amountIn) return; // reward principal comes back whole: wait for `subsidize`
        o.status = Status.Cancelled;
        o.settledAt = uint64(block.timestamp);
        removeOpen(s, id);
        emit OrderCancelled(id, o.cancelRequested ? Reason.User : Reason.Vault);
        o.held = 0;
        o.extra = 0;
        o.fee = 0;
        if (o.lane == 0) {
            s.escrowed -= pool;
            _pay(s, id, o.user, pool, false);
            return;
        }
        uint256 leftover = pool - o.amountIn;
        o.refundReady = o.amountIn;
        s.escrowed -= leftover; // refundReady stays escrowed
        if (leftover > 0) _pay(s, id, s.opsVault, leftover, false);
        emit RewardRefundReady(id, o.amountIn, leftover);
    }

    /// @dev A sold order whose proceeds are held here: pay them less the locked fee and close it.
    function _payHeldProceeds(State storage s, uint256 id) private {
        Order storage o = s.orders[id];
        uint256 pool = o.held;
        if (!isBack(pool, o.amountOut)) return; // dust or a surplus credit is not the proceeds
        o.held = 0;
        s.escrowed -= pool;
        uint256 fee = o.fee < pool ? o.fee : pool;
        s.accruedFees += fee;
        o.fee = fee;
        o.amountOut = pool - fee;
        o.status = Status.Filled;
        removeOpen(s, id);
        _pay(s, id, o.user, pool - fee, false);
        emit SellFilled(id, o.user, o.underlying, pool - fee, fee, false);
    }

    /// @dev Money held for an order that the result closed without needing it (dust bounced before a
    ///      Bought, or before a canonical delivery): it stays that order's.
    function _flushHeld(State storage s, uint256 id) private {
        Order storage o = s.orders[id];
        uint256 h = o.held;
        if (h == 0) return;
        o.held = 0;
        s.escrowed -= h;
        _pay(s, id, _lateTo(s, o, h), h, false);
    }

    // ------------------------------------------------------------------ settlement

    /// @notice Apply a vault result to its order. `canonical` results skip the rate limit and the
    ///         reconciliation queue: they are the proof the queue waits for.
    /// @return applied False when the result changed nothing (wrong kind, order no longer open): the caller
    ///         must not treat the ref as reconciled then.
    function settle(State storage s, uint256 id, Messages.Result memory r, bool canonical)
        external
        returns (bool applied)
    {
        Order storage o = s.orders[id];
        bool buy = o.kind == Kind.Buy;
        // A buy escalated before any answer (HubExits.escalateFunds) still takes the vault's answer.
        bool unanswered = o.outcome == 0 && (o.status == Status.Dispatched || (buy && o.status == Status.Escalated));
        if (r.outcome == Messages.Outcome.Bought) {
            if (!buy) {
                emit ResultIgnored(id, Reason.WrongKind);
                return false;
            }
            if (o.status == Status.Cancelled && o.advanced && !o.orphaned && o.outcome == 0) {
                // The float refunded the order already (original A01); the stock is real, so it goes to
                // the treasury.
                _mint(s, o.underlying, s.treasury, r.amountOut, canonical);
                s.capacity.finalizeBuy(o.capKey, o.underlying, r.amountOut);
                // Proven canonically first: the late LayerZero copy is ignored, so review it here.
                if (canonical) s.capacity.markReviewed(o.capKey);
                o.orphaned = true;
                o.rawOut = r.amountOut;
                o.outcome = 1;
                _markSettled(s, o, r.ref, canonical);
                emit Orphaned(id, r.amountOut);
                return true;
            }
            if (!unanswered) {
                emit ResultIgnored(id, Reason.NotOpen);
                return false;
            }
            // A cancel request, or money bounced back before this result, never takes the fill away.
            _mint(s, o.underlying, o.lane == 1 ? address(this) : o.user, r.amountOut, canonical);
            s.capacity.finalizeBuy(o.capKey, o.underlying, r.amountOut);
            if (canonical) s.capacity.markReviewed(o.capKey);
            o.status = Status.Filled;
            o.settledAt = uint64(block.timestamp);
            o.amountOut = r.amountOut;
            o.rawOut = r.amountOut;
            o.outcome = 1;
            s.escrowed -= o.fee;
            s.accruedFees += o.fee;
            if (o.lane == 1) o.custodyRaw = r.amountOut;
            uint256 left = o.extra;
            o.extra = 0;
            s.escrowed -= left;
            _pay(s, id, o.lane == 1 ? s.opsVault : o.user, left, false);
            _flushHeld(s, id);
            removeOpen(s, id);
            _markSettled(s, o, r.ref, canonical);
            emit BuyFilled(id, o.user, o.underlying, r.amountOut, canonical);
            return true;
        }

        if (r.outcome == Messages.Outcome.Sold) {
            if (buy) {
                emit ResultIgnored(id, Reason.WrongKind);
                return false;
            }
            bool open = o.status == Status.Dispatched || o.status == Status.Pending || o.status == Status.Escalated;
            if (!open || o.outcome != 0) {
                // Answered already (e.g. proven canonically, then escalated): a second copy changes nothing.
                emit ResultIgnored(id, Reason.NotOpen);
                return false;
            }
            uint256 gross = uint256(r.amountOut) * SCALE;
            uint256 fee = (gross * o.feeBps) / BPS;
            uint256 net = gross - fee;
            o.settledAt = uint64(block.timestamp);
            o.fee = fee;
            o.rawOut = r.amountOut;
            o.outcome = 2;
            s.capacity.finalizeRedeem(o.capKey, canonical);
            _markSettled(s, o, r.ref, canonical);
            if (gross == 0) {
                // A canonical delivery paid the holder on the reserve chain; Arc owes nothing.
                o.status = Status.Filled;
                removeOpen(s, id);
                _flushHeld(s, id);
                emit SellFilled(id, o.user, o.underlying, 0, 0, canonical);
                return true;
            }
            o.amountOut = net;
            if (isBack(o.held, net)) {
                // The proceeds beat this result here (review #2b/c): pay them now, never the float too.
                _payHeldProceeds(s, id);
            } else if (s.floatEnabled && available(s) >= net && payAllowance(s) >= net) {
                // Acceleration: the float pays net now; the proceeds replenish it when they return. What is
                // already held (less than half of net) is the first part of that replenishment, never paid on
                // top of net (re-review N2).
                s.escrowed -= o.held;
                o.held = 0;
                o.advanced = true;
                o.status = Status.Filled;
                s.accruedFees += fee;
                removeOpen(s, id);
                _pay(s, id, o.user, net, true);
                emit SellFilled(id, o.user, o.underlying, net, fee, canonical);
            } else {
                o.status = Status.Proceeds;
                emit AwaitingReturn(id, Status.Proceeds, gross);
            }
            return true;
        }

        // Failed. An escalated sell can still fail this way: the vault's Failed result marked the ref settled
        // before the canonical delivery arrived, so the delivery was a no-op and nothing left the reserve.
        bool floatCancelled = buy && o.status == Status.Cancelled && o.advanced && o.outcome == 0;
        bool sellFailedLate = !buy && o.status == Status.Escalated && o.outcome == 0;
        if (!unanswered && o.status != Status.Pending && !sellFailedLate && !floatCancelled) {
            emit ResultIgnored(id, Reason.NotOpen);
            return false;
        }
        o.outcome = 3;
        o.rawOut = 0;
        _markSettled(s, o, r.ref, canonical);
        if (buy) {
            // Nothing was bought: RH owes no stock; the reservation goes (also after a float refund).
            s.capacity.release(o.capKey);
            if (floatCancelled) return true;
            o.settledAt = uint64(block.timestamp);
            bool escalated = o.status == Status.Escalated;
            o.status = Status.Returning;
            emit AwaitingReturn(id, Status.Returning, o.amountIn);
            // Escalated: the principal is delivered on the reserve chain. Otherwise close once it is here.
            _closeReturnedBuy(s, id, escalated);
        } else {
            o.status = Status.Cancelled;
            o.settledAt = uint64(block.timestamp);
            removeOpen(s, id);
            // Nothing was sold, so the burn is undone with the vault's word for it.
            s.listings[o.underlying].arc.mint(o.user, o.amountIn);
            s.capacity.revertRedeem(o.capKey);
            _flushHeld(s, id);
            emit OrderCancelled(id, Reason.Vault);
        }
        return true;
    }

    /// @notice A migration result, proven canonically: the vault bought `amountOut` of `underlying` into
    ///         the reserve; mint the same to the treasury, which distributes it.
    function migrationMint(State storage s, Messages.Result memory r) external {
        if (r.outcome != Messages.Outcome.Bought || r.amountOut == 0) revert BadMigration(r.ref);
        if (Messages.migrationUnderlying(r.ref) != r.underlying) revert BadMigration(r.ref);
        Listing storage l = s.listings[r.underlying];
        if (address(l.arc) == address(0)) revert NotListedHere(r.underlying);
        l.arc.mint(s.treasury, r.amountOut);
        s.capacity.finalizeBuy(r.ref, r.underlying, r.amountOut);
        emit MigrationMinted(r.ref, r.underlying, s.treasury, r.amountOut);
    }

    /// @notice True when a LayerZero-settled order agrees with the canonical result for it.
    function matches(State storage s, uint256 id, Messages.Result memory r) external view returns (bool) {
        Order storage o = s.orders[id];
        return o.rawOut == r.amountOut && o.outcome == uint8(r.outcome) + 1;
    }

    // ------------------------------------------------------------------ limits and reconciliation

    /// @notice Stops minting if the oldest LayerZero settlement is still unconfirmed after the window.
    ///         A resume by the owner restarts the clock for what is still unproven; it never forgives it.
    function checkStale(State storage s) public {
        while (!s.unreconciled.empty()) {
            if (!s.reconciled[s.unreconciled.front()]) break;
            s.unreconciled.popFront();
        }
        if (s.unreconciled.empty()) return;
        uint64 since = s.lzSettledAt[s.unreconciled.front()];
        if (s.resumedAt > since) since = s.resumedAt;
        if (since + RECONCILE_WINDOW < block.timestamp) halt(s, 0);
    }

    /// @notice USDC payable from the float this window: max(floor, bps × float).
    function payAllowance(State storage s) public view returns (uint256) {
        uint256 cap = (available(s) * s.payLimitBps) / BPS;
        if (cap < s.payFloor) cap = s.payFloor;
        uint256 used = block.timestamp >= s.payWindowStart + MINT_WINDOW ? 0 : s.paidInWindow;
        return cap > used ? cap - used : 0;
    }

    /// @notice Pay what order `id` is owed to its payee. Owed money is already held for it, so the only
    ///         limit is the hub's actual balance of owed funds.
    function claimPay(State storage s, uint256 id, address to) external returns (uint256 paid) {
        Order storage o = s.orders[id];
        paid = o.owed;
        if (paid == 0) revert NotClaimable(id, 0);
        o.owed = 0;
        s.claimableTotal -= paid;
        _transfer(to, paid);
    }

    /// @notice Owner only (through the hub): strike what a disputed settlement of order `id` still owes.
    ///         The struck amount stays in the hub (back to the float/reserve), never to the treasury.
    function voidClaimable(State storage s, uint256 id, uint256 amount) external {
        Order storage o = s.orders[id];
        if (!o.disputed || o.owed < amount) revert NotClaimable(id, amount);
        o.owed -= amount;
        s.claimableTotal -= amount;
    }

    function halt(State storage s, uint8 why) public {
        if (s.mintsHalted) return;
        s.mintsHalted = true;
        emit MintsHalted(why);
    }

    /// @notice Shares of `underlying` still mintable through LayerZero in the current window.
    function mintAllowance(State storage s, address underlying) public view returns (uint256) {
        Listing storage l = s.listings[underlying];
        uint256 cap = (l.arc.totalSupply() * s.mintLimitBps) / BPS;
        if (cap < l.mintFloor) cap = l.mintFloor;
        uint256 used = block.timestamp >= s.windowStart[underlying] + MINT_WINDOW ? 0 : s.mintedInWindow[underlying];
        return cap > used ? cap - used : 0;
    }

    /// @notice Native USDC not owed to anyone: the optional acceleration float (zero by default).
    function available(State storage s) public view returns (uint256) {
        uint256 owed = s.escrowed + s.accruedFees + s.claimableTotal;
        return address(this).balance > owed ? address(this).balance - owed : 0;
    }

    // ------------------------------------------------------------------ internals

    function _mint(State storage s, address underlying, address to, uint256 shares, bool canonical) private {
        Listing storage l = s.listings[underlying];
        if (!canonical) {
            checkStale(s);
            if (s.mintsHalted) revert MintsAreHalted();
            uint256 allowance = mintAllowance(s, underlying);
            if (shares > allowance) revert MintLimitExceeded(underlying, shares, allowance);
            if (block.timestamp >= s.windowStart[underlying] + MINT_WINDOW) {
                s.windowStart[underlying] = uint64(block.timestamp);
                s.mintedInWindow[underlying] = 0;
            }
            s.mintedInWindow[underlying] += shares;
        }
        l.arc.mint(to, shares);
    }

    function _markSettled(State storage s, Order storage o, bytes32 ref, bool canonical) private {
        if (canonical) {
            s.reconciled[ref] = true;
            return;
        }
        o.lzSettled = true;
        s.lzSettledAt[ref] = uint64(block.timestamp);
        s.unreconciled.pushBack(ref);
    }

    /// @dev Push `amount` to `to` for order `id`; what cannot be pushed waits in the order's `owed`.
    ///      `fromFloat` payments count against the window allowance (original `_pay` semantics).
    function _pay(State storage s, uint256 id, address to, uint256 amount, bool fromFloat) private {
        if (amount == 0) return;
        if (to == address(0)) to = s.treasury;
        (bool ok,) = to.call{value: amount}("");
        if (ok) {
            if (fromFloat) _countPaid(s, amount);
            return;
        }
        Order storage o = s.orders[id];
        o.owed += amount;
        s.claimableTotal += amount;
        if (fromFloat) _countPaid(s, amount);
        emit OrderOwed(id, to, amount);
        emit Claimable(to, amount);
    }

    function _countPaid(State storage s, uint256 amount) private {
        if (block.timestamp >= s.payWindowStart + MINT_WINDOW) {
            s.payWindowStart = uint64(block.timestamp);
            s.paidInWindow = 0;
        }
        s.paidInWindow += amount;
    }

    function _transfer(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}

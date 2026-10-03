// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SolonStockToken} from "./SolonStockToken.sol";
import {CanonicalGate} from "./CanonicalGate.sol";
import {HubSettlement} from "./HubSettlement.sol";
import {Messages} from "./libs/Messages.sol";

/// @title HubExits — the hub's exit doors, as a second external library
/// @notice Solon code split out of `SolonStockHub`/`HubSettlement` for the code size limit (review p5).
///         Like `HubSettlement` it runs by delegatecall in the hub's context and has no storage or
///         authority of its own. It holds the doors that must keep working when everything else stops:
///         - `escalate` / `canonicalRedeem` (ArcStocks originals): the canonical lane to the reserve chain;
///         - `escalateFunds` (Solon): stuck USDG of an order on the reserve chain, or — for a buy whose
///           principal provably came back or whose owner cancelled, with no vault result yet — a canonical
///           void that closes the ref on the vault (review #3);
///         - `voidOrder` checks (review #3/#8): a zero-amount order message closes an unexecuted ref over
///           LayerZero, so its reservation is released and its money returned, also while paused;
///         - `cancelReward` (review #5): a queued reward order can be refunded exactly and released.
///         Every canonical send carries its own hook cost (`HOOK_FEE`, 1 USDC, forwarded to the gate float)
///         so the gate float cannot be drained by free 1-wei redemptions (review #6); `canonicalRedeem`
///         charges the locked sell fee in shares, like every other exit (review low).
library HubExits {
    /// @notice Native USDC (18 dp) that pays the gate's 1 USDC CCTP hook per canonical send.
    uint256 internal constant HOOK_FEE = 1 ether;

    event OrderEscalated(uint256 indexed id, address indexed to, Messages.DeliverMode mode);
    event SellRequested(
        uint256 indexed id, address indexed user, address indexed underlying, uint256 sharesIn, uint256 minUsdcOut
    );
    event OrderCancelled(uint256 indexed id, HubSettlement.Reason reason);
    event OrderOwed(uint256 indexed id, address indexed to, uint256 amount);
    event Claimable(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error WrongKind(uint256 id);
    error WrongStatus(uint256 id, HubSettlement.Status status);
    error NotYours(uint256 id);
    error TooEarly(uint256 id, uint64 at);
    error InsufficientValue(uint256 got, uint256 need);
    error TransferFailed();

    // ------------------------------------------------------------------ canonical lane

    /// @notice A sell the fast lane did not finish in `escalateAfter` goes canonical (ArcStocks original).
    function escalate(
        HubSettlement.State storage s,
        address gate,
        uint256 id,
        address to,
        uint64 escalateAfter,
        uint256 paid
    ) external {
        HubSettlement.Order storage o = s.orders[id];
        if (o.kind != HubSettlement.Kind.Sell) revert WrongKind(id);
        if (o.status != HubSettlement.Status.Dispatched && o.status != HubSettlement.Status.Pending) {
            revert WrongStatus(id, o.status);
        }
        uint64 at = o.createdAt + escalateAfter;
        if (block.timestamp < at) revert TooEarly(id, at);
        _checkEscalator(o, id, to);
        o.status = HubSettlement.Status.Escalated;
        HubSettlement.removeOpen(s, id);
        _sendDeliver(gate, id, o.underlying, uint128(o.amountIn), to, Messages.DeliverMode.Settlement, paid);
    }

    /// @notice Burn now and receive the stock itself (or its proceeds) at `to` on the reserve chain.
    ///         The locked sell fee is kept in shares (to the treasury; still backed 1:1 by the reserve).
    function canonicalRedeem(
        HubSettlement.State storage s,
        address gate,
        address underlying,
        uint256 sharesIn,
        address to,
        Messages.DeliverMode mode,
        uint256 paid
    ) external returns (uint256 id) {
        if (sharesIn == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        SolonStockToken arc = s.listings[underlying].arc;
        arc.burn(msg.sender, sharesIn);
        uint256 fee = (sharesIn * s.sellFeeBps) / HubSettlement.BPS;
        if (fee > 0) arc.mint(s.treasury, fee);
        uint256 net = sharesIn - fee;
        if (net == 0) revert ZeroAmount();
        id = HubSettlement.place(
            s, msg.sender, underlying, HubSettlement.Kind.Sell, HubSettlement.Status.Escalated, net, 0, 0
        );
        s.capacity.beginRedeem(s.orders[id].capKey, underlying, net);
        HubSettlement.removeOpen(s, id);
        emit SellRequested(id, msg.sender, underlying, net, 0);
        _sendDeliver(gate, id, underlying, uint128(net), to, mode, paid);
    }

    /// @notice Money of a public order stuck on the reserve chain goes to `to` there as USDG through the
    ///         canonical lane after `escalateAfter`:
    ///         - a failed buy's principal or a sell's proceeds (the vault already answered): the Arc-held fee
    ///           and unused reserve of a buy come back here at once; a sell pays its locked fee here (from
    ///           held money first, the rest on top of the 1 USDC hook in `paid`);
    ///         - a buy with no vault answer yet whose owner cancelled or whose principal already came back
    ///           (review #3): the delivery closes the ref on the vault as Failed, which is proven back to
    ///           the hub canonically; the order then settles like any Failed buy (or, if the vault had
    ///           bought first, like any Bought one).
    function escalateFunds(
        HubSettlement.State storage s,
        address gate,
        uint256 id,
        address to,
        uint64 escalateAfter,
        uint256 paid
    ) external {
        HubSettlement.Order storage o = s.orders[id];
        _checkEscalator(o, id, to);
        if (o.lane != 0) revert WrongStatus(id, o.status);
        bool buy = o.kind == HubSettlement.Kind.Buy;
        bool unanswered = buy && o.outcome == 0 && (o.cancelRequested || HubSettlement.isBack(o.held, o.amountIn))
            && (o.status == HubSettlement.Status.Funded || o.status == HubSettlement.Status.Dispatched);
        if (unanswered) {
            uint64 at0 = o.dispatchedAt + escalateAfter;
            if (block.timestamp < at0) revert TooEarly(id, at0);
            o.status = HubSettlement.Status.Escalated; // fee, reserve and held money wait for the result
        } else {
            if (o.status != HubSettlement.Status.Returning && o.status != HubSettlement.Status.Proceeds) {
                revert WrongStatus(id, o.status);
            }
            uint64 at = o.settledAt + escalateAfter;
            if (block.timestamp < at) revert TooEarly(id, at);
            o.status = HubSettlement.Status.Escalated;
            HubSettlement.removeOpen(s, id);
            // Arc-held money comes back here: a buy's fee and unused reserve, and anything held (dust or a
            // partial credit) for either side.
            uint256 held = o.held;
            uint256 back = held + (buy ? o.fee + o.extra : 0);
            s.escrowed -= back;
            o.held = 0;
            if (buy) {
                o.fee = 0;
                o.extra = 0;
            } else {
                // Re-review L1: proceeds taken on the reserve chain still pay the fee locked at Sold — from
                // the money held here first, the rest with this call. Any later Arc return of the same
                // proceeds is then the seller's in full (the fee is already paid).
                uint256 fee = o.fee;
                uint256 fromHeld = fee < held ? fee : held;
                uint256 due = fee - fromHeld;
                if (paid < HOOK_FEE + due) revert InsufficientValue(paid, HOOK_FEE + due);
                paid -= due;
                back -= fromHeld;
                s.accruedFees += fee;
            }
            _pay(s, id, o.user, back);
        }
        _sendDeliver(gate, id, o.underlying, 0, to, Messages.DeliverMode.Settlement, paid);
    }

    // ------------------------------------------------------------------ voids and reward cancels

    /// @notice Checks for `SolonStockHub.voidOrder` and covers the LayerZero fee: from `paid`, the rest
    ///         from the order's own reserve. A void is allowed only for a buy the vault has not answered,
    ///         whose owner asked to cancel or whose principal already came back (anyone may send it then:
    ///         the money only ever goes to the order), or — reward lane — by the hub operator; and for a
    ///         buy the acceleration float already refunded (its late money refills the float). "Came back"
    ///         means at least half of the principal (`HubSettlement.isBack`): dust never qualifies. The
    ///         order's reserve pays for one void; repeats are paid by their caller.
    function checkVoid(HubSettlement.State storage s, uint256 id, bool operator, uint256 paid, uint256 lzFee) external {
        HubSettlement.Order storage o = s.orders[id];
        bool open = o.status == HubSettlement.Status.Funded || o.status == HubSettlement.Status.Dispatched;
        // Re-review N1: a dispatched buy the float already refunded (Cancelled, `advanced`) with no vault
        // answer yet must still be closable on the vault, or its reservation waits forever. Its own
        // reserve went back to the user with the refund, so the caller pays the LayerZero fee.
        bool floatRefunded = o.advanced && o.status == HubSettlement.Status.Cancelled;
        if (
            o.kind != HubSettlement.Kind.Buy || o.outcome != 0
                || !(floatRefunded
                    || (open
                        && (o.cancelRequested
                            || HubSettlement.isBack(o.held, o.amountIn)
                            || (operator && o.lane == 1))))
        ) revert WrongStatus(id, o.status);
        if (paid >= lzFee) return;
        // The order's own reserve pays for one void only; a repeat is at the caller's cost.
        if (o.voided) revert InsufficientValue(paid, lzFee);
        o.voided = true;
        uint256 need = lzFee - paid;
        if (o.extra < need) revert InsufficientValue(paid + o.extra, lzFee);
        o.extra -= need;
        s.escrowed -= need;
    }

    /// @notice Operator: refund a queued (never funded) reward order exactly and release its reservation,
    ///         so a reward head whose route cannot launch never blocks the scheduler (review #5).
    function cancelReward(HubSettlement.State storage s, uint256 id) external {
        HubSettlement.Order storage o = s.orders[id];
        if (o.lane != 1 || o.status != HubSettlement.Status.Pending) revert WrongStatus(id, o.status);
        HubSettlement.refundBuy(s, id, HubSettlement.Reason.Unfundable);
        s.capacity.releaseUnsent(o.capKey);
    }

    // ------------------------------------------------------------------ internals

    /// @dev The seller picks `to`; anyone else only to the seller's own plain (EOA) address.
    function _checkEscalator(HubSettlement.Order storage o, uint256 id, address to) private view {
        if (msg.sender == o.user) {
            if (to == address(0)) revert ZeroAddress();
        } else {
            if (to != o.user || o.user.code.length != 0) revert NotYours(id);
        }
    }

    function _sendDeliver(
        address gate,
        uint256 id,
        address underlying,
        uint128 shares,
        address to,
        Messages.DeliverMode mode,
        uint256 paid
    ) private {
        if (gate == address(0)) revert ZeroAddress();
        if (paid < HOOK_FEE) revert InsufficientValue(paid, HOOK_FEE);
        (bool ok,) = gate.call{value: paid}(""); // native USDC is the gate's USDC float on Arc
        if (!ok) revert TransferFailed();
        CanonicalGate(payable(gate))
            .sendDeliver(
                Messages.Deliver({ref: bytes32(id), underlying: underlying, shares: shares, to: to, mode: mode})
            );
        emit OrderEscalated(id, to, mode);
    }

    function _pay(HubSettlement.State storage s, uint256 id, address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (ok) return;
        s.orders[id].owed += amount;
        s.claimableTotal += amount;
        emit OrderOwed(id, to, amount);
        emit Claimable(to, amount);
    }
}

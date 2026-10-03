// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {SolonStockAdapter} from "./SolonStockAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev ABI reproduced from MIT ArcStocks HubSettlement.Order, preserving widths and field order.
interface IArcStocksV2Hub {
    struct Order {
        address user;
        address underlying;
        uint8 kind;
        uint8 status;
        uint64 createdAt;
        uint64 settledAt;
        uint256 amountIn;
        uint256 minOut;
        uint256 amountOut;
        uint256 fee;
        uint128 rawOut;
        bool lzSettled;
        bool orphaned;
        uint64 dispatchedAt;
    }
    function fees() external view returns (uint16, uint16, uint16);
    function requestBuy(address underlying, uint256 usdcIn, uint256 minOut) external payable returns (uint256);
    function getOrder(uint256 id) external view returns (Order memory);
    function cancel(uint256 id) external;
    function claim() external;
    function claimable(address account) external view returns (uint256);
}

/// @notice One immutable recipient per hub order prevents pooled balances/refunds being attributed twice.
contract ArcStocksV2Order is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable adapter;
    address public immutable hub;
    address public immutable asset;
    address public immutable opsVault;
    address public immutable underlying;
    uint256 public immutable budget;
    uint256 public immutable minOut;
    uint256 public immutable dispatchFeeSurplus;
    uint256 public immutable orderId;
    bool public consumed;

    constructor(address hub_, address asset_, address underlying_, uint256 budget_, uint256 minOut_, address opsVault_)
        payable {
        require(opsVault_ != address(0));
        opsVault = opsVault_;
        adapter = msg.sender;
        hub = hub_;
        asset = asset_;
        underlying = underlying_;
        budget = budget_;
        minOut = minOut_;
        (uint16 bps,,) = IArcStocksV2Hub(hub_).fees();
        require(bps < 10000);
        uint256 gross = Math.mulDiv(budget_ - 1, 10000, 10000 - bps) + 1;
        require(msg.value > gross, "message fee missing");
        orderId = IArcStocksV2Hub(hub_).requestBuy{value: msg.value}(underlying_, gross, minOut_);
        IArcStocksV2Hub.Order memory o = IArcStocksV2Hub(hub_).getOrder(orderId);
        require(
            o.user == address(this) && o.underlying == underlying_ && o.kind == 0 && o.amountIn == budget_
                && o.minOut == minOut_
        );
        dispatchFeeSurplus = address(this).balance;
    }

    receive() external payable {
        require(msg.sender == hub);
    }
    event OpsFeesRecovered(uint256 amount, bool success);

    /// @notice Principal must already have settled; a rejecting Ops vault never blocks it.
    function recoverOpsFees() external nonReentrant returns (bool ok) {
        require(consumed, "principal pending");
        if (IArcStocksV2Hub(hub).claimable(address(this)) != 0) IArcStocksV2Hub(hub).claim();
        uint256 amount = address(this).balance;
        if (amount == 0) return true;
        (ok,) = payable(opsVault).call{value: amount}("");
        emit OpsFeesRecovered(amount, ok);
    }

    function cancel() external {
        require(msg.sender == adapter);
        IArcStocksV2Hub(hub).cancel(orderId);
    }

    function collect() external nonReentrant returns (uint8 status, uint256 raw, uint256 refund) {
        require(msg.sender == adapter && !consumed);
        IArcStocksV2Hub.Order memory o = IArcStocksV2Hub(hub).getOrder(orderId);
        require(
            o.user == address(this) && o.underlying == underlying && o.kind == 0 && o.amountIn == budget
                && o.minOut == minOut
        );
        if (o.status == 2) {
            require(!o.orphaned && o.amountOut >= minOut);
            consumed = true;
            IERC20(asset).safeTransfer(adapter, o.amountOut);
            return (1, o.amountOut, 0);
        }
        if (o.status == 3) {
            if (IArcStocksV2Hub(hub).claimable(address(this)) != 0) IArcStocksV2Hub(hub).claim();
            // Hub cancellation status is authoritative; an unpaid refund remains quarantined.
            if (address(this).balance < budget + dispatchFeeSurplus) return (0, 0, 0);
            consumed = true;
            (bool ok,) = payable(adapter).call{value: budget}("");
            require(ok);
            return (2, 0, budget);
        }
        return (0, 0, 0);
    }
}

/// @notice Manually admitted fallback to the original float-based V2 hub, not a Relay implementation.
/// @dev Each order keeps its hub/address/fee terms. Original hub owns cancel and orphan semantics.
contract ArcStocksV2Adapter is SolonStockAdapter {
    mapping(bytes32 => ArcStocksV2Order) public receivers;
    constructor(Config memory c) SolonStockAdapter(c) {}

    // Per-order recipients return verified refunds; no arbitrary sender can inject a receipt.
    receive() external payable override {
        require(msg.sender == config.hub || isReceiver[msg.sender]);
    }
    mapping(address => bool) private isReceiver;
    function _startFunding(bytes32, Order storage) internal override {}

    /// @dev r12: the ArcStocks hub's fee is paid to a third party, so all of the order's fees are external costs.
    function _internalFee(uint256) internal pure override returns (uint256) {
        return 0;
    }

    function funded(bytes32 id) public view override returns (bool) {
        return orders[id].state != 0;
    }

    function _submit(bytes32 id, Order storage o) internal override {
        ArcStocksV2Order receiver = new ArcStocksV2Order{value: o.budget + o.fees}(
            config.hub, config.asset, config.underlying, o.budget, o.minRaw, config.opsVault
        );
        receivers[id] = receiver;
        isReceiver[address(receiver)] = true;
    }

    function _result(bytes32 id, bytes calldata) internal override returns (uint8, uint256, uint256) {
        if (address(receivers[id]) == address(0)) return (0, 0, 0);
        return receivers[id].collect();
    }

    function requestCancel(bytes32 id) external override onlyCoordinator nonReentrant {
        require(orders[id].state == 2);
        receivers[id].cancel();
    }
}

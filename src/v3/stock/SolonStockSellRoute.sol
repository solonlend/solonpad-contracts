// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SolonStockHub} from "./SolonStockHub.sol";
import {HubSettlement} from "./HubSettlement.sol";
import {SolonStockToken} from "./SolonStockToken.sol";

/// @title SolonStockSellRoute — the fixed typed sell route for StockFeeConverter (IStockSellRoute)
/// @notice New Solon code (phase-4 boundary "卖出Hub proof认证属于阶段5固定typed route"). The converter's
///         stock is redeemed through the hub as an ordinary sell owned by this route; the result is read from
///         the hub's own settled state, never from a keeper proof. Sold: pays the converter the gross proceeds
///         less the hub's 25 bps service fee, topping up the return-leg cost from the Ops fees sent with the
///         order (leftover fees go back to the fixed Ops); Failed: returns the hub's re-minted raw exactly.
contract SolonStockSellRoute is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Sale {
        uint256 hubId;
        address token;
        uint256 raw;
        uint256 fees;
        bool done;
    }

    SolonStockHub public immutable hub;
    address public immutable converter;
    address public immutable ops;
    mapping(bytes32 order => Sale) public sales;
    mapping(bytes32 order => bool) public used;

    event SaleRequested(bytes32 indexed order, uint256 indexed hubId, uint256 raw, uint256 grossFloor, uint256 fees);
    event SaleClaimed(bytes32 indexed order, uint8 status, uint256 paid, uint256 reminted, uint256 opsRefund);

    error NotConverter();
    error BadOrder();
    error NotHub();

    constructor(address hub_, address converter_, address ops_) {
        require(hub_ != address(0) && converter_ != address(0) && ops_ != address(0));
        hub = SolonStockHub(payable(hub_));
        converter = converter_;
        ops = ops_;
    }

    receive() external payable {
        if (msg.sender != address(hub)) revert NotHub();
    }

    function requestSell(bytes32 order, address asset, uint256 raw, uint256 grossFloor, address receiver, bytes32)
        external
        payable
        nonReentrant
    {
        if (msg.sender != converter || receiver != converter) revert NotConverter();
        address underlying = hub.underlyingOfToken(asset);
        if (order == 0 || used[order] || underlying == address(0) || raw == 0) revert BadOrder();
        used[order] = true;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), raw);
        uint256 lzFee = hub.quoteOrder(underlying);
        if (msg.value < lzFee) revert BadOrder();
        uint256 hubId = hub.requestSell{value: lzFee}(underlying, raw, grossFloor);
        sales[order] = Sale(hubId, asset, raw, msg.value - lzFee, false);
        emit SaleRequested(order, hubId, raw, grossFloor, msg.value - lzFee);
    }

    /// @notice The stock layer's single-order limit (CapacityController `lRun`), for the converter.
    function runLimit() external view returns (uint256) {
        return hub.capacity().lRun();
    }

    /// @return status 0 unknown/pending, 1 sold (native paid), 2 failed (raw returned)
    function claimSell(bytes32 order, bytes calldata)
        external
        nonReentrant
        returns (uint8 status, uint256 paid, uint256 reminted)
    {
        if (msg.sender != converter) revert NotConverter();
        Sale storage s = sales[order];
        if (!used[order] || s.done) revert BadOrder();
        HubSettlement.Order memory o = hub.getOrder(s.hubId);
        if (o.owed != 0) hub.claim(s.hubId);
        uint256 opsRefund;
        if (o.status == HubSettlement.Status.Filled && o.outcome == 2) {
            uint256 gross = uint256(o.rawOut) * 1e12;
            uint256 target = gross - (gross * o.feeBps) / 10_000;
            paid = o.amountOut;
            if (paid < target) {
                uint256 topUp = target - paid;
                if (topUp > s.fees) topUp = s.fees;
                s.fees -= topUp;
                paid += topUp;
            }
            status = 1;
        } else if (o.status == HubSettlement.Status.Cancelled && o.outcome == 3) {
            reminted = s.raw;
            status = 2;
        } else {
            return (0, 0, 0);
        }
        s.done = true;
        opsRefund = s.fees;
        s.fees = 0;
        if (paid != 0) {
            (bool ok,) = payable(converter).call{value: paid}("");
            require(ok);
        }
        if (reminted != 0) IERC20(s.token).safeTransfer(converter, reminted);
        if (opsRefund != 0) {
            (bool ok2,) = payable(ops).call{value: opsRefund}("");
            require(ok2);
        }
        emit SaleClaimed(order, status, paid, reminted, opsRefund);
    }
}

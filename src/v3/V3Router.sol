// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {V3QuoteFeeHook} from "./V3QuoteFeeHook.sol";

/// @notice Future A-mode delivery policy; address(0) selects the default B mode.
/// @dev Must check the real payer AND recipient, not the router's identity.
/// This is an official-route seam, not a claim that outside pools/routers are gated.
interface IV3TradeEligibility {
    function checkTrade(bytes32 poolId, address quoteAsset, address payer, address recipient, bool buy) external view;
}

interface IV3RouterFeeTotals {
    function totalReceived(bytes32 poolId) external view returns (uint256);
    function redeemClaims(bytes32 poolId) external;
}

/// @notice Single registered-pool, full-fill-only router for the fixed v3 quote fee hook.
/// @dev Uses v4 unlock/sync/settle/take. Inputs are prepaid before swap; after
/// swap the ledger redeems its fee claims against settled quote reserves.
/// Exact output prepays maxIn and refunds the unused manager credit.
/// No arbitrary calls, hookData, recipient-controlled payer or alternate routers.
contract V3Router is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct SwapRequest {
        PoolKey key;
        bool buy;
        int256 amountSpecified; // Negative exact input; positive exact output (sell = NET quote).
        uint160 sqrtPriceLimitX96; // 0 chooses the full v4 price range.
        uint256 minOut; // Net user output, in the output asset's raw units.
        uint256 maxIn; // Total user input including the hook fee, in input raw units.
        address recipient;
        uint256 deadline;
    }

    struct PoolMetadata {
        address quoteAsset;
        uint8 quoteKind;
        bool zeroForOne;
    }

    IPoolManager public immutable manager;
    V3QuoteFeeHook public immutable hook;
    address public immutable factory;
    IV3TradeEligibility public immutable eligibility;
    address public msgSender;
    address public swapRecipient;

    error SimulationResult(int256 delta, uint256 hookFee);
    error SimulationFailure(bytes reason);
    error OnlySelf();
    error InvalidDependency();
    error UnknownPool();
    error InvalidRequest();
    error DeadlineExpired();
    error UnauthorizedCallback();
    error NativeValueMismatch();
    error InexactInput();
    error InexactOutput();
    error InvalidDelta();
    error PartialFillUnsupported();
    error SlippageExceeded();
    error NativeRefundFailed();

    constructor(IPoolManager manager_, V3QuoteFeeHook hook_, IV3TradeEligibility eligibility_) {
        if (
            address(manager_).code.length == 0 || address(hook_).code.length == 0
                || address(hook_.poolManager()) != address(manager_)
                || (address(eligibility_) != address(0) && address(eligibility_).code.length == 0)
        ) revert InvalidDependency();
        manager = manager_;
        hook = hook_;
        factory = hook_.factory();
        eligibility = eligibility_;
    }

    /// @notice Authenticate the exact registered key and apply the same policy for quotes and execution.
    function validateRequest(SwapRequest calldata request, address payer) public view returns (PoolMetadata memory p) {
        if (block.timestamp > request.deadline) revert DeadlineExpired();
        if (
            payer == address(0) || request.recipient == address(0) || request.recipient == address(this)
                || request.amountSpecified == 0 || request.amountSpecified > type(int128).max
                || request.amountSpecified < -int256(type(int128).max) || request.maxIn == 0
                || request.maxIn > uint256(uint128(type(int128).max))
        ) revert InvalidRequest();
        PoolId id = request.key.toId();
        (address token, address quoteAsset, uint8 kind, bytes32 codeHash,,,,) = hook.pools(id);
        if (
            address(request.key.hooks) != address(hook) || token == address(0) || !hook.initialized(id)
                || token.codehash != codeHash || request.key.fee != 0 || request.key.tickSpacing != 100
        ) revert UnknownPool();
        p = PoolMetadata(quoteAsset, kind, request.buy == (Currency.unwrap(request.key.currency0) == quoteAsset));
        if (address(eligibility) != address(0)) {
            eligibility.checkTrade(PoolId.unwrap(id), quoteAsset, payer, request.recipient, request.buy);
        }
    }

    function swap(SwapRequest calldata request) external payable nonReentrant returns (BalanceDelta delta) {
        (delta,) = _execute(request, msg.sender);
    }

    /// @notice Funded simulation, ALWAYS reverts; any caller may simulate a payer's
    /// approval without being able to persist transfers or allowance consumption.
    /// @dev Funded simulation follows execution through fee-claim redemption and
    /// input/output validation, including the first buy with empty quote reserves.
    function simulate(SwapRequest calldata request, address payer) external payable {
        try this.simulationBody{value: msg.value}(request, payer) returns (BalanceDelta delta, uint256 fee) {
            revert SimulationResult(BalanceDelta.unwrap(delta), fee);
        } catch (bytes memory reason) {
            // Only our successful execution above can produce the result envelope.
            // Token/eligibility/hook reverts cannot spoof a successful quotation.
            revert SimulationFailure(reason);
        }
    }

    function simulationBody(SwapRequest calldata request, address payer)
        external
        payable
        nonReentrant
        returns (BalanceDelta delta, uint256 fee)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        return _execute(request, payer);
    }

    function _execute(SwapRequest calldata request, address payer) private returns (BalanceDelta delta, uint256 fee) {
        PoolMetadata memory p = validateRequest(request, payer);
        uint256 budget = _budget(request);
        bool nativeInput = (p.zeroForOne ? request.key.currency0 : request.key.currency1).isAddressZero();
        if (nativeInput ? msg.value < budget : msg.value != 0) revert NativeValueMismatch();
        msgSender = payer;
        swapRecipient = request.recipient;
        (delta, fee) = abi.decode(manager.unlock(abi.encode(request, p.zeroForOne, budget)), (BalanceDelta, uint256));
        if (nativeInput && msg.value > budget) _refund(payer, msg.value - budget);
        msgSender = address(0);
        swapRecipient = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || msgSender == address(0)) revert UnauthorizedCallback();
        (SwapRequest memory request, bool zeroForOne, uint256 budget) = abi.decode(data, (SwapRequest, bool, uint256));
        Currency input = zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency output = zeroForOne ? request.key.currency1 : request.key.currency0;
        uint256 paid;
        // Match periphery DeltaResolver: native sync also clears stale ERC20 sync.
        manager.sync(input);
        if (input.isAddressZero()) {
            paid = manager.settle{value: budget}();
        } else {
            IERC20(Currency.unwrap(input)).safeTransferFrom(msgSender, address(manager), budget);
            paid = manager.settle();
        }
        if (paid != budget) revert InexactInput();
        uint160 limit = request.sqrtPriceLimitX96;
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        IV3RouterFeeTotals totals = IV3RouterFeeTotals(address(hook.ledger()));
        bytes32 id = PoolId.unwrap(request.key.toId());
        uint256 beforeFee = totals.totalReceived(id);
        BalanceDelta delta = manager.swap(request.key, SwapParams(zeroForOne, request.amountSpecified, limit), "");
        uint256 fee = totals.totalReceived(id) - beforeFee;
        totals.redeemClaims(id);
        int256 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int256 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert InvalidDelta();
        uint256 amountIn = uint256(-inputDelta);
        uint256 amountOut = uint256(outputDelta);
        if (request.amountSpecified < 0
                ? amountIn != uint256(-request.amountSpecified)
                : amountOut != uint256(request.amountSpecified)) revert PartialFillUnsupported();
        if (amountIn > request.maxIn || amountIn > budget || amountOut < request.minOut) revert SlippageExceeded();
        _takeExact(output, request.recipient, amountOut);
        if (budget > amountIn) _takeExact(input, msgSender, budget - amountIn);
        return abi.encode(delta, fee);
    }

    function _takeExact(Currency currency, address recipient, uint256 amount) private {
        if (currency.isAddressZero()) {
            // Native receivers may intentionally forward funds in their callback.
            manager.take(currency, recipient, amount);
            return;
        }
        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 beforeBalance = token.balanceOf(recipient);
        manager.take(currency, recipient, amount);
        uint256 afterBalance = token.balanceOf(recipient);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InexactOutput();
    }

    function _budget(SwapRequest calldata request) private pure returns (uint256 budget) {
        budget = request.amountSpecified < 0 ? uint256(-request.amountSpecified) : request.maxIn;
        if (budget > request.maxIn) revert SlippageExceeded();
    }

    function _refund(address payer, uint256 value) private {
        (bool ok,) = payable(payer).call{value: value}("");
        if (!ok) revert NativeRefundFailed();
    }
}

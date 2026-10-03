// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
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

/// @notice Same A-mode seam as V3Router: address(0) = default B mode.
interface IV3HopEligibility {
    function checkTrade(bytes32 poolId, address quoteAsset, address payer, address recipient, bool buy) external view;
}

interface IV3HopFeeTotals {
    function totalReceived(bytes32 poolId) external view returns (uint256);
    function redeemClaims(bytes32 poolId) external;
}

/// @title V3MultiHopRouter — USDC → STOCK.sol → meme (and back) in one transaction (design r6 §9.5)
/// @notice Two exact-input legs inside one v4 unlock: the fixed protocol pool A (native USDC / STOCK.sol,
///         1% LP fee, no hook) and one registered stock-quoted v3 hook pool whose quote asset is exactly
///         pool A's STOCK.sol. The hook still takes its 1% on the stock leg and the ledger redeems its
///         claims in the same unlock, as in V3Router. Full fill only; the user's minOut bounds the final
///         output; the intermediate STOCK.sol never leaves the manager. `quote` reports the pool-A exchange
///         fee separately (nominal 1% of the USDC or STOCK.sol entering pool A) and the actual hook fee.
///         No arbitrary pools, calldata, payer or recipient control beyond the request.
contract V3MultiHopRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct HopRequest {
        PoolKey memeKey; // registered v3 hook pool quoted in pool A's STOCK.sol
        bool buyMeme; // true: native USDC -> meme; false: meme -> native USDC
        uint256 amountIn; // exact input (native USDC 18 dp, or meme raw)
        uint256 minOut; // minimum final output to `recipient`
        address recipient;
        uint256 deadline;
    }

    IPoolManager public immutable manager;
    V3QuoteFeeHook public immutable hook;
    IV3HopEligibility public immutable eligibility;
    address public immutable stock; // pool A currency1
    uint24 public immutable poolAFee;
    int24 public immutable poolATickSpacing;
    address private _payer;

    error InvalidDependency();
    error UnknownPool();
    error InvalidRequest();
    error DeadlineExpired();
    error UnauthorizedCallback();
    error NativeValueMismatch();
    error PartialFillUnsupported();
    error SlippageExceeded();
    error OnlySelf();
    error SimulationResult(uint256 out, uint256 poolAFee, uint256 hookFee);
    error SimulationFailure(bytes reason);

    constructor(IPoolManager manager_, V3QuoteFeeHook hook_, PoolKey memory poolA, IV3HopEligibility eligibility_) {
        if (
            address(manager_).code.length == 0 || address(hook_.poolManager()) != address(manager_)
                || !poolA.currency0.isAddressZero() || address(poolA.hooks) != address(0)
                || Currency.unwrap(poolA.currency1).code.length == 0
                || (address(eligibility_) != address(0) && address(eligibility_).code.length == 0)
        ) revert InvalidDependency();
        manager = manager_;
        hook = hook_;
        eligibility = eligibility_;
        stock = Currency.unwrap(poolA.currency1);
        poolAFee = poolA.fee;
        poolATickSpacing = poolA.tickSpacing;
    }

    function poolA() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(stock), poolAFee, poolATickSpacing, IHooks(address(0)));
    }

    function swapExactIn(HopRequest calldata r) external payable nonReentrant returns (uint256 out) {
        (out,,) = _execute(r, msg.sender);
    }

    /// @notice Funded quote: runs the full swap inside a reverted call and reports its result; the value
    ///         sent to fund a buy simulation is returned. No swap state persists.
    function quote(HopRequest calldata r, address payer)
        external
        payable
        returns (uint256 out, uint256 feeA, uint256 hookFee)
    {
        try this.simulationBody{value: msg.value}(r, payer) {
            revert InvalidRequest();
        } catch (bytes memory reason) {
            if (reason.length == 100 && bytes4(reason) == SimulationResult.selector) {
                assembly {
                    out := mload(add(reason, 36))
                    feeA := mload(add(reason, 68))
                    hookFee := mload(add(reason, 100))
                }
                // The simulation reverted, so the funding value is still here: hand it back.
                if (msg.value > 0) {
                    (bool ok,) = payable(msg.sender).call{value: msg.value}("");
                    if (!ok) revert NativeValueMismatch();
                }
                return (out, feeA, hookFee);
            }
            revert SimulationFailure(reason);
        }
    }

    function simulationBody(HopRequest calldata r, address payer) external payable nonReentrant {
        if (msg.sender != address(this)) revert OnlySelf();
        (uint256 out, uint256 feeA, uint256 hookFee) = _execute(r, payer);
        revert SimulationResult(out, feeA, hookFee);
    }

    function _execute(HopRequest calldata r, address payer)
        private
        returns (uint256 out, uint256 feeA, uint256 hookFee)
    {
        if (block.timestamp > r.deadline) revert DeadlineExpired();
        if (r.amountIn == 0 || r.amountIn > uint128(type(int128).max) || r.recipient == address(0)) {
            revert InvalidRequest();
        }
        _validateMemePool(r.memeKey, payer, r.recipient, r.buyMeme);
        if (r.buyMeme ? msg.value != r.amountIn : msg.value != 0) revert NativeValueMismatch();
        _payer = payer;
        (out, feeA, hookFee) = abi.decode(manager.unlock(abi.encode(r)), (uint256, uint256, uint256));
        _payer = address(0);
    }

    function _validateMemePool(PoolKey calldata key, address payer, address recipient, bool buy) private view {
        PoolId id = key.toId();
        (address token, address quoteAsset,, bytes32 codeHash,,,,) = hook.pools(id);
        if (
            address(key.hooks) != address(hook) || token == address(0) || !hook.initialized(id)
                || token.codehash != codeHash || key.fee != 0 || key.tickSpacing != 100 || quoteAsset != stock
        ) revert UnknownPool();
        if (address(eligibility) != address(0)) {
            eligibility.checkTrade(PoolId.unwrap(id), quoteAsset, payer, recipient, buy);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || _payer == address(0)) revert UnauthorizedCallback();
        HopRequest memory r = abi.decode(data, (HopRequest));
        PoolKey memory a = poolA();
        bool stockIs0 = Currency.unwrap(r.memeKey.currency0) == stock;
        uint256 out;
        uint256 feeA;
        uint256 hookFee;
        if (r.buyMeme) {
            // Prepay the USDC so the ledger can redeem claims against settled reserves (as V3Router).
            manager.sync(a.currency0);
            manager.settle{value: r.amountIn}();
            uint256 stockOut = _leg(a, true, r.amountIn);
            feeA = r.amountIn * poolAFee / 1_000_000;
            uint256 beforeFee = _fees(r.memeKey);
            out = _leg(r.memeKey, stockIs0, stockOut);
            hookFee = _fees(r.memeKey) - beforeFee;
            IV3HopFeeTotals(address(hook.ledger())).redeemClaims(PoolId.unwrap(r.memeKey.toId()));
            if (out < r.minOut) revert SlippageExceeded();
            manager.take(stockIs0 ? r.memeKey.currency1 : r.memeKey.currency0, r.recipient, out);
        } else {
            Currency memeC = stockIs0 ? r.memeKey.currency1 : r.memeKey.currency0;
            manager.sync(memeC);
            IERC20(Currency.unwrap(memeC)).safeTransferFrom(_payer, address(manager), r.amountIn);
            if (manager.settle() != r.amountIn) revert PartialFillUnsupported();
            uint256 beforeFee = _fees(r.memeKey);
            uint256 stockOut = _leg(r.memeKey, !stockIs0, r.amountIn);
            hookFee = _fees(r.memeKey) - beforeFee;
            IV3HopFeeTotals(address(hook.ledger())).redeemClaims(PoolId.unwrap(r.memeKey.toId()));
            out = _leg(a, false, stockOut);
            feeA = stockOut * poolAFee / 1_000_000;
            if (out < r.minOut) revert SlippageExceeded();
            manager.take(a.currency0, r.recipient, out);
        }
        return abi.encode(out, feeA, hookFee);
    }

    /// @dev One exact-input swap that must fill completely; returns the output amount.
    function _leg(PoolKey memory key, bool zeroForOne, uint256 amountIn) private returns (uint256 amountOut) {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = manager.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        int128 inD = zeroForOne ? d.amount0() : d.amount1();
        int128 outD = zeroForOne ? d.amount1() : d.amount0();
        if (inD >= 0 || outD <= 0 || uint256(uint128(-inD)) != amountIn) revert PartialFillUnsupported();
        amountOut = uint256(uint128(outD));
    }

    function _fees(PoolKey memory key) private view returns (uint256) {
        return IV3HopFeeTotals(address(hook.ledger())).totalReceived(PoolId.unwrap(key.toId()));
    }
}

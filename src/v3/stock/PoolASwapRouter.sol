// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The two views of a StockPoolVault this router reads once, at construction.
interface IPoolAVault {
    function manager() external view returns (IPoolManager);
    function poolKey() external view returns (PoolKey memory);
}

/// @title PoolASwapRouter — single-hop exact-in swaps on the protocol's pool A (native USDC / STOCK.sol)
/// @notice New Solon code. Lets the stock page fill a buy or sell of STOCK.sol in one Arc transaction when pool A
///         can take it, instead of the cross-chain mint/redeem. Only the pool keys of the StockPoolVaults given at
///         construction are tradable (one per STOCK.sol; the caller names the stock, never the pool). Exact input,
///         full fill only, `minOut`, `deadline` and `recipient` on every swap. No fee of its own (pool A's 1% LP fee
///         goes to the vault), no owner, no upgrade, holds no funds between calls.
///         - buy: native USDC (`msg.value`, 18 dp) -> STOCK.sol;
///         - sell: STOCK.sol (pulled from the caller, needs an allowance) -> native USDC (18 dp, sub-1e12 tail kept).
///         `quote` runs the same swap inside the PoolManager and reverts it: no value, allowance or balance needed.
contract PoolASwapRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    struct Pool {
        uint24 fee;
        int24 tickSpacing;
        bool listed;
    }

    /// @notice Pool A's LP fee (1%), the only fee a swap here pays.
    uint24 public constant LP_FEE = 10_000;

    IPoolManager public immutable manager;
    mapping(address stock => Pool) private _pools;
    address[] private _stocks;
    address private _payer;

    event Swap(
        address indexed stock, address indexed payer, address indexed recipient, bool buy, uint256 amountIn, uint256 out
    );

    error InvalidDependency();
    error UnknownStock();
    error InvalidRequest();
    error DeadlineExpired();
    error PartialFill();
    error ZeroOutput();
    error SlippageExceeded();
    error UnauthorizedCallback();
    error QuoteResult(uint256 out, uint160 sqrtPriceAfterX96);

    /// @param manager_ pool A's PoolManager
    /// @param vaults the StockPoolVaults whose pool keys may be traded (fixed forever)
    constructor(IPoolManager manager_, IPoolAVault[] memory vaults) {
        if (address(manager_).code.length == 0 || vaults.length == 0) revert InvalidDependency();
        manager = manager_;
        for (uint256 i; i < vaults.length; ++i) {
            PoolKey memory k = vaults[i].poolKey();
            address stock = Currency.unwrap(k.currency1);
            if (
                vaults[i].manager() != manager_ || !k.currency0.isAddressZero() || address(k.hooks) != address(0)
                    || k.fee != LP_FEE || stock.code.length == 0 || _pools[stock].listed
            ) revert InvalidDependency();
            _pools[stock] = Pool(k.fee, k.tickSpacing, true);
            _stocks.push(stock);
        }
    }

    // ------------------------------------------------------------------ views

    function stocks() external view returns (address[] memory) {
        return _stocks;
    }

    function poolKey(address stock) public view returns (PoolKey memory) {
        Pool memory p = _pools[stock];
        if (!p.listed) revert UnknownStock();
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(stock), p.fee, p.tickSpacing, IHooks(address(0)));
    }

    /// @notice Pool A's current price and in-range liquidity (sqrtPriceX96 is STOCK.sol per native USDC).
    function poolState(address stock) external view returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity) {
        PoolKey memory k = poolKey(stock);
        (sqrtPriceX96, tick,,) = manager.getSlot0(k.toId());
        liquidity = manager.getLiquidity(k.toId());
    }

    // ------------------------------------------------------------------ swaps

    /// @notice Native USDC (`msg.value`, 18 dp) -> STOCK.sol to `recipient`.
    function buy(address stock, uint256 minOut, address recipient, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 out)
    {
        out = _swap(stock, true, msg.value, minOut, recipient, deadline);
    }

    /// @notice STOCK.sol `amountIn` (pulled from the caller) -> native USDC (18 dp) to `recipient`.
    function sell(address stock, uint256 amountIn, uint256 minOut, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 out)
    {
        out = _swap(stock, false, amountIn, minOut, recipient, deadline);
    }

    /// @notice What `buy` (`isBuy`) or `sell` of `amountIn` would pay out right now, and pool A's price after it.
    ///         Reverts (e.g. `PartialFill` when pool A cannot take the whole amount) exactly where the swap would.
    ///         Not a view (the swap runs and is reverted inside the PoolManager): call it with eth_call.
    function quote(address stock, bool isBuy, uint256 amountIn)
        external
        nonReentrant
        returns (uint256 out, uint160 sqrtPriceAfterX96)
    {
        PoolKey memory k = poolKey(stock);
        _checkAmount(amountIn);
        try manager.unlock(abi.encode(true, k, isBuy, amountIn, uint256(0), address(0))) {
            revert InvalidRequest(); // unreachable: the quote callback always reverts
        } catch (bytes memory reason) {
            if (reason.length == 68 && bytes4(reason) == QuoteResult.selector) {
                assembly {
                    out := mload(add(reason, 36))
                    sqrtPriceAfterX96 := mload(add(reason, 68))
                }
                return (out, sqrtPriceAfterX96);
            }
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _swap(address stock, bool isBuy, uint256 amountIn, uint256 minOut, address recipient, uint256 deadline)
        private
        returns (uint256 out)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (recipient == address(0)) revert InvalidRequest();
        PoolKey memory k = poolKey(stock);
        _checkAmount(amountIn);
        _payer = msg.sender;
        out = abi.decode(manager.unlock(abi.encode(false, k, isBuy, amountIn, minOut, recipient)), (uint256));
        _payer = address(0);
        emit Swap(stock, msg.sender, recipient, isBuy, amountIn, out);
    }

    function _checkAmount(uint256 amountIn) private pure {
        if (amountIn == 0 || amountIn > uint128(type(int128).max)) revert InvalidRequest();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert UnauthorizedCallback();
        (bool isQuote, PoolKey memory k, bool isBuy, uint256 amountIn, uint256 minOut, address recipient) =
            abi.decode(data, (bool, PoolKey, bool, uint256, uint256, address));
        // buy: currency0 (native USDC) in, zeroForOne; sell: currency1 (STOCK.sol) in.
        uint160 limit = isBuy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = manager.swap(k, SwapParams(isBuy, -int256(amountIn), limit), "");
        int128 inD = isBuy ? d.amount0() : d.amount1();
        int128 outD = isBuy ? d.amount1() : d.amount0();
        if (inD >= 0 || uint256(uint128(-inD)) != amountIn) revert PartialFill();
        if (outD <= 0) revert ZeroOutput();
        uint256 out = uint256(uint128(outD));
        if (isQuote) {
            (uint160 sqrtAfter,,,) = manager.getSlot0(k.toId());
            revert QuoteResult(out, sqrtAfter);
        }
        if (_payer == address(0)) revert UnauthorizedCallback();
        if (out < minOut) revert SlippageExceeded();
        if (isBuy) {
            manager.sync(k.currency0);
            manager.settle{value: amountIn}();
            manager.take(k.currency1, recipient, out);
        } else {
            manager.sync(k.currency1);
            IERC20(Currency.unwrap(k.currency1)).safeTransferFrom(_payer, address(manager), amountIn);
            if (manager.settle() != amountIn) revert PartialFill();
            manager.take(k.currency0, recipient, out);
        }
        return abi.encode(out);
    }
}

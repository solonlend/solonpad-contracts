// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SignatureChecker
} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

interface IStockOrderHub {
    function requestBuy(address underlying, uint256 usdcIn, uint256 minSharesOut) external payable returns (uint256);
    function requestSell(address underlying, uint256 sharesIn, uint256 minUsdcOut) external payable returns (uint256);
    function cancel(uint256 id) external;
    function escalate(uint256 id, address to) external payable;
    function escalateFunds(uint256 id, address to) external payable;
}

/// @title StockPoolVault — protocol-owned NVDA.sol/USDC liquidity ("pool A", design r6 §9.5)
/// @notice New Solon code. Holds the protocol's position in one plain v4 pool (native USDC / STOCK.sol,
///         1% LP fee, no hook), so stock-quoted meme buyers can get STOCK.sol in the same transaction as
///         their USDC (V3MultiHopRouter). The off-chain range/restock bot drives it through three narrow
///         doors, each bound to a signed reference price from the fixed quote signer:
///         - `rebalanceRange`: move the whole position to a new narrow range around the reference;
///         - `pushPrice`: swap idle inventory toward the reference, never past it (anchoring, §9.5 >1.3%);
///         - `restockMint`/`restockRedeem`: real mint/redeem through the stock hub for this vault only, with
///           minimums bound to the signed reference and its signed tolerance (never 0, review #7);
///         - `cancelRestock`/`escalateRestock`/`escalateRestockFunds`: the hub's exits for the vault's own
///           orders, the canonical ones only to the fixed reserve-chain `reserveRecipient` (review #7).
///         LP fees stay in the vault; funds leave only to the fixed treasury through the owner (timelock).
///         There is no arbitrary call, recipient or pool.
contract StockPoolVault is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint24 public constant LP_FEE = 10_000; // 1%
    int24 public constant TICK_SPACING = 200;
    /// @notice Widest position allowed (±~10% around the reference; the plan is ±~2%).
    int24 public constant MAX_WIDTH = 4_000;
    /// @notice Largest tolerance a signed reference may carry (~2%).
    uint24 public constant MAX_DEVIATION = 200;
    /// @notice Largest gap between the pool price and the reference at which liquidity is re-added (~0.5%).
    uint24 public constant RANGE_DEVIATION = 50;
    /// @notice The stock hub's service fee, taken into account by the restock minimums.
    uint256 public constant HUB_FEE_BPS = 25;
    /// @notice Native USDC paid for each canonical send (the gate's 1 USDC hook).
    uint256 public constant HOOK_FEE = 1 ether;
    bytes32 public constant SALT = bytes32(uint256(1));

    struct Config {
        IPoolManager manager;
        address token; // STOCK.sol on Arc
        address underlying; // its RH underlying, as the hub lists it
        address hub;
        address treasury;
        address keeper;
        address priceSigner;
        address owner; // timelock
        address reserveRecipient; // fixed reserve-chain (RH) recipient of canonical exits
    }

    struct PriceQuote {
        int24 refTick; // reference price as a tick of this pool (STOCK.sol per native USDC)
        uint24 maxDeviation; // ticks the current pool price may be away from it
        uint256 deadline;
        uint256 nonce;
    }

    IPoolManager public immutable manager;
    address public immutable token;
    address public immutable underlying;
    IStockOrderHub public immutable hub;
    address public immutable treasury;
    address public immutable keeper;
    address public immutable priceSigner;
    address public immutable owner;
    address public immutable reserveRecipient;

    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    uint256 public lpFees0;
    uint256 public lpFees1;
    mapping(uint256 => bool) public nonceUsed;

    event Initialized(uint160 sqrtPriceX96);
    event RangeSet(int24 tickLower, int24 tickUpper, uint128 liquidity, int24 refTick);
    event PricePushed(int24 fromTick, int24 toTick, int24 refTick);
    event Restock(bool mint, uint256 hubOrderId, uint256 amount, uint256 value);
    event Exited(uint128 liquidity);
    event Withdrawn(uint256 native, uint256 stock);

    error NotKeeper();
    error NotOwner();
    error BadQuote();
    error BadRange();
    error PriceDeviation();
    error OnlyManager();
    error TransferFailed();
    error Slippage();

    enum Op {
        Range,
        Push,
        Exit
    }

    constructor(Config memory c) {
        require(
            address(c.manager) != address(0) && c.token != address(0) && c.underlying != address(0)
                && c.hub != address(0) && c.treasury != address(0) && c.keeper != address(0)
                && c.priceSigner != address(0) && c.owner != address(0) && c.reserveRecipient != address(0)
        );
        manager = c.manager;
        token = c.token;
        underlying = c.underlying;
        hub = IStockOrderHub(c.hub);
        treasury = c.treasury;
        keeper = c.keeper;
        priceSigner = c.priceSigner;
        owner = c.owner;
        reserveRecipient = c.reserveRecipient;
    }

    receive() external payable {}

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner) revert NotKeeper();
        _;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), LP_FEE, TICK_SPACING, IHooks(address(0)));
    }

    function currentTick() public view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolKey().toId());
    }

    function quoteDigest(PriceQuote memory q) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("SolonStockPoolQuote(int24 refTick,uint24 maxDeviation,uint256 deadline,uint256 nonce)"),
                q.refTick,
                q.maxDeviation,
                q.deadline,
                q.nonce,
                block.chainid,
                address(this),
                PoolId.unwrap(poolKey().toId())
            )
        );
    }

    // ------------------------------------------------------------------ owner

    function initialize(uint160 sqrtPriceX96) external onlyOwner {
        manager.initialize(poolKey(), sqrtPriceX96);
        emit Initialized(sqrtPriceX96);
    }

    /// @notice Remove the whole position (fees collected); funds stay in the vault.
    function exit() external onlyOwner nonReentrant {
        uint128 l = liquidity;
        manager.unlock(abi.encode(Op.Exit, int24(0), int24(0), uint256(0), int24(0)));
        emit Exited(l);
    }

    /// @notice Idle funds to the fixed treasury only.
    function withdraw(uint256 nativeAmount, uint256 stockAmount) external onlyOwner nonReentrant {
        if (nativeAmount > 0) {
            (bool ok,) = treasury.call{value: nativeAmount}("");
            if (!ok) revert TransferFailed();
        }
        if (stockAmount > 0) IERC20(token).safeTransfer(treasury, stockAmount);
        emit Withdrawn(nativeAmount, stockAmount);
    }

    // ------------------------------------------------------------------ keeper

    /// @notice Move the whole position to a new narrow range around the signed reference. Liquidity is only
    ///         re-added while the pool sits at the reference (within `RANGE_DEVIATION`) and inside the range.
    function rebalanceRange(int24 lower, int24 upper, PriceQuote calldata q, bytes calldata sig)
        external
        onlyKeeper
        nonReentrant
    {
        _useQuote(q, sig);
        int24 tick = currentTick();
        int24 gap = tick > q.refTick ? tick - q.refTick : q.refTick - tick;
        if (uint24(gap) > q.maxDeviation || uint24(gap) > RANGE_DEVIATION) revert PriceDeviation();
        if (
            lower >= upper || upper - lower > MAX_WIDTH || lower % TICK_SPACING != 0 || upper % TICK_SPACING != 0
                || q.refTick <= lower || q.refTick >= upper || tick < lower || tick >= upper
        ) revert BadRange();
        manager.unlock(abi.encode(Op.Range, lower, upper, uint256(0), q.refTick));
        emit RangeSet(lower, upper, liquidity, q.refTick);
    }

    /// @notice Swap up to `maxIn` of idle inventory toward the signed reference, stopping exactly at it.
    ///         The direction follows the price gap; the keeper does not choose it. Works at any distance:
    ///         anchoring is needed exactly when the pool is far away, and it can never cross the reference.
    function pushPrice(PriceQuote calldata q, bytes calldata sig, uint256 maxIn) external onlyKeeper nonReentrant {
        _useQuote(q, sig);
        int24 fromTick = currentTick();
        if (fromTick == q.refTick || maxIn == 0) revert BadRange();
        manager.unlock(abi.encode(Op.Push, int24(0), int24(0), maxIn, q.refTick));
        emit PricePushed(fromTick, currentTick(), q.refTick);
    }

    /// @notice Mint STOCK.sol through the stock layer with idle USDC (a real RH purchase); the shares and
    ///         any unused fee reserve come back to this vault. `minShares` must be at least what the signed
    ///         reference, moved by its signed tolerance against the vault, gives after the hub fee.
    function restockMint(
        uint256 usdcIn,
        uint256 minShares,
        uint256 feeReserve,
        PriceQuote calldata q,
        bytes calldata sig
    ) external onlyKeeper nonReentrant {
        _useQuote(q, sig);
        uint160 p = TickMath.getSqrtPriceAtTick(q.refTick - int24(q.maxDeviation));
        uint256 shares = FullMath.mulDiv(FullMath.mulDiv(usdcIn, p, 1 << 96), p, 1 << 96);
        if (minShares == 0 || minShares < (shares * (10_000 - HUB_FEE_BPS)) / 10_000) revert Slippage();
        uint256 id = hub.requestBuy{value: usdcIn + feeReserve}(underlying, usdcIn, minShares);
        emit Restock(true, id, usdcIn, usdcIn + feeReserve);
    }

    /// @notice Redeem idle STOCK.sol to USDC through the stock layer; the proceeds come back to this vault.
    ///         `minUsdc` is bound to the signed reference the same way.
    function restockRedeem(uint256 shares, uint256 minUsdc, uint256 lzFee, PriceQuote calldata q, bytes calldata sig)
        external
        onlyKeeper
        nonReentrant
    {
        _useQuote(q, sig);
        uint160 p = TickMath.getSqrtPriceAtTick(q.refTick + int24(q.maxDeviation));
        uint256 usdc = FullMath.mulDiv(FullMath.mulDiv(shares, 1 << 96, p), 1 << 96, p);
        if (minUsdc == 0 || minUsdc < (usdc * (10_000 - HUB_FEE_BPS)) / 10_000) revert Slippage();
        uint256 id = hub.requestSell{value: lzFee}(underlying, shares, minUsdc);
        emit Restock(false, id, shares, lzFee);
    }

    // ------------------------------------------------------------------ exits for the vault's own orders

    /// @notice Cancel a restock buy (queued: refunded at once; sent: when its money comes back).
    function cancelRestock(uint256 id) external onlyKeeperOrOwner nonReentrant {
        hub.cancel(id);
    }

    /// @notice A stuck restock sell goes canonical; the proceeds go to the fixed reserve-chain recipient.
    function escalateRestock(uint256 id) external onlyKeeperOrOwner nonReentrant {
        hub.escalate{value: HOOK_FEE}(id, reserveRecipient);
    }

    /// @notice Stuck restock money (failed buy, unreturned proceeds, unanswered cancelled buy) goes to the
    ///         fixed reserve-chain recipient through the canonical lane.
    function escalateRestockFunds(uint256 id) external onlyKeeperOrOwner nonReentrant {
        hub.escalateFunds{value: HOOK_FEE}(id, reserveRecipient);
    }

    // ------------------------------------------------------------------ v4

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert OnlyManager();
        (Op op, int24 lower, int24 upper, uint256 maxIn, int24 refTick) =
            abi.decode(data, (Op, int24, int24, uint256, int24));
        PoolKey memory key = poolKey();
        if (op == Op.Push) {
            _push(key, maxIn, refTick);
            return "";
        }
        _removeAll(key);
        if (op == Op.Range) _addAll(key, lower, upper);
        return "";
    }

    function _removeAll(PoolKey memory key) private {
        uint128 l = liquidity;
        if (l == 0) return;
        (BalanceDelta delta, BalanceDelta fees) =
            manager.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, -int256(uint256(l)), SALT), "");
        liquidity = 0;
        lpFees0 += uint128(fees.amount0());
        lpFees1 += uint128(fees.amount1());
        _settle(key, delta);
    }

    function _addAll(PoolKey memory key, int24 lower, int24 upper) private {
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        uint128 l = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            address(this).balance,
            IERC20(token).balanceOf(address(this))
        );
        tickLower = lower;
        tickUpper = upper;
        if (l == 0) return;
        (BalanceDelta delta, BalanceDelta fees) =
            manager.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(uint256(l)), SALT), "");
        liquidity = l;
        lpFees0 += uint128(fees.amount0());
        lpFees1 += uint128(fees.amount1());
        _settle(key, delta);
    }

    function _push(PoolKey memory key, uint256 maxIn, int24 refTick) private {
        int24 tick = currentTick();
        // tick below the reference: STOCK.sol is dear in the pool -> sell STOCK.sol in (price up).
        bool zeroForOne = tick > refTick;
        uint256 have = zeroForOne ? address(this).balance : IERC20(token).balanceOf(address(this));
        if (maxIn > have) maxIn = have;
        BalanceDelta delta =
            manager.swap(key, SwapParams(zeroForOne, -int256(maxIn), TickMath.getSqrtPriceAtTick(refTick)), "");
        _settle(key, delta);
    }

    /// @dev Pay what the vault owes the manager, take what it is owed.
    function _settle(PoolKey memory key, BalanceDelta delta) private {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0) {
            manager.sync(key.currency0);
            manager.settle{value: uint256(uint128(-a0))}();
        } else if (a0 > 0) {
            manager.take(key.currency0, address(this), uint256(uint128(a0)));
        }
        if (a1 < 0) {
            manager.sync(key.currency1);
            IERC20(token).safeTransfer(address(manager), uint256(uint128(-a1)));
            manager.settle();
        } else if (a1 > 0) {
            manager.take(key.currency1, address(this), uint256(uint128(a1)));
        }
    }

    function _useQuote(PriceQuote calldata q, bytes calldata sig) private {
        if (
            block.timestamp > q.deadline || nonceUsed[q.nonce] || q.maxDeviation > MAX_DEVIATION
                || !SignatureChecker.isValidSignatureNow(priceSigner, quoteDigest(q), sig)
        ) revert BadQuote();
        nonceUsed[q.nonce] = true;
    }
}

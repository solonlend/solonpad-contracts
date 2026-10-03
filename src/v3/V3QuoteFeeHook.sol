// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

interface IV3HookFeeLedger {
    function creditClaims(bytes32 poolId, uint256 amount) external;
}

interface IV3InitialPositionStrategy {
    /// @dev Nonzero only while the bound strategy is creating its initial position;
    /// returns keccak256(abi.encode(ModifyLiquidityParams)) for that pool.
    function initialPositionContext(bytes32 poolId) external view returns (bytes32);
}

interface IV3PositionPayer {
    function msgSender() external view returns (address);
}

/// @notice Fixed one-percent quote fee; each successful swap credits the ledger atomically.
/// @dev Fees are minted as ERC6909 claims; the ledger redeems after settlement.
/// No router/unlock entrypoint: core must never skip callbacks via a self-hook swap.
/// Factory/Strategy/PositionManager are deployment trust boundaries. The later launch
/// phase supplies the allowlisted stock registry, live launch context and permanent LP locker.
contract V3QuoteFeeHook is BaseHook {
    bytes32 private constant RECEIPT_SLOT = keccak256("solon.v3.quote.receipt");
    bytes32 private constant FEE_SLOT = keccak256("solon.v3.quote.fee");
    error InvalidSwap();
    error NestedSwap();
    error InvalidReceipt();
    error PartialFillUnsupported();
    error AmountOverflow();
    event QuoteFeeCollected(PoolId indexed poolId, address indexed quoteAsset, uint256 amount);

    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    struct PoolRegistration {
        address token;
        address quoteAsset;
        uint8 quoteKind; // 0 = native USDC18; 1 = direct stock raw units.
        bytes32 tokenCodeHash;
        address strategy;
        address positionManager;
        uint160 initialSqrtPriceX96;
        bytes32 initialPositionHash; // keccak256(abi.encode(ModifyLiquidityParams)); salt = NFT tokenId.
    }
    error InvalidInitialPosition();
    mapping(PoolId => uint256) public initialPositionId;
    error NotFactory();
    error AlreadyRegistered();
    error InvalidPoolKey();
    error UnknownPool();
    error InvalidInitialization();
    error InvalidTokenCode();
    mapping(PoolId => PoolRegistration) public pools;
    mapping(PoolId => bool) public initialized;
    address public immutable factory;
    IV3HookFeeLedger public immutable ledger;

    constructor(IPoolManager manager_, address factory_, IV3HookFeeLedger ledger_) BaseHook(manager_) {
        require(
            address(manager_) != address(0) && factory_ != address(0) && address(ledger_) != address(0), "zero address"
        );
        factory = factory_;
        ledger = ledger_;
    }

    /// @dev Factory is the immutable stock allowlist/code provenance trust boundary.
    function registerPool(PoolKey calldata key, PoolRegistration calldata r) public {
        if (msg.sender != factory) revert NotFactory();
        PoolId id = key.toId();
        if (pools[id].token != address(0)) revert AlreadyRegistered();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (
            address(key.hooks) != address(this) || key.fee != 0 || key.tickSpacing != 100 || c0 >= c1
                || r.token == address(0) || r.token == r.quoteAsset
                || !((c0 == r.token && c1 == r.quoteAsset) || (c1 == r.token && c0 == r.quoteAsset)) || r.quoteKind > 1
                || (r.quoteKind == 0) != (r.quoteAsset == address(0))
                || (r.quoteKind == 1 && r.quoteAsset.code.length == 0) || r.strategy.code.length == 0
                || r.positionManager.code.length == 0 || r.initialSqrtPriceX96 == 0
                || r.initialPositionHash == bytes32(0)
        ) revert InvalidPoolKey();
        if (r.token.code.length == 0 || r.token.codehash != r.tokenCodeHash) revert InvalidTokenCode();
        pools[id] = r;
    }

    mapping(PoolId => bool) public legacyPool;

    /// @notice Existing SOLON pools use governance-funded canonical positions.
    function registerLegacyPool(PoolKey calldata key, PoolRegistration calldata r) external {
        if (r.quoteKind != 1) revert InvalidPoolKey();
        registerPool(key, r);
        legacyPool[key.toId()] = true;
    }

    function _pool(PoolKey calldata key) internal view returns (PoolRegistration storage r) {
        r = pools[key.toId()];
        if (r.token == address(0)) revert UnknownPool();
        if (r.token.code.length == 0 || r.token.codehash != r.tokenCodeHash) revert InvalidTokenCode();
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 price) internal override returns (bytes4) {
        PoolRegistration storage r = _pool(key);
        PoolId id = key.toId();
        if (initialized[id] || sender != r.strategy || price != r.initialSqrtPriceX96) revert InvalidInitialization();
        initialized[id] = true;
        return IHooks.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolRegistration storage r = _pool(key);
        PoolId id = key.toId();
        if (legacyPool[id]) {
            if (
                !initialized[id] || hookData.length != 0 || params.salt == 0 || params.liquidityDelta <= 0
                    || sender != r.positionManager || IV3PositionPayer(sender).msgSender() != r.strategy
            ) {
                revert InvalidInitialPosition();
            }
            if (initialPositionId[id] == 0) initialPositionId[id] = uint256(params.salt);
            return IHooks.beforeAddLiquidity.selector;
        }
        // Canonical PositionManager.msgSender() is its locker and settlement payer.
        // Authenticating the public PositionManager address alone would let anyone add LP.
        bytes32 context = keccak256(abi.encode(params));
        if (
            !initialized[id] || initialPositionId[id] != 0 || hookData.length != 0 || params.salt == bytes32(0)
                || params.liquidityDelta <= 0 || sender != r.positionManager || context != r.initialPositionHash
                || IV3PositionPayer(sender).msgSender() != r.strategy
                || IV3InitialPositionStrategy(r.strategy).initialPositionContext(PoolId.unwrap(id)) != context
        ) {
            revert InvalidInitialPosition();
        }
        initialPositionId[id] = uint256(params.salt);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_load(RECEIPT_SLOT) != 0) revert NestedSwap();
        PoolRegistration storage r = _pool(key);
        if (!initialized[key.toId()] || hookData.length != 0 || params.amountSpecified == 0) revert InvalidSwap();
        if (params.amountSpecified > type(int128).max || params.amountSpecified < -int256(type(int128).max)) {
            revert AmountOverflow();
        }
        bool buy = params.zeroForOne == (Currency.unwrap(key.currency0) == r.quoteAsset);
        bool exactIn = params.amountSpecified < 0;
        uint256 amount = uint256(exactIn ? -params.amountSpecified : params.amountSpecified);
        // Quote specified: exact-in buy ceil(G/100); exact-out sell ceil(N/99),
        // equivalently ceil(100*N/99)-N. Bounds above make both additions safe.
        uint256 fee = buy == exactIn ? (exactIn ? (amount + 99) / 100 : (amount + 98) / 99) : 0;
        if (exactIn && amount <= fee) revert InvalidSwap();
        if (!exactIn && amount + fee > uint256(uint128(type(int128).max))) revert AmountOverflow();
        // Transient receipt cannot outlive this transaction. Manager callbacks are
        // synchronous; one outstanding receipt binds the pool, caller and exact params.
        // It stays locked through mint, ledger accounting and receiver callbacks.
        _store(RECEIPT_SLOT, uint256(keccak256(abi.encode(sender, key, params))));
        _store(FEE_SLOT, fee);
        if (fee != 0) _mintFee(r.quoteAsset, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        bytes32 receipt = bytes32(_load(RECEIPT_SLOT));
        if (receipt == 0 || receipt != keccak256(abi.encode(sender, key, params)) || hookData.length != 0) {
            revert InvalidReceipt();
        }
        PoolRegistration storage r = _pool(key);
        uint256 fee = _load(FEE_SLOT);
        // afterSwap receives CORE deltas, before Hooks.sol subtracts our return delta.
        // Validate full fill before turning either temporary claim into a fee lot.
        int256 coreSpecified = (params.amountSpecified < 0) == params.zeroForOne ? delta.amount0() : delta.amount1();
        if (coreSpecified != params.amountSpecified + int256(fee)) revert PartialFillUnsupported();
        int256 q = Currency.unwrap(key.currency0) == r.quoteAsset ? delta.amount0() : delta.amount1();
        int256 m = Currency.unwrap(key.currency0) == r.quoteAsset ? delta.amount1() : delta.amount0();
        bool buy = params.zeroForOne == (Currency.unwrap(key.currency0) == r.quoteAsset);
        if (buy ? (q >= 0 || m <= 0) : (q <= 0 || m >= 0)) revert InvalidSwap();
        int128 afterFee;
        if (fee == 0) {
            // Quote unspecified: exact-out buy ceil(Q/99); exact-in sell ceil(G/100).
            uint256 quoteAmount = uint256(buy ? -q : q);
            fee = buy ? (quoteAmount + 98) / 99 : (quoteAmount + 99) / 100;
            if (!buy && quoteAmount <= fee) revert InvalidSwap();
            if (buy && quoteAmount + fee > uint256(uint128(type(int128).max))) revert AmountOverflow();
            afterFee = int128(int256(fee));
            _mintFee(r.quoteAsset, fee);
        }
        _credit(key.toId(), r, fee);
        _store(FEE_SLOT, 0);
        _store(RECEIPT_SLOT, 0);
        return (IHooks.afterSwap.selector, afterFee);
    }

    function _mintFee(address quote, uint256 fee) private {
        poolManager.mint(address(ledger), Currency.wrap(quote).toId(), fee);
    }

    function _credit(PoolId id, PoolRegistration storage r, uint256 fee) private {
        ledger.creditClaims(PoolId.unwrap(id), fee);
        emit QuoteFeeCollected(id, r.quoteAsset, fee);
    }

    function _load(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _store(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") { tstore(slot, value) }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }
}

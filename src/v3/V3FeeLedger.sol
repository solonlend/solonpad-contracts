// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IV3FeeLedger, IV3FeeReceiver} from "./interfaces/IV3FeeLedger.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";

interface IV3LedgerHook {
    function poolManager() external view returns (IPoolManager);
}

/// @notice Immutable six-way custody ledger for registered v3 pool fee receipts.
/// @dev Kind 0 uses native USDC18; kind 1 uses an independent stock raw unit.
/// Pool registration is the trusted factory's asset/module admission boundary.
/// Fractional bucket ownership stays in bps remainders; unallocated whole units
/// back those fractions and can never be claimed by the protocol as surplus.
contract V3FeeLedger is IV3FeeLedger, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    mapping(bytes32 => uint256) public pendingClaims;
    mapping(bytes32 => IPoolManager) public claimsManager;
    // ERC6909 balances are shared across pools, so reserve backing by issuer and currency.
    mapping(address => mapping(uint256 => uint256)) public reservedClaims;
    address private redemptionManager;
    bytes32 private redemptionCallback;

    mapping(bytes32 => mapping(uint256 => uint256)) public accrued;
    mapping(bytes32 => mapping(uint256 => uint256)) public remainder;
    mapping(bytes32 => uint256) public totalReceived;
    mapping(bytes32 => uint256) public totalPaid;
    mapping(bytes32 => uint256) public nextLotId;
    mapping(bytes32 => mapping(uint8 => bool)) public stockLotCustody;
    mapping(bytes32 => mapping(uint8 => bool)) public controlledClaim;

    function enableControlledClaim(bytes32 poolId, uint8 bucket) external {
        require(bucket >= 4 && bucket < 6 && totalReceived[poolId] == 0);
        if (msg.sender != pools[poolId].beneficiaries[bucket]) revert Unauthorized();
        controlledClaim[poolId][bucket] = true;
    }
    mapping(bytes32 => mapping(uint256 => mapping(uint8 => uint256))) public stockLotAmount;

    /// @notice A fixed converter opts in before the first receipt; only buckets 4/5.
    function enableStockLotCustody(bytes32 poolId, uint8 bucket) external {
        Pool storage p = pools[poolId];
        require(bucket >= 4 && bucket < 6 && p.settlementKind == 1 && totalReceived[poolId] == 0);
        if (msg.sender != p.beneficiaries[bucket]) revert Unauthorized();
        stockLotCustody[poolId][bucket] = true;
    }

    function claimStockLot(bytes32 poolId, uint256 lotId, uint8 bucket) external nonReentrant returns (uint256 amount) {
        if (msg.sender != pools[poolId].beneficiaries[bucket]) revert Unauthorized();
        require(stockLotCustody[poolId][bucket]);
        amount = stockLotAmount[poolId][lotId][bucket];
        require(amount != 0);
        delete stockLotAmount[poolId][lotId][bucket];
        require(_claim(poolId, bucket, amount, false), "Lot payment failed");
    }

    /// @notice Whole raw units backing the six buckets' fractional interests.
    /// @dev This is shared escrow, never a seventh beneficiary or protocol income.
    function roundingReserve(bytes32 poolId) external view returns (uint256 reserve) {
        for (uint256 i; i < 6; ++i) {
            reserve += remainder[poolId][i];
        }
        return reserve / 10000;
    }

    function poolInfo(bytes32 poolId) external view returns (Pool memory) {
        return pools[poolId];
    }
    address public immutable factory;
    address public immutable nativeUsdcView;

    struct Pool {
        address quote;
        uint8 settlementKind;
        address hook;
        address[6] beneficiaries;
    }
    mapping(bytes32 => Pool) private pools;
    event PoolRegistered(
        bytes32 indexed poolId, address indexed quote, uint8 settlementKind, address hook, address[6] beneficiaries
    );
    event DirectStockCredited(bytes32 indexed poolId, uint256 indexed lotId, address indexed asset, uint256 amount);
    event FeeCredited(
        bytes32 indexed poolId, uint256 indexed lotId, address indexed quote, uint256 amount, uint256[6] allocated
    );
    event Claimed(bytes32 indexed poolId, uint8 indexed bucket, address indexed recipient, uint256 amount);
    event ClaimFailed(bytes32 indexed poolId, uint8 indexed bucket, uint256 amount);
    error Unauthorized();
    error InvalidPool();

    /// @param nativeUsdcView_ Zero disables the Arc-specific 6-decimal payout path.
    /// Nonzero must be the chain's verified ERC20 view of the same native balance.
    constructor(address factory_, address nativeUsdcView_) {
        require(factory_ != address(0));
        factory = factory_;
        nativeUsdcView = nativeUsdcView_;
    }

    mapping(bytes32 => bytes32) public legacyHolderPool;
    mapping(bytes32 => bytes32) public legacyHolderSource;

    /// @notice Only the factory admits the fixed staking sink; creator rights remain bucket 1.
    function registerLegacyPool(bytes32 poolId, address quote, address hook, address[6] calldata beneficiaries)
        external
    {
        if (msg.sender != factory) revert Unauthorized();
        if (beneficiaries[0] != beneficiaries[3]) revert InvalidPool();
        registerPool(poolId, quote, 1, hook, beneficiaries);
        bytes32 source = keccak256(abi.encode(keccak256("SOLON_NVDA_POOL"), poolId));
        legacyHolderSource[poolId] = source;
        legacyHolderPool[source] = poolId;
        controlledClaim[poolId][0] = true;
    }

    function registerPool(bytes32 poolId, address quote, uint8 kind, address hook, address[6] calldata beneficiaries)
        public
    {
        if (msg.sender != factory) revert Unauthorized();
        if (pools[poolId].hook != address(0) || hook == address(0) || kind > 1 || (kind == 0) != (quote == address(0))) revert InvalidPool();
        if (quote != address(0) && (quote.code.length == 0 || quote == nativeUsdcView)) revert InvalidPool();
        for (uint256 i; i < 6; ++i) {
            if (beneficiaries[i] == address(0) || beneficiaries[i] == address(this)) revert InvalidPool();
            if ((i == 0 || i == 2 || i == 3) && beneficiaries[i].code.length == 0) revert InvalidPool();
        }
        pools[poolId] = Pool(quote, kind, hook, beneficiaries);
        // Admission is atomic with registration: a first swap cannot race a
        // keeper's later opt-in and strand operating revenue. Legacy receivers
        // without this marker keep their existing claim behavior.
        for (uint8 bucket = 2; bucket < 6; ++bucket) {
            (bool ok, bytes memory data) =
                beneficiaries[bucket].staticcall{gas: 20000}(abi.encodeWithSignature("feeCustodyMode()"));
            if (ok && data.length == 32) {
                uint256 mode = abi.decode(data, (uint256));
                if (mode == 3 && bucket <= 3) {
                    // Reward custodians account funding during their authenticated pull.
                    // An outsider must not consume that backing ahead of it.
                    controlledClaim[poolId][bucket] = true;
                } else if (bucket <= 3) {
                    if (mode != 0) revert InvalidPool();
                } else if (mode == 1) {
                    if (kind != 0) revert InvalidPool();
                    controlledClaim[poolId][bucket] = true;
                } else if (mode == 2) {
                    if (kind != 1) revert InvalidPool();
                    stockLotCustody[poolId][bucket] = true;
                }
            }
        }
        nextLotId[poolId] = 1;
        emit PoolRegistered(poolId, quote, kind, hook, beneficiaries);
    }

    function creditNative(bytes32 poolId) external payable nonReentrant {
        if (pools[poolId].hook != msg.sender) revert Unauthorized();
        if (pools[poolId].quote != address(0)) revert InvalidPool();
        _credit(poolId, msg.value);
    }

    /// @notice Allocate newly minted PoolManager claims without requiring cash during swap.
    function creditClaims(bytes32 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        if (pool.hook != msg.sender) revert Unauthorized();
        IPoolManager manager = IV3LedgerHook(pool.hook).poolManager();
        IPoolManager previous = claimsManager[poolId];
        if (address(previous) != address(0) && previous != manager) revert InvalidPool();
        uint256 currencyId = Currency.wrap(pool.quote).toId();
        uint256 reserved = reservedClaims[address(manager)][currencyId] + amount;
        require(manager.balanceOf(address(this), currencyId) >= reserved, "Unbacked claims");
        claimsManager[poolId] = manager;
        reservedClaims[address(manager)][currencyId] = reserved;
        pendingClaims[poolId] += amount;
        _credit(poolId, amount);
    }

    /// @notice Convert this pool's existing claims into custody, without a second fee lot.
    function redeemClaims(bytes32 poolId) external nonReentrant {
        if (pools[poolId].hook == address(0)) revert InvalidPool();
        _redeemClaims(poolId);
    }

    function _redeemClaims(bytes32 poolId) internal {
        uint256 amount = pendingClaims[poolId];
        if (amount == 0) return;
        IPoolManager manager = claimsManager[poolId];
        redemptionManager = address(manager);
        if (manager.isUnlocked()) {
            _burnAndTake(poolId);
        } else {
            bytes memory data = abi.encode(poolId);
            redemptionCallback = keccak256(data);
            manager.unlock(data);
            require(redemptionCallback == bytes32(0), "Missing callback");
        }
        redemptionManager = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (
            msg.sender != redemptionManager || redemptionCallback == bytes32(0) || keccak256(data) != redemptionCallback
        ) revert Unauthorized();
        redemptionCallback = bytes32(0);
        _burnAndTake(abi.decode(data, (bytes32)));
        return "";
    }

    function _burnAndTake(bytes32 poolId) internal {
        uint256 amount = pendingClaims[poolId];
        IPoolManager manager = claimsManager[poolId];
        Currency currency = Currency.wrap(pools[poolId].quote);
        uint256 currencyId = currency.toId();
        pendingClaims[poolId] = 0;
        reservedClaims[address(manager)][currencyId] -= amount;
        uint256 beforeBalance = currency.balanceOfSelf();
        manager.burn(address(this), currencyId, amount);
        manager.take(currency, address(this), amount);
        require(currency.balanceOfSelf() == beforeBalance + amount, "Inexact redemption");
    }

    receive() external payable {
        if (msg.sender != redemptionManager) revert Unauthorized();
    }

    /// @dev Lot IDs are generated here only for new validated receipts. A reverting
    /// callback rolls back the receipt, allocation, and ID together. There is no
    /// method for an operator to re-credit an already-held balance or replay a lot.
    function _credit(bytes32 poolId, uint256 amount) internal {
        require(amount != 0, "Zero fee");
        uint256 lotId = nextLotId[poolId]++;
        totalReceived[poolId] += amount;
        uint256[6] memory allocation;
        uint256[6] memory shares = [uint256(5750), 1000, 1000, 500, 1000, 750];
        // Split quotient and residual first to avoid amount*bps overflow. Each
        // bucket retains its own residual; old escrow may fund this lot's carry.
        for (uint256 i; i < 6; ++i) {
            uint256 numerator = (amount % 10000) * shares[i] + remainder[poolId][i];
            allocation[i] = (amount / 10000) * shares[i] + numerator / 10000;
            accrued[poolId][i] += allocation[i];
            remainder[poolId][i] = numerator % 10000;
            if (stockLotCustody[poolId][uint8(i)]) stockLotAmount[poolId][lotId][uint8(i)] = allocation[i];
        }
        Pool storage pool = pools[poolId];
        if (pool.settlementKind == 1) emit DirectStockCredited(poolId, lotId, pool.quote, amount);
        emit FeeCredited(poolId, lotId, pool.quote, amount, allocation);
        // These fixed local modules record rights only; custody stays here until
        // a later pull. They may not call claim while this fee lock is active.
        for (uint256 i; i < 4; ++i) {
            if (i != 1 && allocation[i] != 0) {
                IV3FeeReceiver(pool.beneficiaries[i])
                    .onFeeCredit(
                        i == 0 && legacyHolderSource[poolId] != 0 ? legacyHolderSource[poolId] : poolId,
                        pool.quote,
                        pool.settlementKind,
                        allocation[i]
                    );
            }
        }
    }

    function creditStock(bytes32 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        if (pool.hook != msg.sender) revert Unauthorized();
        if (pool.quote == address(0)) revert InvalidPool();
        IERC20 token = IERC20(pool.quote);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        require(token.balanceOf(address(this)) == beforeBalance + amount, "Inexact transfer");
        _credit(poolId, amount);
    }

    /// @notice Public payment to fixed beneficiaries; opted-in custodians pull their own backing.
    /// @return False if delivery failed; the full original liability is retained.
    function claim(bytes32 poolId, uint8 bucket, uint256 amount) external nonReentrant returns (bool) {
        if (controlledClaim[poolId][bucket] && msg.sender != pools[poolId].beneficiaries[bucket]) {
            revert Unauthorized();
        }
        require(!stockLotCustody[poolId][bucket], "Use stock lot custody");
        return _claim(poolId, bucket, amount, false);
    }

    function _claim(bytes32 poolId, uint8 bucket, uint256 amount, bool sixDecimals) internal returns (bool) {
        Pool storage pool = pools[poolId];
        if (pool.hook == address(0) || bucket >= 6) revert InvalidPool();
        require(amount > 0 && accrued[poolId][bucket] >= amount, "Insufficient credit");
        accrued[poolId][bucket] -= amount;
        totalPaid[poolId] += amount;
        try this.executePayment(
            poolId,
            sixDecimals ? nativeUsdcView : pool.quote,
            pool.beneficiaries[bucket],
            sixDecimals ? amount / 1e12 : amount,
            sixDecimals
        ) {
            emit Claimed(poolId, bucket, pool.beneficiaries[bucket], amount);
            return true;
        } catch {
            accrued[poolId][bucket] += amount;
            totalPaid[poolId] -= amount;
            emit ClaimFailed(poolId, bucket, amount);
            return false;
        }
    }

    function claimUSDC6(bytes32 poolId, uint8 bucket, uint256 amount18) external nonReentrant returns (bool) {
        if (controlledClaim[poolId][bucket] && msg.sender != pools[poolId].beneficiaries[bucket]) {
            revert Unauthorized();
        }
        if (nativeUsdcView == address(0) || pools[poolId].quote != address(0)) revert InvalidPool();
        if ((bucket == 0 || bucket == 2 || bucket == 3) && msg.sender != pools[poolId].beneficiaries[bucket]) {
            revert Unauthorized();
        }
        return _claim(poolId, bucket, (amount18 / 1e12) * 1e12, true);
    }

    /// @dev Self-only revert boundary: even a token that moves funds and returns
    /// false, taxes a payment, or reenters cannot partially consume the credit.
    function executePayment(bytes32 poolId, address asset, address recipient, uint256 amount, bool sixDecimals)
        external
    {
        if (msg.sender != address(this)) revert Unauthorized();
        _redeemClaims(poolId);
        uint256 nativeBefore = address(this).balance;
        uint256 recipientNativeBefore = recipient.balance;
        if (asset == address(0)) {
            (bool success,) = recipient.call{value: amount}("");
            require(success, "Payment failed");
        } else {
            IERC20 token = IERC20(asset);
            uint256 beforeSelf = token.balanceOf(address(this));
            uint256 beforeRecipient = token.balanceOf(recipient);
            token.safeTransfer(recipient, amount);
            require(
                token.balanceOf(address(this)) == beforeSelf - amount
                    && token.balanceOf(recipient) == beforeRecipient + amount,
                "Inexact transfer"
            );
        }
        if (sixDecimals) {
            require(
                address(this).balance == nativeBefore - amount * 1e12
                    && recipient.balance == recipientNativeBefore + amount * 1e12,
                "Not shared native balance"
            );
        }
    }
}

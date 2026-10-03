// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SignatureChecker
} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

interface ISolonFundingHub {
    function beginFunding(
        bytes32 orderId,
        address underlying,
        uint256 budget18,
        uint256 minRawOut,
        address receiver,
        bytes32 path
    ) external payable;
    function fundingReceived(bytes32 orderId) external view returns (uint256);
    function submitFundedBuy(bytes32 orderId) external;
    function requestCancel(bytes32 orderId) external;
    function claimResult(bytes32 orderId, bytes calldata proof)
        external
        returns (uint8 status, uint256 raw, uint256 refund18);
}

/// @notice r12: the hub's buy fee (SolonStockHub.fees), excluded from the external-cost cap.
interface IHubBuyFee {
    function fees() external view returns (uint16 buyFeeBps, uint16 sellFeeBps, uint16 mintLimitBps);
}

/// @notice r7 (design §12.2): SolonStockOracle execution-price read used as the purchase floor (reverts unless Live).
interface IAdapterPriceFloor {
    function rawFor(address asset, uint256 usd18) external view returns (uint256);
}

/// @notice Typed, immutable boundary to the phase-five authenticated settlement hub.
/// @dev The hub must authenticate RH funding receipts and LZ/canonical results. A keeper's proof
/// alone never authorizes delivery. This adapter is not itself a Relay/LZ proof verifier.
contract SolonStockAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Config {
        address coordinator;
        address vault;
        address asset;
        address underlying;
        address hub;
        address signer;
        bytes32 path;
        uint256 destinationChain;
        address opsVault;
        address oracle; // SolonStockOracle (r7): minRawOut >= budget / execPrice * (1 - 100 bps)
    }

    uint256 public constant ORACLE_FLOOR_BPS = 100;

    struct SignedQuote {
        bytes32 orderId;
        uint256 budget18;
        uint256 minRawOut;
        uint256 deadline;
        uint256 nonce;
        uint256 fees18;
        uint256 fixedCost18;
    }

    struct Order {
        uint256 budget;
        uint256 minRaw;
        uint256 fees;
        uint8 state;
    }
    Config public config;
    mapping(bytes32 => Order) public orders;
    mapping(bytes32 => uint256) public feeBalance;
    mapping(uint256 => bool) public nonceUsed;
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "StockBuy(bytes32 orderId,address asset,address underlying,address hub,bytes32 path,uint256 destinationChain,address vault,address refundVault,bytes4 selector,uint256 budget18,uint256 minRawOut,uint256 deadline,uint256 nonce,uint256 fees18,uint256 fixedCost18,address opsVault)"
    );
    error InvalidOrder();
    error Unauthorized();
    error InvalidQuote();
    error InexactResult();
    event FundingStarted(bytes32 indexed orderId, uint256 budget, uint256 fees, bytes32 path);
    event Submitted(bytes32 indexed orderId);
    event ResultConsumed(bytes32 indexed orderId, uint8 status, uint256 raw, uint256 refund18);

    constructor(Config memory c) {
        require(
            c.coordinator != address(0) && c.vault != address(0) && c.asset.code.length != 0
                && c.underlying != address(0) && c.hub.code.length != 0 && c.signer != address(0) && c.path != 0
                && c.destinationChain != 0 && c.opsVault != address(0) && c.oracle.code.length != 0
        );
        config = c;
    }
    modifier onlyCoordinator() {
        if (msg.sender != config.coordinator) revert Unauthorized();
        _;
    }

    receive() external payable virtual {
        if (msg.sender != config.hub) revert Unauthorized();
    }

    function quoteDigest(SignedQuote memory q) public view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SolonStockAdapter"),
                keccak256("3"),
                block.chainid,
                address(this)
            )
        );
        // Two static-word halves concatenated == the former single 17-word abi.encode (byte-identical);
        // split only so `forge coverage --ir-minimum` stays within the stack limit.
        bytes32 data = keccak256(
            bytes.concat(
                abi.encode(
                    QUOTE_TYPEHASH,
                    q.orderId,
                    config.asset,
                    config.underlying,
                    config.hub,
                    config.path,
                    config.destinationChain,
                    config.vault,
                    config.vault
                ),
                abi.encode(
                    this.startFunding.selector,
                    q.budget18,
                    q.minRawOut,
                    q.deadline,
                    q.nonce,
                    q.fees18,
                    q.fixedCost18,
                    config.opsVault
                )
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, data));
    }

    /// @notice Ops pays separately; no part of an entry's reward principal pays bridge/service fees.
    function depositFees(bytes32 id) external payable {
        if (orders[id].state != 0) revert InvalidOrder();
        feeBalance[id] += msg.value;
    }
    event OpsFeesRefunded(bytes32 indexed orderId, uint256 amount, bool success);

    /// @notice Excess deposits go only to fixed Ops. Before funding only Ops may
    /// withdraw, so third parties cannot remove the fees needed by a signed order.
    function refundUnusedFees(bytes32 id) external nonReentrant returns (bool ok) {
        if (orders[id].state == 0 && msg.sender != config.opsVault) revert Unauthorized();
        uint256 amount = feeBalance[id];
        if (amount == 0) return true;
        feeBalance[id] = 0;
        (ok,) = payable(config.opsVault).call{value: amount}("");
        if (!ok) feeBalance[id] = amount;
        emit OpsFeesRefunded(id, amount, ok);
    }

    function startFunding(
        bytes32 id,
        uint256 budget,
        uint256 minRaw,
        uint256 deadline,
        address vault,
        bytes calldata quoteData
    ) external payable onlyCoordinator nonReentrant {
        (SignedQuote memory q, bytes memory sig) = abi.decode(quoteData, (SignedQuote, bytes));
        if (
            id == 0 || orders[id].state != 0 || budget == 0 || minRaw == 0 || msg.value != budget
                || vault != config.vault
        ) revert InvalidOrder();
        // r12 (F4, design §5.1 `budget >= max($100, 200 x C_fixed)`): `fixedCost18` is the EXTERNAL cost only (Relay,
        // LayerZero, gas). The hub's buy fee (25 bps) is an internal transfer to the protocol and is not counted, but
        // every other fee the order pays must be: fees18 <= fixedCost18 + the hub fee.
        if (budget < 100 ether || q.fixedCost18 > budget / 200 || q.fees18 > q.fixedCost18 + _internalFee(budget)) {
            revert InvalidQuote();
        }
        // r7 floor: a signed minimum more than 1% under the Chainlink execution price is refused.
        if (minRaw * 10_000 < IAdapterPriceFloor(config.oracle).rawFor(config.asset, budget) * (10_000 - ORACLE_FLOOR_BPS))
        {
            revert InvalidQuote();
        }
        if (
            q.orderId != id || q.budget18 != budget || q.minRawOut != minRaw || q.deadline != deadline
                || block.timestamp > deadline || nonceUsed[q.nonce] || feeBalance[id] < q.fees18
                || !SignatureChecker.isValidSignatureNow(config.signer, quoteDigest(q), sig)
        ) revert InvalidQuote();
        nonceUsed[q.nonce] = true;
        feeBalance[id] -= q.fees18;
        orders[id] = Order(budget, minRaw, q.fees18, 1);
        _startFunding(id, orders[id]);
        emit FundingStarted(id, budget, q.fees18, config.path);
    }

    /// @dev r12: the part of the order's fees that is an internal transfer to Solon (the hub's buy fee on `budget`).
    function _internalFee(uint256 budget) internal view virtual returns (uint256) {
        (uint16 buyFeeBps,,) = IHubBuyFee(config.hub).fees();
        return (budget * buyFeeBps) / 10_000;
    }

    function _startFunding(bytes32 id, Order storage o) internal virtual {
        ISolonFundingHub(config.hub).beginFunding{value: o.budget + o.fees}(
            id, config.underlying, o.budget, o.minRaw, address(this), config.path
        );
    }

    function funded(bytes32 id) public view virtual returns (bool) {
        return orders[id].state != 0 && ISolonFundingHub(config.hub).fundingReceived(id) >= orders[id].budget;
    }

    function submit(bytes32 id) external onlyCoordinator nonReentrant {
        Order storage o = orders[id];
        if (o.state != 1 || !funded(id)) revert InvalidOrder();
        o.state = 2;
        _submit(id, o);
        emit Submitted(id);
    }

    function _submit(bytes32 id, Order storage) internal virtual {
        ISolonFundingHub(config.hub).submitFundedBuy(id);
    }

    function requestCancel(bytes32 id) external virtual onlyCoordinator nonReentrant {
        if (orders[id].state != 2) revert InvalidOrder();
        ISolonFundingHub(config.hub).requestCancel(id);
    }

    function _result(bytes32 id, bytes calldata proof) internal virtual returns (uint8, uint256, uint256) {
        return ISolonFundingHub(config.hub).claimResult(id, proof);
    }

    function consumeResult(bytes32 id, bytes calldata proof)
        external
        onlyCoordinator
        nonReentrant
        returns (uint8 status, uint256 raw, uint256 refund18)
    {
        Order storage o = orders[id];
        if (o.state == 0 || o.state == 3) revert InvalidOrder();
        uint256 beforeStock = IERC20(config.asset).balanceOf(address(this));
        uint256 beforeNative = address(this).balance;
        (status, raw, refund18) = _result(id, proof);
        if (status == 0) {
            if (
                raw != 0 || refund18 != 0 || IERC20(config.asset).balanceOf(address(this)) != beforeStock
                    || address(this).balance != beforeNative
            ) revert InexactResult();
            return (0, 0, 0);
        }
        if (status == 1) {
            if (
                (o.state != 2 && o.state != 4) || raw < o.minRaw || refund18 != 0
                    || IERC20(config.asset).balanceOf(address(this)) != beforeStock + raw
                    || address(this).balance != beforeNative
            ) revert InexactResult();
        } else if (status == 2) {
            if (
                o.state == 4 || raw != 0 || refund18 != o.budget || address(this).balance != beforeNative + refund18
                    || IERC20(config.asset).balanceOf(address(this)) != beforeStock
            ) revert InexactResult();
        } else {
            revert InexactResult();
        }
        o.state = status == 2 ? 4 : 3;
        if (raw != 0) {
            uint256 prior = IERC20(config.asset).balanceOf(config.vault);
            IERC20(config.asset).safeTransfer(config.vault, raw);
            if (
                IERC20(config.asset).balanceOf(config.vault) != prior + raw
                    || IERC20(config.asset).balanceOf(address(this)) != beforeStock
            ) revert InexactResult();
        }
        if (refund18 != 0) {
            (bool ok,) = payable(config.vault).call{value: refund18}("");
            require(ok);
        }
        emit ResultConsumed(id, status, raw, refund18);
    }
}

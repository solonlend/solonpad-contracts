// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SignatureChecker
} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {BuybackVault} from "./BuybackVault.sol";
import {V3FeeLedger} from "./V3FeeLedger.sol";

interface IBuybackRoute {
    function buy(address token, bytes32 path, address recipient, uint256 minOut) external payable returns (uint256);
}

interface IBuybackDestination {
    function depositBuyback(bytes32 lotId, uint256 amount) external;
}

contract BuybackBurnExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Config {
        address governance;
        address solon;
        address ledger;
        address router;
        bytes32 path;
        address signer;
        address sink;
        address protocolDesk;
    }

    struct Quote {
        bytes32 lotId;
        uint256 budget;
        uint256 minOut;
        uint256 pricePolicyVersion;
        uint256 quotedAt;
        uint256 deadline;
        uint256 nonce;
    }
    Config public config;
    address public immutable vault;
    address public stockConverter;
    address public v2Router;

    struct Lot {
        uint256 budget;
        uint256 bought;
        bool protocolDesk;
        bool executed;
        uint256 spent;
    }
    mapping(bytes32 => Lot) public lots;
    mapping(uint256 => bool) public nonceUsed;
    uint256 public pricePolicyVersion = 1;
    address public pendingSigner;
    uint256 public pendingPolicyVersion;
    uint256 public policyExecutableAt;
    uint256 public totalBudget;
    mapping(bytes32 => bool) public enabledPools;
    mapping(bytes32 => uint256) public poolCollectionNonce;
    event Funded(bytes32 indexed lotId, uint256 budget, bool protocolDesk);
    event Bought(bytes32 indexed lotId, uint256 spent, uint256 received, address destination);
    event PricePolicyScheduled(address indexed signer, uint256 version, uint256 executableAt);
    event PricePolicyActivated(address indexed signer, uint256 version);

    constructor(Config memory c) {
        require(
            c.governance != address(0) && c.solon.code.length != 0 && c.ledger != address(0)
                && c.router.code.length != 0 && c.path != 0 && c.signer != address(0) && c.sink.code.length != 0
                && c.protocolDesk != address(0),
            "Invalid config"
        );
        config = c;
        vault = address(new BuybackVault(c.solon, c.sink, address(this)));
    }

    function configureSources(address converter, address router_) external {
        require(
            msg.sender == config.governance && stockConverter == address(0) && converter != address(0)
                && router_ != address(0),
            "Already wired"
        );
        stockConverter = converter;
        v2Router = router_;
    }

    function schedulePricePolicy(address signer, uint256 version) external {
        require(
            msg.sender == config.governance && signer != address(0) && version > pricePolicyVersion, "Invalid policy"
        );
        pendingSigner = signer;
        pendingPolicyVersion = version;
        policyExecutableAt = block.timestamp + 48 hours;
        emit PricePolicyScheduled(signer, version, policyExecutableAt);
    }

    function activatePricePolicy() external {
        require(policyExecutableAt != 0 && block.timestamp >= policyExecutableAt, "Timelocked policy");
        config.signer = pendingSigner;
        pricePolicyVersion = pendingPolicyVersion;
        delete pendingSigner;
        delete pendingPolicyVersion;
        delete policyExecutableAt;
        emit PricePolicyActivated(config.signer, pricePolicyVersion);
    }

    receive() external payable {
        require(msg.sender == config.ledger, "Ledger only");
    }

    function feeCustodyMode() external pure returns (uint8) {
        return 1;
    }

    function enablePool(bytes32 poolId) external {
        V3FeeLedger.Pool memory p = V3FeeLedger(payable(config.ledger)).poolInfo(poolId);
        require(p.quote == address(0) && p.beneficiaries[4] == address(this), "Wrong pool");
        V3FeeLedger(payable(config.ledger)).enableControlledClaim(poolId, 4);
        enabledPools[poolId] = true;
    }

    function collectLedger(bytes32 poolId, uint256 amount) external nonReentrant returns (bytes32 id) {
        V3FeeLedger.Pool memory p = V3FeeLedger(payable(config.ledger)).poolInfo(poolId);
        require(
            p.quote == address(0) && p.beneficiaries[4] == address(this)
                && V3FeeLedger(payable(config.ledger)).controlledClaim(poolId, 4) && amount != 0,
            "Unknown pool"
        );
        uint256 beforeBalance = address(this).balance;
        require(V3FeeLedger(payable(config.ledger)).claim(poolId, 4, amount), "Ledger payment failed");
        require(address(this).balance == beforeBalance + amount, "Inexact revenue");
        id = keccak256(abi.encode(config.ledger, poolId, ++poolCollectionNonce[poolId]));
        _recordFund(id, amount, false);
    }

    function fundFromConverter(bytes32 id) external payable {
        require(msg.sender == stockConverter, "Converter only");
        _fund(id, false);
    }

    function fundV2(bytes32 id, bool protocolDesk) external payable {
        require(msg.sender == v2Router, "V2 only");
        _fund(id, protocolDesk);
    }

    function _fund(bytes32 id, bool protocolDesk) internal {
        _recordFund(id, msg.value, protocolDesk);
    }

    function _recordFund(bytes32 id, uint256 amount, bool protocolDesk) internal {
        require(id != 0 && amount != 0 && lots[id].budget == 0, "Invalid lot");
        lots[id] = Lot(amount, 0, protocolDesk, false, 0);
        totalBudget += amount;
        emit Funded(id, amount, protocolDesk);
    }

    function quoteDigest(Quote memory q) public view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SolonBuyback"),
                keccak256("3"),
                block.chainid,
                address(this)
            )
        );
        bytes32 hash = keccak256(
            abi.encode(
                keccak256(
                    "Buyback(bytes32 lotId,uint256 budget,uint256 minOut,uint256 pricePolicyVersion,uint256 quotedAt,uint256 deadline,uint256 nonce,address solon,address router,bytes32 path,address recipient)"
                ),
                q.lotId,
                q.budget,
                q.minOut,
                q.pricePolicyVersion,
                q.quotedAt,
                q.deadline,
                q.nonce,
                config.solon,
                config.router,
                config.path,
                lots[q.lotId].protocolDesk ? config.protocolDesk : vault
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, hash));
    }

    function execute(Quote calldata q, bytes calldata signature) external nonReentrant returns (uint256 received) {
        Lot storage l = lots[q.lotId];
        require(
            !l.executed && q.budget <= l.budget - l.spent && q.budget != 0 && q.budget <= 1000 ether, "Invalid budget"
        );
        require(
            q.minOut != 0 && q.pricePolicyVersion == pricePolicyVersion && q.quotedAt <= block.timestamp
                && block.timestamp - q.quotedAt <= 60 && q.deadline >= block.timestamp && q.deadline <= q.quotedAt + 60
                && !nonceUsed[q.nonce],
            "Invalid quote"
        );
        require(SignatureChecker.isValidSignatureNow(config.signer, quoteDigest(q), signature), "Signature");
        bytes32 purchaseId = l.spent == 0 && q.budget == l.budget ? q.lotId : keccak256(abi.encode(q.lotId, q.nonce));
        nonceUsed[q.nonce] = true;
        l.spent += q.budget;
        l.executed = l.spent == l.budget;
        totalBudget -= q.budget;
        IERC20 token = IERC20(config.solon);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 reported =
            IBuybackRoute(config.router).buy{value: q.budget}(config.solon, config.path, address(this), q.minOut);
        received = token.balanceOf(address(this)) - beforeBalance;
        require(received >= q.minOut && reported == received, "Inexact buyback");
        address destination = l.protocolDesk ? config.protocolDesk : vault;
        token.forceApprove(destination, received);
        IBuybackDestination(destination).depositBuyback(purchaseId, received);
        token.forceApprove(destination, 0);
        require(token.balanceOf(address(this)) == beforeBalance, "Unconsumed output");
        l.bought += received;
        emit Bought(purchaseId, q.budget, received, destination);
    }
}

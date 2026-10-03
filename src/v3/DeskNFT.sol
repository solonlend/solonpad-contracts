// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {EIP712} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {
    SignatureChecker
} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {ERC721} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IDeskServicePolicy {
    function oracle() external view returns (address);
    function oracleMaxAge() external view returns (uint256);
    function minimumUSD18() external view returns (uint256);
}

interface IDeskServicePrice {
    function priceUSD18(address asset) external view returns (uint256, uint256);
}

interface IDeskRewards {
    function deliveryInfo(bytes32 key) external view returns (address asset, uint256 revision);
    function recordMintSurcharge() external payable;
    function claimable(uint256 id, bytes32 key) external view returns (uint256);
    function pay(uint256 id, bytes32[] calldata keys, address owner) external returns (uint256);
}

interface IDeskProtocolAccount {
    function receiveDeskProtocol(bytes32 receipt) external payable;
}

interface IDeskEligibility {
    function canReceiveStock(address asset, address wallet) external view returns (bool);
}

contract DeskNFT is ERC721, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    struct Quote {
        uint256 solUsd18;
        uint256 usdcUsd18;
        uint256 quotedAt;
        uint256 pricePolicyVersion;
        bytes32 priceSource;
    }
    address public immutable governance;
    IERC20 public immutable solon;
    address public immutable burnSink;
    address public immutable rewards;
    address public immutable protocolAccount;
    address public immutable controller;
    uint256 public immutable surchargeUSDC18;
    uint256 public immutable quotedAt;
    uint256 public immutable pricePolicyVersion;
    bytes32 public immutable priceSource;
    uint256 public constant MAX_SUPPLY = 5000;
    uint256 public constant SOLON_PER_DESK = 100000e18;
    address public eligibilityAsset;
    uint256 public nextTokenId = 1;
    event DeskMinted(
        uint256 indexed firstTokenId, address indexed owner, address indexed payer, uint256 cards, uint256 lockedSolon
    );

    constructor(
        address governance_,
        address solon_,
        address sink_,
        address rewards_,
        address protocol_,
        address controller_,
        Quote memory quote_
    ) ERC721("Solon Desk", "DESK") EIP712("Solon Desk", "1") {
        require(
            governance_ != address(0) && solon_.code.length > 0 && sink_ != address(0) && rewards_.code.length > 0
                && protocol_.code.length > 0,
            "configuration"
        );
        require(
            quote_.solUsd18 > 0 && quote_.usdcUsd18 > 0 && quote_.quotedAt <= block.timestamp
                && quote_.pricePolicyVersion > 0 && quote_.priceSource != 0,
            "quote"
        );
        eligibilityAsset = solon_;
        governance = governance_;
        solon = IERC20(solon_);
        burnSink = sink_;
        rewards = rewards_;
        protocolAccount = protocol_;
        controller = controller_;
        surchargeUSDC18 = Math.mulDiv(quote_.solUsd18, 1e18, quote_.usdcUsd18) / 2;
        require(surchargeUSDC18 > 0, "surcharge");
        quotedAt = quote_.quotedAt;
        pricePolicyVersion = quote_.pricePolicyVersion;
        priceSource = quote_.priceSource;
    }

    struct Purchase {
        uint256 tokenId;
        address seller;
        address buyer;
        bytes32 stream;
        uint256 nonce;
        uint256 deadline;
        uint256 minUnclaimed;
        uint256 priceNative;
    }
    mapping(uint256 => uint256) public nonces;
    bytes32 public constant PURCHASE_TYPEHASH = keccak256(
        "Purchase(uint256 tokenId,address seller,address buyer,bytes32 stream,uint256 nonce,uint256 deadline,uint256 minUnclaimed,uint256 priceNative)"
    );

    function purchaseDigest(Purchase calldata order) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PURCHASE_TYPEHASH, order)));
    }

    /// @param order minUnclaimed is a raw delivery floor for the explicitly signed stream.
    function purchase(Purchase calldata order, bytes calldata signature) external payable nonReentrant {
        require(
            msg.sender == order.buyer && order.buyer != order.seller && order.buyer != protocolVault
                && order.seller != protocolVault && msg.value == order.priceNative,
            "buyer/payment"
        );
        require(
            block.timestamp <= order.deadline && order.nonce == nonces[order.tokenId]
                && ownerOf(order.tokenId) == order.seller,
            "stale order"
        );
        require(SignatureChecker.isValidSignatureNow(order.seller, purchaseDigest(order), signature), "sale signature");
        require(
            IDeskRewards(rewards).claimable(order.tokenId, order.stream) >= order.minUnclaimed, "unclaimed below floor"
        );
        _safeTransfer(order.seller, order.buyer, order.tokenId, "");
        if (msg.value != 0) {
            uint256 royalty = msg.value / 20;
            (bool feeOk,) = rewards.call{value: royalty}("");
            require(feeOk, "royalty payment");
            (bool ok,) = order.seller.call{value: msg.value - royalty}("");
            require(ok, "sale payment");
        }
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (rewards, salePrice / 20);
    }

    function supportsInterface(bytes4 id) public view override returns (bool) {
        return id == 0x2a55205a || super.supportsInterface(id);
    }

    function bindEligibilityAsset(address asset) external {
        require(msg.sender == governance && totalSupply() == 0 && asset.code.length > 0, "eligibility configuration");
        eligibilityAsset = asset;
    }

    function _eligible(address wallet) internal view {
        if (controller != address(0)) {
            require(IDeskEligibility(controller).canReceiveStock(eligibilityAsset, wallet), "Desk eligibility");
        }
    }

    function approve(address to, uint256 id) public override {
        require(ownerOf(id) != protocolVault, "protocol approval");
        super.approve(to, id);
    }

    function setApprovalForAll(address operator, bool approved) public override {
        require(msg.sender != protocolVault, "protocol approval");
        super.setApprovalForAll(operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) public override nonReentrant {
        super.transferFrom(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public override nonReentrant {
        _checkAuthorized(ownerOf(id), msg.sender, id);
        _safeTransfer(from, to, id, data);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = _ownerOf(id);
        require(from == address(0) || from != protocolVault, "protocol locked");
        require(to != protocolVault || from == address(0), "protocol mint only");
        if (from != address(0)) _eligible(from);
        _eligible(to);
        if (from != address(0)) ++nonces[id];
        return super._update(to, id, auth);
    }
    mapping(address => mapping(address => uint256)) public sponsorEscrow;
    event SponsorshipAuthorized(address indexed sponsor, address indexed recipient, uint256 surcharge);

    function authorizeSponsored(address recipient) external payable nonReentrant {
        require(
            recipient != address(0) && msg.value == surchargeUSDC18 && sponsorEscrow[msg.sender][recipient] == 0,
            "sponsor consent/payment"
        );
        sponsorEscrow[msg.sender][recipient] = msg.value;
        emit SponsorshipAuthorized(msg.sender, recipient, msg.value);
    }

    function grantSponsored(address recipient, address sponsor) external nonReentrant returns (uint256) {
        require(msg.sender == governance && recipient != protocolVault, "governance/recipient");
        uint256 fee = sponsorEscrow[sponsor][recipient];
        require(fee == surchargeUSDC18, "sponsor consent");
        delete sponsorEscrow[sponsor][recipient];
        return _mintPaid(1, recipient, sponsor, fee);
    }

    address public servicePolicy;

    struct DeskQueue {
        bytes32 stream;
        address asset;
        uint256 upperBound;
        uint256 cursor;
        uint256 nextScanAt;
    }
    DeskQueue[] public deskQueues;
    mapping(bytes32 => bool) public deskQueued;
    mapping(uint256 => bytes32[]) private queueStreams;
    mapping(uint256 => uint256[]) private queueRevisions;

    function configureServicePolicy(address policy) external {
        require(msg.sender == governance && servicePolicy == address(0) && policy.code.length > 0, "service policy");
        require(IDeskServicePolicy(policy).oracle().code.length > 0, "service oracle");
        servicePolicy = policy;
    }

    function openDeskQueue(bytes32 key) external returns (uint256) {
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        return _openDeskQueue(keys);
    }

    function openDeskQueue(bytes32[] calldata keys) external returns (uint256) {
        return _openDeskQueue(keys);
    }

    function deskQueueStreams(uint256 id) external view returns (bytes32[] memory, uint256[] memory) {
        return (queueStreams[id], queueRevisions[id]);
    }

    function _openDeskQueue(bytes32[] memory keys) private returns (uint256 id) {
        require(servicePolicy != address(0) && keys.length > 0 && keys.length <= 20, "service streams");
        address asset;
        uint256[] memory revisions = new uint256[](keys.length);
        for (uint256 i; i < keys.length; ++i) {
            for (uint256 j; j < i; ++j) {
                require(keys[i] != keys[j], "duplicate stream");
            }
            (address current, uint256 revision) = IDeskRewards(rewards).deliveryInfo(keys[i]);
            require(current != address(0) && revision != 0, "ready stock");
            if (i == 0) asset = current;
            else require(asset == current, "same asset");
            revisions[i] = revision;
        }
        bytes32 unique = keccak256(abi.encode(keys, asset, revisions));
        require(!deskQueued[unique], "queue exists");
        deskQueued[unique] = true;
        id = deskQueues.length;
        deskQueues.push(DeskQueue(keys[0], asset, totalSupply(), 0, 0));
        queueStreams[id] = keys;
        queueRevisions[id] = revisions;
    }

    /// @notice Automatic service scans a chain-owned tokenId cursor, never a keeper-selected roster.
    function batchDistributeDesk(uint256 queueId, uint256 maxCards)
        external
        nonReentrant
        returns (uint256 paid, uint256 failed)
    {
        require(maxCards > 0 && maxCards <= 32, "batch page");
        DeskQueue storage q = deskQueues[queueId];
        require(block.timestamp % 1 days >= 10 minutes && block.timestamp >= q.nextScanAt, "scan schedule");
        uint256 pushGas = 500000 * queueStreams[queueId].length;
        uint256 reserve = pushGas + 100000;
        if (gasleft() < reserve) return (0, 0);
        if (q.cursor == q.upperBound) q.cursor = 0;
        uint256 start = q.cursor;
        uint256 end = Math.min(q.cursor + maxCards, q.upperBound);
        while (q.cursor < end) {
            if (gasleft() < reserve) break;
            uint256 id = ++q.cursor;
            if (ownerOf(id) == protocolVault) continue;
            try this.executeAutomaticPush{gas: pushGas}(id, queueId) returns (uint256 amount) {
                if (amount != 0) ++paid;
            } catch (bytes memory reason) {
                ++failed;
                emit DeskPushBlocked(id, q.stream, reason);
            }
        }
        if (q.cursor != start) {
            q.nextScanAt = q.cursor == q.upperBound
                ? (block.timestamp / 1 days + 1) * 1 days + 10 minutes
                : block.timestamp + 15 minutes;
        }
    }

    function executeAutomaticPush(uint256 id, uint256 queueId) external returns (uint256 amount) {
        require(msg.sender == address(this), "self");
        DeskQueue storage q = deskQueues[queueId];
        IDeskServicePolicy policy = IDeskServicePolicy(servicePolicy);
        (uint256 price, uint256 at) = IDeskServicePrice(policy.oracle()).priceUSD18(q.asset);
        if (price == 0 || at > block.timestamp || block.timestamp - at > policy.oracleMaxAge()) return 0;
        bytes32[] memory keys = queueStreams[queueId];
        uint256 total;
        for (uint256 i; i < keys.length; ++i) {
            total += IDeskRewards(rewards).claimable(id, keys[i]);
        }
        if (Math.mulDiv(total, price, 1e18) < policy.minimumUSD18()) return 0;
        address owner = ownerOf(id);
        require(owner != protocolVault, "protocol delegated");
        amount = IDeskRewards(rewards).pay(id, keys, owner);
        if (amount != 0) emit DeskPushed(id, q.stream, amount);
    }
    event DeskPushed(uint256 indexed tokenId, bytes32 indexed stream, uint256 amount);
    event DeskPushBlocked(uint256 indexed tokenId, bytes32 indexed stream, bytes reason);

    /// @notice Manual permissionless delivery always pays the current owner, including across transfers.
    function batchDistributeDesk(uint256[] calldata ids, bytes32[] calldata keys)
        external
        nonReentrant
        returns (uint256 paid, uint256 failed)
    {
        require(ids.length <= 32 && keys.length <= 4, "batch page");
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j; j < keys.length; ++j) {
                if (gasleft() < 550000) return (paid, failed);
                try this.executePush{gas: 500000}(ids[i], keys[j]) returns (uint256 amount) {
                    if (amount != 0) ++paid;
                } catch (bytes memory reason) {
                    ++failed;
                    emit DeskPushBlocked(ids[i], keys[j], reason);
                }
            }
        }
    }

    function executePush(uint256 id, bytes32 key) external returns (uint256) {
        require(msg.sender == address(this), "self");
        return _push(id, key);
    }

    function _push(uint256 id, bytes32 key) private returns (uint256 amount) {
        address owner = ownerOf(id);
        require(owner != protocolVault, "protocol delegated");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        amount = IDeskRewards(rewards).pay(id, keys, owner);
        if (amount != 0) emit DeskPushed(id, key, amount);
    }

    function claim(uint256 id, bytes32[] calldata keys) external nonReentrant returns (uint256) {
        address owner = ownerOf(id);
        require(owner != protocolVault, "protocol delegated");
        _checkAuthorized(owner, msg.sender, id);
        return IDeskRewards(rewards).pay(id, keys, owner);
    }
    address public protocolVault;
    uint256 public protocolMinted;

    function configureProtocolVault(address vault) external {
        require(
            msg.sender == governance && protocolVault == address(0) && vault.code.length > 0 && balanceOf(vault) == 0
        );
        protocolVault = vault;
    }

    function mintProtocol(uint256 count) external payable nonReentrant returns (uint256) {
        require(msg.sender == protocolVault && protocolMinted + count <= 1000, "protocol vault/cap");
        protocolMinted += count;
        return _mintPaid(count, protocolVault, msg.sender, msg.value);
    }

    function totalSupply() public view returns (uint256) {
        return nextTokenId - 1;
    }

    function mint(uint256 count, address to) external payable nonReentrant returns (uint256) {
        require(to != protocolVault, "protocol mint only");
        return _mintPaid(count, to, msg.sender, msg.value);
    }

    /// @notice Cumulative primary-mint cap per receiving address (public mint and sponsored grants; the protocol
    ///         vault has its own 1000-card cap). Default 50 = 1% of MAX_SUPPLY. Secondary transfers are not capped.
    uint256 public mintCapPerAddress = 50;
    mapping(address => uint256) public mintedTo;
    event MintCapSet(uint256 cap);

    /// @notice Timelock (48h): any value up to MAX_SUPPLY.
    function setMintCapPerAddress(uint256 cap) external {
        require(msg.sender == governance && cap <= MAX_SUPPLY, "mint cap");
        mintCapPerAddress = cap;
        emit MintCapSet(cap);
    }

    /// @notice Guardian (via V3Governance.guardianCall) or timelock: lower only.
    function tightenMintCapPerAddress(uint256 cap) external {
        require(msg.sender == governance && cap < mintCapPerAddress, "mint cap");
        mintCapPerAddress = cap;
        emit MintCapSet(cap);
    }

    function guardianTightenOnly(bytes4 selector) external pure returns (bool) {
        return selector == this.tightenMintCapPerAddress.selector;
    }

    function _mintPaid(uint256 count, address to, address payer, uint256 fee) internal returns (uint256 first) {
        require(count > 0 && count <= 20 && totalSupply() + count <= MAX_SUPPLY, "mint capacity");
        if (to != protocolVault) {
            uint256 minted = mintedTo[to] + count;
            require(minted <= mintCapPerAddress, "address mint cap");
            mintedTo[to] = minted;
        }
        require(fee == surchargeUSDC18 * count, "surcharge payment");
        uint256 burn = count * SOLON_PER_DESK;
        uint256 beforeSink = solon.balanceOf(burnSink);
        uint256 beforePayer = solon.balanceOf(payer);
        solon.safeTransferFrom(payer, burnSink, burn);
        require(
            solon.balanceOf(burnSink) == beforeSink + burn && solon.balanceOf(payer) + burn == beforePayer, "sink delta"
        );
        first = nextTokenId;
        nextTokenId += count;
        for (uint256 id = first; id < first + count; ++id) {
            _safeMint(to, id);
        }
        uint256 protocolPart = fee / 10;
        IDeskProtocolAccount(protocolAccount).receiveDeskProtocol{value: protocolPart}(
            keccak256(abi.encode(address(this), first, count))
        );
        IDeskRewards(rewards).recordMintSurcharge{value: fee - protocolPart}();
        emit DeskMinted(first, to, payer, count, burn);
    }
}

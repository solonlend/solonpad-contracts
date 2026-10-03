// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ERC721} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {V3FeeLedger} from "./V3FeeLedger.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {
    SignatureChecker
} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

/// @notice Fixed policy seam. B skips identity checks; A queries the current owner's delivery eligibility.
interface ICreatorEligibilityPolicy {
    function eligibilityEnabled() external view returns (bool);
    function canReceiveStock(address asset, address owner) external view returns (bool);
}

/// @notice One transferable right to the registered pool's immutable 10% creator bucket.
/// @dev Historical unclaimed fees follow ownership. The ledger remains the source
/// of entitlement even when a third party has already pulled funds into this NFT.
/// There is no administrator withdrawal, burn, supply expansion or pool setter.
contract CreatorRightsNFT is ERC721, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;
    mapping(uint256 => uint256) public paid;
    event CreatorClaimed(uint256 indexed tokenId, address indexed owner, address indexed asset, uint256 amountRaw);
    event CreatorClaimFailed(uint256 indexed tokenId, uint256 amountRaw);
    address public immutable factory;
    V3FeeLedger public immutable ledger;
    address public immutable eligibilityPolicy;
    uint256 public nextTokenId = 1;
    mapping(bytes32 => uint256) public tokenOfPool;
    mapping(uint256 => bytes32) public poolOf;
    mapping(uint256 => address) public quoteAsset;
    error Unauthorized();
    error InvalidPool();

    constructor(address factory_, V3FeeLedger ledger_, address eligibilityPolicy_)
        ERC721("Solon Creator Rights", "SCR")
        EIP712("Solon Creator Rights", "1")
    {
        require(factory_ != address(0) && address(ledger_).code.length != 0, "Invalid configuration");
        factory = factory_;
        ledger = ledger_;
        eligibilityPolicy = eligibilityPolicy_;
    }

    function mint(bytes32 poolId, address creator) external nonReentrant returns (uint256 id) {
        if (msg.sender != factory) revert Unauthorized();
        V3FeeLedger.Pool memory pool = ledger.poolInfo(poolId);
        if (tokenOfPool[poolId] != 0 || pool.hook == address(0) || pool.beneficiaries[1] != address(this)) {
            revert InvalidPool();
        }
        id = nextTokenId++;
        tokenOfPool[poolId] = id;
        poolOf[id] = poolId;
        quoteAsset[id] = pool.quote;
        _safeMint(creator, id);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        return 'data:application/json;utf8,{"name":"Solon Creator Rights","description":"Transfer includes accrued unclaimed income. Fixed pool quote asset; no pool administration or royalty rights."}';
    }

    function ownerOfPool(bytes32 poolId) external view returns (address) {
        return ownerOf(tokenOfPool[poolId]);
    }

    /// @dev The immutable ledger's 10% bucket carries its own rounding remainder.
    /// Its lifetime entitlement is floor(total received / 10), including amounts
    /// third parties have already permissionlessly delivered to this contract.
    function claimable(uint256 id) public view returns (uint256) {
        _requireOwned(id);
        return ledger.totalReceived(poolOf[id]) / 10 - paid[id];
    }

    /// @param payoutMode 0: native USDC18 or stock raw; 1: shared native USDC6 view.
    /// @return True only on complete payment. Delivery failure preserves all debt.
    function claimCreator(uint256 id, address asset, uint256 amountRaw, uint8 payoutMode)
        external
        nonReentrant
        returns (bool)
    {
        address owner = ownerOf(id);
        _checkAuthorized(owner, msg.sender, id);
        require(asset == quoteAsset[id] && payoutMode <= 1, "Invalid payout");
        if (payoutMode == 1) {
            require(asset == address(0) && ledger.nativeUsdcView() != address(0), "Invalid USDC view");
            amountRaw = amountRaw / 1e12 * 1e12;
        }
        require(amountRaw != 0 && amountRaw <= claimable(id), "Insufficient credit");
        paid[id] += amountRaw;
        try this.executePayment(id, owner, amountRaw, payoutMode) {
            emit CreatorClaimed(id, owner, asset, amountRaw);
            return true;
        } catch {
            paid[id] -= amountRaw;
            emit CreatorClaimFailed(id, amountRaw);
            return false;
        }
    }

    /// @dev Self-call revert boundary atomically rolls back the ledger pull and
    /// token effects on any failed, taxed or false-returning delivery.
    function executePayment(uint256 id, address owner, uint256 amount, uint8 payoutMode) external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (quoteAsset[id] != address(0) && eligibilityPolicy != address(0)) {
            ICreatorEligibilityPolicy policy = ICreatorEligibilityPolicy(eligibilityPolicy);
            require(!policy.eligibilityEnabled() || policy.canReceiveStock(quoteAsset[id], owner), "Delivery blocked");
        }
        bytes32 pool = poolOf[id];
        uint256 delivered = ledger.totalReceived(pool) / 10 - ledger.accrued(pool, 1);
        uint256 needed = paid[id] > delivered ? paid[id] - delivered : 0;
        if (needed != 0) require(ledger.claim(pool, 1, needed), "Ledger payment failed");
        address asset = quoteAsset[id];
        uint256 nativeBefore = address(this).balance;
        uint256 ownerNativeBefore = owner.balance;
        if (payoutMode == 1) asset = ledger.nativeUsdcView();
        if (asset == address(0)) {
            (bool ok,) = owner.call{value: amount}("");
            require(ok, "Payment failed");
        } else {
            IERC20 token = IERC20(asset);
            uint256 beforeSelf = token.balanceOf(address(this));
            uint256 beforeOwner = token.balanceOf(owner);
            uint256 units = payoutMode == 1 ? amount / 1e12 : amount;
            token.safeTransfer(owner, units);
            require(
                token.balanceOf(address(this)) == beforeSelf - units && token.balanceOf(owner) == beforeOwner + units,
                "Inexact transfer"
            );
            if (payoutMode == 1) {
                require(
                    address(this).balance == nativeBefore - amount && owner.balance == ownerNativeBefore + amount,
                    "Not shared native balance"
                );
            }
        }
    }

    function transferFrom(address from, address to, uint256 id) public override nonReentrant {
        super.transferFrom(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public override nonReentrant {
        _checkAuthorized(ownerOf(id), msg.sender, id);
        _safeTransfer(from, to, id, data);
    }

    struct Purchase {
        uint256 tokenId;
        address seller;
        address buyer;
        address asset;
        uint256 nonce;
        uint256 deadline;
        uint256 minAccrued;
        uint256 priceNative;
    }
    mapping(uint256 => uint256) public nonces;
    bytes32 public constant PURCHASE_TYPEHASH = keccak256(
        "Purchase(uint256 tokenId,address seller,address buyer,address asset,uint256 nonce,uint256 deadline,uint256 minAccrued,uint256 priceNative)"
    );
    event Purchased(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 priceNative);

    function purchaseDigest(Purchase calldata order) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(PURCHASE_TYPEHASH, order)));
    }

    /// @notice Voluntary atomic sale route; ordinary ERC721 transfers remain available.
    function purchase(Purchase calldata order, bytes calldata signature) external payable nonReentrant {
        require(
            msg.sender == order.buyer && order.buyer != order.seller && msg.value == order.priceNative,
            "Invalid buyer/payment"
        );
        require(block.timestamp <= order.deadline && order.nonce == nonces[order.tokenId], "Expired or stale order");
        require(
            ownerOf(order.tokenId) == order.seller && quoteAsset[order.tokenId] == order.asset, "Invalid seller/asset"
        );
        require(
            SignatureChecker.isValidSignatureNow(order.seller, purchaseDigest(order), signature), "Invalid signature"
        );
        require(claimable(order.tokenId) >= order.minAccrued, "Accrued below signed floor");
        _safeTransfer(order.seller, order.buyer, order.tokenId, "");
        if (msg.value != 0) {
            (bool ok,) = order.seller.call{value: msg.value}("");
            require(ok, "Sale payment failed");
        }
        emit Purchased(order.tokenId, order.seller, order.buyer, msg.value);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        if (from != address(0)) ++nonces[id];
    }

    receive() external payable {
        if (msg.sender != address(ledger)) revert Unauthorized();
    }
}

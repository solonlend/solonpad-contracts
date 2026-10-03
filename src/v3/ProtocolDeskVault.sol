// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {DeskNFT} from "./DeskNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IDeskOps {
    function payDeskSurcharge(bytes32 lotId, uint256 firstTokenId, uint256 cards, address desk)
        external
        returns (uint256);
}

/// @notice Permanently routed cards funded exclusively by the fixed buyback executor.
contract ProtocolDeskVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    DeskNFT public immutable nft;
    IERC20 public immutable solon;
    address public immutable burnSink;
    address public immutable buyer;
    address public immutable ops;
    uint256 public constant protocolMax = 1000;
    uint256 public pendingSolon;
    uint256 public totalDeposited;
    uint256 public totalLocked;
    bytes32 public lotCommitment;
    mapping(bytes32 => uint256) public deposits;
    event BuybackDeposited(bytes32 indexed lotId, uint256 amount);
    event ProtocolMinted(bytes32 indexed lotCommitment, uint256 indexed firstTokenId, uint256 cards, uint256 locked);

    constructor(DeskNFT nft_, IERC20 solon_, address sink_, address buyer_, address ops_) {
        require(
            address(nft_).code.length > 0 && address(solon_) == address(nft_.solon()) && sink_ == nft_.burnSink()
                && buyer_ != address(0) && ops_.code.length > 0,
            "configuration"
        );
        nft = nft_;
        solon = solon_;
        burnSink = sink_;
        buyer = buyer_;
        ops = ops_;
    }

    function depositBuyback(bytes32 lotId, uint256 amount) external nonReentrant {
        require(msg.sender == buyer && lotId != 0 && amount > 0 && deposits[lotId] == 0, "buyback lot");
        uint256 beforeBalance = solon.balanceOf(address(this));
        solon.safeTransferFrom(msg.sender, address(this), amount);
        require(solon.balanceOf(address(this)) == beforeBalance + amount, "deposit delta");
        deposits[lotId] = amount;
        pendingSolon += amount;
        totalDeposited += amount;
        lotCommitment = keccak256(abi.encode(lotCommitment, lotId, amount));
        emit BuybackDeposited(lotId, amount);
    }

    function mintAvailable(uint256 maxCards) external nonReentrant returns (uint256 cards) {
        require(maxCards > 0 && maxCards <= 20, "mint page");
        cards = pendingSolon / nft.SOLON_PER_DESK();
        if (cards > maxCards) cards = maxCards;
        uint256 remaining = nft.MAX_SUPPLY() - nft.totalSupply();
        uint256 protocolRemaining = protocolMax - nft.protocolMinted();
        if (remaining > protocolRemaining) remaining = protocolRemaining;
        if (cards > remaining) cards = remaining;
        if (cards == 0) return 0;
        uint256 first = nft.nextTokenId();
        uint256 cost = cards * nft.surchargeUSDC18();
        uint256 beforeNative = address(this).balance;
        require(
            IDeskOps(ops).payDeskSurcharge(lotCommitment, first, cards, address(nft)) == cost
                && address(this).balance == beforeNative + cost,
            "ops surcharge"
        );
        uint256 burn = cards * nft.SOLON_PER_DESK();
        pendingSolon -= burn;
        totalLocked += burn;
        solon.forceApprove(address(nft), burn);
        require(nft.mintProtocol{value: cost}(cards) == first, "mint receipt");
        solon.forceApprove(address(nft), 0);
        emit ProtocolMinted(lotCommitment, first, cards, burn);
    }
    event OverflowLocked(bytes32 indexed lotCommitment, uint256 amount);

    function sweepOverflowToBurn() external nonReentrant returns (uint256 amount) {
        require(nft.protocolMinted() == protocolMax || nft.totalSupply() == nft.MAX_SUPPLY(), "capacity available");
        amount = pendingSolon;
        if (amount == 0) return 0;
        pendingSolon = 0;
        uint256 beforeSink = solon.balanceOf(burnSink);
        uint256 beforeSelf = solon.balanceOf(address(this));
        solon.safeTransfer(burnSink, amount);
        require(
            solon.balanceOf(burnSink) == beforeSink + amount && solon.balanceOf(address(this)) + amount == beforeSelf,
            "sink delta"
        );
        totalLocked += amount;
        emit OverflowLocked(lotCommitment, amount);
    }

    function onERC721Received(address operator, address from, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(nft) && from == address(0) && operator == address(this), "mint only");
        return this.onERC721Received.selector;
    }

    receive() external payable {
        require(msg.sender == ops, "ops only");
    }
}

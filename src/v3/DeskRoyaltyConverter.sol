// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {V2FeeConverter} from "./V2FeeConverter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRoyaltyRouteAsset {
    function asset() external view returns (address);
}

/// @notice A manifest-bound other-currency royalty escrow. Only actual converted USDC
/// enters the fixed Desk pot, which checkpoints its current card supply at receipt.
/// No withdrawal, route replacement, estimated credit or arbitrary recipient exists.
contract DeskRoyaltyConverter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    V2FeeConverter public immutable converter;
    address public immutable rewards;
    address public immutable asset;
    mapping(bytes32 => uint256) public pending;
    mapping(bytes32 => uint256) public conversionCount;
    uint256 public nonce;
    event RoyaltyDeposited(bytes32 indexed lot, address indexed payer, uint256 raw);
    event RoyaltyConverted(bytes32 indexed lot, bytes32 indexed slice, uint256 raw, uint256 actualUSDC18);

    constructor(address r, address a, address route, address signer, address ops, bytes32 path, uint32 version) {
        require(
            r.code.length != 0 && a.code.length != 0 && IRoyaltyRouteAsset(route).asset() == a, "fixed royalty route"
        );
        rewards = r;
        asset = a;
        converter = new V2FeeConverter(address(this), route, signer, ops, path, version);
    }

    function deposit(uint256 raw) external nonReentrant returns (bytes32 id) {
        require(raw != 0, "empty royalty");
        id = keccak256(abi.encode(address(this), ++nonce));
        IERC20 token = IERC20(asset);
        uint256 beforeSelf = token.balanceOf(address(this));
        uint256 beforePayer = token.balanceOf(msg.sender);
        token.safeTransferFrom(msg.sender, address(this), raw);
        require(
            token.balanceOf(address(this)) == beforeSelf + raw && token.balanceOf(msg.sender) + raw == beforePayer,
            "royalty delta"
        );
        pending[id] = raw;
        emit RoyaltyDeposited(id, msg.sender, raw);
    }

    function nextConversionId(bytes32 id) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), id, conversionCount[id]));
    }

    function convert(bytes32 id, uint256 raw, bytes calldata quoteData) external nonReentrant returns (uint256 actual) {
        require(raw != 0 && raw <= pending[id], "royalty lot");
        bytes32 slice = nextConversionId(id);
        pending[id] -= raw;
        ++conversionCount[id];
        IERC20 token = IERC20(asset);
        uint256 beforeRaw = token.balanceOf(address(this));
        uint256 beforeNative = address(this).balance;
        token.forceApprove(address(converter), raw);
        actual = converter.convert(slice, asset, raw, quoteData);
        token.forceApprove(address(converter), 0);
        require(
            actual != 0 && token.balanceOf(address(this)) + raw == beforeRaw
                && address(this).balance == beforeNative + actual,
            "conversion delta"
        );
        uint256 beforeRecipient = rewards.balance;
        (bool ok,) = rewards.call{value: actual}("");
        require(ok && address(this).balance == beforeNative && rewards.balance == beforeRecipient + actual, "pot delta");
        emit RoyaltyConverted(id, slice, raw, actual);
    }

    receive() external payable {
        require(msg.sender == address(converter), "converter only");
    }
}

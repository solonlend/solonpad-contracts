// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {OApp, Origin, MessagingFee} from "../lz/OApp.sol";
import {ILayerZeroComposerLike} from "../interfaces/IOFTLike.sol";

/// @title FloatReceiver — Robinhood Chain end of the candidate FloatRebalancer
/// @notice New Solon code; candidate, disabled unless the Arc FloatRebalancer is enabled. The USDG OFT
///         credits this contract and the endpoint then calls `lzCompose` with the OFT compose message
///         (LayerZero OFTComposeMsgCodec layout: nonce, srcEid, amountLD, composeFrom, composeMsg). Only the
///         fixed OFT through the endpoint, composed from the fixed Ethereum adapter, is accepted; the credited
///         amount goes straight to the fixed reserve vault and the (id, GUID, amount) receipt is reported to
///         the Arc rebalancer over LayerZero. Each GUID and each id is used once.
contract FloatReceiver is OApp, Ownable2Step, ILayerZeroComposerLike {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdg;
    address public immutable oft;
    bytes32 public immutable ethAdapter;
    address public immutable vault;
    uint32 public immutable arcEid;
    bytes public receiptOptions = hex"0003010011010000000000000000000000000000c350"; // lzReceive gas 50k on Arc

    mapping(bytes32 guid => bool) public guidUsed;
    mapping(bytes32 id => uint256) public received;

    event FloatReceived(bytes32 indexed id, bytes32 indexed guid, uint256 amount);

    error NotEndpoint();
    error NotOft();
    error WrongComposer();
    error Duplicate();

    constructor(
        address endpoint,
        address owner_,
        address usdg_,
        address oft_,
        address ethAdapter_,
        address vault_,
        uint32 arcEid_
    ) OApp(endpoint, owner_) Ownable(owner_) {
        require(usdg_ != address(0) && oft_ != address(0) && ethAdapter_ != address(0) && vault_ != address(0));
        usdg = IERC20(usdg_);
        oft = oft_;
        ethAdapter = bytes32(uint256(uint160(ethAdapter_)));
        vault = vault_;
        arcEid = arcEid_;
    }

    receive() external payable {}

    function lzCompose(address from, bytes32 guid, bytes calldata message, address, bytes calldata) external payable {
        if (msg.sender != address(endpoint)) revert NotEndpoint();
        if (from != oft) revert NotOft();
        if (message.length < 108) revert WrongComposer();
        uint256 amount = uint256(bytes32(message[12:44]));
        if (bytes32(message[44:76]) != ethAdapter) revert WrongComposer();
        bytes32 id = abi.decode(message[76:], (bytes32));
        if (guidUsed[guid] || received[id] != 0) revert Duplicate();
        guidUsed[guid] = true;
        received[id] = amount;
        usdg.safeTransfer(vault, amount);
        emit FloatReceived(id, guid, amount);
        bytes memory payload = abi.encode(id, guid, amount);
        MessagingFee memory fee = _quote(arcEid, payload, receiptOptions, false);
        _lzSend(arcEid, payload, receiptOptions, fee, payable(address(this)));
    }

    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal pure override {
        revert WrongComposer(); // this contract only sends
    }

    /// @dev Receipts are sent from inside `lzCompose`; the fee comes from this contract's own balance.
    function _payNative(uint256 nativeFee) internal view override returns (uint256) {
        if (address(this).balance < nativeFee) revert NotEnoughNative(address(this).balance);
        return nativeFee;
    }

    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}

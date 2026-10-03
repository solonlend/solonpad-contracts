// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    MerkleProof
} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";
import {Messages} from "./libs/Messages.sol";
import {CctpV2, ITokenMessengerV2, IMessageTransmitterV2} from "./libs/CctpV2.sol";

/// @title CanonicalGate — the hub's door to the canonical lane, on Arc
/// @notice Forked from ArcStocks v2 `CanonicalGate` (MIT, verified Arc 0xd82ead0b…4c56). Everything that
///         touches Circle lives here so the hub stays small and only ever sees two kinds of proof.
///         Outbound: the hub asks the gate to burn 1 USDC with a Deliver hook towards the Ethereum
///         bridger. Inbound: anyone redeems an attested message from the bridger carrying a vault
///         checkpoint; the hub then proves individual results against those checkpoints. The gate holds
///         only its own little USDC float. It cannot mint, pay or move anything else.
/// @dev Solon changes (A06 narrowed): the hook float is withdrawable only to the fixed `fundsRecipient`;
///      the bridger is set once and any later change waits `CONFIG_DELAY`; `ReentrancyGuardTransient`
///      is replaced by the storage `ReentrancyGuard` available in this repository (same semantics).
contract CanonicalGate is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant HOOK_AMOUNT = 1e6;
    uint64 public constant CONFIG_DELAY = 48 hours;

    ITokenMessengerV2 public immutable tokenMessenger;
    IMessageTransmitterV2 public immutable messageTransmitter;
    IERC20 public immutable usdc;
    uint32 public immutable ethereumDomain;
    bytes32 public immutable ethereumTokenMessenger;
    /// @notice The only contract that may send deliveries through the gate.
    address public immutable hub;
    /// @notice The only destination of hook-float withdrawals.
    address public immutable fundsRecipient;
    /// @notice The Ethereum bridger: hooks go to it, checkpoints come from it.
    address public bridger;
    address public keeper;
    address public pendingBridger;
    uint64 public pendingBridgerEta;

    Messages.Checkpoint[] private _checkpoints;

    event BridgerSet(address bridger);
    event BridgerProposed(address bridger, uint64 eta);
    event KeeperSet(address keeper);
    event DeliverSent(bytes32 indexed ref, address indexed to, Messages.DeliverMode mode);
    event CheckpointReceived(uint256 indexed index, bytes32 root, uint64 fromSeq, uint64 toSeq);
    event Funded(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error NotHub();
    error NotKeeper();
    error ZeroAddress();
    error WrongSource(uint32 domain, bytes32 sender);
    error NotFromBridger(bytes32 messageSender);
    error ReceiveFailed();
    error BadCheckpoint(uint256 index, uint64 seq);
    error BadProof();
    error InsufficientUsdc(uint256 have, uint256 need);
    error Timelocked();

    constructor(
        address tokenMessenger_,
        address messageTransmitter_,
        address usdc_,
        uint32 ethereumDomain_,
        address ethereumTokenMessenger_,
        address hub_,
        address fundsRecipient_,
        address owner_
    ) Ownable(owner_) {
        if (hub_ == address(0) || fundsRecipient_ == address(0)) revert ZeroAddress();
        tokenMessenger = ITokenMessengerV2(tokenMessenger_);
        messageTransmitter = IMessageTransmitterV2(messageTransmitter_);
        usdc = IERC20(usdc_);
        ethereumDomain = ethereumDomain_;
        ethereumTokenMessenger = CctpV2.toBytes32(ethereumTokenMessenger_);
        hub = hub_;
        fundsRecipient = fundsRecipient_;
    }

    /// @notice Solon: the hub forwards each canonical send's 1 USDC hook cost here as native value. On Arc
    ///         native USDC and the USDC ERC20 view are one balance, so this refills the hook float
    ///         (review #6: exits pay their own hook, the float cannot be drained by free 1-wei redeems).
    receive() external payable {}

    // ------------------------------------------------------------------ outbound (hub → Ethereum → vault)

    /// @notice Burn 1 USDC towards the bridger with the delivery as hook data. Hub only.
    function sendDeliver(Messages.Deliver calldata d) external nonReentrant {
        if (msg.sender != hub) revert NotHub();
        if (bridger == address(0)) revert ZeroAddress();
        uint256 have = usdc.balanceOf(address(this));
        if (have < HOOK_AMOUNT) revert InsufficientUsdc(have, HOOK_AMOUNT);
        usdc.forceApprove(address(tokenMessenger), HOOK_AMOUNT);
        tokenMessenger.depositForBurnWithHook(
            HOOK_AMOUNT,
            ethereumDomain,
            CctpV2.toBytes32(bridger),
            address(usdc),
            CctpV2.toBytes32(bridger),
            0,
            CctpV2.FINALITY_FINALIZED,
            Messages.encode(d)
        );
        emit DeliverSent(d.ref, d.to, d.mode);
    }

    // ------------------------------------------------------------------ inbound (vault → Ethereum → hub)

    /// @notice Redeem an attested CCTP message from the bridger carrying a vault checkpoint. Anyone.
    function relay(bytes calldata message, bytes calldata attestation) external nonReentrant {
        if (!messageTransmitter.receiveMessage(message, attestation)) revert ReceiveFailed();
        CctpV2.Parsed memory p = CctpV2.parse(message);
        if (p.sourceDomain != ethereumDomain || p.sender != ethereumTokenMessenger) {
            revert WrongSource(p.sourceDomain, p.sender);
        }
        if (CctpV2.toAddress(p.messageSender) != bridger) revert NotFromBridger(p.messageSender);
        Messages.Checkpoint memory c = Messages.decodeCheckpoint(p.hookData);
        _checkpoints.push(c);
        emit CheckpointReceived(_checkpoints.length - 1, c.root, c.fromSeq, c.toSeq);
    }

    /// @notice Reverts unless `r` is in checkpoint `index`. The hub calls this before applying a result.
    function verify(Messages.Result calldata r, uint256 index, bytes32[] calldata proof) external view {
        Messages.Checkpoint storage c = _checkpoints[index];
        if (r.seq < c.fromSeq || r.seq > c.toSeq) revert BadCheckpoint(index, r.seq);
        if (!MerkleProof.verify(proof, c.root, Messages.leaf(r))) revert BadProof();
    }

    function checkpointCount() external view returns (uint256) {
        return _checkpoints.length;
    }

    function checkpointAt(uint256 i) external view returns (Messages.Checkpoint memory) {
        return _checkpoints[i];
    }

    // ------------------------------------------------------------------ admin and float

    /// @notice First bridger immediately; any change after that waits `CONFIG_DELAY` (`executeBridger`).
    function setBridger(address bridger_) external onlyOwner {
        if (bridger_ == address(0)) revert ZeroAddress();
        if (bridger == address(0)) {
            bridger = bridger_;
            emit BridgerSet(bridger_);
            return;
        }
        pendingBridger = bridger_;
        pendingBridgerEta = uint64(block.timestamp) + CONFIG_DELAY;
        emit BridgerProposed(bridger_, pendingBridgerEta);
    }

    function executeBridger() external onlyOwner {
        if (pendingBridger == address(0) || block.timestamp < pendingBridgerEta) revert Timelocked();
        bridger = pendingBridger;
        pendingBridger = address(0);
        pendingBridgerEta = 0;
        emit BridgerSet(bridger);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function fund(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /// @notice Hook float back to the fixed `fundsRecipient` only.
    function withdraw(uint256 amount) external {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        usdc.safeTransfer(fundsRecipient, amount);
        emit Withdrawn(fundsRecipient, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Messages} from "../libs/Messages.sol";
import {CctpV2, ITokenMessengerV2, IMessageTransmitterV2} from "../libs/CctpV2.sol";
import {IInbox, IBridge, IOutbox} from "../libs/Arbitrum.sol";
import {IReserveVaultDeliver, IBridgerCheckpoint} from "../interfaces/IArcStocksV2.sol";

/// @title EthereumBridger — the canonical relay on Ethereum
/// @notice Forked from ArcStocks v2 `Bridger` (MIT, verified Ethereum 0x02bc6bba…ed05). Two one-way pipes
///         with no operator:
///
///           Arc (gate) ──CCTP──▶ relay() ──retryable ticket──▶ vault.deliver() on Robinhood Chain
///           Robinhood Chain ──outbox (7 days)──▶ acceptCheckpoint() ──CCTP hook──▶ gate on Arc
///
///         Anyone may call `relay` and `retry`; Circle's attestation and the rollup's outbox are the
///         only authorities. The bridger holds a little USDC (to pay the 1 USDC that carries a hook)
///         and nothing else of value.
/// @dev Solon changes (A06 narrowed): the hook float is withdrawable only to the fixed `fundsRecipient`;
///      `ReentrancyGuardTransient` is replaced by the storage `ReentrancyGuard` available in this repository.
contract EthereumBridger is Ownable2Step, ReentrancyGuard, IBridgerCheckpoint {
    using SafeERC20 for IERC20;

    IMessageTransmitterV2 public immutable messageTransmitter;
    ITokenMessengerV2 public immutable tokenMessenger;
    IERC20 public immutable usdc;
    IInbox public immutable inbox;
    IBridge public immutable bridge;
    /// @notice CCTP domain of Arc and its TokenMessengerV2, the only sender `relay` accepts.
    uint32 public immutable arcDomain;
    bytes32 public immutable arcTokenMessenger;
    /// @notice The canonical gate on Arc (the burn's `messageSender`, and where checkpoints are sent).
    address public immutable gate;
    address public immutable vault;
    /// @notice The only destination of hook-float withdrawals.
    address public immutable fundsRecipient;

    /// @notice Deliveries relayed from Arc, kept so a lapsed retryable can be re-created by anyone.
    mapping(bytes32 ref => Messages.Deliver) private _deliveries;
    mapping(bytes32 ref => bool) public relayed;
    /// @notice Checkpoints received from the rollup, forwarded to Arc as soon as USDC is on hand.
    Messages.Checkpoint[] private _checkpoints;
    uint256 public forwardedThrough;

    event Relayed(bytes32 indexed ref, address indexed underlying, uint128 shares, address to, uint256 ticket);
    event Retried(bytes32 indexed ref, uint256 ticket);
    event CheckpointAccepted(uint256 indexed index, bytes32 root, uint64 fromSeq, uint64 toSeq);
    event CheckpointForwarded(uint256 indexed index, bytes32 root);
    event Funded(uint256 amount);

    error WrongSource(uint32 domain, bytes32 sender);
    error NotFromGate(bytes32 messageSender);
    error ReceiveFailed();
    error UnknownRef(bytes32 ref);
    error NotOutbox(address sender);
    error NotFromVault(address l2Sender);
    error NothingToForward();
    error InsufficientUsdc(uint256 have, uint256 need);

    constructor(
        address messageTransmitter_,
        address tokenMessenger_,
        address usdc_,
        address inbox_,
        address bridge_,
        uint32 arcDomain_,
        address arcTokenMessenger_,
        address gate_,
        address vault_,
        address fundsRecipient_,
        address owner_
    ) Ownable(owner_) {
        require(fundsRecipient_ != address(0));
        fundsRecipient = fundsRecipient_;
        messageTransmitter = IMessageTransmitterV2(messageTransmitter_);
        tokenMessenger = ITokenMessengerV2(tokenMessenger_);
        usdc = IERC20(usdc_);
        inbox = IInbox(inbox_);
        bridge = IBridge(bridge_);
        arcDomain = arcDomain_;
        arcTokenMessenger = CctpV2.toBytes32(arcTokenMessenger_);
        gate = gate_;
        vault = vault_;
    }

    // ------------------------------------------------------------------ Arc → Robinhood Chain

    /// @notice Redeem an attested burn from the hub and turn its hook into a retryable ticket that
    ///         calls `vault.deliver`. `msg.value` pays the ticket (submission + L2 gas); the excess is
    ///         refunded on the rollup to `msg.sender`.
    function relay(bytes calldata message, bytes calldata attestation, uint256 gasLimit, uint256 maxFeePerGas)
        external
        payable
        nonReentrant
        returns (uint256 ticket)
    {
        if (!messageTransmitter.receiveMessage(message, attestation)) revert ReceiveFailed();
        CctpV2.Parsed memory p = CctpV2.parse(message);
        if (p.sourceDomain != arcDomain || p.sender != arcTokenMessenger) revert WrongSource(p.sourceDomain, p.sender);
        if (CctpV2.toAddress(p.messageSender) != gate) revert NotFromGate(p.messageSender);
        Messages.Deliver memory d = Messages.decodeDeliver(p.hookData);
        _deliveries[d.ref] = d;
        relayed[d.ref] = true;
        ticket = _ticket(d, gasLimit, maxFeePerGas);
        emit Relayed(d.ref, d.underlying, d.shares, d.to, ticket);
    }

    /// @notice A retryable ticket lives seven days; if nobody redeemed it, anyone re-creates it here.
    ///         The vault ignores a ref it already settled, so retrying is always safe.
    function retry(bytes32 ref, uint256 gasLimit, uint256 maxFeePerGas)
        external
        payable
        nonReentrant
        returns (uint256 ticket)
    {
        if (!relayed[ref]) revert UnknownRef(ref);
        ticket = _ticket(_deliveries[ref], gasLimit, maxFeePerGas);
        emit Retried(ref, ticket);
    }

    function deliveryOf(bytes32 ref) external view returns (Messages.Deliver memory) {
        return _deliveries[ref];
    }

    // ------------------------------------------------------------------ Robinhood Chain → Arc

    /// @notice Called by the rollup's outbox when a vault checkpoint is executed on Ethereum.
    function acceptCheckpoint(Messages.Checkpoint calldata c) external override nonReentrant {
        if (msg.sender != address(bridge)) revert NotOutbox(msg.sender);
        address l2Sender = IOutbox(bridge.activeOutbox()).l2ToL1Sender();
        if (l2Sender != vault) revert NotFromVault(l2Sender);
        _checkpoints.push(c);
        emit CheckpointAccepted(_checkpoints.length - 1, c.root, c.fromSeq, c.toSeq);
        if (usdc.balanceOf(address(this)) >= HOOK_AMOUNT) _forward();
    }

    /// @notice Sends every accepted-but-unforwarded checkpoint to the hub as a CCTP hook. Anyone.
    function forward() external nonReentrant {
        if (forwardedThrough == _checkpoints.length) revert NothingToForward();
        _forward();
    }

    function checkpointCount() external view returns (uint256) {
        return _checkpoints.length;
    }

    function checkpointAt(uint256 i) external view returns (Messages.Checkpoint memory) {
        return _checkpoints[i];
    }

    // ------------------------------------------------------------------ funds

    /// @notice USDC that rides along with hooks. 1 USDC per checkpoint; Standard Transfer, no fee.
    uint256 public constant HOOK_AMOUNT = 1e6;

    function fund(uint256 amount) external {
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(amount);
    }

    function withdraw(uint256 amount) external onlyOwner {
        usdc.safeTransfer(fundsRecipient, amount);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ internals

    function _ticket(Messages.Deliver memory d, uint256 gasLimit, uint256 maxFeePerGas) private returns (uint256) {
        bytes memory data = abi.encodeCall(IReserveVaultDeliver.deliver, (d));
        uint256 submission = inbox.calculateRetryableSubmissionFee(data.length, block.basefee);
        return inbox.createRetryableTicket{value: msg.value}(
            vault, 0, submission, msg.sender, msg.sender, gasLimit, maxFeePerGas, data
        );
    }

    function _forward() private {
        uint256 n = _checkpoints.length;
        for (uint256 i = forwardedThrough; i < n; ++i) {
            uint256 have = usdc.balanceOf(address(this));
            if (have < HOOK_AMOUNT) revert InsufficientUsdc(have, HOOK_AMOUNT);
            usdc.forceApprove(address(tokenMessenger), HOOK_AMOUNT);
            tokenMessenger.depositForBurnWithHook(
                HOOK_AMOUNT,
                arcDomain,
                CctpV2.toBytes32(gate),
                address(usdc),
                CctpV2.toBytes32(gate),
                0,
                CctpV2.FINALITY_FINALIZED,
                Messages.encode(_checkpoints[i])
            );
            forwardedThrough = i + 1;
            emit CheckpointForwarded(i, _checkpoints[i].root);
        }
    }
}

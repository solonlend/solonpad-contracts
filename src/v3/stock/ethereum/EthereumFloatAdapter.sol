// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SignatureChecker
} from "../../../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {CctpV2, ITokenMessengerV2, IMessageTransmitterV2} from "../libs/CctpV2.sol";
import {IOFTLike, SendParam, OFTReceipt, IStableConverter} from "../interfaces/IOFTLike.sol";
import {MessagingFee, MessagingReceipt} from "../lz/ILayerZeroEndpointV2.sol";

/// @title EthereumFloatAdapter — Ethereum leg of the candidate FloatRebalancer (design r5 §8.6 backup path)
/// @notice New Solon code; candidate, not accepted for production. Per rebalance id it advances
///         Attested (CCTP message from the fixed Arc rebalancer redeemed here; the CCTP nonce and the USDC
///         actually minted are recorded) → Converted (fixed whitelisted converter, signed net floor at most
///         30 bps under the input, actual output measured) → Bridging (USDG OFT send to the fixed RH
///         receiver with the id as compose message; the OFT GUID comes from the send receipt). Anything not
///         done by the rebalance deadline is quarantined here and can only go back to the Arc rebalancer as
///         USDC over CCTP; nothing is re-sent or re-spent. Keepers pay gas and fees; they choose nothing.
contract EthereumFloatAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_SLIPPAGE_BPS = 30;

    enum State {
        None,
        Attested,
        Converted,
        Bridging,
        Quarantined,
        Returned
    }

    struct Config {
        address messageTransmitter;
        address tokenMessenger;
        address usdc;
        address usdg;
        address converter;
        address oft;
        uint32 arcDomain;
        address arcTokenMessenger;
        address arcRebalancer;
        uint32 rhEid;
        address rhReceiver; // may be 0 at deployment and fixed once with setReceiver
        address signer;
        address owner;
    }

    struct ConvertQuote {
        bytes32 id;
        uint256 minOut; // USDG, 6 dp
        uint256 deadline;
        uint256 nonce;
    }

    struct Leg {
        State state;
        bytes32 cctpNonce;
        uint256 usdc;
        uint256 usdg;
        uint256 minUSDG;
        uint256 deadline;
        bytes32 guid;
    }

    IMessageTransmitterV2 public immutable messageTransmitter;
    ITokenMessengerV2 public immutable tokenMessenger;
    IERC20 public immutable usdc;
    IERC20 public immutable usdg;
    IStableConverter public immutable converter;
    IOFTLike public immutable oft;
    uint32 public immutable arcDomain;
    bytes32 public immutable arcTokenMessenger;
    address public immutable arcRebalancer;
    uint32 public immutable rhEid;
    address public immutable signer;
    address public immutable owner;
    address public rhReceiver;

    mapping(bytes32 id => Leg) private _legs;
    mapping(bytes32 cctpNonce => bytes32 id) public legOfNonce;
    mapping(uint256 nonce => bool) public quoteNonceUsed;

    event ReceiverSet(address receiver);
    event Attested(bytes32 indexed id, bytes32 cctpNonce, uint256 usdc);
    event Converted(bytes32 indexed id, uint256 usdcIn, uint256 usdgOut);
    event Bridged(bytes32 indexed id, bytes32 guid, uint256 amountSent, uint256 amountReceived);
    event LegQuarantined(bytes32 indexed id, State at);
    event ReturnedToArc(bytes32 indexed id, uint256 usdc);

    error WrongSource();
    error ReceiveFailed();
    error Duplicate();
    error BadQuote();
    error SlippageTooWide();
    error Expired();
    error WrongState(bytes32 id);
    error NotOwner();

    constructor(Config memory c) {
        require(
            c.messageTransmitter != address(0) && c.tokenMessenger != address(0) && c.usdc != address(0)
                && c.usdg != address(0) && c.converter != address(0) && c.oft != address(0)
                && c.arcRebalancer != address(0) && c.signer != address(0) && c.owner != address(0)
        );
        messageTransmitter = IMessageTransmitterV2(c.messageTransmitter);
        tokenMessenger = ITokenMessengerV2(c.tokenMessenger);
        usdc = IERC20(c.usdc);
        usdg = IERC20(c.usdg);
        converter = IStableConverter(c.converter);
        oft = IOFTLike(c.oft);
        arcDomain = c.arcDomain;
        arcTokenMessenger = CctpV2.toBytes32(c.arcTokenMessenger);
        arcRebalancer = c.arcRebalancer;
        rhEid = c.rhEid;
        rhReceiver = c.rhReceiver;
        signer = c.signer;
        owner = c.owner;
    }

    function setReceiver(address receiver) external {
        if (msg.sender != owner) revert NotOwner();
        if (rhReceiver != address(0) || receiver == address(0)) revert Duplicate();
        rhReceiver = receiver;
        emit ReceiverSet(receiver);
    }

    /// @notice Redeem the Arc rebalancer's CCTP burn for rebalance `id` (anyone may relay it).
    function attest(bytes calldata message, bytes calldata attestation) external nonReentrant {
        uint256 before = usdc.balanceOf(address(this));
        if (!messageTransmitter.receiveMessage(message, attestation)) revert ReceiveFailed();
        CctpV2.Parsed memory p = CctpV2.parse(message);
        if (
            p.sourceDomain != arcDomain || p.sender != arcTokenMessenger
                || CctpV2.toAddress(p.messageSender) != arcRebalancer
                || CctpV2.toAddress(p.mintRecipient) != address(this)
        ) revert WrongSource();
        (bytes32 id, uint256 minUSDG, uint256 deadline) = abi.decode(p.hookData, (bytes32, uint256, uint256));
        if (_legs[id].state != State.None || legOfNonce[p.nonce] != bytes32(0)) revert Duplicate();
        uint256 got = usdc.balanceOf(address(this)) - before;
        _legs[id] = Leg(State.Attested, p.nonce, got, 0, minUSDG, deadline, 0);
        legOfNonce[p.nonce] = id;
        emit Attested(id, p.nonce, got);
    }

    function quoteDigest(ConvertQuote memory q) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("SolonFloatConvert(bytes32 id,uint256 minOut,uint256 deadline,uint256 nonce)"),
                q.id,
                q.minOut,
                q.deadline,
                q.nonce,
                block.chainid,
                address(this),
                address(converter)
            )
        );
    }

    function convert(ConvertQuote calldata q, bytes calldata sig) external nonReentrant {
        Leg storage l = _legs[q.id];
        if (l.state != State.Attested) revert WrongState(q.id);
        if (block.timestamp > l.deadline) revert Expired();
        if (q.minOut * 10_000 < l.usdc * (10_000 - MAX_SLIPPAGE_BPS) || q.minOut < l.minUSDG) revert SlippageTooWide();
        if (
            block.timestamp > q.deadline || quoteNonceUsed[q.nonce]
                || !SignatureChecker.isValidSignatureNow(signer, quoteDigest(q), sig)
        ) revert BadQuote();
        quoteNonceUsed[q.nonce] = true;
        uint256 before = usdg.balanceOf(address(this));
        usdc.forceApprove(address(converter), l.usdc);
        converter.convert(address(usdc), address(usdg), l.usdc, q.minOut);
        usdc.forceApprove(address(converter), 0);
        uint256 out = usdg.balanceOf(address(this)) - before;
        if (out < q.minOut) revert SlippageTooWide();
        l.usdg = out;
        l.state = State.Converted;
        emit Converted(q.id, l.usdc, out);
    }

    /// @notice Send the converted USDG to the fixed RH receiver; `msg.value` pays the OFT message.
    function bridge(bytes32 id, bytes calldata extraOptions) external payable nonReentrant {
        Leg storage l = _legs[id];
        if (l.state != State.Converted || rhReceiver == address(0)) revert WrongState(id);
        if (block.timestamp > l.deadline) revert Expired();
        usdg.forceApprove(address(oft), l.usdg);
        (MessagingReceipt memory r, OFTReceipt memory o) = oft.send{value: msg.value}(
            SendParam(
                rhEid, bytes32(uint256(uint160(rhReceiver))), l.usdg, l.minUSDG, extraOptions, abi.encode(id), ""
            ),
            MessagingFee(msg.value, 0),
            msg.sender
        );
        usdg.forceApprove(address(oft), 0);
        if (o.amountReceivedLD < l.minUSDG) revert SlippageTooWide();
        l.guid = r.guid;
        l.state = State.Bridging;
        emit Bridged(id, r.guid, o.amountSentLD, o.amountReceivedLD);
    }

    /// @notice Past the rebalance deadline an unbridged leg is quarantined where it is.
    function expire(bytes32 id) external {
        Leg storage l = _legs[id];
        if ((l.state != State.Attested && l.state != State.Converted) || block.timestamp <= l.deadline) {
            revert WrongState(id);
        }
        emit LegQuarantined(id, l.state);
        l.state = State.Quarantined;
    }

    /// @notice A quarantined leg still holding its USDC goes back to the Arc rebalancer (the only place).
    ///         A leg quarantined after conversion must first be converted back off-chain-approved; not
    ///         implemented in this candidate (it stays quarantined and visible).
    function returnToArc(bytes32 id) external nonReentrant {
        Leg storage l = _legs[id];
        if (l.state != State.Quarantined || l.usdg != 0) revert WrongState(id);
        l.state = State.Returned;
        usdc.forceApprove(address(tokenMessenger), l.usdc);
        tokenMessenger.depositForBurnWithHook(
            l.usdc,
            arcDomain,
            CctpV2.toBytes32(arcRebalancer),
            address(usdc),
            CctpV2.toBytes32(arcRebalancer),
            0,
            CctpV2.FINALITY_FINALIZED,
            abi.encode(id)
        );
        emit ReturnedToArc(id, l.usdc);
    }

    function legOf(bytes32 id) external view returns (Leg memory) {
        return _legs[id];
    }
}

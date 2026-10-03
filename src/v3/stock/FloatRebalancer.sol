// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SignatureChecker
} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {OApp, Origin} from "./lz/OApp.sol";
import {CctpV2, ITokenMessengerV2, IMessageTransmitterV2} from "./libs/CctpV2.sol";

/// @title FloatRebalancer — optional acceleration-float mover, Arc → Robinhood Chain (design r5 §8.6)
/// @notice New Solon code; a CANDIDATE that is disabled by default and has not passed route acceptance.
///         It only moves money it holds itself (independently funded float, or the hub's free float sent to
///         it as one of the hub's two fixed float recipients); it never touches order escrow, fees, owed
///         payouts or reward budgets, and it never raises any capacity limit. Path (backup route of §8.6):
///         Arc USDC --CCTP (finalized)--> EthereumFloatAdapter --fixed converter--> USDG --USDG OFT (compose)
///         --> FloatReceiver --> ReserveVault; the receiver reports the OFT GUID and the amount actually
///         credited back over LayerZero, which finalizes the rebalance here. Each step is advanced only by
///         the receipt of the previous one (CCTP nonce on Ethereum, OFT GUID on RH). A rebalance that times
///         out is quarantined: its money stays counted in flight and can only come back through the adapter
///         as a CCTP return, never be spent twice. The reverse direction is not implemented.
contract FloatRebalancer is OApp, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant ENABLE_DELAY = 48 hours;

    enum State {
        None,
        Sent,
        Finalized,
        Quarantined,
        Returned
    }

    struct Config {
        address endpoint;
        address owner;
        address guardian;
        address usdc; // Arc USDC ERC20 view (same balance as native)
        address tokenMessenger;
        address messageTransmitter;
        uint32 ethDomain;
        address ethTokenMessenger;
        address ethAdapter;
        uint32 rhEid;
        address signer;
    }

    struct StartQuote {
        bytes32 id;
        uint256 amount; // USDC, 6 dp
        uint256 minUSDG; // signed net floor that must reach the reserve vault
        uint256 deadline; // end-to-end; after it the rebalance can be quarantined
        uint256 nonce;
    }

    struct Rebalance {
        State state;
        uint256 amount;
        uint256 minUSDG;
        uint256 deadline;
        bytes32 guid; // OFT GUID reported by the receiver
        uint256 received; // USDG actually credited to the vault
        uint256 returned; // USDC that came back after a quarantine
    }

    IERC20 public immutable usdc;
    ITokenMessengerV2 public immutable tokenMessenger;
    IMessageTransmitterV2 public immutable messageTransmitter;
    uint32 public immutable ethDomain;
    bytes32 public immutable ethTokenMessenger;
    address public immutable ethAdapter;
    uint32 public immutable rhEid;
    address public immutable signer;
    address public immutable guardian;

    bool public enabled;
    uint64 public enableEta;
    uint256 public inFlight;
    mapping(bytes32 id => Rebalance) private _rebalances;
    mapping(uint256 nonce => bool) public nonceUsed;

    event EnableProposed(uint64 eta);
    event EnabledSet(bool enabled);
    event Started(bytes32 indexed id, uint256 amount, uint256 minUSDG, uint256 deadline);
    event Finalized(bytes32 indexed id, bytes32 guid, uint256 received);
    event Quarantined(bytes32 indexed id);
    event ReturnedFunds(bytes32 indexed id, uint256 amount);
    event DustSwept(address indexed to, uint256 amount);

    error Disabled();
    error Timelocked();
    error BadQuote();
    error InsufficientFree();
    error WrongState(bytes32 id);
    error WrongSource();
    error ReceiveFailed();
    error NotGuardian();

    constructor(Config memory c) OApp(c.endpoint, c.owner) Ownable(c.owner) {
        require(
            c.usdc != address(0) && c.tokenMessenger != address(0) && c.messageTransmitter != address(0)
                && c.ethAdapter != address(0) && c.signer != address(0) && c.guardian != address(0)
        );
        usdc = IERC20(c.usdc);
        tokenMessenger = ITokenMessengerV2(c.tokenMessenger);
        messageTransmitter = IMessageTransmitterV2(c.messageTransmitter);
        ethDomain = c.ethDomain;
        ethTokenMessenger = CctpV2.toBytes32(c.ethTokenMessenger);
        ethAdapter = c.ethAdapter;
        rhEid = c.rhEid;
        signer = c.signer;
        guardian = c.guardian;
    }

    // ------------------------------------------------------------------ switch

    function proposeEnable() external onlyOwner {
        enableEta = uint64(block.timestamp) + ENABLE_DELAY;
        emit EnableProposed(enableEta);
    }

    function enable() external onlyOwner {
        if (enableEta == 0 || block.timestamp < enableEta) revert Timelocked();
        enableEta = 0;
        enabled = true;
        emit EnabledSet(true);
    }

    /// @notice The guardian or owner may switch the candidate off at once.
    function disable() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        enabled = false;
        enableEta = 0;
        emit EnabledSet(false);
    }

    // ------------------------------------------------------------------ flow

    function quoteDigest(StartQuote memory q) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "SolonFloatRebalance(bytes32 id,uint256 amount,uint256 minUSDG,uint256 deadline,uint256 nonce,uint256 chainId,address rebalancer,address ethAdapter,uint32 rhEid)"
                ),
                q.id,
                q.amount,
                q.minUSDG,
                q.deadline,
                q.nonce,
                block.chainid,
                address(this),
                ethAdapter,
                rhEid
            )
        );
    }

    /// @return ok whether `amount` could start now; `free` this contract's own USDC; `inFlight_` money out.
    function previewRebalance(uint256 amount) external view returns (bool ok, uint256 free, uint256 inFlight_) {
        free = usdc.balanceOf(address(this));
        return (enabled && amount != 0 && amount <= free, free, inFlight);
    }

    function start(StartQuote calldata q, bytes calldata sig) external nonReentrant {
        if (!enabled) revert Disabled();
        if (
            q.id == 0 || q.amount == 0 || q.minUSDG == 0 || q.minUSDG > q.amount || block.timestamp >= q.deadline
                || nonceUsed[q.nonce] || _rebalances[q.id].state != State.None
                || !SignatureChecker.isValidSignatureNow(signer, quoteDigest(q), sig)
        ) revert BadQuote();
        if (q.amount > usdc.balanceOf(address(this))) revert InsufficientFree();
        nonceUsed[q.nonce] = true;
        _rebalances[q.id] = Rebalance(State.Sent, q.amount, q.minUSDG, q.deadline, 0, 0, 0);
        inFlight += q.amount;
        usdc.forceApprove(address(tokenMessenger), q.amount);
        tokenMessenger.depositForBurnWithHook(
            q.amount,
            ethDomain,
            CctpV2.toBytes32(ethAdapter),
            address(usdc),
            CctpV2.toBytes32(ethAdapter),
            0,
            CctpV2.FINALITY_FINALIZED,
            abi.encode(q.id, q.minUSDG, q.deadline)
        );
        emit Started(q.id, q.amount, q.minUSDG, q.deadline);
    }

    /// @notice After its deadline an unfinished rebalance is quarantined: still in flight, never re-spent.
    function expire(bytes32 id) external {
        Rebalance storage r = _rebalances[id];
        if (r.state != State.Sent || block.timestamp <= r.deadline) revert WrongState(id);
        r.state = State.Quarantined;
        emit Quarantined(id);
    }

    /// @notice A quarantined (or unfinished) rebalance's USDC came back from the adapter through CCTP.
    function receiveReturn(bytes calldata message, bytes calldata attestation) external nonReentrant {
        uint256 before = usdc.balanceOf(address(this));
        if (!messageTransmitter.receiveMessage(message, attestation)) revert ReceiveFailed();
        CctpV2.Parsed memory p = CctpV2.parse(message);
        if (
            p.sourceDomain != ethDomain || p.sender != ethTokenMessenger
                || CctpV2.toAddress(p.messageSender) != ethAdapter
        ) revert WrongSource();
        bytes32 id = abi.decode(p.hookData, (bytes32));
        Rebalance storage r = _rebalances[id];
        if (r.state != State.Sent && r.state != State.Quarantined) revert WrongState(id);
        r.state = State.Returned;
        r.returned = usdc.balanceOf(address(this)) - before;
        inFlight -= r.amount;
        emit ReturnedFunds(id, r.returned);
    }

    /// @dev The RH receiver reports (id, OFT guid, USDG actually credited to the vault).
    function _lzReceive(Origin calldata origin, bytes32, bytes calldata message, address, bytes calldata)
        internal
        override
    {
        if (origin.srcEid != rhEid) revert WrongSource();
        (bytes32 id, bytes32 guid, uint256 received) = abi.decode(message, (bytes32, bytes32, uint256));
        Rebalance storage r = _rebalances[id];
        if (r.state != State.Sent && r.state != State.Quarantined) revert WrongState(id);
        r.state = State.Finalized;
        r.guid = guid;
        r.received = received;
        inFlight -= r.amount;
        emit Finalized(id, guid, received);
    }

    /// @notice The hub's withdrawFloat pays NATIVE USDC (18 dp); it is the same money as the 0x3600 view spent here.
    receive() external payable {}

    /// @notice Only the sub-1e12 native tail the 6-dp view cannot move; whole units (the float) are never touched.
    function sweepDust(address to) external onlyOwner {
        uint256 dust = address(this).balance % 1e12;
        if (dust == 0) return;
        (bool ok,) = to.call{value: dust}("");
        if (!ok) revert ReceiveFailed();
        emit DustSwept(to, dust);
    }

    function rebalanceOf(bytes32 id) external view returns (Rebalance memory) {
        return _rebalances[id];
    }

    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}

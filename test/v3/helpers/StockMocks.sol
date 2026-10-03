// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "../../../src/v3/stock/lz/ILayerZeroEndpointV2.sol";
import {IFundingRoute, IFundingReturnSink, IReserveFunding} from "../../../src/v3/stock/interfaces/IFundingRoute.sol";
import {IExecutionVenue} from "../../../src/v3/stock/interfaces/IExecutionVenue.sol";
import {CctpV2} from "../../../src/v3/stock/libs/CctpV2.sol";

interface ILzReceiverLike {
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address executor,
        bytes calldata extraData
    ) external payable;
}

interface ILzComposerLike {
    function lzCompose(address from, bytes32 guid, bytes calldata message, address executor, bytes calldata extraData)
        external
        payable;
}

/// @notice LayerZero EndpointV2 test double: records outbound packets; `deliver` executes one on the
///         destination endpoint exactly like the real executor path (endpoint -> OApp.lzReceive).
contract MockLzEndpoint {
    struct Packet {
        uint32 dstEid;
        bytes32 receiver;
        address sender;
        bytes message;
        uint64 nonce;
        bool delivered;
    }

    uint32 public immutable eid;
    uint256 public nativeFee = 0.01 ether;
    Packet[] public packets;
    mapping(address => address) public delegates;
    mapping(uint32 => MockLzEndpoint) public remote;
    uint64 public nonce;

    constructor(uint32 eid_) {
        eid = eid_;
    }

    function connect(MockLzEndpoint other) external {
        remote[other.eid()] = other;
    }

    function setFee(uint256 fee) external {
        nativeFee = fee;
    }

    function setDelegate(address d) external {
        delegates[msg.sender] = d;
    }

    function lzToken() external pure returns (address) {
        return address(0);
    }

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, 0);
    }

    function send(MessagingParams calldata p, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory r)
    {
        require(msg.value >= nativeFee, "lz fee");
        packets.push(Packet(p.dstEid, p.receiver, msg.sender, p.message, ++nonce, false));
        if (msg.value > nativeFee) {
            (bool ok,) = refundAddress.call{value: msg.value - nativeFee}("");
            require(ok);
        }
        r = MessagingReceipt(keccak256(abi.encode(eid, nonce)), nonce, MessagingFee(nativeFee, 0));
    }

    function packetCount() external view returns (uint256) {
        return packets.length;
    }

    function packetMessage(uint256 i) external view returns (bytes memory) {
        return packets[i].message;
    }

    /// @notice Deliver outbound packet `i` to its destination endpoint.
    function deliver(uint256 i) external {
        Packet storage p = packets[i];
        require(!p.delivered, "delivered");
        p.delivered = true;
        remote[p.dstEid].execute(
            Origin(eid, bytes32(uint256(uint160(p.sender))), p.nonce), address(uint160(uint256(p.receiver))), p.message
        );
    }

    /// @notice Deliver packet `i` again (a duplicate / replayed message).
    function redeliver(uint256 i) external {
        Packet storage p = packets[i];
        remote[p.dstEid].execute(
            Origin(eid, bytes32(uint256(uint160(p.sender))), p.nonce), address(uint160(uint256(p.receiver))), p.message
        );
    }

    function execute(Origin calldata origin, address receiver, bytes calldata message) external {
        ILzReceiverLike(receiver).lzReceive(origin, keccak256(abi.encode(origin)), message, address(this), "");
    }

    /// @notice Execute an LZ compose on `to` as this endpoint (OFT compose delivery).
    function composeTo(address to, address from, bytes32 guid, bytes calldata message) external {
        ILzComposerLike(to).lzCompose(from, guid, message, address(this), "");
    }

    /// @notice Inject an arbitrary packet as if it came from `sender` on `srcEid` (forgery tests).
    function inject(uint32 srcEid, address sender, address receiver, bytes calldata message) external {
        ILzReceiverLike(receiver)
            .lzReceive(Origin(srcEid, bytes32(uint256(uint160(sender))), 999), bytes32(0), message, address(this), "");
    }

    receive() external payable {}
}

contract MockUSDG is ERC20 {
    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRHStock is ERC20 {
    uint256 public uiMultiplier = 1e18;
    mapping(address => bool) public blocked;

    constructor() ERC20("NVIDIA Robinhood Token", "NVDA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMultiplier(uint256 m) external {
        uiMultiplier = m;
    }

    function setBlocked(address who, bool b) external {
        blocked[who] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// @notice Venue double: fixed price in USDG (6 dp) per 1e18 raw; can be told to fail.
contract MockVenue is IExecutionVenue {
    IERC20 public immutable usdg;
    MockRHStock public immutable stock;
    uint256 public pricePerShare6 = 100e6; // $100 per 1e18 raw
    bool public fail;
    uint256 public shortBy; // report more than delivered (lying venue)

    constructor(IERC20 usdg_, MockRHStock stock_) {
        usdg = usdg_;
        stock = stock_;
    }

    function setPrice(uint256 p) external {
        pricePerShare6 = p;
    }

    function setFail(bool f) external {
        fail = f;
    }

    function setShortBy(uint256 s) external {
        shortBy = s;
    }

    function buy(address, uint256 settlementIn, uint256 minSharesOut, address recipient)
        external
        returns (uint256 sharesOut)
    {
        require(!fail, "venue fail");
        usdg.transferFrom(msg.sender, address(this), settlementIn);
        sharesOut = settlementIn * 1e18 / pricePerShare6;
        require(sharesOut >= minSharesOut, "min");
        stock.mint(recipient, sharesOut - shortBy);
    }

    function sell(address, uint256 sharesIn, uint256 minSettlementOut, address recipient)
        external
        returns (uint256 settlementOut)
    {
        require(!fail, "venue fail");
        stock.transferFrom(msg.sender, address(this), sharesIn);
        settlementOut = sharesIn * pricePerShare6 / 1e18;
        require(settlementOut >= minSettlementOut, "min");
        MockUSDG(address(usdg)).mint(recipient, settlementOut);
    }

    function settlementToken() external view returns (address) {
        return address(usdg);
    }

    function isSupported(address s) external view returns (bool) {
        return s == address(stock);
    }
}

/// @notice Arc-side native funding route double. Records each send; the test plays the solver/bridge:
///         `fill` pays USDG to the reserve vault for the ref, `refund` returns native to the hub.
contract MockNativeRoute is IFundingRoute {
    struct Sent {
        bytes32 ref;
        uint256 amountIn;
        uint256 fee;
        uint256 minOut;
        bool done;
    }

    address public immutable caller;
    address public destination;
    MockUSDG public immutable usdg;
    Sent[] public sent;
    bool public rejectQuotes;

    constructor(address caller_, address destination_, MockUSDG usdg_) {
        caller = caller_;
        destination = destination_;
        usdg = usdg_;
    }

    function setDestination(address d) external {
        destination = d;
    }

    function setReject(bool r) external {
        rejectQuotes = r;
    }

    function asset() external pure returns (address) {
        return address(0);
    }

    function validate(bytes32, uint256, uint256, uint256, bytes calldata q) public view {
        require(!rejectQuotes && keccak256(q) == keccak256("ok"), "bad quote");
    }

    function send(bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, bytes calldata q)
        external
        payable
        returns (bytes32)
    {
        require(msg.sender == caller, "caller");
        validate(ref, amountIn, fee, minOut, q);
        require(msg.value == amountIn + fee, "value");
        sent.push(Sent(ref, amountIn, fee, minOut, false));
        return keccak256(abi.encode(ref, sent.length));
    }

    function sentCount() external view returns (uint256) {
        return sent.length;
    }

    /// @notice Solver fills on the reserve chain: pays `amount` USDG to the vault for the ref.
    function fill(uint256 i, uint256 amount) external {
        Sent storage s = sent[i];
        require(!s.done);
        s.done = true;
        usdg.mint(address(this), amount);
        usdg.approve(destination, amount);
        IReserveFunding(destination).fund(s.ref, amount);
    }

    /// @notice The intent expired: the source-side refund comes back to the hub for the ref.
    function refund(uint256 i, uint256 amount) external {
        Sent storage s = sent[i];
        require(!s.done);
        s.done = true;
        IFundingReturnSink(caller).receiveReturn{value: amount}(s.ref);
    }

    /// @notice Credit an inbound return (proceeds or refund bridged back from the reserve chain).
    function deliverReturnFor(bytes32 ref) external payable {
        IFundingReturnSink(caller).receiveReturn{value: msg.value}(ref);
    }

    receive() external payable {}
}

/// @notice RH-side USDG return route double: pulls USDG from the vault; `complete` delivers native to
///         the Arc hub through the Arc route's authority (tests pass the hub address directly).
contract MockTokenRoute is IFundingRoute {
    struct Sent {
        bytes32 ref;
        uint256 amountIn;
        uint256 minOut;
        bool done;
    }

    address public caller;
    address public immutable destination;
    IERC20 public immutable token;
    Sent[] public sent;

    constructor(address destination_, IERC20 token_) {
        destination = destination_;
        token = token_;
    }

    function setCaller(address c) external {
        caller = c;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function validate(bytes32, uint256, uint256, uint256, bytes calldata q) public pure {
        require(keccak256(q) == keccak256("ok"), "bad quote");
    }

    function send(bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, bytes calldata q)
        external
        payable
        returns (bytes32)
    {
        require(msg.sender == caller, "caller");
        validate(ref, amountIn, fee, minOut, q);
        token.transferFrom(msg.sender, address(this), amountIn + fee);
        sent.push(Sent(ref, amountIn, minOut, false));
        return keccak256(abi.encode(ref, sent.length));
    }

    function sentCount() external view returns (uint256) {
        return sent.length;
    }

    /// @notice Deliver the Arc side of a return: `native18` of native USDC to the hub for the ref.
    ///         The Arc route is the hub's authority, so the test calls through `arcRoute`.
    function complete(uint256 i, address payable arcRoute, uint256 native18) external payable {
        Sent storage s = sent[i];
        require(!s.done && msg.value == native18);
        s.done = true;
        MockNativeRoute(arcRoute).deliverReturnFor{value: native18}(s.ref);
    }
}

contract MockArbSys {
    struct L1Call {
        address destination;
        bytes data;
    }

    L1Call[] public calls;

    function sendTxToL1(address destination, bytes calldata data) external payable returns (uint256) {
        calls.push(L1Call(destination, data));
        return calls.length;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function callData(uint256 i) external view returns (bytes memory) {
        return calls[i].data;
    }
}

/// @notice Circle TokenMessengerV2 double: pulls the burn amount and records the hook.
contract MockTokenMessenger {
    struct Burn {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinality;
        bytes hookData;
        address sender;
    }

    Burn[] public burns;

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        IERC20(burnToken).transferFrom(msg.sender, address(this), amount);
        burns.push(
            Burn(
                amount,
                destinationDomain,
                mintRecipient,
                burnToken,
                destinationCaller,
                maxFee,
                minFinalityThreshold,
                hookData,
                msg.sender
            )
        );
    }

    function burnCount() external view returns (uint256) {
        return burns.length;
    }

    function hookOf(uint256 i) external view returns (bytes memory) {
        return burns[i].hookData;
    }

    function finalityOf(uint256 i) external view returns (uint32) {
        return burns[i].minFinality;
    }
}

/// @notice Circle MessageTransmitterV2 double: "valid" attests; each message can be received once.
///         With a mint token set, it mints the burn amount to the message's mint recipient like CCTP.
contract MockMessageTransmitter {
    mapping(bytes32 => bool) public used;
    address public mintToken;

    function setMintToken(address t) external {
        mintToken = t;
    }

    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool) {
        if (keccak256(attestation) != keccak256("valid")) return false;
        bytes32 h = keccak256(message);
        if (used[h]) return false;
        used[h] = true;
        if (mintToken != address(0)) {
            CctpV2.Parsed memory p = CctpV2.parse(message);
            MockUSDG(mintToken).mint(CctpV2.toAddress(p.mintRecipient), p.amount);
        }
        return true;
    }
}

/// @notice Arbitrum parent-chain Bridge + Outbox double: executes an L2->L1 message from `l2Sender`.
contract MockArbBridge {
    address public l2ToL1Sender;

    function activeOutbox() external view returns (address) {
        return address(this);
    }

    function executeCall(address l2Sender, address to, bytes calldata data) external returns (bytes memory) {
        l2ToL1Sender = l2Sender;
        (bool ok, bytes memory ret) = to.call(data);
        l2ToL1Sender = address(0);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }
}

/// @notice Arbitrum Delayed Inbox double: records retryable tickets.
contract MockInbox {
    struct Ticket {
        address to;
        bytes data;
        uint256 value;
    }

    Ticket[] public tickets;

    function createRetryableTicket(
        address to,
        uint256,
        uint256,
        address,
        address,
        uint256,
        uint256,
        bytes calldata data
    ) external payable returns (uint256) {
        tickets.push(Ticket(to, data, msg.value));
        return tickets.length;
    }

    function calculateRetryableSubmissionFee(uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function ticketCount() external view returns (uint256) {
        return tickets.length;
    }

    function ticketData(uint256 i) external view returns (address, bytes memory) {
        return (tickets[i].to, tickets[i].data);
    }
}

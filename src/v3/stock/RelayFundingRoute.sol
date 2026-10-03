// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SignatureChecker
} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {IFundingRoute, IFundingReturnSink} from "./interfaces/IFundingRoute.sol";

interface IRelayDepositoryV2 {
    function depositErc20(address depositor, address token, uint256 amount, bytes32 id) external;
}

/// @title RelayFundingRoute — the preferred zero-float money leg (design r5 §8.5/§8.6)
/// @notice New Solon code. One immutable route per direction: Arc native USDC → RH USDG (caller = hub)
///         or RH USDG → Arc native USDC (caller = reserve vault). Each `send` carries exactly one order's
///         money to the fixed Relay depository (v2 deposit entry points), tagged with the Relay request id that Solon's quote
///         signer bound to that order (ref, amounts, destination, minimum out, deadline, nonce). The route
///         never chooses recipients, holds no balance and accepts no arbitrary calldata.
///
///         Inbound returns on Arc (refunds of unfilled intents, sale proceeds) are credited to the hub for a
///         ref only through `receiveReturnFor`, callable only by the fixed Relay executor on this chain.
/// @dev r12 (fork finding F1): deposits use the Relay depository v2 entry points — `depositNative(depositor, id)`
///      for the native asset (Arc USDC) and `depositErc20(depositor, token, amount, id)` for a token (RH USDG), with
///      `id` = the signed Relay request id and `depositor` = the fixed caller (hub / reserve vault: Relay credits and
///      refunds it, never the route). Source: relayprotocol/relay-depository packages/ethereum-vm/src/RelayDepository.sol
///      (commit 458a64c) and docs.relay.link/references/protocol/contracts/evm-depository; the live depository
///      0x4cD00E387622C35bDDB9b4c962C136462338BC31 (Arc 5042 + RH 4663, 8,628 B) exposes both selectors. The old raw
///      `call{value}(requestId)` reverts there and a bare ERC-20 transfer emits no deposit event. Solver settlement and
///      the return executor still need a small live drill before enabling.
/// @dev r14 (live $5 probe, Arc tx 0xb55e59e2…386ad, 2026-10-01): a `depositNative` deposit lands on chain but Relay
///      fails the order with ORIGIN_CURRENCY_MISMATCH — Relay prices Arc native USDC as its ERC-20 view
///      0x3600000000000000000000000000000000000000 (6 dp) and only accepts `depositErc20(depositor, 0x3600…, amount6, id)`
///      (the API's own Arc step is router multicall -> that call). The native arm therefore approves `nativeToken` (the
///      view, which moves the same native balance) to the depository and calls `depositErc20` with
///      amount6 = (amountIn + fee) / 1e12. The sub-6-dp remainder (< 1e12 wei) is never deposited: it goes straight back to
///      the caller in the same call, so nothing is lost and nothing stays in the route. Source: relayprotocol/
///      relay-depository packages/ethereum-vm/src/RelayDepository.sol (commit 1f3bc34: depositErc20 = safeTransferFrom
///      msg.sender -> depository, then RelayErc20Deposit(depositor, token, amount, id)) and
///      docs.relay.link/references/protocol/contracts/evm-depository.
contract RelayFundingRoute is IFundingRoute, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Config {
        address caller; // Arc hub or RH reserve vault
        address asset; // address(0) = native
        address destination; // RH vault (Arc route) or Arc hub (RH route)
        uint256 destinationChainId;
        address depository; // Relay deposit receiver on this chain
        address signer; // Solon quote signer
        address returnExecutor; // Relay fill executor allowed to credit returns (Arc only; 0 = disabled)
        address nativeToken; // native routes: ERC-20 view of the native asset Relay prices (Arc 0x3600…, 6 dp); else 0
    }

    struct Quote {
        bytes32 requestId;
        uint256 deadline;
        uint256 nonce;
    }

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "RelayFunding(bytes32 ref,uint256 amountIn,uint256 fee,uint256 minOut,bytes32 requestId,uint256 deadline,uint256 nonce,address caller,address asset,address destination,uint256 destinationChainId,address depository)"
    );

    address public immutable caller;
    address public immutable asset;
    address public immutable destination;
    uint256 public immutable destinationChainId;
    address public immutable depository;
    address public immutable signer;
    address public immutable returnExecutor;
    address public immutable nativeToken;

    /// @notice Native (18 dp) units per `nativeToken` (6 dp) unit.
    uint256 public constant NATIVE_SCALE = 1e12;

    mapping(uint256 nonce => bool) public nonceUsed;
    mapping(bytes32 requestId => bytes32 ref) public requestRef;

    event Sent(bytes32 indexed ref, bytes32 indexed requestId, uint256 amountIn, uint256 fee, uint256 minOut);
    event ReturnCredited(bytes32 indexed ref, uint256 amount);
    event DustReturned(bytes32 indexed ref, uint256 amount);

    error NotCaller();
    error NotExecutor();
    error BadQuote();
    error BadValue();
    error DepositFailed();

    constructor(Config memory c) {
        require(
            c.caller != address(0) && c.destination != address(0) && c.destinationChainId != 0
                && c.depository != address(0) && c.signer != address(0)
                && (c.asset == address(0)) == (c.nativeToken != address(0))
        );
        caller = c.caller;
        asset = c.asset;
        destination = c.destination;
        destinationChainId = c.destinationChainId;
        depository = c.depository;
        signer = c.signer;
        returnExecutor = c.returnExecutor;
        nativeToken = c.nativeToken;
    }

    function quoteDigest(bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, Quote memory q)
        public
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SolonRelayFundingRoute"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        bytes32 data = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                ref,
                amountIn,
                fee,
                minOut,
                q.requestId,
                q.deadline,
                q.nonce,
                caller,
                asset,
                destination,
                destinationChainId,
                depository
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, data));
    }

    function validate(bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, bytes calldata quote) public view {
        (Quote memory q, bytes memory sig) = abi.decode(quote, (Quote, bytes));
        if (
            amountIn == 0 || minOut == 0 || block.timestamp > q.deadline || nonceUsed[q.nonce] || q.requestId == 0
                || requestRef[q.requestId] != bytes32(0)
                || !SignatureChecker.isValidSignatureNow(signer, quoteDigest(ref, amountIn, fee, minOut, q), sig)
        ) revert BadQuote();
    }

    function send(bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, bytes calldata quote)
        external
        payable
        nonReentrant
        returns (bytes32 transferId)
    {
        if (msg.sender != caller) revert NotCaller();
        validate(ref, amountIn, fee, minOut, quote);
        (Quote memory q,) = abi.decode(quote, (Quote, bytes));
        nonceUsed[q.nonce] = true;
        requestRef[q.requestId] = ref == bytes32(0) ? bytes32(type(uint256).max) : ref;
        uint256 total = amountIn + fee;
        if (asset == address(0)) {
            if (msg.value != total) revert BadValue();
            uint256 amount6 = total / NATIVE_SCALE;
            uint256 dust = total - amount6 * NATIVE_SCALE;
            if (amount6 == 0) revert BadValue();
            IERC20 view_ = IERC20(nativeToken);
            uint256 before = depository.balance;
            view_.forceApprove(depository, amount6);
            (bool ok,) = depository.call(
                abi.encodeCall(IRelayDepositoryV2.depositErc20, (caller, nativeToken, amount6, q.requestId))
            );
            if (
                !ok || depository.balance != before + amount6 * NATIVE_SCALE
                    || view_.allowance(address(this), depository) != 0
            ) revert DepositFailed();
            if (dust != 0) {
                (bool back,) = caller.call{value: dust}("");
                if (!back) revert DepositFailed();
                emit DustReturned(ref, dust);
            }
        } else {
            if (msg.value != 0) revert BadValue();
            IERC20 token = IERC20(asset);
            token.safeTransferFrom(msg.sender, address(this), total);
            uint256 before = token.balanceOf(depository);
            token.forceApprove(depository, total);
            (bool ok,) = depository.call(
                abi.encodeCall(IRelayDepositoryV2.depositErc20, (caller, asset, total, q.requestId))
            );
            if (
                !ok || token.balanceOf(depository) != before + total || token.allowance(address(this), depository) != 0
            ) revert DepositFailed();
        }
        transferId = q.requestId;
        emit Sent(ref, q.requestId, amountIn, fee, minOut);
    }

    /// @notice Credit money that came back for `ref` (Arc side only).
    function receiveReturnFor(bytes32 ref) external payable nonReentrant {
        if (returnExecutor == address(0) || msg.sender != returnExecutor) revert NotExecutor();
        IFundingReturnSink(caller).receiveReturn{value: msg.value}(ref);
        emit ReturnCredited(ref, msg.value);
    }
}

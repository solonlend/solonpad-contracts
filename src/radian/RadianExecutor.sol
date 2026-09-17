// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PonsV2LaunchFactory} from "../v2/PonsV2LaunchFactory.sol";
import {IPonsV2LaunchFactory} from "../v2/interfaces/ILaunchpadV2.sol";

interface IExecCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
}

/// @title RadianExecutor
/// @notice Delegated buys with bounded authority. A user deposits quote here,
///         signs one EIP-712 `BuyAuth` (per-buy cap, gas-price cap, count,
///         spacing, deadline, nonce), and the platform keeper executes buys on
///         the user's behalf — recurring buys ("DCA"), timed entries — with the
///         tokens always delivered to the user. Nothing the keeper does can move
///         funds anywhere but the user's wallet or the launch's curve.
///
///         Borrowed discipline: the service fee is a `constant` (no later hike),
///         charged on the quote actually spent (a clamped fill refunds the
///         user's ledger); the keeper earns a fixed gas stipend, never a
///         self-reported cost; every exit (`withdraw`, `cancelAuth`) works
///         without the keeper or any frontend.
contract RadianExecutor {
    using SafeERC20 for IERC20;

    struct BuyAuth {
        address user;
        address token; // launch token (its curve + quote asset come from the factory)
        uint256 perBuyMax; // quote units per execution
        uint256 maxGasPrice; // caps the stipend the keeper can charge
        uint32 totalCount;
        uint32 minInterval; // seconds between executions
        uint64 deadline;
        uint256 nonce; // must equal nonces[user]; cancelAuth bumps it
    }

    struct Exec {
        uint32 count;
        uint64 lastAt;
    }

    bytes32 public constant AUTH_TYPEHASH = keccak256(
        "BuyAuth(address user,address token,uint256 perBuyMax,uint256 maxGasPrice,uint32 totalCount,uint32 minInterval,uint64 deadline,uint256 nonce)"
    );
    uint256 public constant FEE_BPS = 50; // 0.5% of quote spent, fixed forever
    uint256 public constant GAS_STIPEND = 300_000; // gas units × min(tx.gasprice, auth.maxGasPrice)
    uint256 private constant BPS = 10_000;
    address private constant NATIVE = address(0);

    PonsV2LaunchFactory public immutable factory;
    bytes32 public immutable DOMAIN_SEPARATOR;
    address public keeper;

    mapping(address user => mapping(address asset => uint256)) public balanceOf; // asset 0 = native quote
    mapping(address user => uint256) public nonces;
    mapping(bytes32 authId => Exec) public execs;
    mapping(address asset => uint256) public feePool;
    mapping(address keeper => uint256) public gasCredit;

    uint256 private _lock = 1;

    event Deposited(address indexed user, address indexed asset, uint256 amount);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount, address to);
    event AuthCancelled(address indexed user, uint256 newNonce);
    event Executed(bytes32 indexed authId, address indexed user, address indexed token, uint256 spent, uint256 fee, uint256 tokensOut, uint256 stipend);
    event KeeperSet(address keeper);
    event FeesWithdrawn(address indexed asset, address to, uint256 amount);
    event GasClaimed(address indexed keeper, uint256 amount);

    error NotKeeper();
    error NotOwner();
    error BadSignature();
    error AuthExpired();
    error AuthExhausted();
    error TooSoon();
    error OverCap();
    error UnknownToken();
    error Insufficient();

    modifier nonReentrant() {
        require(_lock != 2, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(PonsV2LaunchFactory factory_) {
        require(address(factory_) != address(0), "zero");
        factory = factory_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("RadianExecutor"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ---- user: funds + authority ----

    function deposit() external payable {
        require(msg.value > 0, "zero");
        balanceOf[msg.sender][NATIVE] += msg.value;
        emit Deposited(msg.sender, NATIVE, msg.value);
    }

    function depositToken(address asset, uint256 amount) external nonReentrant {
        require(asset != NATIVE && amount > 0, "bad");
        IERC20 t = IERC20(asset);
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = t.balanceOf(address(this)) - before;
        balanceOf[msg.sender][asset] += got;
        emit Deposited(msg.sender, asset, got);
    }

    /// @notice Always available: no keeper, no signature, no frontend needed.
    function withdraw(address asset, uint256 amount, address to) external nonReentrant {
        require(to != address(0) && amount > 0, "bad");
        uint256 bal = balanceOf[msg.sender][asset];
        if (bal < amount) revert Insufficient();
        balanceOf[msg.sender][asset] = bal - amount;
        _pay(asset, to, amount);
        emit Withdrawn(msg.sender, asset, amount, to);
    }

    /// @notice Voids every outstanding authorization of the caller.
    function cancelAuth() external {
        uint256 n = ++nonces[msg.sender];
        emit AuthCancelled(msg.sender, n);
    }

    function authId(BuyAuth calldata a) public pure returns (bytes32) {
        return keccak256(abi.encode(a.user, a.token, a.perBuyMax, a.maxGasPrice, a.totalCount, a.minInterval, a.deadline, a.nonce));
    }

    function hashAuth(BuyAuth calldata a) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(AUTH_TYPEHASH, a.user, a.token, a.perBuyMax, a.maxGasPrice, a.totalCount, a.minInterval, a.deadline, a.nonce)
        );
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    // ---- keeper ----

    /// @notice Execute one buy under `a`. Tokens go to `a.user`; the stipend
    ///         and fee come from the user's deposit; a clamped fill credits the
    ///         unspent quote back to the user.
    function executeBuy(BuyAuth calldata a, bytes calldata sig, uint256 amount, uint256 minOut)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.sender != keeper) revert NotKeeper();
        if (_recover(hashAuth(a), sig) != a.user) revert BadSignature();
        if (a.nonce != nonces[a.user]) revert BadSignature();
        if (block.timestamp > a.deadline) revert AuthExpired();
        bytes32 id = authId(a);
        Exec storage e = execs[id];
        if (e.count >= a.totalCount) revert AuthExhausted();
        if (e.lastAt != 0 && block.timestamp < uint256(e.lastAt) + a.minInterval) revert TooSoon();
        if (amount == 0 || amount > a.perBuyMax) revert OverCap();

        IPonsV2LaunchFactory.LaunchedToken memory L = factory.getLaunchedToken(a.token);
        if (L.curve == address(0)) revert UnknownToken();
        address asset = L.pairToken;

        uint256 gasPrice = tx.gasprice < a.maxGasPrice ? tx.gasprice : a.maxGasPrice;
        uint256 stipend = GAS_STIPEND * gasPrice;
        uint256 fee = (amount * FEE_BPS) / BPS;

        // debit before the external call
        uint256 quoteBal = balanceOf[a.user][asset];
        if (quoteBal < amount + fee) revert Insufficient();
        balanceOf[a.user][asset] = quoteBal - amount - fee;
        if (stipend > 0) {
            uint256 nat = balanceOf[a.user][NATIVE];
            if (nat < stipend) revert Insufficient();
            balanceOf[a.user][NATIVE] = nat - stipend;
        }

        uint256 spent;
        if (asset == NATIVE) {
            uint256 before = address(this).balance;
            tokensOut = IExecCurve(L.curve).buy{value: amount}(amount, minOut, a.user);
            uint256 refund = address(this).balance - (before - amount);
            spent = amount - refund;
        } else {
            IERC20 q = IERC20(asset);
            q.forceApprove(L.curve, amount);
            uint256 before = q.balanceOf(address(this));
            tokensOut = IExecCurve(L.curve).buy(amount, minOut, a.user);
            q.forceApprove(L.curve, 0);
            spent = before - q.balanceOf(address(this));
        }
        // fee is on what was actually spent; the difference (and any refund) goes back
        uint256 feeDue = (spent * FEE_BPS) / BPS;
        balanceOf[a.user][asset] += (amount - spent) + (fee - feeDue);
        feePool[asset] += feeDue;
        gasCredit[msg.sender] += stipend;

        e.count += 1;
        e.lastAt = uint64(block.timestamp);
        emit Executed(id, a.user, a.token, spent, feeDue, tokensOut, stipend);
    }

    function claimGas() external nonReentrant {
        uint256 c = gasCredit[msg.sender];
        require(c > 0, "nothing");
        gasCredit[msg.sender] = 0;
        _pay(NATIVE, msg.sender, c);
        emit GasClaimed(msg.sender, c);
    }

    // ---- platform ----

    function platformOwner() public view returns (address) {
        return factory.owner();
    }

    function setKeeper(address k) external {
        if (msg.sender != platformOwner()) revert NotOwner();
        keeper = k;
        emit KeeperSet(k);
    }

    /// @notice The only owner exit: accrued service fees, nothing else.
    function withdrawFees(address asset, address to) external nonReentrant {
        if (msg.sender != platformOwner()) revert NotOwner();
        uint256 f = feePool[asset];
        require(f > 0 && to != address(0), "nothing");
        feePool[asset] = 0;
        _pay(asset, to, f);
        emit FeesWithdrawn(asset, to, f);
    }

    // ---- internals ----

    function _pay(address asset, address to, uint256 amount) private {
        if (asset == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "send failed");
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(digest, v, r, s);
    }

    receive() external payable {} // curve refunds on clamped fills
}

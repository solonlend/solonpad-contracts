// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPoFCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
}

interface IPoFVaultPoke {
    function poke() external;
    function currentRound() external view returns (uint256);
}

/// @title PoFRouter
/// @notice The "official path" of Proof-of-Fee launches. Buys routed through
///         here record Work for the buyer: the quote actually spent on the
///         curve (fees are proportional to it). Buys made directly on the curve
///         still work, still pay fees, and record no Work — exactly like a
///         hook-pool launch's non-official venues. Sells never record Work.
contract PoFRouter {
    using SafeERC20 for IERC20;

    struct Info {
        address vault;
        address curve;
        address pairToken;
    }

    address public immutable launcher; // RadianLaunchRouter registers launches
    mapping(address token => Info) public launches;
    mapping(address token => mapping(uint256 round => uint256)) public totalWork;
    mapping(address token => mapping(uint256 round => mapping(address user => uint256))) public workOf;
    // Rounds in which any Work landed, ascending; the vault settles only these,
    // so an idle stretch of thousands of empty rounds costs nothing to skip.
    mapping(address token => uint256[]) private _activeRounds;

    uint256 private _lock = 1;

    event Registered(address indexed token, address vault, address curve, address pairToken);
    event WorkRecorded(address indexed token, uint256 indexed round, address indexed user, uint256 quoteSpent, uint256 tokensOut);

    error NotLauncher();
    error UnknownToken();
    error BadValue();

    modifier nonReentrant() {
        require(_lock != 2, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address launcher_) {
        require(launcher_ != address(0), "zero");
        launcher = launcher_;
    }

    function register(address token, address vault, address curve, address pairToken) external {
        if (msg.sender != launcher) revert NotLauncher();
        require(launches[token].vault == address(0), "registered");
        launches[token] = Info(vault, curve, pairToken);
        emit Registered(token, vault, curve, pairToken);
    }

    function activeRoundCount(address token) external view returns (uint256) {
        return _activeRounds[token].length;
    }

    function activeRoundAt(address token, uint256 i) external view returns (uint256) {
        return _activeRounds[token][i];
    }

    /// @notice Buy `token` on its curve and record the quote spent as Work for
    ///         the caller in the current round.
    function buy(address token, uint256 quoteIn, uint256 minOut) external payable nonReentrant returns (uint256 out) {
        return _buy(token, quoteIn, minOut, msg.sender);
    }

    /// @notice The launch router's opening buy on behalf of the creator.
    function buyFor(address token, uint256 quoteIn, uint256 minOut, address beneficiary)
        external
        payable
        nonReentrant
        returns (uint256 out)
    {
        if (msg.sender != launcher) revert NotLauncher();
        return _buy(token, quoteIn, minOut, beneficiary);
    }

    function _buy(address token, uint256 quoteIn, uint256 minOut, address user) private returns (uint256 out) {
        Info memory i = launches[token];
        if (i.vault == address(0)) revert UnknownToken();
        IPoFVaultPoke(i.vault).poke(); // settle ended rounds before new Work lands
        uint256 round = IPoFVaultPoke(i.vault).currentRound();

        uint256 spent;
        if (i.pairToken == address(0)) {
            if (msg.value != quoteIn) revert BadValue();
            uint256 before = address(this).balance - msg.value;
            out = IPoFCurve(i.curve).buy{value: quoteIn}(quoteIn, minOut, user);
            uint256 refund = address(this).balance - before; // clamped fill
            spent = quoteIn - refund;
            if (refund > 0) {
                (bool ok,) = msg.sender.call{value: refund}("");
                require(ok, "refund failed");
            }
        } else {
            if (msg.value != 0) revert BadValue();
            IERC20 q = IERC20(i.pairToken);
            q.safeTransferFrom(msg.sender, address(this), quoteIn);
            q.forceApprove(i.curve, quoteIn);
            out = IPoFCurve(i.curve).buy(quoteIn, minOut, user);
            q.forceApprove(i.curve, 0);
            uint256 left = q.balanceOf(address(this));
            spent = quoteIn - left;
            if (left > 0) q.safeTransfer(msg.sender, left);
        }

        if (spent > 0) {
            if (totalWork[token][round] == 0) _activeRounds[token].push(round);
            totalWork[token][round] += spent;
            workOf[token][round][user] += spent;
        }
        emit WorkRecorded(token, round, user, spent, out);
    }

    receive() external payable {}
}

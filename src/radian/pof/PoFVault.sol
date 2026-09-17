// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPoFVCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sweepFees(uint256 minBuybackTokensOut) external;
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function graduated() external view returns (bool);
    function launchedAt() external view returns (uint256);
}

interface IPoFEscrow {
    function claim() external returns (uint256);
    function claimToken(address token) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function balanceOfToken(address, address) external view returns (uint256);
}

interface IPoFWork {
    function totalWork(address token, uint256 round) external view returns (uint256);
    function workOf(address token, uint256 round, address user) external view returns (uint256);
    function activeRoundCount(address token) external view returns (uint256);
    function activeRoundAt(address token, uint256 i) external view returns (uint256);
}

interface IPoFLauncher {
    function keeper() external view returns (address);
    function platformOwner() external view returns (address);
}

/// @title PoFVault
/// @notice Proof-of-Fee: the launch's creator-fee share buys the token back on
///         its own curve, and those bought-back tokens are handed out, round by
///         round, to the traders whose fees paid for them — in proportion to
///         the quote they spent through the official router. Nothing is minted:
///         rewards can never exceed what fees actually bought.
///
///         Per round: reward_i = pool × work_i ÷ max(totalWork, targetWork).
///         Under-subscribed rounds pay out pro-rata and the rest rolls over;
///         an empty round distributes nothing and its pool carries forward.
contract PoFVault {
    using SafeERC20 for IERC20;

    struct Config {
        uint128 targetWork; // quote units per round below which payouts are pro-rated
        uint32 roundSeconds; // 60 – 86400
        uint32 minInterval; // between buybacks; ≥ 600
        uint16 maxBuybackReserveBps; // per buyback, share of the curve's quote reserve; ≤ 1000
    }

    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_SETTLE = 64;

    address public launcher;
    address public token;
    address public curve;
    address public pairToken;
    address public feeEscrow;
    address public workRouter; // PoFRouter
    Config public config;
    uint256 public launchedAt;
    bool public initialized;

    uint256 public unallocated; // bought-back tokens not yet assigned to a round
    uint256 public settledCount; // cursor into the router's active-round list
    mapping(uint256 round => uint256) public roundPool;
    mapping(uint256 round => uint256) public roundTotal;
    mapping(uint256 round => bool) public settled;
    mapping(uint256 round => mapping(address user => bool)) public claimed;

    uint256 public totalClaimedQuote;
    uint256 public totalBought;
    uint256 public totalPaid;
    uint64 public lastBuybackAt;

    uint256 private _lock = 1;

    event Initialized(address token, address curve, address pairToken, Config config);
    event Buyback(uint256 quoteIn, uint256 tokensOut);
    event RoundSettled(uint256 indexed round, uint256 pool, uint256 totalWork);
    event Claimed(address indexed user, uint256 amount);

    error NotKeeper();
    error TooSoon();
    error Expired();

    modifier nonReentrant() {
        require(_lock != 2, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    function initialize(
        address launcher_,
        address token_,
        address curve_,
        address pairToken_,
        address feeEscrow_,
        address workRouter_,
        Config calldata cfg
    ) external {
        require(!initialized, "initialized");
        require(token_ != address(0) && curve_ != address(0) && feeEscrow_ != address(0) && workRouter_ != address(0), "zero");
        require(cfg.roundSeconds >= 60 && cfg.roundSeconds <= 1 days, "round");
        require(cfg.minInterval >= 600 && cfg.maxBuybackReserveBps <= 1000 && cfg.targetWork > 0, "config");
        initialized = true;
        launcher = launcher_;
        token = token_;
        curve = curve_;
        pairToken = pairToken_;
        feeEscrow = feeEscrow_;
        workRouter = workRouter_;
        config = cfg;
        launchedAt = IPoFVCurve(curve_).launchedAt();
        emit Initialized(token_, curve_, pairToken_, cfg);
    }

    // ---- rounds ----

    function currentRound() public view returns (uint256) {
        return (block.timestamp - launchedAt) / config.roundSeconds;
    }

    /// @notice Settle every ended round that saw Work (bounded per call).
    function poke() public {
        uint256 cur = currentRound();
        IPoFWork w = IPoFWork(workRouter);
        uint256 n = w.activeRoundCount(token);
        uint256 done;
        while (settledCount < n && done < MAX_SETTLE) {
            uint256 r = w.activeRoundAt(token, settledCount);
            if (r >= cur) break;
            uint256 total = w.totalWork(token, r);
            uint256 pool = total >= config.targetWork ? unallocated : (unallocated * total) / config.targetWork;
            roundPool[r] = pool;
            roundTotal[r] = total;
            settled[r] = true;
            unallocated -= pool;
            settledCount++;
            done++;
            emit RoundSettled(r, pool, total);
        }
    }

    // ---- fees → buyback ----

    /// @notice Claim accrued fees and buy the token back on its curve. The
    ///         bought tokens become the pool for upcoming rounds.
    /// @param minOut Off-chain simulated output for the exact spend (see `plannedSpend`).
    function claimAndBuy(uint256 minOut, uint256 deadline) external nonReentrant returns (uint256 spent, uint256 out) {
        if (msg.sender != IPoFLauncher(launcher).keeper() && msg.sender != IPoFLauncher(launcher).platformOwner()) {
            revert NotKeeper();
        }
        if (block.timestamp > deadline) revert Expired();
        if (lastBuybackAt != 0 && block.timestamp < uint256(lastBuybackAt) + config.minInterval) revert TooSoon();
        if (!IPoFVCurve(curve).graduated()) {
            try IPoFVCurve(curve).sweepFees(0) {} catch {}
        }
        if (claimable() > 0) {
            uint256 claimedNow = _isNative() ? IPoFEscrow(feeEscrow).claim() : IPoFEscrow(feeEscrow).claimToken(pairToken);
            totalClaimedQuote += claimedNow;
        }
        spent = plannedSpend();
        if (spent == 0 || IPoFVCurve(curve).graduated()) return (0, 0);
        require(minOut > 0, "quote required");
        if (_isNative()) {
            out = IPoFVCurve(curve).buy{value: spent}(spent, minOut, address(this));
        } else {
            IERC20(pairToken).forceApprove(curve, spent);
            out = IPoFVCurve(curve).buy(spent, minOut, address(this));
            IERC20(pairToken).forceApprove(curve, 0);
        }
        unallocated += out;
        totalBought += out;
        lastBuybackAt = uint64(block.timestamp);
        emit Buyback(spent, out);
        // Settle after buying, so a round that just ended is paid from the
        // buyback its own fees funded rather than handing it to the next one.
        poke();
    }

    /// @notice Fees accrued to this vault in the escrow (after a sweep).
    function claimable() public view returns (uint256) {
        return _isNative() ? IPoFEscrow(feeEscrow).balanceOf(address(this)) : IPoFEscrow(feeEscrow).balanceOfToken(address(this), pairToken);
    }

    /// @notice Quote this vault would spend on the next buyback: its balance
    ///         plus what is claimable, capped to a share of the curve's reserve.
    function plannedSpend() public view returns (uint256) {
        uint256 bal = (_isNative() ? address(this).balance : IERC20(pairToken).balanceOf(address(this))) + claimable();
        (uint256 q,) = IPoFVCurve(curve).getReserves();
        uint256 cap = (q * config.maxBuybackReserveBps) / BPS;
        return bal > cap ? cap : bal;
    }

    // ---- claims ----

    function pendingOf(address user, uint256[] calldata rounds) external view returns (uint256 total) {
        IPoFWork w = IPoFWork(workRouter);
        for (uint256 i = 0; i < rounds.length; i++) {
            uint256 r = rounds[i];
            if (!settled[r] || claimed[r][user] || roundTotal[r] == 0) continue;
            total += (roundPool[r] * w.workOf(token, r, user)) / roundTotal[r];
        }
    }

    function claim(uint256[] calldata rounds) external nonReentrant returns (uint256 total) {
        IPoFWork w = IPoFWork(workRouter);
        for (uint256 i = 0; i < rounds.length; i++) {
            uint256 r = rounds[i];
            if (!settled[r] || claimed[r][msg.sender] || roundTotal[r] == 0) continue;
            claimed[r][msg.sender] = true;
            total += (roundPool[r] * w.workOf(token, r, msg.sender)) / roundTotal[r];
        }
        if (total > 0) {
            totalPaid += total;
            IERC20(token).safeTransfer(msg.sender, total);
        }
        emit Claimed(msg.sender, total);
    }

    function _isNative() private view returns (bool) {
        return pairToken == address(0);
    }

    receive() external payable {}
}

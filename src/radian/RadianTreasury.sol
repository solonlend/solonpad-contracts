// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ICurveBuy {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function graduated() external view returns (bool);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
}

interface IBurnable {
    function burn(uint256 amount) external;
    function balanceOf(address a) external view returns (uint256);
}

interface IStakingNotify {
    function notifyReward() external payable;
    function stakingToken() external view returns (address);
}

interface IFeeEscrow {
    function claim() external returns (uint256 amount);
    function claimToken(address token) external returns (uint256 amount);
    function balanceOf(address recipient) external view returns (uint256);
}

/// @title RadianTreasury
/// @notice Collects platform fees (native USDC) and, on `flush`, splits them:
///         `buybackBps` buys $RADIAN on its bonding curve and BURNS it (scarcity),
///         the remainder is streamed to stakers as real USDC yield. This is the
///         closed loop — real revenue in, buyback + real yield out.
/// @dev Protocol fees on Radian accrue in PonsV2FeeEscrow under the recipient's
///      address and are only paid to `msg.sender` of `claim()`, so the treasury
///      must be the one calling the escrow: `claimFees()` does that and is
///      permissionless. Native USDC has no withdrawal path other than `flush`.
///      Ownership is two-step and cannot be renounced.
contract RadianTreasury is Ownable2Step {
    using SafeERC20 for IERC20;

    address public keeper; // may call flush (e.g. a cron)
    address public immutable radian; // $RADIAN launcher token (ERC20Burnable)
    address public immutable radianCurve; // its bonding curve (buyback venue)
    IFeeEscrow public immutable feeEscrow; // platform escrow that holds our fee balance
    IStakingNotify public staking;

    uint16 public buybackBps = 5_000; // 50% buyback+burn, 50% to stakers
    // Anti-sandwich bounds: a single flush may buy at most this share of the
    // curve's quote reserve (caps price impact), and flushes are rate-limited.
    uint16 public maxBuybackReserveBps = 500; // 5% of the curve's quote reserve
    uint32 public minFlushInterval = 1 hours;
    uint64 public lastFlushAt;

    uint256 public totalBurned; // lifetime $RADIAN burned
    uint256 public totalToStakers; // lifetime USDC streamed to stakers
    uint256 public totalFlushed; // lifetime USDC processed

    event Flushed(uint256 usdcIn, uint256 radianBurned, uint256 toStakers);
    event FeesClaimed(uint256 amount);
    event TokenFeesClaimed(address indexed token, uint256 amount);
    event BuybackBpsSet(uint16 bps);
    event FlushLimitsSet(uint16 maxBuybackReserveBps, uint32 minFlushInterval);
    event StakingSet(address staking);
    event KeeperSet(address keeper);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(address radian_, address radianCurve_, address feeEscrow_, address owner_) Ownable(owner_) {
        require(radian_ != address(0) && radianCurve_ != address(0) && feeEscrow_ != address(0), "zero");
        radian = radian_;
        radianCurve = radianCurve_;
        feeEscrow = IFeeEscrow(feeEscrow_);
    }

    receive() external payable {}

    // ---- fee intake ----

    /// @notice Pull this treasury's native-USDC fee balance out of the platform
    ///         escrow. Permissionless: the funds can only land here.
    function claimFees() external returns (uint256 amount) {
        amount = feeEscrow.claim();
        emit FeesClaimed(amount);
    }

    /// @notice Pull an ERC-20 fee balance (EURC, a stock quote…) out of the
    ///         escrow. The flywheel runs on native USDC, so these are held for
    ///         the owner to route (see `rescueERC20`).
    function claimTokenFees(address token) external returns (uint256 amount) {
        amount = feeEscrow.claimToken(token);
        emit TokenFeesClaimed(token, amount);
    }

    /// @notice Native USDC waiting in the escrow for this treasury.
    function claimableFees() external view returns (uint256) {
        return feeEscrow.balanceOf(address(this));
    }

    // ---- the flywheel ----

    /// @notice Split the treasury's USDC: buyback+burn + fund staker rewards.
    /// @param minRadianOut Slippage guard for the curve buy, from an off-chain
    ///        quote. Required (> 0) whenever a buyback will execute.
    /// @param deadline Latest block timestamp at which this flush may execute.
    function flush(uint256 minRadianOut, uint256 deadline) external returns (uint256 burned, uint256 toStakers) {
        require(msg.sender == owner() || msg.sender == keeper, "not keeper");
        require(block.timestamp <= deadline, "expired");
        require(block.timestamp >= uint256(lastFlushAt) + minFlushInterval, "too soon");
        require(address(staking) != address(0), "no staking");
        uint256 bal = address(this).balance;
        require(bal > 0, "empty");

        uint256 buyback = (bal * buybackBps) / 10_000;
        toStakers = bal - buyback;

        if (buyback > 0 && !ICurveBuy(radianCurve).graduated()) {
            require(minRadianOut > 0, "quote required");
            // Cap the buy to a share of the curve's quote reserve; anything
            // above the cap stays here for a later flush so the long-run split
            // is preserved instead of leaking to stakers.
            (uint256 quoteReserve,) = ICurveBuy(radianCurve).getReserves();
            uint256 cap = (quoteReserve * maxBuybackReserveBps) / 10_000;
            if (buyback > cap) buyback = cap;
            if (buyback > 0) {
                ICurveBuy(radianCurve).buy{value: buyback}(buyback, minRadianOut, address(this));
                burned = IBurnable(radian).balanceOf(address(this));
                if (burned > 0) {
                    IBurnable(radian).burn(burned);
                    totalBurned += burned;
                }
            }
        } else {
            // curve graduated (buyback venue moved to V4) — route all to stakers for now
            buyback = 0;
            toStakers = bal;
        }

        if (toStakers > 0) {
            staking.notifyReward{value: toStakers}();
            totalToStakers += toStakers;
        }
        lastFlushAt = uint64(block.timestamp);
        totalFlushed += buyback + toStakers;
        emit Flushed(buyback + toStakers, burned, toStakers);
    }

    // ---- admin ----

    /// @dev The staking pool must be for $RADIAN — guards against pointing the
    ///      reward stream at the wrong contract by mistake.
    function setStaking(address s) external onlyOwner {
        require(s != address(0), "zero");
        require(IStakingNotify(s).stakingToken() == radian, "wrong staking token");
        staking = IStakingNotify(s);
        emit StakingSet(s);
    }

    function setBuybackBps(uint16 bps) external onlyOwner {
        require(bps <= 10_000, "range");
        buybackBps = bps;
        emit BuybackBpsSet(bps);
    }

    function setFlushLimits(uint16 maxBuybackReserveBps_, uint32 minFlushInterval_) external onlyOwner {
        require(maxBuybackReserveBps_ > 0 && maxBuybackReserveBps_ <= 10_000, "range");
        maxBuybackReserveBps = maxBuybackReserveBps_;
        minFlushInterval = minFlushInterval_;
        emit FlushLimitsSet(maxBuybackReserveBps_, minFlushInterval_);
    }

    function setKeeper(address k) external onlyOwner {
        keeper = k;
        emit KeeperSet(k);
    }

    /// @notice Move an ERC-20 (claimed non-native fees, or tokens sent by
    ///         mistake) out of the treasury. $RADIAN is excluded: bought-back
    ///         tokens exist only to be burned. Native USDC is never rescuable.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        require(token != radian, "radian is burn-only");
        require(to != address(0), "zero");
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @dev An ownerless treasury could never re-point staking or the keeper.
    function renounceOwnership() public pure override {
        revert("renounce disabled");
    }
}

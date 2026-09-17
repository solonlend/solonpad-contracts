// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IWallCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sweepFees(uint256 minBuybackTokensOut) external;
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function graduated() external view returns (bool);
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
}

interface IWallToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function burn(uint256) external;
}

interface IWallEscrow {
    function claim() external returns (uint256);
    function claimToken(address token) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function balanceOfToken(address, address) external view returns (uint256);
}

interface IWallVault {
    function totalLocked(address token) external view returns (uint256);
}

interface IWallStakingNotify {
    function notifyReward(uint256 amount) external payable;
}

interface IWallLauncher {
    function keeper() external view returns (address);
    function platformOwner() external view returns (address);
}

/// @title WallTreasury
/// @notice One per "stock treasury" launch. Receives the launch's creator-fee
///         share in the quote asset (a tokenized stock or stablecoin), streams a
///         slice to stakers, keeps the rest as a growing reserve that is never
///         sold, and — while the token is still on its bonding curve — defends
///         book value by buying and burning when the market trades under it.
///
///         Book value = reserve ÷ circulating supply, both on-chain balances; no
///         oracle. The wall is a bid funded by fees, not a guarantee.
///
///         After graduation the buyback venue is the V4 pool; the maker-side
///         ladder for that phase is a separate module (see radian-wall docs,
///         TREASURY.md), so `defend` reverts once the curve has graduated.
contract WallTreasury {
    using SafeERC20 for IERC20;

    struct Config {
        uint16 marginBps; // defend when spot < bookValue × (1 + margin); ≤ 2000
        uint16 epochBudgetBps; // max share of the reserve spent per 24h window; ≤ 2500
        uint16 streamBps; // share of every fee claim streamed to stakers; ≤ 5000
        uint16 maxSlippageBps; // floor on the keeper's minOut vs. spot; ≤ 1000
        uint32 minInterval; // seconds between defends; ≥ 600
        uint128 keeperBounty; // quote units per successful defend; capped at 1% of the reserve
    }

    uint256 private constant BPS = 10_000;

    // ---- identity (set once) ----
    address public launcher; // RadianLaunchRouter: keeper + platform owner source
    address public token;
    address public curve;
    address public pairToken; // address(0) = native quote
    address public feeEscrow;
    address public vault; // PonsV2BuybackVault (locked tokens are not circulating)
    address public staking;
    Config public config;
    bool public initialized;

    // ---- ledger ----
    uint256 public totalClaimed; // quote claimed from the escrow, lifetime
    uint256 public totalStreamed; // quote sent to stakers, lifetime
    uint256 public totalSpent; // quote spent defending, lifetime
    uint256 public totalBurned; // tokens burned, lifetime
    uint256 public totalBounty; // quote paid to keepers, lifetime
    uint64 public lastDefendAt;
    uint64 public windowStart;
    uint256 public spentInWindow;

    uint256 private _lock = 1;

    event Initialized(address token, address curve, address pairToken, address staking, Config config);
    event FeesClaimed(uint256 claimed, uint256 streamed, uint256 kept);
    event Defended(address indexed keeper, uint256 spent, uint256 burned, uint256 bounty, uint256 spotBefore, uint256 bookValue);
    event KeeperBountySet(uint128 bounty);

    error NotKeeper();
    error Graduated();
    error TooSoon();
    error AboveFloor(uint256 spot, uint256 floor);
    error NothingToSpend();
    error MinOutTooLow(uint256 minOut, uint256 floorOut);
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
        address vault_,
        address staking_,
        Config calldata cfg
    ) external {
        require(!initialized, "initialized");
        require(token_ != address(0) && curve_ != address(0) && feeEscrow_ != address(0) && staking_ != address(0), "zero");
        require(cfg.marginBps <= 2000 && cfg.epochBudgetBps <= 2500 && cfg.streamBps <= 5000, "config");
        require(cfg.maxSlippageBps <= 1000 && cfg.minInterval >= 600, "config");
        initialized = true;
        launcher = launcher_;
        token = token_;
        curve = curve_;
        pairToken = pairToken_;
        feeEscrow = feeEscrow_;
        vault = vault_;
        staking = staking_;
        config = cfg;
        emit Initialized(token_, curve_, pairToken_, staking_, cfg);
    }

    // ---- views ----

    function isNative() public view returns (bool) {
        return pairToken == address(0);
    }

    /// @notice Quote held by the treasury (the NVDA pile).
    function reserve() public view returns (uint256) {
        return isNative() ? address(this).balance : IERC20(pairToken).balanceOf(address(this));
    }

    /// @notice Quote fees accrued to this treasury in the escrow, not yet claimed.
    function claimable() public view returns (uint256) {
        return isNative() ? IWallEscrow(feeEscrow).balanceOf(address(this)) : IWallEscrow(feeEscrow).balanceOfToken(address(this), pairToken);
    }

    /// @notice Tokens that can trade: total supply minus what the curve still
    ///         holds, minus tokens locked in the platform vault, minus our own.
    function circulating() public view returns (uint256) {
        IWallToken t = IWallToken(token);
        uint256 supply = t.totalSupply();
        uint256 held = t.balanceOf(curve) + t.balanceOf(address(this));
        if (vault != address(0)) held += IWallVault(vault).totalLocked(token);
        return supply > held ? supply - held : 0;
    }

    /// @notice Quote units per 1e18 tokens, from balances only.
    function bookValue() public view returns (uint256) {
        uint256 c = circulating();
        return c == 0 ? 0 : (reserve() * 1e18) / c;
    }

    /// @notice Curve spot in the same units as `bookValue`.
    function spot() public view returns (uint256) {
        (uint256 q, uint256 tk) = IWallCurve(curve).getReserves();
        return tk == 0 ? 0 : (q * 1e18) / tk;
    }

    /// @notice The price the wall defends: book value plus the configured margin.
    function floorPrice() public view returns (uint256) {
        return (bookValue() * (BPS + config.marginBps)) / BPS;
    }

    /// @notice Budget still spendable in the current 24h window.
    function budgetRemaining() public view returns (uint256) {
        uint256 budget = (reserve() * config.epochBudgetBps) / BPS;
        if (block.timestamp >= uint256(windowStart) + 1 days) return budget;
        return budget > spentInWindow ? budget - spentInWindow : 0;
    }

    /// @notice Gross quote needed to lift the curve spot to the floor
    ///         (constant product: Q' = sqrt(floor × Q × T / 1e18)), grossed up
    ///         for the curve's fee and creator tax.
    function quoteToRestoreFloor() public view returns (uint256) {
        (uint256 q, uint256 tk) = IWallCurve(curve).getReserves();
        uint256 f = floorPrice();
        if (q == 0 || tk == 0 || f == 0) return 0;
        uint256 qTarget = Math.sqrt(Math.mulDiv(f, q * tk, 1e18));
        if (qTarget <= q) return 0;
        uint256 net = qTarget - q;
        uint256 feeBps = IWallCurve(curve).feeBps() + IWallCurve(curve).creatorTaxBps();
        return feeBps >= BPS ? net : (net * BPS) / (BPS - feeBps);
    }

    // ---- actions ----

    /// @notice Pull accrued fees from the escrow; stream `streamBps` to stakers,
    ///         keep the rest. Permissionless: funds can only land here or in the
    ///         launch's own staking pool.
    function claimFees() external nonReentrant returns (uint256 claimed, uint256 streamed) {
        // Fees sit on the curve until swept; as the launch's creator-fee
        // recipient this treasury may sweep (no buyback leg: buybackEnabled is
        // false). A sweep that cannot run (graduated, operator-only) is skipped.
        if (!IWallCurve(curve).graduated()) {
            try IWallCurve(curve).sweepFees(0) {} catch {}
        }
        if (claimable() == 0) return (0, 0);
        claimed = isNative() ? IWallEscrow(feeEscrow).claim() : IWallEscrow(feeEscrow).claimToken(pairToken);
        if (claimed == 0) return (0, 0);
        totalClaimed += claimed;
        streamed = (claimed * config.streamBps) / BPS;
        if (streamed > 0) {
            if (isNative()) {
                IWallStakingNotify(staking).notifyReward{value: streamed}(streamed);
            } else {
                IERC20(pairToken).forceApprove(staking, streamed);
                IWallStakingNotify(staking).notifyReward(streamed);
            }
            totalStreamed += streamed;
        }
        emit FeesClaimed(claimed, streamed, claimed - streamed);
    }

    /// @notice Buy and burn on the curve while the spot is under the floor.
    /// @param maxSpend Keeper's cap for this call; the contract spends the
    ///        smallest of this, what restores the floor, the window budget and
    ///        the reserve.
    /// @param minOut Slippage bound from an off-chain simulation of the exact
    ///        spend; must be at least spot-implied output less maxSlippage.
    function defend(uint256 maxSpend, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 spent, uint256 burned)
    {
        if (msg.sender != IWallLauncher(launcher).keeper() && msg.sender != IWallLauncher(launcher).platformOwner()) {
            revert NotKeeper();
        }
        if (block.timestamp > deadline) revert Expired();
        if (IWallCurve(curve).graduated()) revert Graduated();
        if (lastDefendAt != 0 && block.timestamp < uint256(lastDefendAt) + config.minInterval) revert TooSoon();

        uint256 s = spot();
        uint256 f = floorPrice();
        if (s == 0 || s >= f) revert AboveFloor(s, f);

        if (block.timestamp >= uint256(windowStart) + 1 days) {
            windowStart = uint64(block.timestamp);
            spentInWindow = 0;
        }
        uint256 res = reserve();
        uint256 bounty = _bountyFor(res);
        uint256 spendable = res > bounty ? res - bounty : 0;
        spent = quoteToRestoreFloor();
        if (spent > maxSpend) spent = maxSpend;
        uint256 budget = budgetRemaining();
        if (spent > budget) spent = budget;
        if (spent > spendable) spent = spendable;
        if (spent == 0) revert NothingToSpend();

        // minOut must not be looser than spot less the configured slippage
        uint256 feeBps = IWallCurve(curve).feeBps() + IWallCurve(curve).creatorTaxBps();
        uint256 net = feeBps >= BPS ? 0 : (spent * (BPS - feeBps)) / BPS;
        uint256 floorOut = ((net * 1e18) / s) * (BPS - config.maxSlippageBps) / BPS;
        if (minOut < floorOut) revert MinOutTooLow(minOut, floorOut);

        if (isNative()) {
            IWallCurve(curve).buy{value: spent}(spent, minOut, address(this));
        } else {
            IERC20(pairToken).forceApprove(curve, spent);
            IWallCurve(curve).buy(spent, minOut, address(this));
            IERC20(pairToken).forceApprove(curve, 0);
        }
        burned = IWallToken(token).balanceOf(address(this));
        if (burned > 0) IWallToken(token).burn(burned);

        spentInWindow += spent;
        totalSpent += spent;
        totalBurned += burned;
        lastDefendAt = uint64(block.timestamp);
        if (bounty > 0) {
            totalBounty += bounty;
            _pay(msg.sender, bounty);
        }
        emit Defended(msg.sender, spent, burned, bounty, s, f);
    }

    /// @notice Platform owner may re-size the keeper bounty (gas drifts); every
    ///         other parameter is fixed at launch.
    function setKeeperBounty(uint128 bounty) external {
        require(msg.sender == IWallLauncher(launcher).platformOwner(), "not owner");
        config.keeperBounty = bounty;
        emit KeeperBountySet(bounty);
    }

    function _bountyFor(uint256 res) private view returns (uint256) {
        uint256 b = config.keeperBounty;
        uint256 cap = res / 100; // never more than 1% of the pile per defend
        return b > cap ? cap : b;
    }

    function _pay(address to, uint256 amount) private {
        if (isNative()) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "send failed");
        } else {
            IERC20(pairToken).safeTransfer(to, amount);
        }
    }

    receive() external payable {} // native fee claims + curve refunds
}

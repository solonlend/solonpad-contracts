// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IERC20Min {
    function transfer(address to, uint256 v) external returns (bool);
    function transferFrom(address from, address to, uint256 v) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

/// @title RadianStaking
/// @notice Stake $RADIAN, earn native USDC — real yield streamed from platform
///         fees. Synthetix StakingRewards accounting, reward asset = the native
///         gas coin (USDC on Arc), funded by RadianTreasury via `notifyReward`.
///         Rewards can never exceed what the treasury actually deposits, so this
///         is a distribution of real revenue, not an inflationary emission.
/// @dev Ownership is two-step (Ownable2Step) so the handover to a multisig
///      cannot be lost to a typo, and it cannot be renounced (an ownerless
///      pool could never re-point its distributor). Synthetix semantics are
///      kept as-is: rewards streamed while nobody is staked are not recoverable.
contract RadianStaking is Ownable2Step {
    IERC20Min public immutable stakingToken; // $RADIAN
    address public rewardsDistributor; // RadianTreasury (may notify rewards)

    uint256 public constant DURATION = 7 days;
    uint256 public periodFinish;
    uint256 public rewardRate; // native USDC (18-dec) per second
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // lifetime USDC distributed to stakers — for the "revenue shared" stat
    uint256 public totalDistributed;

    uint256 private _lock = 1;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount);
    event DistributorSet(address distributor);

    modifier nonReentrant() {
        require(_lock == 1, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(address stakingToken_, address owner_) Ownable(owner_) {
        require(stakingToken_ != address(0), "zero");
        stakingToken = IERC20Min(stakingToken_);
    }

    function setRewardsDistributor(address d) external onlyOwner {
        rewardsDistributor = d;
        emit DistributorSet(d);
    }

    /// @dev An ownerless staking pool could never re-point its distributor.
    function renounceOwnership() public pure override {
        revert("renounce disabled");
    }

    // ---- views ----

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return (stakedOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18
            + rewards[account];
    }

    /// @notice Annualized reward rate in native USDC per staked token (1e18 scaled).
    function rewardRatePerYear() external view returns (uint256) {
        if (totalStaked == 0) return 0;
        return (rewardRate * 365 days * 1e18) / totalStaked;
    }

    // ---- actions ----

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "zero");
        totalStaked += amount;
        stakedOf[msg.sender] += amount;
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0 && stakedOf[msg.sender] >= amount, "bad amount");
        totalStaked -= amount;
        stakedOf[msg.sender] -= amount;
        require(stakingToken.transfer(msg.sender, amount), "send failed");
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward == 0) return;
        rewards[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: reward}("");
        require(ok, "reward send failed");
        emit RewardPaid(msg.sender, reward);
    }

    /// @notice Withdraw everything and claim. Safe to call with nothing staked
    ///         (e.g. to collect rewards left after a full withdrawal).
    function exit() external {
        uint256 staked = stakedOf[msg.sender];
        if (staked > 0) withdraw(staked);
        getReward();
    }

    /// @notice Fund a new reward period with native USDC (msg.value). Only the
    ///         treasury/distributor (or the owner). Streams over DURATION.
    function notifyReward() external payable updateReward(address(0)) {
        require(msg.sender == rewardsDistributor || msg.sender == owner(), "not distributor");
        uint256 reward = msg.value;
        require(reward > 0, "zero reward");
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / DURATION;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (reward + leftover) / DURATION;
        }
        require(rewardRate > 0, "reward too small");
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;
        totalDistributed += reward;
        emit RewardAdded(reward);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title WallStaking
/// @notice Stake a Wall-template token, earn its quote asset (the tokenized stock
///         or stablecoin the launch is priced in), streamed from fees the launch's
///         WallTreasury actually claimed. Synthetix StakingRewards accounting;
///         clone-initialized (one instance per launch); no owner — the distributor
///         is fixed at initialization to the launch's treasury.
contract WallStaking {
    using SafeERC20 for IERC20;

    uint256 public constant DURATION = 7 days;

    IERC20 public stakingToken;
    address public rewardToken; // address(0) = native quote (USDC on Arc)
    address public distributor; // the WallTreasury
    bool public initialized;

    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public totalStaked;
    uint256 public totalDistributed;
    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _lock = 1;

    event Initialized(address stakingToken, address rewardToken, address distributor);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount);

    modifier nonReentrant() {
        require(_lock != 2, "reentrancy");
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

    function initialize(address stakingToken_, address rewardToken_, address distributor_) external {
        require(!initialized, "initialized");
        require(stakingToken_ != address(0) && distributor_ != address(0), "zero");
        initialized = true;
        stakingToken = IERC20(stakingToken_);
        rewardToken = rewardToken_;
        distributor = distributor_;
        emit Initialized(stakingToken_, rewardToken_, distributor_);
    }

    // ---- views ----

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return (stakedOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    // ---- actions ----

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(initialized, "not initialized");
        require(amount > 0, "zero");
        totalStaked += amount;
        stakedOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0 && stakedOf[msg.sender] >= amount, "bad amount");
        totalStaked -= amount;
        stakedOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward == 0) return;
        rewards[msg.sender] = 0;
        _pay(msg.sender, reward);
        emit RewardPaid(msg.sender, reward);
    }

    function exit() external {
        uint256 staked = stakedOf[msg.sender];
        if (staked > 0) withdraw(staked);
        getReward();
    }

    /// @notice Fund a new reward period. Native reward: `msg.value == amount`.
    ///         ERC-20 reward: pulled from the distributor (approve first).
    function notifyReward(uint256 amount) external payable updateReward(address(0)) {
        require(msg.sender == distributor, "not distributor");
        require(amount > 0, "zero reward");
        if (rewardToken == address(0)) {
            require(msg.value == amount, "value");
        } else {
            require(msg.value == 0, "no value");
            IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        }
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / DURATION;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (amount + leftover) / DURATION;
        }
        require(rewardRate > 0, "reward too small");
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;
        totalDistributed += amount;
        emit RewardAdded(amount);
    }

    function _pay(address to, uint256 amount) private {
        if (rewardToken == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "reward send failed");
        } else {
            IERC20(rewardToken).safeTransfer(to, amount);
        }
    }
}

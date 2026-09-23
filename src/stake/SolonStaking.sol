// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title SolonStaking
/// @notice Stake SOLON, earn SOLON: every day's protocol buyback is streamed to
///         stakers over 7 days (BUYBACK lane), plus a one-off genesis pool
///         streamed over 30 days (GENESIS lane). Synthetix StakingRewards
///         accounting (same shape as RadianStaking / WallStaking) with two
///         independent lanes summed into one rewardPerToken.
///
///         No lock, no cooldown: `unstake` is one step and pays out principal
///         plus accrued rewards in the same transaction. Exits (`unstake`,
///         `claim`) can never be paused.
///
/// @dev Staking token == reward token, so the contract keeps principal and
///      rewards in two explicit buckets: `totalStaked` (principal) and
///      `rewardReserve` (injected − paid − compounded). Reward payouts are
///      capped by `rewardReserve`, so no reward-side bug can ever reach staked
///      principal. `balanceOf(this) == totalStaked + rewardReserve` for plain
///      SOLON transfers (anything sent in directly is simply stranded).
///
///      The principal path of `unstake` does not depend on the reward maths:
///      settlement and payout run as isolated self-calls under try/catch, so if
///      the reward update ever reverts, principal is still returned and the
///      reward stays on the books (`RewardSettleFailed`).
///
///      Design: docs/DESIGN-stake-v1.md §2.
contract SolonStaking is Ownable2Step {
    using SafeERC20 for IERC20;

    uint8 public constant LANE_BUYBACK = 0;
    uint8 public constant LANE_GENESIS = 1;
    uint256 public constant BUYBACK_DURATION = 7 days;
    uint256 public constant GENESIS_DURATION = 30 days;
    /// @dev guards against a mistaken call producing rate = 0 / dust periods
    uint256 public constant MIN_NOTIFY = 1_000e18;

    IERC20 public immutable solon;
    address public distributor; // buyback daemon hot key: notifyBuyback only
    uint256 public stakeCap; // bounds new stake/compound only, never exits
    bool public paused; // blocks stake / compound / notifyBuyback / seedGenesis only
    bool public genesisSeeded;

    struct Lane {
        uint256 rate; // SOLON wei per second
        uint256 periodFinish;
        uint256 injected; // lifetime
    }

    Lane[2] internal _lanes;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public totalStaked;
    uint256 public rewardReserve;
    /// @dev reward that streamed while nothing was staked, plus rate-truncation
    ///      remainders; owner can only put it back into the BUYBACK stream.
    uint256 public idleRewards;
    uint256 public totalPaid;

    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    /// lane => (block.timestamp / 1 days) => SOLON injected that day
    mapping(uint8 => mapping(uint256 => uint256)) public injectedOnDay;

    uint256 private _lock = 1;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event Compounded(address indexed user, uint256 amount);
    event RewardAdded(uint8 indexed lane, uint256 amount, bytes32 buybackTx);
    event RewardSettleFailed(address indexed user);
    event IdleReallocated(uint256 amount);
    event DistributorSet(address distributor);
    event StakeCapSet(uint256 cap);
    event Paused(address account);
    event Unpaused(address account);

    modifier nonReentrant() {
        require(_lock == 1, "reentrancy");
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "self only");
        _;
    }

    modifier updateReward(address account) {
        _checkpoint(account);
        _;
    }

    constructor(address solon_, address owner_, uint256 stakeCap_) Ownable(owner_) {
        require(solon_ != address(0), "zero");
        solon = IERC20(solon_);
        stakeCap = stakeCap_;
        lastUpdateTime = block.timestamp;
        emit StakeCapSet(stakeCap_);
    }

    // ---------------------------------------------------------------- admin

    function setDistributor(address d) external onlyOwner {
        distributor = d;
        emit DistributorSet(d);
    }

    function setStakeCap(uint256 cap) external onlyOwner {
        stakeCap = cap;
        emit StakeCapSet(cap);
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @dev An ownerless pool could never re-point its distributor.
    function renounceOwnership() public pure override {
        revert("renounce disabled");
    }

    /// @notice Recover a token sent here by mistake. Never SOLON: principal and
    ///         committed rewards are untouchable by the owner.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(solon), "not SOLON");
        IERC20(token).safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------- views

    function laneInfo(uint8 lane)
        external
        view
        returns (uint256 rate, uint256 periodFinish, uint256 duration, uint256 injected)
    {
        Lane storage l = _lanes[lane];
        return (l.rate, l.periodFinish, _duration(lane), l.injected);
    }

    function laneInjected(uint8 lane) external view returns (uint256) {
        return _lanes[lane].injected;
    }

    /// @notice Current combined streaming rate (SOLON wei / second).
    function rewardRate() external view returns (uint256 r) {
        for (uint8 i; i < 2; i++) {
            if (block.timestamp < _lanes[i].periodFinish) r += _lanes[i].rate;
        }
    }

    /// @notice Reward still to stream out of both lanes from now on.
    function unflowedRewards() public view returns (uint256 u) {
        for (uint8 i; i < 2; i++) {
            Lane storage l = _lanes[i];
            if (block.timestamp < l.periodFinish) u += (l.periodFinish - block.timestamp) * l.rate;
        }
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + (_pendingFlow() * 1e18) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return (stakedOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }

    // ---------------------------------------------------------------- user

    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "zero");
        require(totalStaked + amount <= stakeCap, "cap");
        uint256 received = _pull(msg.sender, amount);
        totalStaked += received;
        stakedOf[msg.sender] += received;
        emit Staked(msg.sender, received);
    }

    /// @notice Single-step, instant. Settles and pays accrued rewards, then
    ///         returns `amount` principal — all in this transaction. The
    ///         principal leg runs even if the reward leg reverts.
    function unstake(uint256 amount) external nonReentrant {
        uint256 s = stakedOf[msg.sender];
        require(amount > 0 && amount <= s, "bad amount");

        try this.selfCheckpoint(msg.sender) {
            try this.selfPay(msg.sender) {}
            catch {
                emit RewardSettleFailed(msg.sender);
            }
        } catch {
            emit RewardSettleFailed(msg.sender);
        }

        stakedOf[msg.sender] = s - amount;
        totalStaked -= amount;
        solon.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant updateReward(msg.sender) returns (uint256) {
        return _pay(msg.sender);
    }

    /// @notice Restake accrued rewards (same token, no external call).
    function compound() external nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 r = rewards[msg.sender];
        require(r > 0, "nothing");
        require(r <= rewardReserve, "reserve");
        require(totalStaked + r <= stakeCap, "cap");
        rewards[msg.sender] = 0;
        rewardReserve -= r;
        totalStaked += r;
        stakedOf[msg.sender] += r;
        emit Compounded(msg.sender, r);
    }

    /// @dev Isolated legs of `unstake`, reachable only through the self-call so
    ///      a revert in either rolls back only that leg.
    function selfCheckpoint(address account) external onlySelf {
        _checkpoint(account);
    }

    function selfPay(address account) external onlySelf {
        _pay(account);
    }

    // ---------------------------------------------------------------- funding

    /// @notice Daily buyback injection, streamed over 7 days (leftover of the
    ///         running period is folded in). `buybackTx` links the on-chain
    ///         buyback the SOLON came from.
    function notifyBuyback(uint256 amount, bytes32 buybackTx) external nonReentrant whenNotPaused {
        require(msg.sender == distributor, "not distributor");
        require(amount >= MIN_NOTIFY, "below minimum");
        _checkpoint(address(0));
        uint256 received = _pull(msg.sender, amount);
        _inject(LANE_BUYBACK, received);
        emit RewardAdded(LANE_BUYBACK, received, buybackTx);
    }

    /// @notice One-off genesis pool, streamed over 30 days. Owner only, once.
    function seedGenesis(uint256 amount) external onlyOwner nonReentrant whenNotPaused {
        require(!genesisSeeded, "genesis seeded");
        require(amount >= MIN_NOTIFY, "below minimum");
        genesisSeeded = true;
        _checkpoint(address(0));
        uint256 received = _pull(msg.sender, amount);
        _inject(LANE_GENESIS, received);
        emit RewardAdded(LANE_GENESIS, received, bytes32(0));
    }

    /// @notice Put idle rewards (streamed while nothing was staked, and
    ///         truncation dust) back into the BUYBACK stream. They can only go
    ///         back to stakers, never out of the contract.
    function reallocateIdle() external onlyOwner nonReentrant {
        _checkpoint(address(0));
        uint256 idle = idleRewards;
        require(idle > 0, "nothing");
        idleRewards = 0;
        _startPeriod(LANE_BUYBACK, idle);
        emit IdleReallocated(idle);
    }

    // ---------------------------------------------------------------- internal

    function _duration(uint8 lane) internal pure returns (uint256) {
        return lane == LANE_BUYBACK ? BUYBACK_DURATION : GENESIS_DURATION;
    }

    /// reward streamed by both lanes since lastUpdateTime
    function _pendingFlow() internal view returns (uint256 flow) {
        uint256 last = lastUpdateTime;
        for (uint8 i; i < 2; i++) {
            Lane storage l = _lanes[i];
            uint256 end = block.timestamp < l.periodFinish ? block.timestamp : l.periodFinish;
            if (end > last) flow += (end - last) * l.rate;
        }
    }

    function _checkpoint(address account) internal {
        uint256 flow = _pendingFlow();
        if (flow > 0) {
            if (totalStaked == 0) idleRewards += flow;
            else rewardPerTokenStored += (flow * 1e18) / totalStaked;
        }
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    /// pays what is owed, never more than the reward reserve (principal is
    /// out of reach); any shortfall stays recorded for the user.
    function _pay(address account) internal returns (uint256 pay) {
        uint256 owed = rewards[account];
        if (owed == 0) return 0;
        uint256 reserve = rewardReserve;
        pay = owed < reserve ? owed : reserve;
        if (pay == 0) return 0;
        rewards[account] = owed - pay;
        rewardReserve = reserve - pay;
        totalPaid += pay;
        solon.safeTransfer(account, pay);
        emit RewardPaid(account, pay);
    }

    function _pull(address from, uint256 amount) internal returns (uint256 received) {
        uint256 before = solon.balanceOf(address(this));
        solon.safeTransferFrom(from, address(this), amount);
        received = solon.balanceOf(address(this)) - before;
    }

    function _inject(uint8 lane, uint256 amount) internal {
        rewardReserve += amount;
        _lanes[lane].injected += amount;
        injectedOnDay[lane][block.timestamp / 1 days] += amount;
        _startPeriod(lane, amount);
    }

    /// Synthetix notify: fold the running period's leftover in, restretch over
    /// the lane's full duration. Truncation remainder goes to idle so every wei
    /// stays accounted for. Must be called right after a checkpoint.
    function _startPeriod(uint8 lane, uint256 amount) internal {
        Lane storage l = _lanes[lane];
        uint256 d = _duration(lane);
        uint256 total = amount;
        if (block.timestamp < l.periodFinish) total += (l.periodFinish - block.timestamp) * l.rate;
        uint256 rate = total / d;
        require(rate > 0, "reward too small");
        l.rate = rate;
        l.periodFinish = block.timestamp + d;
        idleRewards += total - rate * d;
        require(unflowedRewards() + idleRewards <= rewardReserve, "underfunded");
    }
}

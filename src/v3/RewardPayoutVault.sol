// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {EligibilityController} from "./EligibilityController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRewardPayoutSource {
    function stageCredit(address account, uint256[] calldata epochs, address asset) external returns (uint256);
    function deliveryAllowed(address account, address asset) external view returns (bool);
    function queueAsset(uint256 epoch) external view returns (address);
    function participantAt(uint256 index) external view returns (address);
    function queueSnapshot(uint256 epoch) external view returns (uint256 upperBound, uint256 revision);
    function poolId() external view returns (bytes32);
    function settlementKind() external view returns (uint8);
}

/// @notice Fixed-source custody. Only verified source deltas create beneficiary debt.
contract RewardPayoutVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    mapping(address => bool) public trustedSource;
    mapping(address => mapping(address => uint256)) public readyRaw;
    mapping(address => mapping(address => uint256)) public paidTotal;
    mapping(address => uint256) public totalLiability;
    EligibilityController public immutable controller;
    address public immutable configurator;
    address public distributor;
    address public factory;
    address public deskModule;
    address public stakingModule;
    bool public rewardModulesConfigured;
    event RewardModulesConfigured(address indexed desk, address indexed staking);
    event SourceRegistered(address indexed source);
    address[] public sources;
    event CreditStaged(address indexed source, address indexed account, address indexed asset, uint256 amount);
    event DeliveryBlocked(address indexed account, address indexed asset, bytes reason);
    event Paid(address indexed account, address indexed asset, uint256 amount);

    constructor(address[] memory sourceList, EligibilityController controller_) {
        require(address(controller_).code.length != 0, "controller");
        controller = controller_;
        configurator = msg.sender;
        for (uint256 i; i < sourceList.length; i++) {
            require(sourceList[i].code.length != 0 && !trustedSource[sourceList[i]], "source");
            trustedSource[sourceList[i]] = true;
            sources.push(sourceList[i]);
        }
    }

    function configureFactory(address factory_) external {
        require(msg.sender == configurator && factory == address(0) && factory_.code.length != 0, "factory");
        factory = factory_;
    }

    function registerSource(address source) external {
        require(
            (msg.sender == factory || msg.sender == deskModule || msg.sender == stakingModule)
                && msg.sender != address(0) && source.code.length != 0 && !trustedSource[source],
            "source"
        );
        trustedSource[source] = true;
        sources.push(source);
        emit SourceRegistered(source);
    }

    /// @notice Fixed local modules may enroll only the source adapters their code creates.
    function configureRewardModules(address desk, address staking) external {
        require(
            msg.sender == configurator && !rewardModulesConfigured && (desk != address(0) || staking != address(0)),
            "modules"
        );
        require(
            (desk == address(0) || desk.code.length != 0) && (staking == address(0) || staking.code.length != 0),
            "module code"
        );
        rewardModulesConfigured = true;
        deskModule = desk;
        stakingModule = staking;
        emit RewardModulesConfigured(desk, staking);
    }

    function stageCredit(address source, address account, uint256[] calldata epochs, address asset)
        external
        nonReentrant
        returns (uint256 amount)
    {
        require(trustedSource[source] && account != address(0), "source/account");
        require(epochs.length <= 20, "epoch page");
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        amount = IRewardPayoutSource(source).stageCredit(account, epochs, asset);
        require(IERC20(asset).balanceOf(address(this)) == beforeBalance + amount, "stage delta");
        readyRaw[account][asset] += amount;
        totalLiability[asset] += amount;
        emit CreditStaged(source, account, asset, amount);
    }

    function claim(address[] calldata assets) external nonReentrant {
        require(assets.length <= 4, "asset page");
        for (uint256 i; i < assets.length; i++) {
            try this.claimOne{gas: 500000}(msg.sender, assets[i]) {}
            catch (bytes memory reason) {
                emit DeliveryBlocked(msg.sender, assets[i], reason);
            }
        }
    }

    function claimOne(address account, address asset) external {
        require(msg.sender == address(this), "self");
        _pay(account, asset);
    }

    function claimFor(address account, address asset) external nonReentrant returns (uint256) {
        require(msg.sender == account || trustedSource[msg.sender] || msg.sender == distributor, "payer");
        return _pay(account, asset);
    }

    function configureDistributor(address d) external {
        require(msg.sender == configurator && distributor == address(0) && d.code.length != 0, "distributor");
        distributor = d;
    }

    function _pay(address account, address asset) internal returns (uint256 amount) {
        amount = readyRaw[account][asset];
        if (amount == 0) return 0;
        require(controller.canReceiveStock(asset, account), "eligibility");
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        uint256 recipientBefore = IERC20(asset).balanceOf(account);
        readyRaw[account][asset] = 0;
        paidTotal[account][asset] += amount;
        totalLiability[asset] -= amount;
        IERC20(asset).safeTransfer(account, amount);
        require(
            IERC20(asset).balanceOf(address(this)) + amount == beforeBalance
                && IERC20(asset).balanceOf(account) == recipientBefore + amount,
            "payout delta"
        );
        emit Paid(account, asset, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IWiringPayoutChoice {
    struct Choice {
        address asset;
        bytes32 assetId;
        uint32 version;
        bytes32 pricePolicy;
        bool enabled;
    }

    function choose(address token, uint256 id) external returns (Choice memory);
}

interface IWiringToken {
    function setDefaultRewardAsset(address asset) external;
    function configurePool(bytes32 pool, address quote, uint8 kind) external;
    function configureEligibility(address controller) external;
    function configurePayout(address payout) external;
    function configureRounds(address manager, bytes32 assetId, uint32 version, bytes32 pricePolicy) external;
    function configureAssetSchedule(address schedule) external;
    function declareEpochRewardPolicy(
        uint256 epoch,
        address asset,
        bytes32 assetId,
        uint32 version,
        bytes32 pricePolicy
    ) external;
}

interface IWiringPayout {
    function registerSource(address source) external;
    function trustedSource(address source) external view returns (bool);
}

interface IWiringRounds {
    function registerSource(address source, bytes32 pool) external;
    function vault() external view returns (address);
}

interface IWiringEligibilityController {
    function registry() external view returns (address);
}

interface IWiringEligibilityRegistry {
    function allowRewardPool(address pool) external;
}

/// @notice Statically linked factory logic. Solidity's fixed library delegatecall preserves
/// the factory as token configurator; there is no user-selected call target or upgrade slot.
library V3RewardWiring {
    struct Infrastructure {
        address controller;
        address payout;
        address rounds;
        bytes32 assetId;
        uint32 adapterVersion;
        bytes32 pricePolicy;
    }

    struct EpochPolicy {
        uint256 epoch;
        address asset;
        bytes32 assetId;
        uint32 version;
        bytes32 pricePolicy;
    }

    struct Defaults {
        address rewardAsset; // factory default (NVDA.sol)
        address payoutChoice; // LaunchPayoutChoice, or address(0)
        uint256 choiceId; // 0 = default
    }

    error InvalidPayoutChoice();
    event LaunchPayoutChosen(bytes32 indexed poolId, address indexed token, uint256 indexed choiceId, address asset);

    /// @notice r7: bind the coin's payout stock (creator's single-stock choice, default NVDA) and wire rewards.
    ///         A chosen stock replaces the factory calendar and epoch policies with its own fixed purchase policy;
    ///         a stock-quote coin is always paid in its quote stock and cannot choose.
    function wireLaunch(
        address token,
        bytes32 pool,
        address quote,
        uint8 kind,
        Defaults memory d,
        Infrastructure memory infra,
        address schedule,
        EpochPolicy[] memory policies
    ) external {
        address asset = d.rewardAsset;
        if (d.choiceId != 0) {
            if (kind != 0 || d.payoutChoice == address(0)) revert InvalidPayoutChoice();
            IWiringPayoutChoice.Choice memory c = IWiringPayoutChoice(d.payoutChoice).choose(token, d.choiceId);
            asset = c.asset;
            infra.assetId = c.assetId;
            infra.adapterVersion = c.version;
            infra.pricePolicy = c.pricePolicy;
            schedule = address(0);
            policies = new EpochPolicy[](0);
        }
        IWiringToken(token).setDefaultRewardAsset(asset);
        IWiringToken(token).configurePool(pool, quote, kind);
        wire(token, pool, kind, infra, schedule, policies);
        emit LaunchPayoutChosen(pool, token, d.choiceId, kind == 1 ? quote : asset);
    }

    function wire(
        address token,
        bytes32 pool,
        uint8 kind,
        Infrastructure memory infra,
        address schedule,
        EpochPolicy[] memory policies
    ) public {
        IWiringToken target = IWiringToken(token);
        target.configureEligibility(infra.controller);
        target.configurePayout(infra.payout);
        address registry = IWiringEligibilityController(infra.controller).registry();
        if (registry != address(0)) IWiringEligibilityRegistry(registry).allowRewardPool(token);
        IWiringPayout pay = IWiringPayout(infra.payout);
        pay.registerSource(token);
        if (kind == 0) {
            target.configureRounds(infra.rounds, infra.assetId, infra.adapterVersion, infra.pricePolicy);
            if (schedule != address(0)) target.configureAssetSchedule(schedule);
            for (uint256 i; i < policies.length; i++) {
                EpochPolicy memory ep = policies[i];
                if (ep.epoch >= block.timestamp / 1 days) {
                    target.declareEpochRewardPolicy(ep.epoch, ep.asset, ep.assetId, ep.version, ep.pricePolicy);
                }
            }
            IWiringRounds rounds = IWiringRounds(infra.rounds);
            rounds.registerSource(token, pool);
            address rewardVault = rounds.vault();
            if (!pay.trustedSource(rewardVault)) pay.registerSource(rewardVault);
        }
    }
}

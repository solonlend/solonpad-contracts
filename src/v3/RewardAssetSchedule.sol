// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Immutable UTC calendar and asset sequence; keepers cannot select the stock.
/// @dev Epochs before start accrue the first asset and wait until start for execution.
contract RewardAssetSchedule {
    struct Policy {
        address asset;
        bytes32 assetId;
        uint32 version;
        bytes32 pricePolicy;
    }
    Policy[] private policies;
    uint256 public immutable startEpoch;
    uint256 public immutable intervalDays;
    uint256 public immutable roundInterval;

    constructor(
        uint256 start,
        uint256 interval,
        address[] memory assets,
        bytes32[] memory ids,
        uint32[] memory versions,
        bytes32[] memory prices
    ) {
        require(
            interval != 0 && assets.length != 0 && assets.length == ids.length && assets.length == versions.length
                && assets.length == prices.length,
            "schedule"
        );
        startEpoch = start;
        intervalDays = interval;
        roundInterval = interval * 1 days;
        require(start * 1 days <= type(uint32).max && roundInterval <= type(uint32).max, "schedule horizon");
        for (uint256 i; i < assets.length; ++i) {
            require(assets[i].code.length != 0 && ids[i] != 0 && versions[i] != 0 && prices[i] != 0, "asset policy");
            policies.push(Policy(assets[i], ids[i], versions[i], prices[i]));
        }
    }

    function policyCount() external view returns (uint256) {
        return policies.length;
    }

    function policyAt(uint256 index)
        public
        view
        returns (address asset, bytes32 assetId, uint32 version, bytes32 pricePolicy)
    {
        Policy storage p = policies[index];
        return (p.asset, p.assetId, p.version, p.pricePolicy);
    }

    function rotationIndex(uint256 epoch) public view returns (uint256) {
        return epoch < startEpoch ? 0 : ((epoch - startEpoch) / intervalDays) % policies.length;
    }

    function resolve(uint256 epoch)
        external
        view
        returns (address asset, bytes32 assetId, uint32 version, bytes32 pricePolicy)
    {
        return policyAt(rotationIndex(epoch));
    }

    function nextRoundAt(uint256 epoch) external view returns (uint256) {
        return epoch < startEpoch
            ? startEpoch * 1 days
            : (startEpoch + ((epoch - startEpoch) / intervalDays + 1) * intervalDays) * 1 days;
    }
}

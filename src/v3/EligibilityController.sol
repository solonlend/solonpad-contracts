// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IEligibilityStatus {
    function policyOf(address wallet) external view returns (bytes32);
    function status(address wallet, uint8 asset, uint256 time) external view returns (bool);
}

/// @notice One-way B -> A switch. Governance must be the deployment's 3/5 multisig.
/// @dev The on-chain 48h delay and UTC boundary cannot be bypassed by governance.
contract EligibilityController {
    address public immutable governance;
    address public registry;
    bytes32 public policyHash;
    uint256 public effectiveEpoch;
    mapping(address => uint16) public assetIds;
    mapping(address => uint256) public systemVaultMask;
    event SystemVaultBound(address indexed vault, uint256 assetMask);

    function bindSystemVault(address vault, uint256 assetMask) external {
        if (msg.sender != governance) revert Unauthorized();
        require(
            effectiveEpoch == 0 && vault.code.length != 0 && assetMask != 0 && systemVaultMask[vault] == 0,
            "system vault"
        );
        systemVaultMask[vault] = assetMask;
        emit SystemVaultBound(vault, assetMask);
    }
    event EnableScheduled(address indexed registry, bytes32 indexed policyHash, uint256 effectiveEpoch);
    event EnableCancelled();
    error Unauthorized();
    error InvalidSchedule();

    constructor(address governance_) {
        require(governance_ != address(0));
        governance = governance_;
    }

    function scheduleEnable(address registry_, bytes32 policy, uint256 epoch) external {
        if (msg.sender != governance) revert Unauthorized();
        if (
            effectiveEpoch != 0 || registry_.code.length == 0 || policy == 0
                || epoch * 1 days < block.timestamp + 48 hours
        ) revert InvalidSchedule();
        registry = registry_;
        policyHash = policy;
        effectiveEpoch = epoch;
        emit EnableScheduled(registry_, policy, epoch);
    }

    function cancelEnable() external {
        if (msg.sender != governance) revert Unauthorized();
        if (effectiveEpoch == 0 || enabled()) revert InvalidSchedule();
        registry = address(0);
        policyHash = 0;
        effectiveEpoch = 0;
        emit EnableCancelled();
    }

    function enabled() public view returns (bool) {
        return effectiveEpoch != 0 && block.timestamp >= effectiveEpoch * 1 days;
    }

    function eligibilityEnabled() external view returns (bool) {
        return enabled();
    }

    function modeGeneration() external view returns (uint256) {
        return enabled() ? 1 : 0;
    }

    /// @notice Asset identity is frozen before the announced mode switch.
    function bindAsset(address asset, uint8 id) external {
        if (msg.sender != governance) revert Unauthorized();
        require(effectiveEpoch == 0 && asset != address(0) && assetIds[asset] == 0);
        assetIds[asset] = uint16(id) + 1;
    }

    /// @notice The official router supplies the real funding and receiving
    /// addresses. Native-USDC/meme transfers remain unrestricted in mode A.
    function checkTrade(bytes32, address quoteAsset, address payer, address recipient, bool) external view {
        if (!enabled() || quoteAsset == address(0)) return;
        require(canReceiveStock(quoteAsset, payer) && canReceiveStock(quoteAsset, recipient), "trade eligibility");
    }

    function canReceiveStock(address asset, address wallet) public view returns (bool) {
        if (!enabled()) return true;
        uint16 id = assetIds[asset];
        if (id != 0 && (systemVaultMask[wallet] & (uint256(1) << (id - 1))) != 0) return true;
        return id != 0 && IEligibilityStatus(registry).policyOf(wallet) == policyHash
            && IEligibilityStatus(registry).status(wallet, uint8(id - 1), block.timestamp);
    }
}

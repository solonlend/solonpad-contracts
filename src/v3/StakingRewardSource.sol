// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {
    SignatureChecker
} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {StakingCarry} from "./libraries/StakingCarry.sol";
import {EligibilityRegistry} from "./EligibilityRegistry.sol";
import {EligibilityController} from "./EligibilityController.sol";
import {V3FeeLedger} from "./V3FeeLedger.sol";

interface IStakingRewardEngine {
    function sealSource(bytes32, uint256) external returns (uint256, uint256, uint8);
    function sourceAsset(bytes32, uint256) external view returns (address);
    function sourcePolicy(bytes32, uint256) external view returns (bytes32, uint32, bytes32, uint8);
    function sourceQueueSnapshot(bytes32, uint256) external view returns (uint256, uint256);
    function participantAt(uint256) external view returns (address);
    function lastFeeAt(bytes32) external view returns (uint256);
    function payout() external view returns (address);
    function roundsManager() external view returns (address);
    function stageSource(bytes32, address, uint256[] calldata, address) external returns (uint256);
    function sourceInfo(bytes32) external view returns (bytes32, address, uint8, bytes32, uint32, bytes32);
    function sourceCredit(bytes32, address, uint256) external view returns (uint256);
    function deliveryAllowed(address, address) external view returns (bool);
}

interface IStakingPayout {
    function stageCredit(address, address, uint256[] calldata, address) external returns (uint256);
    function claimFor(address, address) external returns (uint256);
}

/// @notice Immutable source/asset/kind adapter for the existing payout and round APIs.
contract StakingRewardSource {
    IStakingRewardEngine public immutable staking;
    // Write-once storage avoids solc 0.8.26 via-IR immutable substitution ICE.
    bytes32 public key;

    constructor(address staking_, bytes32 key_) {
        staking = IStakingRewardEngine(staking_);
        key = key_;
    }

    function rewardPolicy(uint256 epoch, uint8 cohort) external view returns (bytes32, uint32, bytes32, uint8) {
        require(cohort == 0, "cohort");
        return staking.sourcePolicy(key, epoch);
    }

    function sealReward(uint256 epoch, uint8 cohort) external returns (uint256 budget, uint256 credit, uint8 kind) {
        require(msg.sender == staking.roundsManager() && cohort == 0, "manager/cohort");
        (budget, credit, kind) = staking.sealSource(key, epoch);
        (bool ok,) = msg.sender.call{value: budget}("");
        require(ok, "round funding");
    }

    function queueSnapshot(uint256 epoch) external view returns (uint256, uint256) {
        return staking.sourceQueueSnapshot(key, epoch);
    }

    function participantAt(uint256 i) external view returns (address) {
        return staking.participantAt(i);
    }

    function lastFeeAt() external view returns (uint256) {
        return staking.lastFeeAt(key);
    }

    receive() external payable {
        require(msg.sender == address(staking), "staking");
    }

    /// @notice DirectStock claims share payout debt with automated distribution.
    /// PurchaseStock uses the RoundManager RewardVault allocation IDs.
    function claim(uint256[] calldata epochs, address[] calldata assets) external {
        require(epochs.length <= 20 && assets.length <= 4, "claim page");
        (, address asset, uint8 kind,,,) = staking.sourceInfo(key);
        require(kind == 1, "claim purchase through reward vault");
        IStakingPayout vault = IStakingPayout(staking.payout());
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] != asset) continue;
            vault.stageCredit(address(this), msg.sender, epochs, asset);
            vault.claimFor(msg.sender, asset);
        }
    }

    function stageCredit(address account, uint256[] calldata epochs, address asset) external returns (uint256) {
        require(msg.sender == staking.payout(), "payout");
        return staking.stageSource(key, account, epochs, asset);
    }

    function poolId() external view returns (bytes32 source) {
        (source,,,,,) = staking.sourceInfo(key);
    }

    function settlementKind() external view returns (uint8 kind) {
        (,, kind,,,) = staking.sourceInfo(key);
    }

    function queueAsset(uint256 epoch) external view returns (address asset) {
        return staking.sourceAsset(key, epoch);
    }

    function creditOf(address account, uint256 epoch, uint8 cohort) external view returns (uint256) {
        require(cohort == 0, "credit cohort");
        return staking.sourceCredit(key, account, epoch);
    }

    function deliveryAllowed(address account, address asset) external view returns (bool) {
        return staking.deliveryAllowed(account, asset);
    }
}

interface IStakingHolderPolicy {
    function queueAsset(uint256) external view returns (address);
    function defaultRewardAsset() external view returns (address);
    function assetSchedule() external view returns (address);
    function rewardPolicy(uint256, uint8) external view returns (bytes32, uint32, bytes32, uint8);
}

interface IStakingEligibilityAssets {
    function assetIds(address) external view returns (uint16);
}

interface IStakingAssetSchedule {
    function policyCount() external view returns (uint256);
    function policyAt(uint256) external view returns (address, bytes32, uint32, bytes32);
    function resolve(uint256) external view returns (address, bytes32, uint32, bytes32);
}

/// @dev Fixed factory keeps source creation bytecode out of the staking runtime.
contract StakingRewardSourceFactory {
    using StakingCarry for StakingCarry.Stream;
    mapping(bytes32 => StakingCarry.Stream) private streams;

    function checkpointCarry(bytes32 key, bool running, uint256 time, uint256 deposit27)
        external
        returns (uint256 released)
    {
        require(msg.sender == staking, "staking");
        StakingCarry.Stream storage stream = streams[key];
        released = stream.checkpoint(running, time);
        if (deposit27 != 0) stream.deposit(deposit27);
    }

    function carryState(bytes32 key) external view returns (uint256, uint256, uint256, uint256) {
        StakingCarry.Stream storage c = streams[key];
        return (c.deposited + c.pendingDeposit, c.released, c.clock, c.last);
    }
    address public immutable staking;

    constructor(address staking_) {
        staking = staking_;
    }

    function resolvePool(address ledger, bytes32 pool, address quote, uint8 kind, uint256 epoch)
        external
        view
        returns (address asset, bytes32 id, uint32 version, bytes32 policy)
    {
        (bytes32 actualPool, uint8 bucket) = ledgerPosition(ledger, pool);
        V3FeeLedger.Pool memory p = V3FeeLedger(payable(ledger)).poolInfo(actualPool);
        require(bucket != 0 || (kind == 1 && p.beneficiaries[0] == staking), "legacy holder");
        require(p.beneficiaries[3] == staking && p.quote == quote && p.settlementKind == kind, "ledger source");
        if (kind == 1) return (quote, 0, 0, 0);
        IStakingHolderPolicy h = IStakingHolderPolicy(p.beneficiaries[0]);
        asset = h.queueAsset(epoch);
        if (asset == address(0)) {
            address schedule = h.assetSchedule();
            if (schedule == address(0)) asset = h.defaultRewardAsset();
            else (asset,,,) = IStakingAssetSchedule(schedule).resolve(epoch);
        }
        (id, version, policy,) = h.rewardPolicy(epoch, 0);
    }

    /// @notice A-mode credential expiry for a staker, or zero when the credential
    /// cannot earn now (missing, revoked, expired, wrong policy or basket).
    function eligibilityExpiry(address controller, address account, uint256 requiredMask)
        external
        view
        returns (uint32 expiry)
    {
        EligibilityController c = EligibilityController(controller);
        uint256 mask;
        uint256 generation;
        bytes32 policy;
        bool revoked;
        (, expiry, mask, generation,, policy, revoked) = EligibilityRegistry(c.registry()).credentials(account);
        if (
            generation == 0 || revoked || expiry <= block.timestamp || policy != c.policyHash() || requiredMask == 0
                || (mask & requiredMask) != requiredMask
        ) return 0;
    }

    function ledgerPosition(address ledger, bytes32 source) public view returns (bytes32 pool, uint8 bucket) {
        pool = V3FeeLedger(payable(ledger)).legacyHolderPool(source);
        return pool == 0 ? (source, uint8(3)) : (pool, uint8(0));
    }

    address public v2Schedule;
    address public protocolSchedule;
    bool private schedulesConfigured;

    function configureSchedules(address v2, address protocol, address controller) external returns (uint256 mask) {
        require(
            msg.sender == staking && !schedulesConfigured && (v2 != address(0) || protocol != address(0))
                && (v2 == address(0) || v2.code.length != 0) && (protocol == address(0) || protocol.code.length != 0),
            "schedules"
        );
        schedulesConfigured = true;
        v2Schedule = v2;
        protocolSchedule = protocol;
        return _scheduleMask(v2, controller) | _scheduleMask(protocol, controller);
    }

    function assetMask(address controller, address[] calldata assets) external view returns (uint256 mask) {
        for (uint256 i; i < assets.length; ++i) {
            uint16 id = IStakingEligibilityAssets(controller).assetIds(assets[i]);
            require(id != 0 && assets[i].code.length != 0, "basket asset");
            mask |= uint256(1) << (id - 1);
        }
    }

    function _scheduleMask(address schedule, address controller) internal view returns (uint256 mask) {
        if (schedule == address(0)) return 0;
        uint256 count = IStakingAssetSchedule(schedule).policyCount();
        for (uint256 i; i < count; ++i) {
            (address asset,,,) = IStakingAssetSchedule(schedule).policyAt(i);
            uint16 id = IStakingEligibilityAssets(controller).assetIds(asset);
            if (id != 0) mask |= uint256(1) << (id - 1);
        }
    }

    function resolveExternal(bool v2, address protocol, uint256 epoch)
        external
        view
        returns (address asset, bytes32 id, uint32 version, bytes32 policy)
    {
        address schedule = v2 ? v2Schedule : protocolSchedule;
        if (!v2 && schedule == address(0)) {
            (bool ok, bytes memory data) = protocol.staticcall(abi.encodeWithSignature("schedule()"));
            if (ok && data.length == 32) schedule = abi.decode(data, (address));
        }
        if (schedule != address(0)) return IStakingAssetSchedule(schedule).resolve(epoch);
    }

    function validStakeConsent(
        address sponsor,
        address beneficiary,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external view returns (bool) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Solon Staking V2"),
                keccak256("1"),
                block.chainid,
                staking
            )
        );
        bytes32 body = keccak256(
            abi.encode(
                keccak256(
                    "StakeConsent(address sponsor,address beneficiary,uint256 amount,uint256 nonce,uint256 deadline)"
                ),
                sponsor,
                beneficiary,
                amount,
                nonce,
                deadline
            )
        );
        return SignatureChecker.isValidSignatureNow(
            beneficiary, keccak256(abi.encodePacked("\x19\x01", domain, body)), signature
        );
    }

    function create(bytes32 key) external returns (address) {
        require(msg.sender == staking, "staking");
        return address(new StakingRewardSource(staking, key));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {EIP712} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {
    SignatureChecker
} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IEligibilityModule {
    function onEligibilityChange(address wallet) external;
}

contract EligibilityRegistry is EIP712, ReentrancyGuard {
    struct Attestation {
        uint256 chainId;
        address registry;
        address wallet;
        bytes32 beneficiaryCommitment;
        uint256 assetMask;
        uint256 investorClass;
        bytes32 jurisdictionPolicyHash;
        uint256 issuedAt;
        uint256 validUntil;
        uint256 nonce;
        bytes32 termsHash;
    }
    address public immutable governance;
    mapping(address => bool) public issuer;

    struct IssuerChange {
        uint256 at;
        bool allowed;
    }
    mapping(address => IssuerChange) public issuerChanges;

    constructor(address governance_) EIP712("Solon Eligibility", "1") {
        require(governance_ != address(0));
        governance = governance_;
    }

    function scheduleIssuer(address who, bool allowed) external {
        require(msg.sender == governance && who != address(0), "governance");
        issuerChanges[who] = IssuerChange(block.timestamp + 48 hours, allowed);
    }

    function executeIssuer(address who) external {
        IssuerChange memory c = issuerChanges[who];
        require(c.at != 0 && block.timestamp >= c.at, "issuer timelock");
        issuer[who] = c.allowed;
        delete issuerChanges[who];
    }
    bytes32 public constant TYPEHASH = keccak256(
        "Eligibility(uint256 chainId,address registry,address wallet,bytes32 beneficiaryCommitment,uint256 assetMask,uint256 investorClass,bytes32 jurisdictionPolicyHash,uint256 issuedAt,uint256 validUntil,uint256 nonce,bytes32 termsHash)"
    );

    struct Credential {
        uint32 issuedAt;
        uint32 validUntil;
        uint256 assetMask;
        uint256 generation;
        bytes32 id;
        bytes32 policyHash;
        bool revoked;
    }
    mapping(address => Credential) public credentials;
    mapping(address => uint256) public nonces;
    mapping(bytes32 => address) public credentialWallet;
    event Registered(address indexed wallet, bytes32 indexed credentialId, uint256 generation, uint32 validUntil);
    event Revoked(address indexed wallet, bytes32 indexed credentialId, bytes32 reasonHash);

    function digest(Attestation calldata a) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(TYPEHASH, a)));
    }

    function register(Attestation calldata a, address[] calldata signers, bytes[] calldata sigs, bytes calldata consent)
        external
        nonReentrant
    {
        _register(a, signers, sigs, consent);
    }

    function renew(Attestation calldata a, address[] calldata signers, bytes[] calldata sigs, bytes calldata consent)
        external
        nonReentrant
    {
        require(credentials[a.wallet].generation != 0, "unregistered");
        _register(a, signers, sigs, consent);
    }

    function _register(
        Attestation calldata a,
        address[] calldata signers,
        bytes[] calldata sigs,
        bytes calldata consent
    ) internal {
        require(signers.length == 2 && sigs.length == 2 && signers[0] != signers[1], "two issuers required");
        require(a.chainId == block.chainid && a.registry == address(this) && a.wallet != address(0), "domain");
        require(
            a.nonce == nonces[a.wallet] && a.issuedAt <= block.timestamp && a.validUntil > block.timestamp
                && a.validUntil <= type(uint32).max,
            "time/nonce"
        );
        require(
            a.beneficiaryCommitment != 0 && a.termsHash != 0 && a.jurisdictionPolicyHash != 0 && a.assetMask != 0,
            "claims"
        );
        bytes32 hash = digest(a);
        for (uint256 i; i < 2; ++i) {
            require(
                issuer[signers[i]] && SignatureChecker.isValidSignatureNow(signers[i], hash, sigs[i]),
                "issuer signature"
            );
        }
        require(SignatureChecker.isValidSignatureNow(a.wallet, hash, consent), "wallet consent");
        // Settle the old segment at its original expiry/revocation boundary first.
        _notify(a.wallet);
        uint256 generation = credentials[a.wallet].generation + 1;
        credentials[a.wallet] = Credential(
            uint32(a.issuedAt), uint32(a.validUntil), a.assetMask, generation, hash, a.jurisdictionPolicyHash, false
        );
        credentialWallet[hash] = a.wallet;
        ++nonces[a.wallet];
        emit Registered(a.wallet, hash, generation, uint32(a.validUntil));
    }

    function status(address wallet, uint8 asset, uint256 time) external view returns (bool) {
        Credential storage c = credentials[wallet];
        return !c.revoked && c.generation != 0 && c.issuedAt <= time && time < c.validUntil
            && (c.assetMask & (uint256(1) << asset)) != 0;
    }

    function validUntil(address wallet) external view returns (uint32) {
        return credentials[wallet].validUntil;
    }

    function assetMaskOf(address wallet) external view returns (uint256) {
        return credentials[wallet].assetMask;
    }

    function policyOf(address wallet) external view returns (bytes32) {
        return credentials[wallet].policyHash;
    }

    function revoke(bytes32 id, bytes32 reasonHash) external nonReentrant {
        require(msg.sender == governance || issuer[msg.sender], "revoke authority");
        address wallet = credentialWallet[id];
        require(wallet != address(0) && credentials[wallet].id == id && !credentials[wallet].revoked, "credential");
        _notify(wallet);
        credentials[wallet].revoked = true;
        emit Revoked(wallet, id, reasonHash);
    }
    address public factory;
    event FactoryConfigured(address indexed factory);

    /// @notice One fixed deployment factory may register its newly launched holder pools.
    function configureFactory(address factory_) external {
        require(msg.sender == governance && factory == address(0) && factory_.code.length != 0, "factory");
        factory = factory_;
        emit FactoryConfigured(factory_);
    }
    mapping(address => bool) public rewardModule;
    mapping(address => address[]) private pools;
    address public desk;
    address public staking;

    function allowRewardPool(address pool) external {
        require((msg.sender == governance || msg.sender == factory) && pool.code.length != 0);
        rewardModule[pool] = true;
    }

    function setFixedModules(address desk_, address staking_) external {
        require(msg.sender == governance && desk == address(0) && staking == address(0));
        require(
            (desk_ == address(0) || desk_.code.length != 0) && (staking_ == address(0) || staking_.code.length != 0)
        );
        desk = desk_;
        staking = staking_;
    }

    function bindRewardPool(address wallet) external {
        require(rewardModule[msg.sender], "unknown module");
        address[] storage p = pools[wallet];
        for (uint256 i; i < p.length; ++i) {
            if (p[i] == msg.sender) return;
        }
        require(p.length < 8, "pool capacity");
        p.push(msg.sender);
    }

    function unbindRewardPool(address wallet) external {
        address[] storage p = pools[wallet];
        for (uint256 i; i < p.length; ++i) {
            if (p[i] == msg.sender) {
                p[i] = p[p.length - 1];
                p.pop();
                return;
            }
        }
    }

    function boundPools(address wallet) external view returns (address[] memory) {
        return pools[wallet];
    }

    function _notify(address wallet) internal {
        address[] memory p = pools[wallet];
        for (uint256 i; i < p.length; ++i) {
            IEligibilityModule(p[i]).onEligibilityChange(wallet);
        }
        if (desk != address(0)) IEligibilityModule(desk).onEligibilityChange(wallet);
        if (staking != address(0)) IEligibilityModule(staking).onEligibilityChange(wallet);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SignatureChecker
} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

interface IV2FundRouter {
    function onFunded(bytes32 id, uint8 kind, address token, uint256 amount) external payable;
}

/// @notice Public collect evidence is attested by two independent auditors; only exact new custody creates funded budgets.
/// Historical receipts are not natively readable by the EVM. Auditors attest platform-only delta after cutover.
contract V2FeeIngress is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public constant SOLON = 0xd36687146385F7Dc84A18FEA3D00319d39D6d1a0;
    address public constant SOLON_SPLITTER = 0xD6B05564ceA990b69ABF10B433279093758e2A54;
    bytes32 public constant SOLON_POOL = 0xe4c4b7da3706193e7bf6e7b236156718a5856bc6d6866440661969ae3dcb0a77;

    struct Source {
        uint256 chainId;
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        uint256 positionId;
        address splitter;
        address platformRecipient;
        uint64 cutoverBlock;
        uint32 policyVersion;
        uint8 kind;
    }

    struct Evidence {
        bytes32 source;
        bytes32 collectTx;
        uint64 collectBlock;
        uint32 logIndex;
        address token;
        uint256 actualPlatformAmount;
        uint32 policyVersion;
    }

    struct AuditSignature {
        uint8 auditor;
        bytes signature;
    }

    struct Lot {
        Evidence evidence;
        uint8 state;
        bool admitted;
    }
    address public immutable governance;
    address[3] public auditors;
    address public router;
    bytes32 public immutable solonSourceKey;
    mapping(bytes32 => Source) public sources;
    mapping(bytes32 => Lot) private lots;
    mapping(bytes32 => bool) public receiptUsed;
    event Observed(
        bytes32 indexed id,
        bytes32 indexed source,
        bytes32 indexed collectTx,
        address token,
        uint256 amount,
        uint64 collectBlock,
        uint32 logIndex,
        bool admitted
    );
    event Funded(bytes32 indexed id, address token, uint256 amount);

    constructor(address gov, address[3] memory auditors_, address funder, uint64 cutover) {
        require(gov != address(0) && funder != address(0));
        for (uint256 i; i < 3; i++) {
            require(auditors_[i] != address(0));
            for (uint256 j; j < i; j++) {
                require(auditors_[i] != auditors_[j]);
            }
        }
        governance = gov;
        auditors = auditors_;
        Source memory s =
            Source(5042, address(0), SOLON, 10000, 100, address(0), 45012, SOLON_SPLITTER, funder, cutover, 1, 1);
        bytes32 id = sourceKey(s);
        solonSourceKey = id;
        sources[id] = s;
    }

    function sourceKey(Source memory s) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                s.chainId,
                keccak256(abi.encode(s.currency0, s.currency1, s.fee, s.tickSpacing, s.hooks)),
                s.positionId,
                s.splitter
            )
        );
    }

    function evidenceDigest(Evidence memory e) public view returns (bytes32) {
        return keccak256(abi.encode(keccak256("V2PlatformCollectEvidenceV1"), e, block.chainid, address(this)));
    }

    function setRouter(address r) external {
        require(msg.sender == governance && router == address(0) && r.code.length != 0);
        router = r;
    }

    function lotInfo(bytes32 id) external view returns (Lot memory) {
        return lots[id];
    }

    function recordLot(Evidence calldata e, AuditSignature[2] calldata sigs)
        external
        nonReentrant
        returns (bytes32 id)
    {
        require(e.collectTx != 0 && e.actualPlatformAmount != 0 && e.collectBlock <= block.number);
        require(sigs[0].auditor < 3 && sigs[1].auditor < 3 && sigs[0].auditor != sigs[1].auditor);
        bytes32 digest = evidenceDigest(e);
        for (uint256 i; i < 2; i++) {
            require(SignatureChecker.isValidSignatureNow(auditors[sigs[i].auditor], digest, sigs[i].signature));
        }
        bytes32 receipt = keccak256(abi.encode(e.source, e.collectTx, e.logIndex, e.token));
        require(!receiptUsed[receipt]);
        receiptUsed[receipt] = true;
        id = keccak256(abi.encode(digest));
        require(lots[id].state == 0);
        Source storage s = sources[e.source];
        bool admitted = s.kind != 0 && s.chainId == block.chainid && e.collectBlock >= s.cutoverBlock
            && e.policyVersion == s.policyVersion && (e.token == s.currency0 || e.token == s.currency1);
        lots[id] = Lot(e, 1, admitted);
        emit Observed(id, e.source, e.collectTx, e.token, e.actualPlatformAmount, e.collectBlock, e.logIndex, admitted);
    }

    function fundLot(bytes32 id) external payable nonReentrant {
        Lot storage l = lots[id];
        require(l.state == 1 && l.admitted && router != address(0));
        Evidence storage e = l.evidence;
        Source storage s = sources[e.source];
        require(msg.sender == s.platformRecipient);
        l.state = 2;
        if (e.token == address(0)) {
            require(msg.value == e.actualPlatformAmount);
            IV2FundRouter(router).onFunded{value: msg.value}(id, s.kind, e.token, msg.value);
        } else {
            require(msg.value == 0);
            IERC20 token = IERC20(e.token);
            uint256 beforeBalance = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), e.actualPlatformAmount);
            require(token.balanceOf(address(this)) == beforeBalance + e.actualPlatformAmount);
            uint256 beforeRouter = token.balanceOf(router);
            token.safeTransfer(router, e.actualPlatformAmount);
            require(
                token.balanceOf(router) == beforeRouter + e.actualPlatformAmount
                    && token.balanceOf(address(this)) == beforeBalance
            );
            IV2FundRouter(router).onFunded(id, s.kind, e.token, e.actualPlatformAmount);
        }
        emit Funded(id, e.token, e.actualPlatformAmount);
    }
    mapping(bytes32 => uint256) public sourceActivation;
    event SourceScheduled(bytes32 indexed source, bytes32 configHash, uint256 executeAfter);
    event SourceActivated(bytes32 indexed source, bytes32 configHash);

    function scheduleSource(Source calldata s) external {
        require(
            msg.sender == governance && s.kind == 2 && s.chainId == block.chainid && s.currency0 < s.currency1
                && s.positionId != 0 && s.splitter != address(0) && s.platformRecipient != address(0)
                && s.policyVersion != 0
        );
        require(
            sources[sourceKey(s)].kind == 0
                && keccak256(abi.encode(s.currency0, s.currency1, s.fee, s.tickSpacing, s.hooks)) != SOLON_POOL
        );
        bytes32 hash = keccak256(abi.encode(s));
        sourceActivation[hash] = block.timestamp + 48 hours;
        emit SourceScheduled(sourceKey(s), hash, block.timestamp + 48 hours);
    }

    function activateSource(Source calldata s) external {
        bytes32 hash = keccak256(abi.encode(s));
        require(
            sourceActivation[hash] != 0 && block.timestamp >= sourceActivation[hash] && sources[sourceKey(s)].kind == 0
        );
        delete sourceActivation[hash];
        sources[sourceKey(s)] = s;
        emit SourceActivated(sourceKey(s), hash);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {
    TimelockController
} from "../../../lib/v4-core/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";

/// @notice Solon v3 governance: OpenZeppelin v5 TimelockController (unchanged scheduling,
/// execution and operation-id semantics) with a fixed 48h floor, a tighten-only guardian and a
/// one-shot deployment bootstrap.
///
/// Roles
/// - PROPOSER/CANCELLER: the 3/5 multisig. Only proposer; there is no external admin, so role
///   changes, guardian allowlists and delay changes are themselves 48h self-operations.
/// - EXECUTOR: open (address(0)); anyone may execute a ready operation.
/// - GUARDIAN (2/3): CANCELLER of ordinary pending operations and caller of target-declared
///   tighten-only selectors (pause / lower caps). It cannot propose, execute early, send value,
///   call the governance itself, or cancel protected self-operations (so it cannot block its own
///   removal). Recovery (unpause, raising caps) is always an ordinary 48h operation.
/// - Bootstrap: the deployer may CREATE and wire contracts as this address until it closes the
///   window (or the deadline passes). Afterwards the path is permanently disabled.
contract V3Governance is TimelockController {
    uint256 public constant MIN_DELAY = 48 hours;
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @dev Operations that call the governance itself (roles, delay, guardian allowlist).
    mapping(bytes32 => bool) public protectedOperation;
    /// @dev Replaces the parent's private delay so the floor can be enforced on updates.
    uint256 private _delay = MIN_DELAY;

    error ProtectedOperation(bytes32 id);
    error DelayBelowFloor(uint256 delay);
    error InvalidRole();
    error BootstrapUnavailable();
    error NotTightenOnly(address target, bytes4 selector);

    event GuardianActionSet(address indexed target, bytes4 indexed selector, bool allowed);
    event GuardianCalled(address indexed target, bytes4 indexed selector);

    /// @dev target => selector => guardian may call it immediately.
    mapping(address => mapping(bytes4 => bool)) public guardianAction;

    /// @notice 48h self-operation. A selector can be granted only if the (non-proxy) target's own
    /// code declares it tighten-only via `guardianTightenOnly(bytes4)`; revoking is always allowed.
    function setGuardianAction(address target, bytes4 selector, bool allowed) external {
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        if (allowed) {
            if (target == address(this) || target.code.length == 0) revert NotTightenOnly(target, selector);
            (bool ok, bytes memory ret) =
                target.staticcall(abi.encodeWithSignature("guardianTightenOnly(bytes4)", selector));
            if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) != 1) revert NotTightenOnly(target, selector);
        }
        guardianAction[target][selector] = allowed;
        emit GuardianActionSet(target, selector, allowed);
    }

    /// @notice Immediate tighten-only call; carries no value.
    function guardianCall(address target, bytes calldata data)
        external
        onlyRole(GUARDIAN_ROLE)
        returns (bytes memory ret)
    {
        bytes4 selector = bytes4(data);
        if (target == address(this) || !guardianAction[target][selector]) revert NotTightenOnly(target, selector);
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        emit GuardianCalled(target, selector);
    }

    event BootstrapCreated(address indexed deployed);
    event BootstrapCalled(address indexed target, bytes4 indexed selector);
    event BootstrapClosed();

    uint256 public constant MAX_BOOTSTRAP_WINDOW = 7 days;
    address public immutable bootstrapper;
    uint256 public immutable bootstrapDeadline;
    bool public bootstrapClosed;

    modifier onlyBootstrap() {
        if (msg.sender != bootstrapper || bootstrapClosed || block.timestamp > bootstrapDeadline) {
            revert BootstrapUnavailable();
        }
        _;
    }

    /// @notice Deployment-only CREATE so that `msg.sender`-configured roles equal governance.
    function bootstrapCreate(bytes calldata initCode) external onlyBootstrap returns (address deployed) {
        bytes memory code = initCode;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        if (deployed == address(0)) revert BootstrapUnavailable();
        emit BootstrapCreated(deployed);
    }

    /// @notice Deployment-only one-shot wiring. No value and never the governance itself.
    function bootstrapCall(address target, bytes calldata data) external onlyBootstrap returns (bytes memory ret) {
        if (target == address(this) || target.code.length == 0) revert BootstrapUnavailable();
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        emit BootstrapCalled(target, bytes4(data));
    }

    /// @notice Bootstrapper closes it after wiring; after the deadline anyone may record closure.
    function closeBootstrap() external {
        if (bootstrapClosed || (msg.sender != bootstrapper && block.timestamp <= bootstrapDeadline)) {
            revert BootstrapUnavailable();
        }
        bootstrapClosed = true;
        emit BootstrapClosed();
    }

    constructor(address multisig, address guardian, address bootstrapper_, uint256 bootstrapDeadline_)
        TimelockController(MIN_DELAY, _one(multisig), _one(address(0)), address(0))
    {
        if (multisig == address(0) || guardian == address(0) || guardian == multisig) revert InvalidRole();
        _grantRole(CANCELLER_ROLE, guardian);
        _grantRole(GUARDIAN_ROLE, guardian);
        // Absolute deadline (not now+window) keeps the runtime code, and so the manifest codehash,
        // independent of the block the deployment lands in.
        if (
            bootstrapper_ == address(0) || bootstrapDeadline_ < block.timestamp
                || bootstrapDeadline_ > block.timestamp + MAX_BOOTSTRAP_WINDOW
        ) revert InvalidRole();
        bootstrapper = bootstrapper_;
        bootstrapDeadline = bootstrapDeadline_;
    }

    function _one(address a) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override {
        super.schedule(target, value, data, predecessor, salt, delay);
        if (target == address(this)) protectedOperation[hashOperation(target, value, data, predecessor, salt)] = true;
    }

    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override {
        super.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i] == address(this)) {
                protectedOperation[hashOperationBatch(targets, values, payloads, predecessor, salt)] = true;
                break;
            }
        }
    }

    /// @notice Guardian may cancel ordinary operations; only the proposer cancels protected ones.
    function cancel(bytes32 id) public override {
        if (protectedOperation[id] && !hasRole(PROPOSER_ROLE, msg.sender)) revert ProtectedOperation(id);
        super.cancel(id);
    }

    /// @notice Still a self-operation; the 48h floor can never be lowered.
    function updateDelay(uint256 newDelay) external override {
        if (newDelay < MIN_DELAY) revert DelayBelowFloor(newDelay);
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        emit MinDelayChange(_delay, newDelay);
        _delay = newDelay;
    }

    function getMinDelay() public view override returns (uint256) {
        return _delay;
    }
}

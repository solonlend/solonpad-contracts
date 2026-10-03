// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {V3FeeLedger} from "./V3FeeLedger.sol";

interface IProtocolOps {
    function receiveBudget(uint256 version) external payable;
}

/// @notice Cash-only protocol revenue. Governance is the published timelock/multisig.
contract ProtocolVault is ReentrancyGuard {
    address public immutable governance;
    address public immutable treasury;
    address public immutable ops;
    address public immutable ledger;
    uint256 public liabilities;
    uint256 public executionBudget;
    uint256 public operatingBuffer = 100 ether;
    address public stockConverter;
    address public desk;
    mapping(bytes32 => bool) public creditedReceipt;
    uint256 public stockConversionRevenue;
    uint256 public deskRevenue;

    struct Pot {
        address source;
        bytes32 destinationId;
        address destination;
        uint256 cash;
        uint256 committed;
        uint256 inFlight;
        uint256 reserved;
    }
    mapping(bytes32 => Pot) public pots;
    uint256 public potCash;
    mapping(bytes32 => bool) public enabledPools;
    uint256 public ledgerRevenue;
    mapping(bytes32 => uint256) public scheduledAt;
    event Scheduled(bytes32 indexed action, uint256 executableAt);
    event CommitmentsSet(uint256 liabilities, uint256 executionBudget, uint256 operatingBuffer);
    event SurplusWithdrawn(uint256 amount);
    event OpsAllocated(uint256 indexed version, uint256 amount);
    event RevenueReceived(bytes32 indexed receipt, uint8 source, uint256 amount);
    event PotRegistered(bytes32 indexed sourceId, bytes32 indexed destinationId, address source, address destination);
    event PotRouted(bytes32 indexed sourceId, bytes32 indexed destinationId, uint256 amount);

    constructor(address gov, address treasury_, address ops_, address ledger_) {
        require(gov != address(0) && treasury_ != address(0) && ops_ != address(0) && ledger_ != address(0));
        governance = gov;
        treasury = treasury_;
        ops = ops_;
        ledger = ledger_;
    }
    receive() external payable {}

    function feeCustodyMode() external pure returns (uint8) {
        return 1;
    }

    function enablePool(bytes32 poolId) external {
        V3FeeLedger.Pool memory p = V3FeeLedger(payable(ledger)).poolInfo(poolId);
        require(p.quote == address(0) && p.beneficiaries[5] == address(this), "Wrong pool");
        V3FeeLedger(payable(ledger)).enableControlledClaim(poolId, 5);
        enabledPools[poolId] = true;
    }

    function collectLedger(bytes32 poolId, uint256 amount) external nonReentrant {
        V3FeeLedger.Pool memory p = V3FeeLedger(payable(ledger)).poolInfo(poolId);
        require(
            p.quote == address(0) && p.beneficiaries[5] == address(this)
                && V3FeeLedger(payable(ledger)).controlledClaim(poolId, 5) && amount != 0,
            "Unknown pool"
        );
        uint256 beforeBalance = address(this).balance;
        require(V3FeeLedger(payable(ledger)).claim(poolId, 5, amount), "Ledger payment failed");
        require(address(this).balance == beforeBalance + amount, "Inexact revenue");
        ledgerRevenue += amount;
        emit RevenueReceived(poolId, 2, amount);
    }

    function configureSources(address converter, address desk_) external {
        require(
            msg.sender == governance && stockConverter == address(0) && converter != address(0) && desk_ != address(0),
            "Already wired"
        );
        stockConverter = converter;
        desk = desk_;
    }

    function fundFromConverter(bytes32 id) external payable {
        require(msg.sender == stockConverter, "Converter only");
        _revenue(id, 0);
        stockConversionRevenue += msg.value;
    }

    function receiveDeskProtocol(bytes32 id) external payable {
        require(msg.sender == desk, "Desk only");
        _revenue(id, 1);
        deskRevenue += msg.value;
    }

    function _revenue(bytes32 id, uint8 source) internal {
        bytes32 receipt = keccak256(abi.encode(msg.sender, id));
        require(id != 0 && msg.value != 0 && !creditedReceipt[receipt], "Invalid receipt");
        creditedReceipt[receipt] = true;
        emit RevenueReceived(id, source, msg.value);
    }

    function schedule(bytes32 action) external {
        require(msg.sender == governance && action != 0, "Governance only");
        scheduledAt[action] = block.timestamp + 48 hours;
        emit Scheduled(action, scheduledAt[action]);
    }

    function _consume() internal {
        bytes32 action = keccak256(msg.data);
        uint256 at = scheduledAt[action];
        require(msg.sender == governance && at != 0 && block.timestamp >= at, "Timelocked");
        delete scheduledAt[action];
    }

    function setCommitments(uint256 debt, uint256 budget, uint256 buffer) external {
        _consume();
        require(buffer >= 100 ether, "Buffer floor");
        require(debt >= liabilities && budget >= executionBudget, "Cannot erase obligations");
        require(debt + budget + buffer + potCash <= address(this).balance, "Unfunded commitments");
        liabilities = debt;
        executionBudget = budget;
        operatingBuffer = buffer;
        emit CommitmentsSet(debt, budget, buffer);
    }

    function availableSurplus() public view returns (uint256) {
        uint256 locked = liabilities + executionBudget + operatingBuffer + potCash;
        return address(this).balance > locked ? address(this).balance - locked : 0;
    }

    function withdrawSurplus(address to, uint256 amount) external nonReentrant {
        _consume();
        require(to == treasury && amount <= availableSurplus(), "Reserved funds");
        (bool ok,) = payable(treasury).call{value: amount}("");
        require(ok, "Payment failed");
        emit SurplusWithdrawn(amount);
    }

    function allocateOps(uint256 amount, uint256 version) external nonReentrant {
        _consume();
        require(amount != 0 && version != 0 && amount <= executionBudget, "Budget exceeded");
        require(address(this).balance >= liabilities + executionBudget + operatingBuffer + potCash, "Reserved funds");
        executionBudget -= amount;
        IProtocolOps(ops).receiveBudget{value: amount}(version);
        emit OpsAllocated(version, amount);
    }

    /// @notice Separate sponsored capital, never the fee-time assigned six reward buckets.
    function registerPot(bytes32 id, address source, bytes32 destinationId, address destination) external {
        _consume();
        require(
            id != 0 && source != address(0) && destinationId != 0 && destination.code.length != 0
                && destination != address(this) && pots[id].source == address(0),
            "Invalid pot"
        );
        pots[id] = Pot(source, destinationId, destination, 0, 0, 0, 0);
        emit PotRegistered(id, destinationId, source, destination);
    }

    function fundPot(bytes32 id) external payable {
        Pot storage p = pots[id];
        require(msg.sender == p.source && msg.value != 0, "Pot source only");
        p.cash += msg.value;
        potCash += msg.value;
    }

    /// @dev The fixed source may only increase protected obligations; governance cannot erase them.
    function commitPot(bytes32 id, uint256 assigned, uint256 inFlight, uint256 reserved) external {
        Pot storage p = pots[id];
        require(msg.sender == p.source, "Pot source only");
        require(
            assigned >= p.committed && inFlight >= p.inFlight && reserved >= p.reserved
                && assigned + inFlight + reserved <= p.cash,
            "Invalid commitments"
        );
        p.committed = assigned;
        p.inFlight = inFlight;
        p.reserved = reserved;
    }

    function routeUnallocatedPot(bytes32 id, uint256 amount, bytes32 destinationId) external nonReentrant {
        _consume();
        Pot storage p = pots[id];
        require(
            destinationId == p.destinationId && amount != 0 && amount <= p.cash - p.committed - p.inFlight - p.reserved,
            "Assigned funds"
        );
        p.cash -= amount;
        potCash -= amount;
        (bool ok,) = payable(p.destination).call{value: amount}("");
        require(ok, "Pot transfer failed");
        emit PotRouted(id, destinationId, amount);
    }
}

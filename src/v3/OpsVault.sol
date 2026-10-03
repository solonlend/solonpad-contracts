// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SignatureChecker
} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

interface IDeskExpenseView {
    function nextTokenId() external view returns (uint256);
    function surchargeUSDC18() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IOrderFeeTarget {
    function depositFees(bytes32 orderId) external payable;
}

interface IShortfallTarget {
    function subsidizeShortfall(bytes32 orderId) external payable;
}

/// @notice Verified expense receipts spend only separately funded operation budgets.
contract OpsVault is ReentrancyGuard {
    struct Expense {
        bytes32 orderId;
        uint8 kind;
        bytes32 receipt;
        uint256 amount;
        uint256 budgetVersion;
        uint256 deadline;
    }
    address public immutable governance;
    address public immutable protocol;
    address public immutable verifier;
    mapping(uint8 => address) public targets;
    mapping(uint8 => bool) public typedFeeTarget;
    mapping(uint8 => bool) public shortfallTarget;
    mapping(uint256 => uint256) public budget;
    mapping(bytes32 => bool) public paidReceipt;
    mapping(bytes32 => bool) public tippedOrder;
    address public desk;
    address public protocolDeskVault;
    uint256 public constant DESK_BUDGET_VERSION = 7;
    uint256 public totalBudget;
    mapping(bytes32 => uint256) public unbudgetedSchedule;
    event UnbudgetedScheduled(uint256 indexed version, uint256 amount, uint256 executableAt);
    event BudgetFunded(uint256 indexed version, uint256 amount);
    event ExpensePaid(bytes32 indexed orderId, bytes32 indexed receipt, uint8 kind, uint256 amount, uint256 version);

    constructor(address gov, address protocol_, address verifier_) {
        require(gov != address(0) && protocol_ != address(0) && verifier_ != address(0));
        governance = gov;
        protocol = protocol_;
        verifier = verifier_;
    }

    /// @dev One-time target wiring. Changing an expense route requires a new deployment/version.
    function configureTarget(uint8 kind, address target) external {
        require(
            msg.sender == governance && kind < 7 && target != address(0) && targets[kind] == address(0),
            "Invalid target"
        );
        targets[kind] = target;
    }

    function configureFeeTarget(uint8 kind, address target) external {
        require(
            msg.sender == governance && kind > 0 && kind < 7 && target.code.length != 0 && targets[kind] == address(0),
            "Invalid fee target"
        );
        targets[kind] = target;
        typedFeeTarget[kind] = true;
    }

    function configureSubsidyTarget(uint8 kind, address target) external {
        require(
            msg.sender == governance && kind == 6 && target.code.length != 0 && targets[kind] == address(0),
            "Invalid subsidy target"
        );
        targets[kind] = target;
        shortfallTarget[kind] = true;
    }

    function configureDesk(address desk_, address vault_) external {
        require(
            msg.sender == governance && desk == address(0) && desk_.code.length != 0 && vault_ != address(0),
            "Already wired"
        );
        desk = desk_;
        protocolDeskVault = vault_;
    }
    receive() external payable {}

    function receiveBudget(uint256 version) external payable {
        require(msg.sender == protocol && version != 0 && msg.value != 0, "Protocol only");
        budget[version] += msg.value;
        totalBudget += msg.value;
        emit BudgetFunded(version, msg.value);
    }

    /// @notice Independent operating sponsorship is actual new cash, never a protocol fee haircut.
    function fundBudget(uint256 version) external payable {
        require(version != 0 && msg.value != 0, "Empty funding");
        budget[version] += msg.value;
        totalBudget += msg.value;
        emit BudgetFunded(version, msg.value);
    }

    /// @notice Legacy adapter refunds arrive without a version. Governance may only re-budget
    /// the actual excess cash after delay; no withdrawal or arbitrary call is introduced.
    function scheduleUnbudgeted(uint256 version, uint256 amount) external {
        require(msg.sender == governance && version != 0 && amount != 0, "Governance only");
        unbudgetedSchedule[keccak256(abi.encode(version, amount))] = block.timestamp + 48 hours;
        emit UnbudgetedScheduled(version, amount, block.timestamp + 48 hours);
    }

    function allocateUnbudgeted(uint256 version, uint256 amount) external {
        bytes32 key = keccak256(abi.encode(version, amount));
        uint256 at = unbudgetedSchedule[key];
        require(at != 0 && block.timestamp >= at && amount <= address(this).balance - totalBudget, "Unbacked budget");
        delete unbudgetedSchedule[key];
        budget[version] += amount;
        totalBudget += amount;
        emit BudgetFunded(version, amount);
    }

    function expenseDigest(Expense memory e) public view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SolonOps"),
                keccak256("3"),
                block.chainid,
                address(this)
            )
        );
        bytes32 hash = keccak256(
            abi.encode(
                keccak256(
                    "Expense(bytes32 orderId,uint8 kind,bytes32 receipt,uint256 amount,uint256 budgetVersion,uint256 deadline,address target)"
                ),
                e.orderId,
                e.kind,
                e.receipt,
                e.amount,
                e.budgetVersion,
                e.deadline,
                targets[e.kind]
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, hash));
    }

    function payExpense(Expense calldata e, bytes calldata signature) external nonReentrant {
        require(
            e.budgetVersion != DESK_BUDGET_VERSION && e.orderId != 0 && e.receipt != 0 && !paidReceipt[e.receipt]
                && e.amount != 0 && e.amount <= budget[e.budgetVersion] && block.timestamp <= e.deadline
                && targets[e.kind] != address(0),
            "Invalid expense"
        );
        require(SignatureChecker.isValidSignatureNow(verifier, expenseDigest(e), signature), "Unverified receipt");
        if (e.kind == 0) {
            require(!tippedOrder[e.orderId], "Tip already paid");
            tippedOrder[e.orderId] = true;
        }
        paidReceipt[e.receipt] = true;
        budget[e.budgetVersion] -= e.amount;
        totalBudget -= e.amount;
        if (shortfallTarget[e.kind]) {
            IShortfallTarget(targets[e.kind]).subsidizeShortfall{value: e.amount}(e.orderId);
        } else if (typedFeeTarget[e.kind]) {
            IOrderFeeTarget(targets[e.kind]).depositFees{value: e.amount}(e.orderId);
        } else {
            (bool ok,) = payable(targets[e.kind]).call{value: e.amount}("");
            require(ok, "Expense failed");
        }
        emit ExpensePaid(e.orderId, e.receipt, e.kind, e.amount, e.budgetVersion);
    }

    /// @dev Fixed protocol vault receives this only inside its atomic mint operation.
    /// A reverted mint rolls back budget and receipt consumption as well.
    function payDeskSurcharge(bytes32 lotId, uint256 firstTokenId, uint256 cards, address desk_)
        external
        nonReentrant
        returns (uint256 amount)
    {
        require(
            msg.sender == protocolDeskVault && desk_ == desk && lotId != 0 && cards != 0 && cards <= 20,
            "Invalid desk expense"
        );
        require(firstTokenId == IDeskExpenseView(desk).nextTokenId(), "Wrong token range");
        bytes32 receipt = keccak256(abi.encode("DESK_SURCHARGE", lotId, firstTokenId, cards, desk));
        require(!paidReceipt[receipt], "Receipt used");
        amount = IDeskExpenseView(desk).surchargeUSDC18() * cards;
        require(amount != 0 && budget[DESK_BUDGET_VERSION] >= amount, "Ops shortfall");
        paidReceipt[receipt] = true;
        budget[DESK_BUDGET_VERSION] -= amount;
        totalBudget -= amount;
        (bool ok,) = payable(protocolDeskVault).call{value: amount}("");
        require(ok, "Desk funding failed");
        emit ExpensePaid(lotId, receipt, 7, amount, DESK_BUDGET_VERSION);
    }

    /// @notice Factory readiness uses paid NFT supply and actual non-Desk operating budget.
    function paidDeskCount() external view returns (uint256) {
        return desk == address(0) ? 0 : IDeskExpenseView(desk).totalSupply();
    }

    function opsAvailable() external view returns (uint256) {
        return totalBudget - budget[DESK_BUDGET_VERSION];
    }
}

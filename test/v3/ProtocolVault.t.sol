// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ProtocolVault} from "../../src/v3/ProtocolVault.sol";
import {OpsVault} from "../../src/v3/OpsVault.sol";

contract ProtocolVaultTest is Test {
    ProtocolVault vault;
    address treasury = address(0x1234);

    function setUp() public {
        vm.etch(address(0x5678), address(new OpsBudgetFixture()).code);
        vault = new ProtocolVault(address(this), treasury, address(0x5678), address(0x9876));
        vm.deal(address(vault), 500 ether);
    }

    function approveAction(bytes memory data) internal {
        vault.schedule(keccak256(data));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
    }

    function testSurplusDeductsDebtBudgetAndOperatingBuffer() public {
        bytes memory data = abi.encodeCall(vault.setCommitments, (50 ether, 60 ether, 140 ether));
        approveAction(data);
        vault.setCommitments(50 ether, 60 ether, 140 ether);
        assertEq(vault.availableSurplus(), 250 ether);
        data = abi.encodeCall(vault.withdrawSurplus, (treasury, 250 ether));
        approveAction(data);
        vault.withdrawSurplus(treasury, 250 ether);
        assertEq(treasury.balance, 250 ether);
        assertEq(address(vault).balance, 250 ether);
    }

    function testGovernanceCannotWithdrawEarlyOrToArbitraryRecipient() public {
        vm.expectRevert();
        vault.withdrawSurplus(treasury, 1 ether);
        approveAction(abi.encodeCall(vault.withdrawSurplus, (address(99), 1 ether)));
        vm.expectRevert();
        vault.withdrawSurplus(address(99), 1 ether);
    }

    function testOpsAllocationConsumesReservedBudgetWithoutTouchingDebt() public {
        approveAction(abi.encodeCall(vault.setCommitments, (50 ether, 60 ether, 140 ether)));
        vault.setCommitments(50 ether, 60 ether, 140 ether);
        bytes memory callData = abi.encodeWithSignature("allocateOps(uint256,uint256)", 60 ether, 1);
        approveAction(callData);
        (bool ok,) = address(vault).call(callData);
        assertTrue(ok);
        assertEq(vault.executionBudget(), 0);
        assertEq(vault.liabilities(), 50 ether);
        assertEq(address(0x5678).balance, 60 ether);
    }

    function testOnlyWiredConverterCanCreditUniqueRevenueReceipt() public {
        (bool wired,) = address(vault)
            .call(abi.encodeWithSignature("configureSources(address,address)", address(this), address(77)));
        assertTrue(wired);
        vm.deal(address(this), 10 ether);
        bytes memory data = abi.encodeWithSignature("fundFromConverter(bytes32)", keccak256("fee lot"));
        (bool ok,) = address(vault).call{value: 10 ether}(data);
        assertTrue(ok);
        assertEq(address(vault).balance, 510 ether);
        (ok,) = address(vault).call(data);
        assertFalse(ok);
    }

    function testUnallocatedPotCannotExposeCommittedRightsAsProfit() public {
        address destination = address(new OpsBudgetFixture());
        bytes32 source = keccak256("sponsored-pot");
        bytes32 destinationId = keccak256("published-rewards");
        bytes memory data = abi.encodeWithSignature(
            "registerPot(bytes32,address,bytes32,address)", source, address(this), destinationId, destination
        );
        approveAction(data);
        (bool ok,) = address(vault).call(data);
        assertTrue(ok);
        vm.deal(address(this), 100 ether);
        (ok,) = address(vault).call{value: 100 ether}(abi.encodeWithSignature("fundPot(bytes32)", source));
        assertTrue(ok);
        (ok,) = address(vault)
            .call(
                abi.encodeWithSignature(
                    "commitPot(bytes32,uint256,uint256,uint256)", source, 40 ether, 20 ether, 10 ether
                )
            );
        assertTrue(ok);
        assertEq(vault.availableSurplus(), 400 ether);
        data = abi.encodeWithSignature("routeUnallocatedPot(bytes32,uint256,bytes32)", source, 31 ether, destinationId);
        approveAction(data);
        (ok,) = address(vault).call(data);
        assertFalse(ok);
        data = abi.encodeWithSignature("routeUnallocatedPot(bytes32,uint256,bytes32)", source, 30 ether, destinationId);
        approveAction(data);
        (ok,) = address(vault).call(data);
        assertTrue(ok);
        assertEq(destination.balance, 30 ether);
        assertEq(vault.availableSurplus(), 400 ether);
    }

    function testGovernanceCannotEraseUnpaidCommitmentsToWithdrawThem() public {
        approveAction(abi.encodeCall(vault.setCommitments, (50 ether, 60 ether, 100 ether)));
        vault.setCommitments(50 ether, 60 ether, 100 ether);
        approveAction(abi.encodeCall(vault.setCommitments, (0, 0, 100 ether)));
        vm.expectRevert();
        vault.setCommitments(0, 0, 100 ether);
    }
}

contract OpsBudgetFixture {
    function receiveBudget(uint256) external payable {}
    receive() external payable {}
}

contract OpsVaultTest is Test {
    OpsVault ops;
    uint256 key = 992;
    address recipient = address(0x8888);

    function setUp() public {
        ops = new OpsVault(address(this), address(this), vm.addr(key));
        ops.configureTarget(0, recipient);
        vm.deal(address(this), 20 ether);
        ops.receiveBudget{value: 10 ether}(1);
    }

    function signedExpense(bytes32 receipt, uint256 amount)
        internal
        view
        returns (OpsVault.Expense memory e, bytes memory sig)
    {
        e = OpsVault.Expense(keccak256("settled-order"), 0, receipt, amount, 1, vm.getBlockTimestamp() + 60);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ops.expenseDigest(e));
        sig = abi.encodePacked(r, s, v);
    }

    function testVerifiedExpensePaysOnlyFixedTargetAndConsumesReceipt() public {
        bytes32 receipt = keccak256("receipt");
        (OpsVault.Expense memory e, bytes memory sig) = signedExpense(receipt, 3 ether);
        ops.payExpense(e, sig);
        assertEq(recipient.balance, 3 ether);
        assertTrue(ops.paidReceipt(receipt));
        vm.expectRevert();
        ops.payExpense(e, sig);
    }

    function testNoSelfReportedOrOverBudgetExpenses() public {
        (OpsVault.Expense memory e, bytes memory sig) = signedExpense(keccak256("r"), 11 ether);
        vm.expectRevert();
        ops.payExpense(e, sig);
        (e, sig) = signedExpense(keccak256("r"), 1 ether);
        e.amount = 2 ether;
        vm.expectRevert();
        ops.payExpense(e, sig);
        assertEq(address(ops).balance, 10 ether);
    }

    function testDeskSurchargeUsesDedicatedBudgetAndBindsNextToken() public {
        DeskOpsFixture desk = new DeskOpsFixture();
        (bool wired,) =
            address(ops).call(abi.encodeWithSignature("configureDesk(address,address)", address(desk), address(this)));
        assertTrue(wired);
        ops.receiveBudget{value: 5 ether}(7);
        bytes memory data = abi.encodeWithSignature(
            "payDeskSurcharge(bytes32,uint256,uint256,address)", keccak256("buyback lot"), 1, 2, address(desk)
        );
        uint256 beforeBalance = address(this).balance;
        (bool ok,) = address(ops).call(data);
        assertTrue(ok);
        assertEq(address(this).balance, beforeBalance + 2 ether);
        (ok,) = address(ops).call(data);
        assertFalse(ok);
    }

    function testExplicitServiceFeeFundsTypedOrderWithoutTakingPrincipal() public {
        TypedFeeFixture adapter = new TypedFeeFixture();
        (bool ok,) =
            address(ops).call(abi.encodeWithSignature("configureFeeTarget(uint8,address)", 1, address(adapter)));
        assertTrue(ok);
        OpsVault.Expense memory e = OpsVault.Expense(
            keccak256("new order"), 1, keccak256("fee quote"), 1 ether, 1, vm.getBlockTimestamp() + 60
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ops.expenseDigest(e));
        ops.payExpense(e, abi.encodePacked(r, s, v));
        assertEq(adapter.feeBalance(e.orderId), 1 ether);
    }

    function testLaunchReadinessCountsPaidCardsAndUsableOperationsBudget() public {
        (bool ok, bytes memory result) = address(ops).staticcall(abi.encodeWithSignature("opsAvailable()"));
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), 10 ether);
        DeskOpsFixture desk = new DeskOpsFixture();
        ops.configureDesk(address(desk), address(this));
        ops.receiveBudget{value: 5 ether}(7);
        (ok, result) = address(ops).staticcall(abi.encodeWithSignature("paidDeskCount()"));
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), 1);
        (ok, result) = address(ops).staticcall(abi.encodeWithSignature("opsAvailable()"));
        assertTrue(ok);
        assertEq(abi.decode(result, (uint256)), 10 ether);
    }

    function testVerifiedShortfallSubsidyUsesTypedFixedConverter() public {
        TypedSubsidyFixture converter = new TypedSubsidyFixture();
        (bool ok,) =
            address(ops).call(abi.encodeWithSignature("configureSubsidyTarget(uint8,address)", 6, address(converter)));
        assertTrue(ok);
        OpsVault.Expense memory e = OpsVault.Expense(
            keccak256("short order"), 6, keccak256("real shortfall receipt"), 2 ether, 1, vm.getBlockTimestamp() + 60
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, ops.expenseDigest(e));
        ops.payExpense(e, abi.encodePacked(r, s, v));
        assertEq(converter.subsidy(e.orderId), 2 ether);
    }

    function testSameSuccessfulOrderCannotPayTipTwiceUnderDifferentReceipts() public {
        (OpsVault.Expense memory e, bytes memory sig) = signedExpense(keccak256("tip receipt1"), 1 ether);
        ops.payExpense(e, sig);
        (e, sig) = signedExpense(keccak256("tip receipt2"), 1 ether);
        vm.expectRevert();
        ops.payExpense(e, sig);
    }

    function testIndependentOpsFundingAndReturnedCashRequireActualBudgetBacking() public {
        (bool ok,) = address(ops).call{value: 2 ether}(abi.encodeWithSignature("fundBudget(uint256)", 1));
        assertTrue(ok);
        assertEq(ops.budget(1), 12 ether);
        (ok,) = address(ops).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(ops.budget(1), 12 ether);
        bytes memory data = abi.encodeWithSignature("scheduleUnbudgeted(uint256,uint256)", 1, 1 ether);
        (ok,) = address(ops).call(data);
        assertTrue(ok);
        data = abi.encodeWithSignature("allocateUnbudgeted(uint256,uint256)", 1, 1 ether);
        (ok,) = address(ops).call(data);
        assertFalse(ok);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        (ok,) = address(ops).call(data);
        assertTrue(ok);
        assertEq(ops.budget(1), 13 ether);
        (ok,) = address(ops).call(data);
        assertFalse(ok);
    }
    receive() external payable {}
}

contract DeskOpsFixture {
    function nextTokenId() external pure returns (uint256) {
        return 1;
    }

    function surchargeUSDC18() external pure returns (uint256) {
        return 1 ether;
    }

    function totalSupply() external pure returns (uint256) {
        return 1;
    }
}

contract TypedFeeFixture {
    mapping(bytes32 => uint256) public feeBalance;

    function depositFees(bytes32 id) external payable {
        feeBalance[id] += msg.value;
    }
}

contract TypedSubsidyFixture {
    mapping(bytes32 => uint256) public subsidy;

    function subsidizeShortfall(bytes32 id) external payable {
        subsidy[id] += msg.value;
    }
}

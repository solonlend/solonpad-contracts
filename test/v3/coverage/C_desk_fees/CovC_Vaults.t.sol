// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ProtocolVault} from "../../../../src/v3/ProtocolVault.sol";
import {OpsVault} from "../../../../src/v3/OpsVault.sol";
import {V3FeeLedger} from "../../../../src/v3/V3FeeLedger.sol";
import {CovCMockLedger, CovCSwitchReceiver, CovCNoReceive, CovCToken} from "./CovCMocks.sol";
import {CovCFeeReceiver} from "./CovC_Buyback.t.sol";

contract CovCOpsBudget {
    uint256 public got;

    function receiveBudget(uint256) external payable {
        got += msg.value;
    }
}

contract CovCProtocolVaultTest is Test {
    ProtocolVault vault;
    CovCSwitchReceiver treasury;
    CovCOpsBudget ops;
    CovCMockLedger mledger;
    address converter = address(0xC0);
    address desk = address(0xDE);

    function setUp() public {
        treasury = new CovCSwitchReceiver();
        ops = new CovCOpsBudget();
        mledger = new CovCMockLedger();
        vault = new ProtocolVault(address(this), address(treasury), address(ops), address(mledger));
        vault.configureSources(converter, desk);
        vm.deal(address(mledger), 1000 ether);
        vm.deal(converter, 1000 ether);
        vm.deal(desk, 1000 ether);
    }

    function _approve(bytes memory data) internal {
        vault.schedule(keccak256(data));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
    }

    function _mockPool(bytes32 pool) internal {
        address[6] memory b;
        b[5] = address(vault);
        mledger.setPool(pool, address(0), 0, address(1), b);
        mledger.setControlled(pool, 5, true);
    }

    /// L62 both arms against the real ledger.
    function test_EnablePoolRealLedger() public {
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        ProtocolVault pv = new ProtocolVault(address(this), address(treasury), address(ops), address(ledger));
        address r = address(new CovCFeeReceiver());
        bytes32 pool = keccak256("native");
        vm.expectRevert(bytes("Wrong pool"));
        pv.enablePool(pool);
        CovCToken quote = new CovCToken();
        bytes32 stockPool = keccak256("stock");
        ledger.registerPool(stockPool, address(quote), 1, address(this), [r, r, r, r, r, r]);
        vm.expectRevert(bytes("Wrong pool"));
        pv.enablePool(stockPool);
        ledger.registerPool(pool, address(0), 0, address(this), [r, r, r, r, r, address(pv)]);
        pv.enablePool(pool);
        assertTrue(pv.enabledPools(pool));
        assertTrue(ledger.controlledClaim(pool, 5));
    }

    /// L69 false arm.
    function test_CollectLedgerUnknownPool() public {
        bytes32 pool = keccak256("p");
        _mockPool(pool);
        vm.expectRevert(bytes("Unknown pool"));
        vault.collectLedger(pool, 0);
        mledger.setControlled(pool, 5, false);
        vm.expectRevert(bytes("Unknown pool"));
        vault.collectLedger(pool, 1 ether);
        address[6] memory b;
        b[5] = address(0xBEEF);
        mledger.setPool(pool, address(0), 0, address(1), b);
        mledger.setControlled(pool, 5, true);
        vm.expectRevert(bytes("Unknown pool"));
        vault.collectLedger(pool, 1 ether);
        b[5] = address(vault);
        mledger.setPool(pool, address(0x1234), 1, address(1), b);
        vm.expectRevert(bytes("Unknown pool"));
        vault.collectLedger(pool, 1 ether);
    }

    /// L75 false arm; L76 both arms.
    function test_CollectLedgerPaymentAndExactness() public {
        bytes32 pool = keccak256("p");
        _mockPool(pool);
        mledger.setClaimBehaviour(false, 0, 0);
        vm.expectRevert(bytes("Ledger payment failed"));
        vault.collectLedger(pool, 1 ether);
        mledger.setClaimBehaviour(true, 1, 0);
        vm.expectRevert(bytes("Inexact revenue"));
        vault.collectLedger(pool, 1 ether);
        mledger.setClaimBehaviour(true, 0, 0);
        vault.collectLedger(pool, 1 ether);
        assertEq(vault.ledgerRevenue(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    /// L91 both arms.
    function test_FundFromConverterOnlyConverter() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("Converter only"));
        vault.fundFromConverter{value: 1 ether}(bytes32(uint256(1)));
        vm.prank(converter);
        vault.fundFromConverter{value: 2 ether}(bytes32(uint256(1)));
        assertEq(vault.stockConversionRevenue(), 2 ether);
        assertTrue(vault.creditedReceipt(keccak256(abi.encode(converter, bytes32(uint256(1))))));
        vm.prank(converter);
        vm.expectRevert(bytes("Invalid receipt"));
        vault.fundFromConverter{value: 2 ether}(bytes32(uint256(1)));
    }

    /// L97 both arms.
    function test_ReceiveDeskProtocolOnlyDesk() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("Desk only"));
        vault.receiveDeskProtocol{value: 1 ether}(bytes32(uint256(1)));
        vm.prank(desk);
        vault.receiveDeskProtocol{value: 3 ether}(bytes32(uint256(1)));
        assertEq(vault.deskRevenue(), 3 ether);
        assertEq(address(vault).balance, 3 ether);
        vm.prank(desk);
        vm.expectRevert(bytes("Invalid receipt"));
        vault.receiveDeskProtocol{value: 0}(bytes32(uint256(2)));
    }

    /// L124 both arms (buffer floor) and L126 both arms (funding check), each with exact boundary values.
    function test_SetCommitmentsBufferFloorAndFunding() public {
        vm.deal(address(vault), 300 ether);
        bytes memory low = abi.encodeCall(vault.setCommitments, (0, 0, 100 ether - 1));
        _approve(low);
        vm.expectRevert(bytes("Buffer floor"));
        vault.setCommitments(0, 0, 100 ether - 1);
        bytes memory over = abi.encodeCall(vault.setCommitments, (100 ether, 100 ether, 100 ether + 1));
        _approve(over);
        vm.expectRevert(bytes("Unfunded commitments"));
        vault.setCommitments(100 ether, 100 ether, 100 ether + 1);
        bytes memory exact = abi.encodeCall(vault.setCommitments, (100 ether, 100 ether, 100 ether));
        _approve(exact);
        vault.setCommitments(100 ether, 100 ether, 100 ether);
        assertEq(vault.availableSurplus(), 0);
        assertEq(vault.operatingBuffer(), 100 ether);
        // a consumed schedule cannot be replayed
        vm.expectRevert(bytes("Timelocked"));
        vault.setCommitments(100 ether, 100 ether, 100 ether);
    }

    /// L142 both arms: treasury refusing ETH reverts the whole withdrawal; accepting pays exactly.
    function test_WithdrawSurplusPaymentFailure() public {
        vm.deal(address(vault), 150 ether);
        treasury.setRejects(true);
        bytes memory data = abi.encodeCall(vault.withdrawSurplus, (address(treasury), 50 ether));
        _approve(data);
        vm.expectRevert(bytes("Payment failed"));
        vault.withdrawSurplus(address(treasury), 50 ether);
        assertEq(address(vault).balance, 150 ether);
        treasury.setRejects(false);
        vault.withdrawSurplus(address(treasury), 50 ether);
        assertEq(address(treasury).balance, 50 ether);
        assertEq(address(vault).balance, 100 ether);
        // buffer-protected: nothing more
        _approve(abi.encodeCall(vault.withdrawSurplus, (address(treasury), 1)));
        vm.expectRevert(bytes("Reserved funds"));
        vault.withdrawSurplus(address(treasury), 1);
    }

    /// L148/L149: budget bound arms, and the reserved-funds guard on its pass arm.
    function test_AllocateOpsBudgetBounds() public {
        vm.deal(address(vault), 200 ether);
        _approve(abi.encodeCall(vault.setCommitments, (0, 50 ether, 100 ether)));
        vault.setCommitments(0, 50 ether, 100 ether);
        bytes memory tooMuch = abi.encodeCall(vault.allocateOps, (50 ether + 1, 1));
        _approve(tooMuch);
        vm.expectRevert(bytes("Budget exceeded"));
        vault.allocateOps(50 ether + 1, 1);
        bytes memory zeroVersion = abi.encodeCall(vault.allocateOps, (1 ether, 0));
        _approve(zeroVersion);
        vm.expectRevert(bytes("Budget exceeded"));
        vault.allocateOps(1 ether, 0);
        bytes memory ok = abi.encodeCall(vault.allocateOps, (50 ether, 1));
        _approve(ok);
        vault.allocateOps(50 ether, 1);
        assertEq(ops.got(), 50 ether);
        assertEq(vault.executionBudget(), 0);
        assertEq(address(vault).balance, 150 ether);
    }

    function _pot(bytes32 id, address dest) internal {
        bytes memory reg = abi.encodeCall(vault.registerPot, (id, address(this), keccak256("dst"), dest));
        _approve(reg);
        vault.registerPot(id, address(this), keccak256("dst"), dest);
    }

    /// L177 both arms: only the pot source may raise commitments; unregistered pots have no source.
    function test_CommitPotSourceOnly() public {
        CovCSwitchReceiver dest = new CovCSwitchReceiver();
        bytes32 id = keccak256("pot");
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("Pot source only"));
        vault.commitPot(id, 0, 0, 0);
        _pot(id, address(dest));
        vm.deal(address(this), 10 ether);
        vault.fundPot{value: 10 ether}(id);
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("Pot source only"));
        vault.commitPot(id, 1, 1, 1);
        vault.commitPot(id, 1 ether, 2 ether, 3 ether);
        (,,,, uint256 committed, uint256 inFlight, uint256 reserved) = vault.pots(id);
        assertEq(committed, 1 ether);
        assertEq(inFlight, 2 ether);
        assertEq(reserved, 3 ether);
        // cannot lower nor exceed cash
        vm.expectRevert(bytes("Invalid commitments"));
        vault.commitPot(id, 0, 2 ether, 3 ether);
        vm.expectRevert(bytes("Invalid commitments"));
        vault.commitPot(id, 5 ether + 1, 2 ether, 3 ether);
    }

    /// L198 both arms: a destination rejecting ETH reverts routing and keeps pot accounting intact.
    function test_RouteUnallocatedPotTransferFailure() public {
        CovCSwitchReceiver dest = new CovCSwitchReceiver();
        bytes32 id = keccak256("pot");
        _pot(id, address(dest));
        vm.deal(address(this), 10 ether);
        vault.fundPot{value: 10 ether}(id);
        dest.setRejects(true);
        bytes memory route = abi.encodeCall(vault.routeUnallocatedPot, (id, 4 ether, keccak256("dst")));
        _approve(route);
        vm.expectRevert(bytes("Pot transfer failed"));
        vault.routeUnallocatedPot(id, 4 ether, keccak256("dst"));
        assertEq(vault.potCash(), 10 ether);
        dest.setRejects(false);
        vault.routeUnallocatedPot(id, 4 ether, keccak256("dst"));
        assertEq(address(dest).balance, 4 ether);
        assertEq(vault.potCash(), 6 ether);
        (,,, uint256 cash,,,) = vault.pots(id);
        assertEq(cash, 6 ether);
    }
}

contract CovCDeskViewMock {
    uint256 public nextTokenId = 1;
    uint256 public surchargeUSDC18 = 1 ether;

    function setNext(uint256 n) external {
        nextTokenId = n;
    }

    function totalSupply() external view returns (uint256) {
        return nextTokenId - 1;
    }
}

contract CovCOpsVaultTest is Test {
    OpsVault ops;
    uint256 key = 992;
    CovCSwitchReceiver recipient;
    CovCDeskViewMock desk;
    CovCSwitchReceiver pdv;

    function setUp() public {
        ops = new OpsVault(address(this), address(this), vm.addr(key));
        recipient = new CovCSwitchReceiver();
        ops.configureTarget(0, address(recipient));
        ops.configureTarget(1, address(recipient));
        desk = new CovCDeskViewMock();
        pdv = new CovCSwitchReceiver();
        ops.configureDesk(address(desk), address(pdv));
        vm.deal(address(this), 100 ether);
        ops.receiveBudget{value: 10 ether}(1);
        ops.receiveBudget{value: 10 ether}(7);
    }

    function _exp(bytes32 order, uint8 kind, bytes32 receipt, uint256 amount, uint256 signer)
        internal
        view
        returns (OpsVault.Expense memory e, bytes memory sig)
    {
        e = OpsVault.Expense(order, kind, receipt, amount, 1, vm.getBlockTimestamp() + 60);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, ops.expenseDigest(e));
        sig = abi.encodePacked(r, s, v);
    }

    /// L161 both arms.
    function test_PayExpenseRequiresVerifierSignature() public {
        (OpsVault.Expense memory e, bytes memory sig) = _exp(keccak256("o"), 1, keccak256("r"), 1 ether, key + 1);
        vm.expectRevert(bytes("Unverified receipt"));
        ops.payExpense(e, sig);
        (e, sig) = _exp(keccak256("o"), 1, keccak256("r"), 1 ether, key);
        ops.payExpense(e, sig);
        assertEq(address(recipient).balance, 1 ether);
        assertEq(ops.budget(1), 9 ether);
        assertEq(ops.totalBudget(), 19 ether);
    }

    /// L163 both arms: kind-0 tips are one per order; other kinds are not tip-limited.
    function test_TipOncePerOrder() public {
        (OpsVault.Expense memory e, bytes memory sig) = _exp(keccak256("o"), 0, keccak256("r1"), 1 ether, key);
        ops.payExpense(e, sig);
        assertTrue(ops.tippedOrder(keccak256("o")));
        (e, sig) = _exp(keccak256("o"), 0, keccak256("r2"), 1 ether, key);
        vm.expectRevert(bytes("Tip already paid"));
        ops.payExpense(e, sig);
        (e, sig) = _exp(keccak256("o"), 1, keccak256("r3"), 1 ether, key);
        ops.payExpense(e, sig);
        assertFalse(ops.paidReceipt(keccak256("r2")));
        assertEq(address(recipient).balance, 2 ether);
    }

    /// L175 both arms: an untyped target refusing ETH reverts and consumes nothing.
    function test_UntypedTargetFailureReverts() public {
        recipient.setRejects(true);
        (OpsVault.Expense memory e, bytes memory sig) = _exp(keccak256("o"), 1, keccak256("r"), 1 ether, key);
        vm.expectRevert(bytes("Expense failed"));
        ops.payExpense(e, sig);
        assertFalse(ops.paidReceipt(keccak256("r")));
        assertEq(ops.budget(1), 10 ether);
        recipient.setRejects(false);
        ops.payExpense(e, sig);
        assertEq(address(recipient).balance, 1 ether);
    }

    /// L191 false arm: the first token id must equal the Desk's next id.
    function test_DeskSurchargeWrongTokenRange() public {
        vm.prank(address(pdv));
        vm.expectRevert(bytes("Wrong token range"));
        ops.payDeskSurcharge(keccak256("lot"), 2, 1, address(desk));
        vm.prank(address(pdv));
        assertEq(ops.payDeskSurcharge(keccak256("lot"), 1, 2, address(desk)), 2 ether);
        assertEq(address(pdv).balance, 2 ether);
        assertEq(ops.budget(7), 8 ether);
    }

    /// L193 both arms: same (lot, first, cards, desk) receipt cannot be paid twice.
    function test_DeskSurchargeReceiptUsed() public {
        vm.prank(address(pdv));
        ops.payDeskSurcharge(keccak256("lot"), 1, 1, address(desk));
        vm.prank(address(pdv));
        vm.expectRevert(bytes("Receipt used"));
        ops.payDeskSurcharge(keccak256("lot"), 1, 1, address(desk));
        assertEq(ops.budget(7), 9 ether);
    }

    /// L200 both arms: protocol desk vault refusing ETH reverts and rolls back the receipt.
    function test_DeskFundingFailed() public {
        pdv.setRejects(true);
        vm.prank(address(pdv));
        vm.expectRevert(bytes("Desk funding failed"));
        ops.payDeskSurcharge(keccak256("lot"), 1, 1, address(desk));
        assertEq(ops.budget(7), 10 ether);
        pdv.setRejects(false);
        vm.prank(address(pdv));
        ops.payDeskSurcharge(keccak256("lot"), 1, 1, address(desk));
        assertEq(address(pdv).balance, 1 ether);
    }
}

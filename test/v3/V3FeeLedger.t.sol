// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {IV3FeeReceiver} from "../../src/v3/interfaces/IV3FeeLedger.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LedgerStock is ERC20 {
    bool public frozen;
    bool public taxed;
    bool public falseReturn;

    function configure(bool freeze_, bool tax_, bool false_) external {
        frozen = freeze_;
        taxed = tax_;
        falseReturn = false_;
    }
    constructor() ERC20("Stock", "STK") {}

    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, value);
        return !falseReturn;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!frozen, "Frozen");
        super._update(from, to, value);
        if (taxed && from != address(0) && to != address(0) && value > 0) super._update(to, address(0), 1);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Test-only Arc shared-balance model; mainnet behavior requires a fork gate.
contract NativeUsdcView {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function balanceOf(address who) external view returns (uint256) {
        return who.balance / 1e12;
    }

    function transfer(address to, uint256 amount6) external returns (bool) {
        uint256 amount18 = amount6 * 1e12;
        vm.deal(msg.sender, msg.sender.balance - amount18);
        vm.deal(to, to.balance + amount18);
        return true;
    }
}

contract LedgerReceiver is IV3FeeReceiver {
    uint256 public credited;
    bool public rejects;
    bool public rejectsCredit;

    function setRejectCredit(bool value) external {
        rejectsCredit = value;
    }

    function setReject(bool value) external {
        rejects = value;
    }

    function onFeeCredit(bytes32, address, uint8, uint256 amount) external {
        require(!rejectsCredit, "Callback rejected");
        credited += amount;
    }

    receive() external payable {
        require(!rejects, "Rejected");
    }
}

contract ReentrantLedgerRecipient {
    V3FeeLedger public ledger;
    bytes32 public pool;

    function configure(V3FeeLedger ledger_, bytes32 pool_) external {
        ledger = ledger_;
        pool = pool_;
    }

    receive() external payable {
        ledger.claim(pool, 1, 1);
    }
}

contract V3FeeLedgerTest is Test {
    V3FeeLedger ledger;
    bytes32 constant POOL = keccak256("native");
    address[6] beneficiaries;

    function setUp() public {
        ledger = new V3FeeLedger(address(this), address(0));
        for (uint256 i; i < 6; ++i) {
            beneficiaries[i] = address(new LedgerReceiver());
        }
        ledger.registerPool(POOL, address(0), 0, address(this), beneficiaries);
        vm.deal(address(this), 100 ether);
    }

    function testNativeFeeSplitsSixImmutableBuckets() public {
        ledger.creditNative{value: 10000}(POOL);
        uint256[6] memory expected = [uint256(5750), 1000, 1000, 500, 1000, 750];
        for (uint256 i; i < 6; ++i) {
            assertEq(ledger.accrued(POOL, i), expected[i]);
        }
    }

    function testSplitFeesPreserveEachBucketsFraction() public {
        for (uint256 i; i < 40; ++i) {
            ledger.creditNative{value: 1}(POOL);
        }
        assertEq(ledger.accrued(POOL, 0), 23);
        assertEq(ledger.accrued(POOL, 1), 4);
        assertEq(ledger.accrued(POOL, 5), 3);
    }

    function testRegistrationAndCreditAreAuthorizedOnce() public {
        vm.expectRevert();
        ledger.registerPool(POOL, address(0), 0, address(this), beneficiaries);
        vm.prank(address(99));
        vm.expectRevert();
        ledger.registerPool(bytes32(uint256(2)), address(0), 0, address(this), beneficiaries);
        vm.prank(address(99));
        vm.expectRevert();
        ledger.creditNative(POOL);
        vm.expectRevert();
        ledger.creditNative(bytes32(uint256(3)));
    }

    function testStockCreditsOnlyNewExactTransferNotDonation() public {
        LedgerStock stock = new LedgerStock();
        bytes32 stockPool = keccak256("stock");
        ledger.registerPool(stockPool, address(stock), 1, address(this), beneficiaries);
        stock.mint(address(ledger), 50000);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        ledger.creditStock(stockPool, 10000);
        assertEq(ledger.accrued(stockPool, 0), 5750);
        assertEq(ledger.accrued(POOL, 0), 0);
        assertEq(stock.balanceOf(address(ledger)), 60000);
        vm.expectRevert();
        ledger.creditStock(stockPool, 10000);
        assertEq(ledger.accrued(stockPool, 0), 5750);
    }

    function testPullClaimFixedBeneficiaryFailureRetainsDebt() public {
        ledger.creditNative{value: 10000}(POOL);
        LedgerReceiver(payable(beneficiaries[1])).setReject(true);
        assertFalse(ledger.claim(POOL, 1, 1000));
        assertEq(ledger.accrued(POOL, 1), 1000);
        LedgerReceiver(payable(beneficiaries[1])).setReject(false);
        vm.prank(address(99));
        assertTrue(ledger.claim(POOL, 1, 1000));
        assertEq(beneficiaries[1].balance, 1000);
        assertEq(ledger.accrued(POOL, 1), 0);
        assertEq(address(ledger).balance, 9000);
    }

    function testFeeAtomicallyFixesThreeRewardModulesRights() public {
        ledger.creditNative{value: 10000}(POOL);
        assertEq(LedgerReceiver(payable(beneficiaries[0])).credited(), 5750);
        assertEq(LedgerReceiver(payable(beneficiaries[2])).credited(), 1000);
        assertEq(LedgerReceiver(payable(beneficiaries[3])).credited(), 500);
        assertEq(LedgerReceiver(payable(beneficiaries[1])).credited(), 0);
    }

    function testUsdcSixDecimalsConsumesOnlyTransferredNativeUnits() public {
        V3FeeLedger arc = new V3FeeLedger(address(this), address(new NativeUsdcView()));
        arc.registerPool(POOL, address(0), 0, address(this), beneficiaries);
        arc.creditNative{value: 10000e12 + 10000}(POOL);
        assertTrue(arc.claimUSDC6(POOL, 1, 1000e12 + 1000));
        assertEq(beneficiaries[1].balance, 1000e12);
        assertEq(arc.accrued(POOL, 1), 1000);
        assertEq(address(arc).balance, 9000e12 + 10000);
    }

    function testStrangerCannotBypassNativeModuleReceiveViaUSDC6() public {
        V3FeeLedger arc = new V3FeeLedger(address(this), address(new NativeUsdcView()));
        arc.registerPool(POOL, address(0), 0, address(this), beneficiaries);
        arc.creditNative{value: 10000e12}(POOL);
        for (uint8 bucket; bucket < 4; ++bucket) {
            if (bucket == 1) continue;
            uint256 owed = arc.accrued(POOL, bucket);
            vm.prank(address(99));
            vm.expectRevert(V3FeeLedger.Unauthorized.selector);
            arc.claimUSDC6(POOL, bucket, owed);
            assertEq(arc.accrued(POOL, bucket), owed);
            vm.prank(beneficiaries[bucket]);
            assertTrue(arc.claimUSDC6(POOL, bucket, owed));
        }
        vm.prank(address(99));
        assertTrue(arc.claimUSDC6(POOL, 1, 1000e12));
    }

    function testLotsAndReserveAccountForFractionalEscrow() public {
        assertEq(ledger.nextLotId(POOL), 1);
        ledger.creditNative{value: 1}(POOL);
        assertEq(ledger.nextLotId(POOL), 2);
        assertEq(ledger.totalReceived(POOL), 1);
        assertEq(ledger.roundingReserve(POOL), 1);
        ledger.creditNative{value: 39}(POOL);
        assertEq(ledger.nextLotId(POOL), 3);
        assertEq(ledger.roundingReserve(POOL), 0);
        assertTrue(ledger.claim(POOL, 1, 4));
        assertEq(ledger.totalReceived(POOL), 40);
        assertEq(ledger.totalPaid(POOL), 4);
    }

    function testMaximumRawAmountDoesNotOverflowSplitMultiplication() public {
        LedgerStock stock = new LedgerStock();
        bytes32 stockPool = keccak256("maximum");
        ledger.registerPool(stockPool, address(stock), 1, address(this), beneficiaries);
        stock.mint(address(this), type(uint256).max);
        stock.approve(address(ledger), type(uint256).max);
        ledger.creditStock(stockPool, type(uint256).max);
        assertEq(
            ledger.accrued(stockPool, 0), type(uint256).max / 10000 * 5750 + type(uint256).max % 10000 * 5750 / 10000
        );
    }

    function testRevertingRewardCallbackRollsBackBalancesAndLot() public {
        LedgerReceiver(payable(beneficiaries[2])).setRejectCredit(true);
        vm.expectRevert();
        ledger.creditNative{value: 10000}(POOL);
        assertEq(ledger.totalReceived(POOL), 0);
        assertEq(ledger.nextLotId(POOL), 1);
        assertEq(address(ledger).balance, 0);
        assertEq(ledger.accrued(POOL, 0), 0);
        assertEq(LedgerReceiver(payable(beneficiaries[0])).credited(), 0);
    }

    function testReentrantRecipientCannotConsumeDebtTwice() public {
        ReentrantLedgerRecipient recipient = new ReentrantLedgerRecipient();
        bytes32 pool = keccak256("reentry");
        beneficiaries[1] = address(recipient);
        ledger.registerPool(pool, address(0), 0, address(this), beneficiaries);
        recipient.configure(ledger, pool);
        ledger.creditNative{value: 10000}(pool);
        assertFalse(ledger.claim(pool, 1, 1000));
        assertEq(ledger.accrued(pool, 1), 1000);
        assertEq(ledger.totalPaid(pool), 0);
        assertEq(address(recipient).balance, 0);
        assertTrue(ledger.claim(pool, 5, 750));
    }

    function testFrozenFalseReturningAndTaxedStockCannotEraseDebt() public {
        LedgerStock stock = new LedgerStock();
        bytes32 pool = keccak256("hostile");
        ledger.registerPool(pool, address(stock), 1, address(this), beneficiaries);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        ledger.creditStock(pool, 10000);
        stock.configure(true, false, false);
        assertFalse(ledger.claim(pool, 1, 1000));
        stock.configure(false, true, false);
        assertFalse(ledger.claim(pool, 1, 1000));
        stock.configure(false, false, true);
        assertFalse(ledger.claim(pool, 1, 1000));
        assertEq(stock.balanceOf(beneficiaries[1]), 0);
        assertEq(ledger.accrued(pool, 1), 1000);
        assertEq(stock.balanceOf(address(ledger)), 10000);
        assertEq(ledger.totalPaid(pool), 0);
        stock.configure(false, false, false);
        assertTrue(ledger.claim(pool, 1, 1000));
        assertEq(stock.balanceOf(beneficiaries[1]), 1000);
    }

    function testInexactIncomingStockRollsBackEntireLot() public {
        LedgerStock stock = new LedgerStock();
        bytes32 pool = keccak256("tax");
        ledger.registerPool(pool, address(stock), 1, address(this), beneficiaries);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        stock.configure(false, true, false);
        vm.expectRevert();
        ledger.creditStock(pool, 10000);
        assertEq(stock.balanceOf(address(this)), 10000);
        assertEq(ledger.totalReceived(pool), 0);
        assertEq(ledger.nextLotId(pool), 1);
    }

    function testSixDecimalViewMustActuallyDebitSameNativeBalance() public {
        LedgerStock unrelated = new LedgerStock();
        V3FeeLedger wrong = new V3FeeLedger(address(this), address(unrelated));
        wrong.registerPool(POOL, address(0), 0, address(this), beneficiaries);
        wrong.creditNative{value: 10000e12}(POOL);
        unrelated.mint(address(wrong), 10000);
        assertFalse(wrong.claimUSDC6(POOL, 1, 1000e12));
        assertEq(wrong.accrued(POOL, 1), 1000e12);
        assertEq(unrelated.balanceOf(beneficiaries[1]), 0);
        assertEq(address(wrong).balance, 10000e12);
    }

    function testMultiPoolSameQuoteAndMultipleStocksStayIsolated() public {
        LedgerStock a = new LedgerStock();
        LedgerStock b = new LedgerStock();
        for (uint256 i = 1; i <= 3; ++i) {
            address quote = i < 3 ? address(a) : address(b);
            ledger.registerPool(bytes32(i), quote, 1, address(this), beneficiaries);
        }
        a.mint(address(this), 30000);
        b.mint(address(this), 30000);
        a.approve(address(ledger), 30000);
        b.approve(address(ledger), 30000);
        ledger.creditStock(bytes32(uint256(1)), 10000);
        ledger.creditStock(bytes32(uint256(2)), 20000);
        ledger.creditStock(bytes32(uint256(3)), 30000);
        assertTrue(ledger.claim(bytes32(uint256(1)), 1, 1000));
        assertEq(ledger.accrued(bytes32(uint256(2)), 1), 2000);
        assertEq(ledger.accrued(bytes32(uint256(3)), 1), 3000);
        assertEq(a.balanceOf(address(ledger)), 29000);
        assertEq(b.balanceOf(address(ledger)), 30000);
    }

    function testFuzzSplittingCannotDivertFractionsToProtocol(uint96 seed, uint8 cuts) public {
        uint256 amount = bound(uint256(seed), 1, 1e24);
        uint256 parts = bound(uint256(cuts), 1, 64);
        bytes32 whole = keccak256("whole");
        ledger.registerPool(whole, address(0), 0, address(this), beneficiaries);
        vm.deal(address(this), 2 * amount);
        ledger.creditNative{value: amount}(whole);
        uint256 left = amount;
        for (uint256 i; i < parts && left > 0; ++i) {
            uint256 part = i == parts - 1 ? left : amount / parts;
            if (part == 0) continue;
            ledger.creditNative{value: part}(POOL);
            left -= part;
        }
        uint256 allocated;
        uint256 fractions;
        for (uint256 i; i < 6; ++i) {
            assertEq(ledger.accrued(POOL, i), ledger.accrued(whole, i));
            assertEq(ledger.remainder(POOL, i), ledger.remainder(whole, i));
            allocated += ledger.accrued(POOL, i);
            fractions += ledger.remainder(POOL, i);
        }
        assertEq(allocated * 10000 + fractions, amount * 10000);
        assertEq(allocated + ledger.roundingReserve(POOL), amount);
    }

    function testRegistrationRejectsMissingStockOrAccountingModules() public {
        vm.expectRevert();
        ledger.registerPool(keccak256("bad stock"), address(7), 1, address(this), beneficiaries);
        for (uint256 i; i < 4; ++i) {
            if (i == 1) continue;
            address previous = beneficiaries[i];
            beneficiaries[i] = address(7);
            vm.expectRevert();
            ledger.registerPool(keccak256(abi.encode(i)), address(0), 0, address(this), beneficiaries);
            beneficiaries[i] = previous;
        }
    }
    event DirectStockCredited(bytes32 indexed poolId, uint256 indexed lotId, address indexed asset, uint256 amount);

    function testDirectStockLotEmitsActualAssetReceipt() public {
        LedgerStock stock = new LedgerStock();
        bytes32 pool = keccak256("event");
        ledger.registerPool(pool, address(stock), 1, address(this), beneficiaries);
        stock.mint(address(this), 10000);
        stock.approve(address(ledger), 10000);
        vm.expectEmit(true, true, true, true, address(ledger));
        emit DirectStockCredited(pool, 1, address(stock), 10000);
        ledger.creditStock(pool, 10000);
    }

    function testNativeDonationsCannotBeCountedAsFeesOrWithdrawn() public {
        vm.deal(address(ledger), 10000);
        ledger.creditNative{value: 40}(POOL);
        assertEq(ledger.totalReceived(POOL), 40);
        assertEq(ledger.accrued(POOL, 5), 3);
        vm.expectRevert();
        ledger.claim(POOL, 5, 10003);
        assertEq(address(ledger).balance, 10040);
        vm.expectRevert();
        ledger.creditNative(POOL);
        assertEq(ledger.nextLotId(POOL), 2);
    }

    function testDisabledOrSubMinimumUsdcViewCannotConsumeCredit() public {
        ledger.creditNative{value: 10000}(POOL);
        vm.expectRevert();
        ledger.claimUSDC6(POOL, 1, 1000);
        V3FeeLedger arc = new V3FeeLedger(address(this), address(new NativeUsdcView()));
        arc.registerPool(POOL, address(0), 0, address(this), beneficiaries);
        arc.creditNative{value: 10000}(POOL);
        vm.expectRevert();
        arc.claimUSDC6(POOL, 1, 1000);
        assertEq(arc.accrued(POOL, 1), 1000);
    }
}

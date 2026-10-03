// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {LedgerReceiver, LedgerStock} from "./V3FeeLedger.t.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

interface IClaimsLedger {
    function creditClaims(bytes32 poolId, uint256 amount) external;
    function redeemClaims(bytes32 poolId) external;
}

/// Uses a real PM unlock/mint/settle cycle; no initial PM reserves are needed.
contract LedgerClaimsHook {
    IPoolManager public immutable poolManager;
    V3FeeLedger public immutable ledger;

    constructor(IPoolManager manager_, V3FeeLedger ledger_) {
        poolManager = manager_;
        ledger = ledger_;
    }

    function fund(bytes32 pool, address quote, uint256 amount, bool redeemUnlocked) external {
        poolManager.unlock(abi.encode(pool, quote, amount, redeemUnlocked));
    }

    function credit(bytes32 pool, uint256 amount) external {
        IClaimsLedger(address(ledger)).creditClaims(pool, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (bytes32 pool, address quote, uint256 amount, bool redeemUnlocked) =
            abi.decode(data, (bytes32, address, uint256, bool));
        Currency currency = Currency.wrap(quote);
        poolManager.mint(address(ledger), currency.toId(), amount);
        // This executes before the payer's settle, like the fee hook in swap.
        IClaimsLedger(address(ledger)).creditClaims(pool, amount);
        if (quote == address(0)) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            LedgerStock(quote).transfer(address(poolManager), amount);
            poolManager.settle();
        }
        if (redeemUnlocked) IClaimsLedger(address(ledger)).redeemClaims(pool);
        return "";
    }
}

contract V3FeeLedgerClaimsTest is Test {
    V3FeeLedger ledger;
    PoolManager manager;
    LedgerClaimsHook hook;
    bytes32 constant POOL = keccak256("claim-native");
    address[6] beneficiaries;

    function setUp() public {
        manager = new PoolManager(address(this));
        ledger = new V3FeeLedger(address(this), address(0));
        hook = new LedgerClaimsHook(IPoolManager(address(manager)), ledger);
        for (uint256 i; i < 6; ++i) {
            beneficiaries[i] = address(new LedgerReceiver());
        }
        ledger.registerPool(POOL, address(0), 0, address(hook), beneficiaries);
        vm.deal(address(hook), 100 ether);
    }

    function testClaimBackedFeeCreditsBeforeSettlementAndRedeemsOnce() public {
        hook.fund(POOL, address(0), 10000, false);
        assertEq(ledger.totalReceived(POOL), 10000);
        assertEq(ledger.accrued(POOL, 0), 5750);
        assertEq(LedgerReceiver(payable(beneficiaries[0])).credited(), 5750);
        assertEq(address(ledger).balance, 0);
        assertEq(manager.balanceOf(address(ledger), 0), 10000);
        vm.prank(address(99));
        IClaimsLedger(address(ledger)).redeemClaims(POOL);
        assertEq(address(ledger).balance, 10000);
        assertEq(manager.balanceOf(address(ledger), 0), 0);
        IClaimsLedger(address(ledger)).redeemClaims(POOL);
        assertEq(ledger.totalReceived(POOL), 10000);
        assertEq(ledger.nextLotId(POOL), 2);
    }

    function testClaimAutomaticallyRedeemsBackingBeforePayout() public {
        hook.fund(POOL, address(0), 10000, false);
        assertTrue(ledger.claim(POOL, 1, 1000));
        assertEq(beneficiaries[1].balance, 1000);
        assertEq(address(ledger).balance, 9000);
        assertEq(manager.balanceOf(address(ledger), 0), 0);
        assertEq(ledger.totalReceived(POOL), 10000);
        assertEq(ledger.totalPaid(POOL), 1000);
    }

    function testClaimsCannotBeCreditedByStrangerOrWithoutBackingOrReplayed() public {
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        IClaimsLedger(address(ledger)).creditClaims(POOL, 10000);
        vm.expectRevert("Unbacked claims");
        hook.credit(POOL, 10000);
        hook.fund(POOL, address(0), 10000, false);
        vm.expectRevert("Unbacked claims");
        hook.credit(POOL, 10000);
        assertEq(ledger.totalReceived(POOL), 10000);
        assertEq(ledger.nextLotId(POOL), 2);
        IClaimsLedger(address(ledger)).redeemClaims(POOL);
        vm.expectRevert("Unbacked claims");
        hook.credit(POOL, 10000);
    }

    function testWrongCurrencyBackingCannotCreditStockPool() public {
        LedgerStock stock = new LedgerStock();
        bytes32 stockPool = keccak256("wrong currency");
        ledger.registerPool(stockPool, address(stock), 1, address(hook), beneficiaries);
        vm.expectRevert("Unbacked claims");
        hook.fund(stockPool, address(0), 10000, false);
        assertEq(manager.balanceOf(address(ledger), 0), 0);
        assertEq(ledger.totalReceived(stockPool), 0);
    }

    function testSameQuoteBackingCannotBeReusedAcrossPools() public {
        bytes32 other = keccak256("same quote");
        ledger.registerPool(other, address(0), 0, address(hook), beneficiaries);
        hook.fund(POOL, address(0), 10000, false);
        vm.expectRevert("Unbacked claims");
        hook.credit(other, 10000);
        hook.fund(other, address(0), 20000, false);
        assertTrue(ledger.claim(POOL, 1, 1000));
        assertEq(manager.balanceOf(address(ledger), 0), 20000);
        assertEq(ledger.pendingClaims(other), 20000);
        assertEq(ledger.reservedClaims(address(manager), 0), 20000);
        assertEq(ledger.accrued(other, 1), 2000);
        assertTrue(ledger.claim(other, 1, 2000));
        assertEq(address(ledger).balance, 27000);
        assertEq(manager.balanceOf(address(ledger), 0), 0);
        assertEq(ledger.totalReceived(POOL), 10000);
        assertEq(ledger.totalReceived(other), 20000);
    }

    function testRedemptionWorksInsideExistingUnlock() public {
        hook.fund(POOL, address(0), 10000, true);
        assertEq(address(ledger).balance, 10000);
        assertEq(manager.balanceOf(address(ledger), 0), 0);
        assertEq(ledger.totalReceived(POOL), 10000);
        assertEq(ledger.pendingClaims(POOL), 0);
    }

    function testUnauthorizedUnlockCallbackCannotTakeClaims() public {
        hook.fund(POOL, address(0), 10000, false);
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.unlockCallback(abi.encode(POOL));
        vm.prank(address(manager));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.unlockCallback(abi.encode(POOL));
        assertEq(manager.balanceOf(address(ledger), 0), 10000);
        assertEq(ledger.pendingClaims(POOL), 10000);
    }

    function testRevertingAccountingCallbackRollsBackMintAndAllocation() public {
        LedgerReceiver(payable(beneficiaries[2])).setRejectCredit(true);
        vm.expectRevert("Callback rejected");
        hook.fund(POOL, address(0), 10000, false);
        assertEq(ledger.totalReceived(POOL), 0);
        assertEq(ledger.pendingClaims(POOL), 0);
        assertEq(ledger.reservedClaims(address(manager), 0), 0);
        assertEq(manager.balanceOf(address(ledger), 0), 0);
        assertEq(LedgerReceiver(payable(beneficiaries[0])).credited(), 0);
    }

    function testRejectedNativePayoutPreservesBackingAndDebt() public {
        hook.fund(POOL, address(0), 10000, false);
        LedgerReceiver(payable(beneficiaries[1])).setReject(true);
        assertFalse(ledger.claim(POOL, 1, 1000));
        assertEq(manager.balanceOf(address(ledger), 0), 10000);
        assertEq(ledger.pendingClaims(POOL), 10000);
        assertEq(ledger.accrued(POOL, 1), 1000);
        assertEq(ledger.totalPaid(POOL), 0);
        assertEq(address(ledger).balance, 0);
        LedgerReceiver(payable(beneficiaries[1])).setReject(false);
        assertTrue(ledger.claim(POOL, 1, 1000));
    }

    function testStockRedemptionFailurePreservesBackingAndDebt() public {
        LedgerStock stock = new LedgerStock();
        bytes32 stockPool = keccak256("stock claim");
        ledger.registerPool(stockPool, address(stock), 1, address(hook), beneficiaries);
        stock.mint(address(hook), 10000);
        hook.fund(stockPool, address(stock), 10000, false);
        uint256 currencyId = uint256(uint160(address(stock)));
        stock.configure(true, false, false);
        assertFalse(ledger.claim(stockPool, 1, 1000));
        stock.configure(false, true, false);
        assertFalse(ledger.claim(stockPool, 1, 1000));
        stock.configure(false, false, true);
        assertFalse(ledger.claim(stockPool, 1, 1000));
        assertEq(manager.balanceOf(address(ledger), currencyId), 10000);
        assertEq(ledger.pendingClaims(stockPool), 10000);
        assertEq(ledger.accrued(stockPool, 1), 1000);
        assertEq(ledger.totalPaid(stockPool), 0);
        assertEq(stock.balanceOf(address(ledger)), 0);
        stock.configure(false, false, false);
        assertTrue(ledger.claim(stockPool, 1, 1000));
        assertEq(stock.balanceOf(beneficiaries[1]), 1000);
        assertEq(stock.balanceOf(address(ledger)), 9000);
        assertEq(ledger.totalReceived(stockPool), 10000);
    }
}

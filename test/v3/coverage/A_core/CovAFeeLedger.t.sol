// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3FeeLedger} from "../../../../src/v3/V3FeeLedger.sol";
import {LedgerReceiver, LedgerStock, NativeUsdcView} from "../../V3FeeLedger.t.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";

/// @dev Receiver that declares a configurable feeCustodyMode marker.
contract CovAModeReceiver {
    uint256 public feeCustodyMode;

    constructor(uint256 mode) {
        feeCustodyMode = mode;
    }

    function onFeeCredit(bytes32, address, uint8, uint256) external {}

    receive() external payable {}
}

/// @dev Misbehaving PoolManager stand-in: may skip the unlock callback or short-deliver on take.
contract CovAMockManager {
    bool public unlockedFlag;
    bool public callBack = true;
    bool public deliver = true;
    uint256 public claimBalance = type(uint128).max;

    function configure(bool unlocked_, bool callBack_, bool deliver_, uint256 bal) external {
        unlockedFlag = unlocked_;
        callBack = callBack_;
        deliver = deliver_;
        claimBalance = bal;
    }

    /// TransientStateLibrary.isUnlocked reads the lock flag through exttload.
    function exttload(bytes32) external view returns (bytes32) {
        return unlockedFlag ? bytes32(uint256(1)) : bytes32(0);
    }

    function balanceOf(address, uint256) external view returns (uint256) {
        return claimBalance;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        if (callBack) return IUnlockCallback(msg.sender).unlockCallback(data);
        return "";
    }

    function burn(address, uint256, uint256) external {}

    function take(Currency currency, address to, uint256 amount) external {
        if (!deliver) return;
        require(Currency.unwrap(currency) == address(0), "native only");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "take");
    }

    receive() external payable {}
}

/// @dev Fee hook stand-in whose PoolManager can be switched.
contract CovAMockHook {
    address public poolManager;
    V3FeeLedger public immutable ledger;

    constructor(V3FeeLedger ledger_, address manager_) {
        ledger = ledger_;
        poolManager = manager_;
    }

    function setManager(address m) external {
        poolManager = m;
    }

    function credit(bytes32 pool, uint256 amount) external {
        ledger.creditClaims(pool, amount);
    }
}

/// @notice Branch coverage for V3FeeLedger: authorization, registration markers, stock lots,
/// claims redemption failures and payment exactness.
contract CovAFeeLedgerTest is Test {
    V3FeeLedger ledger;
    bytes32 constant POOL = keccak256("cov-native");
    address[6] beneficiaries;

    function setUp() public {
        ledger = new V3FeeLedger(address(this), address(new NativeUsdcView()));
        for (uint256 i; i < 6; ++i) {
            beneficiaries[i] = address(new LedgerReceiver());
        }
        ledger.registerPool(POOL, address(0), 0, address(this), beneficiaries);
        vm.deal(address(this), 100 ether);
    }

    function _stockPool(bytes32 pool) internal returns (LedgerStock stock) {
        stock = new LedgerStock();
        ledger.registerPool(pool, address(stock), 1, address(this), beneficiaries);
    }

    function _creditStock(bytes32 pool, LedgerStock stock, uint256 amount) internal {
        stock.mint(address(this), amount);
        stock.approve(address(ledger), amount);
        ledger.creditStock(pool, amount);
    }

    // line 101
    function testConstructorRejectsZeroFactory() public {
        vm.expectRevert();
        new V3FeeLedger(address(0), address(0));
        V3FeeLedger ok = new V3FeeLedger(address(1), address(0));
        assertEq(ok.factory(), address(1));
    }

    // line 42 both arms
    function testEnableControlledClaimOnlyBeneficiary() public {
        bytes32 pool = keccak256("ctrl");
        ledger.registerPool(pool, address(0), 0, address(this), beneficiaries);
        vm.prank(address(0xBAD));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.enableControlledClaim(pool, 4);
        assertFalse(ledger.controlledClaim(pool, 4));
        vm.prank(beneficiaries[4]);
        ledger.enableControlledClaim(pool, 4);
        assertTrue(ledger.controlledClaim(pool, 4));
        ledger.creditNative{value: 10000}(pool);
        vm.prank(address(0xBAD));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.claim(pool, 4, 1);
        // line 311: same gate on the USDC6 path
        vm.prank(address(0xBAD));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.claimUSDC6(pool, 4, 1e12);
        vm.prank(beneficiaries[4]);
        assertTrue(ledger.claim(pool, 4, 1000));
        assertEq(beneficiaries[4].balance, 1000);
    }

    // lines 51, 56, 57, 59, 61, 283
    function testStockLotCustodyLifecycle() public {
        bytes32 pool = keccak256("lots");
        LedgerStock stock = _stockPool(pool);
        vm.prank(address(0xBAD));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.enableStockLotCustody(pool, 4);
        vm.prank(beneficiaries[4]);
        ledger.enableStockLotCustody(pool, 4);
        assertTrue(ledger.stockLotCustody(pool, 4));
        _creditStock(pool, stock, 10000); // lot 1: bucket 4 = 1000

        // line 283: lot-custody bucket cannot use the generic claim
        vm.expectRevert(bytes("Use stock lot custody"));
        ledger.claim(pool, 4, 1);
        assertTrue(ledger.claim(pool, 5, 750)); // generic claim on a non-lot bucket passes line 283
        assertEq(stock.balanceOf(beneficiaries[5]), 750);

        // line 56: only the bucket owner
        vm.prank(address(0xBAD));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.claimStockLot(pool, 1, 4);
        // line 57: bucket without lot custody
        vm.prank(beneficiaries[3]);
        vm.expectRevert();
        ledger.claimStockLot(pool, 1, 3);
        // line 59: unknown lot
        vm.prank(beneficiaries[4]);
        vm.expectRevert();
        ledger.claimStockLot(pool, 2, 4);
        // line 61 false arm: frozen delivery -> whole call reverts, lot preserved
        stock.configure(true, false, false);
        vm.prank(beneficiaries[4]);
        vm.expectRevert(bytes("Lot payment failed"));
        ledger.claimStockLot(pool, 1, 4);
        assertEq(ledger.stockLotAmount(pool, 1, 4), 1000);
        assertEq(ledger.accrued(pool, 4), 1000);
        stock.configure(false, false, false);
        vm.prank(beneficiaries[4]);
        assertEq(ledger.claimStockLot(pool, 1, 4), 1000);
        assertEq(stock.balanceOf(beneficiaries[4]), 1000);
        assertEq(ledger.stockLotAmount(pool, 1, 4), 0);
        assertEq(ledger.accrued(pool, 4), 0);
        // line 59 again: replay of a consumed lot
        vm.prank(beneficiaries[4]);
        vm.expectRevert();
        ledger.claimStockLot(pool, 1, 4);
    }

    // lines 113, 114
    function testRegisterLegacyPoolGates() public {
        LedgerStock stock = new LedgerStock();
        address[6] memory b = beneficiaries;
        vm.prank(address(0xBAD));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.registerLegacyPool(keccak256("legacy"), address(stock), address(this), b);
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.registerLegacyPool(keccak256("legacy"), address(stock), address(this), b); // b[0] != b[3]
        b[3] = b[0];
        ledger.registerLegacyPool(keccak256("legacy"), address(stock), address(this), b);
        assertTrue(ledger.controlledClaim(keccak256("legacy"), 0));
        bytes32 source = ledger.legacyHolderSource(keccak256("legacy"));
        assertEq(source, keccak256(abi.encode(keccak256("SOLON_NVDA_POOL"), keccak256("legacy"))));
        assertEq(ledger.legacyHolderPool(source), keccak256("legacy"));
    }

    // line 129: zero or self beneficiary
    function testRegisterRejectsZeroOrSelfBeneficiary() public {
        address[6] memory b = beneficiaries;
        b[5] = address(0);
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.registerPool(keccak256("z"), address(0), 0, address(this), b);
        b[5] = address(ledger);
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.registerPool(keccak256("z"), address(0), 0, address(this), b);
        b[4] = address(0xE0A); // EOA allowed for buckets 1/4/5
        b[5] = address(0xE0B);
        ledger.registerPool(keccak256("z"), address(0), 0, address(this), b);
    }

    function _withMode(uint256 bucket, uint256 mode) internal returns (address[6] memory b) {
        b = beneficiaries;
        b[bucket] = address(new CovAModeReceiver(mode));
    }

    // lines 141-152: every feeCustodyMode arm
    function testFeeCustodyModeMarkers() public {
        LedgerStock stock = new LedgerStock();
        // bucket 2 mode 3 -> controlled
        ledger.registerPool(keccak256("m1"), address(0), 0, address(this), _withMode(2, 3));
        assertTrue(ledger.controlledClaim(keccak256("m1"), 2));
        // bucket 3 mode 0 -> accepted, uncontrolled (line 146 false arm)
        ledger.registerPool(keccak256("m2"), address(0), 0, address(this), _withMode(3, 0));
        assertFalse(ledger.controlledClaim(keccak256("m2"), 3));
        // bucket 2 mode 1 -> InvalidPool (line 146 true arm)
        address[6] memory b = _withMode(2, 1);
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.registerPool(keccak256("m3"), address(0), 0, address(this), b);
        // bucket 4 mode 1: native ok + controlled; stock -> InvalidPool (line 148)
        b = _withMode(4, 1);
        ledger.registerPool(keccak256("m4"), address(0), 0, address(this), b);
        assertTrue(ledger.controlledClaim(keccak256("m4"), 4));
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.registerPool(keccak256("m5"), address(stock), 1, address(this), b);
        // bucket 5 mode 2: stock ok + lot custody; native -> InvalidPool (line 151)
        b = _withMode(5, 2);
        ledger.registerPool(keccak256("m6"), address(stock), 1, address(this), b);
        assertTrue(ledger.stockLotCustody(keccak256("m6"), 5));
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.registerPool(keccak256("m7"), address(0), 0, address(this), b);
        // bucket 4 mode 3 / mode 7: no marker (fall-through arm of line 150)
        ledger.registerPool(keccak256("m8"), address(0), 0, address(this), _withMode(4, 3));
        assertFalse(ledger.controlledClaim(keccak256("m8"), 4));
        assertFalse(ledger.stockLotCustody(keccak256("m8"), 4));
        ledger.registerPool(keccak256("m9"), address(stock), 1, address(this), _withMode(5, 7));
        assertFalse(ledger.stockLotCustody(keccak256("m9"), 5));
    }

    // lines 162, 234, 268, 269, 273
    function testCreditGuards() public {
        bytes32 pool = keccak256("credit-guards");
        LedgerStock stock = _stockPool(pool);
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.creditNative{value: 1}(pool); // native into stock pool
        vm.expectRevert(bytes("Zero fee"));
        ledger.creditNative{value: 0}(POOL);
        vm.prank(address(0xBAD));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.creditStock(pool, 1);
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.creditStock(POOL, 1); // stock into native pool
        vm.expectRevert(bytes("Zero fee"));
        ledger.creditStock(pool, 0);
        stock.mint(address(this), 100);
        stock.approve(address(ledger), 100);
        stock.configure(false, true, false);
        vm.expectRevert(bytes("Inexact transfer"));
        ledger.creditStock(pool, 100);
        assertEq(ledger.totalReceived(pool), 0);
        assertEq(ledger.nextLotId(pool), 1);
        assertEq(ledger.totalReceived(POOL), 0);
    }

    // line 289 + 326
    function testClaimInvalidBucketOrPoolAndSelfOnlyPayment() public {
        ledger.creditNative{value: 10000}(POOL);
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.claim(POOL, 6, 1);
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.claim(keccak256("unknown"), 1, 1);
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.executePayment(POOL, address(0), address(this), 1, false);
        assertEq(address(ledger).balance, 10000);
    }

    // line 332 both arms + line 338 false arm (exact reasons via the self-only boundary)
    function testPaymentExactnessReasons() public {
        ledger.creditNative{value: 10000}(POOL);
        LedgerReceiver(payable(beneficiaries[1])).setReject(true);
        vm.prank(address(ledger));
        vm.expectRevert(bytes("Payment failed"));
        ledger.executePayment(POOL, address(0), beneficiaries[1], 1000, false);
        assertFalse(ledger.claim(POOL, 1, 1000));
        LedgerReceiver(payable(beneficiaries[1])).setReject(false);
        assertTrue(ledger.claim(POOL, 1, 1000));
        assertEq(beneficiaries[1].balance, 1000);

        bytes32 pool = keccak256("taxed-pay");
        LedgerStock stock = _stockPool(pool);
        _creditStock(pool, stock, 10000);
        stock.configure(false, true, false);
        vm.prank(address(ledger));
        vm.expectRevert(bytes("Inexact transfer"));
        ledger.executePayment(pool, address(stock), beneficiaries[1], 1000, false);
        assertFalse(ledger.claim(pool, 1, 1000));
        assertEq(ledger.accrued(pool, 1), 1000);
        assertEq(stock.balanceOf(address(ledger)), 10000);
    }

    // line 227
    function testReceiveRejectsStrangers() public {
        (bool ok, bytes memory err) = address(ledger).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(err), V3FeeLedger.Unauthorized.selector);
    }

    function _claimsPool(CovAMockManager pm) internal returns (CovAMockHook hook, bytes32 pool) {
        hook = new CovAMockHook(ledger, address(pm));
        pool = keccak256(abi.encode("claims", address(hook)));
        ledger.registerPool(pool, address(0), 0, address(hook), beneficiaries);
    }

    // lines 172, 175
    function testCreditClaimsManagerSwitchAndUnbacked() public {
        CovAMockManager pm = new CovAMockManager();
        (CovAMockHook hook, bytes32 pool) = _claimsPool(pm);
        vm.prank(address(0xBAD));
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.creditClaims(pool, 100);
        pm.configure(false, true, true, 99);
        vm.expectRevert(bytes("Unbacked claims"));
        hook.credit(pool, 100);
        pm.configure(false, true, true, 100);
        hook.credit(pool, 100);
        assertEq(ledger.pendingClaims(pool), 100);
        assertEq(ledger.reservedClaims(address(pm), 0), 100);
        // reserved backing is shared: a second 1 wei is unbacked at balance 100
        vm.expectRevert(bytes("Unbacked claims"));
        hook.credit(pool, 1);
        CovAMockManager other = new CovAMockManager();
        hook.setManager(address(other));
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        hook.credit(pool, 1);
        assertEq(ledger.totalReceived(pool), 100);
    }

    // lines 184, 199 (both arms), 223 (both arms)
    function testRedeemClaimsMissingCallbackAndInexactRedemption() public {
        vm.expectRevert(V3FeeLedger.InvalidPool.selector);
        ledger.redeemClaims(keccak256("unknown"));

        CovAMockManager pm = new CovAMockManager();
        vm.deal(address(pm), 1 ether);
        (CovAMockHook hook, bytes32 pool) = _claimsPool(pm);
        hook.credit(pool, 1000);

        // manager returns from unlock without calling back
        pm.configure(false, false, true, type(uint128).max);
        vm.expectRevert(bytes("Missing callback"));
        ledger.redeemClaims(pool);
        // manager already unlocked but take short-delivers
        pm.configure(true, true, false, type(uint128).max);
        vm.expectRevert(bytes("Inexact redemption"));
        ledger.redeemClaims(pool);
        // same through the locked/callback path
        pm.configure(false, true, false, type(uint128).max);
        vm.expectRevert(bytes("Inexact redemption"));
        ledger.redeemClaims(pool);
        assertEq(ledger.pendingClaims(pool), 1000);
        assertEq(ledger.reservedClaims(address(pm), 0), 1000);
        assertEq(address(ledger).balance, 0);

        // honest manager: callback path redeems exactly once
        pm.configure(false, true, true, type(uint128).max);
        ledger.redeemClaims(pool);
        assertEq(ledger.pendingClaims(pool), 0);
        assertEq(ledger.reservedClaims(address(pm), 0), 0);
        assertEq(address(ledger).balance, 1000);
        ledger.redeemClaims(pool); // amount == 0 early return
        assertEq(address(ledger).balance, 1000);
        assertTrue(ledger.claim(pool, 1, 100));
        assertEq(beneficiaries[1].balance, 100);
    }

    // line 206: callback outside an active redemption
    function testUnlockCallbackRejectedOutsideRedemption() public {
        vm.expectRevert(V3FeeLedger.Unauthorized.selector);
        ledger.unlockCallback(abi.encode(POOL));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BurnSink} from "../../../../src/v3/BurnSink.sol";
import {BuybackVault} from "../../../../src/v3/BuybackVault.sol";
import {BuybackBurnExecutor} from "../../../../src/v3/BuybackBurnExecutor.sol";
import {V3FeeLedger} from "../../../../src/v3/V3FeeLedger.sol";
import {CovCToken, CovCMockLedger} from "./CovCMocks.sol";

contract CovCBuyRoute {
    CovCToken token;
    uint256 public output = 100 ether;

    constructor(CovCToken t) {
        token = t;
    }

    function buy(address, bytes32, address recipient, uint256) external payable returns (uint256) {
        token.mint(recipient, output);
        return output;
    }
}

/// @notice ProtocolDeskVault stand-in: pulls (or deliberately does not pull) the bought SOLON.
contract CovCDeskDest {
    CovCToken token;
    bool public pull = true;
    mapping(bytes32 => uint256) public got;

    constructor(CovCToken t) {
        token = t;
    }

    function setPull(bool v) external {
        pull = v;
    }

    function depositBuyback(bytes32 id, uint256 amount) external {
        if (pull) token.transferFrom(msg.sender, address(this), amount);
        got[id] += amount;
    }
}

contract CovCFeeReceiver {
    function onFeeCredit(bytes32, address, uint8, uint256) external {}
    receive() external payable {}
}

contract CovCBuybackVaultTest is Test {
    CovCToken token;
    BurnSink sink;
    BuybackVault vault;

    function setUp() public {
        token = new CovCToken();
        sink = new BurnSink();
        vault = new BuybackVault(address(token), address(sink), address(this));
        token.mint(address(this), 1000 ether);
        token.approve(address(vault), type(uint256).max);
    }

    /// L41 false arm: fee-on-transfer receipt is rejected, no lot recorded.
    function test_DepositInexactReceiptReverts() public {
        token.setShortFrom(address(this));
        vm.expectRevert(bytes("Inexact receipt"));
        vault.depositBuyback(bytes32(uint256(1)), 10 ether);
        (uint256 amount,) = vault.lots(bytes32(uint256(1)));
        assertEq(amount, 0);
        assertEq(vault.totalPending(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    /// L49 false arm (unknown / already burned lot) and true arm (pending lot burns).
    function test_BurnPendingRequiresPendingLot() public {
        vm.expectRevert(bytes("Not pending"));
        vault.burnPending(bytes32(uint256(9)));
        vault.depositBuyback(bytes32(uint256(9)), 5 ether);
        assertTrue(vault.burnPending(bytes32(uint256(9))));
        assertEq(token.balanceOf(address(sink)), 5 ether);
        vm.expectRevert(bytes("Not pending"));
        vault.burnPending(bytes32(uint256(9)));
        assertEq(vault.totalBurned(), 5 ether);
    }

    /// L63 both arms: only the vault itself may call deliverToSink (true arm runs inside burnPending).
    function test_DeliverToSinkSelfOnly() public {
        vault.depositBuyback(bytes32(uint256(2)), 5 ether);
        vm.expectRevert(bytes("Self only"));
        vault.deliverToSink(5 ether);
        assertEq(token.balanceOf(address(vault)), 5 ether);
        assertTrue(vault.burnPending(bytes32(uint256(2))));
        assertEq(token.balanceOf(address(sink)), 5 ether);
    }

    /// L67 false arm: a taxed sink delivery fails the exact-burn check; the try/catch defers, keeping the lot pending.
    function test_InexactBurnIsDeferredNotLost() public {
        bytes32 id = bytes32(uint256(3));
        vault.depositBuyback(id, 5 ether);
        token.setShortFrom(address(vault));
        assertFalse(vault.burnPending(id));
        (uint256 amount, BuybackVault.State st) = vault.lots(id);
        assertEq(amount, 5 ether);
        assertEq(uint8(st), uint8(BuybackVault.State.BurnPending));
        assertEq(vault.totalPending(), 5 ether);
        assertEq(vault.totalBurned(), 0);
        assertEq(token.balanceOf(address(vault)), 5 ether);
        assertEq(token.balanceOf(address(sink)), 0);
        token.setShortFrom(address(0));
        assertTrue(vault.burnPending(id));
        assertEq(token.balanceOf(address(sink)), 5 ether);
    }
}

contract CovCBuybackExecutorTest is Test {
    CovCToken token;
    BurnSink sink;
    CovCBuyRoute router;
    CovCDeskDest desk;
    CovCMockLedger mledger;
    BuybackBurnExecutor executor;
    uint256 key = 7123;
    address converter = address(0xC0);
    address v2 = address(0xB2);

    function setUp() public {
        token = new CovCToken();
        sink = new BurnSink();
        router = new CovCBuyRoute(token);
        desk = new CovCDeskDest(token);
        mledger = new CovCMockLedger();
        executor = new BuybackBurnExecutor(
            BuybackBurnExecutor.Config(
                address(this),
                address(token),
                address(mledger),
                address(router),
                keccak256("FIXED_POOL"),
                vm.addr(key),
                address(sink),
                address(desk)
            )
        );
        executor.configureSources(converter, v2);
        vm.deal(converter, 1000 ether);
        vm.deal(v2, 1000 ether);
        vm.deal(address(mledger), 1000 ether);
    }

    function _quote(bytes32 id, uint256 nonce, uint256 signer)
        internal
        view
        returns (BuybackBurnExecutor.Quote memory q, bytes memory sig)
    {
        q = BuybackBurnExecutor.Quote(
            id, 100 ether, 90 ether, 1, vm.getBlockTimestamp(), vm.getBlockTimestamp() + 60, nonce
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, executor.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    function _mockPool(bytes32 pool) internal {
        address[6] memory b;
        b[4] = address(executor);
        mledger.setPool(pool, address(0), 0, address(1), b);
        mledger.setControlled(pool, 4, true);
    }

    /// L111 both arms: only the fixed ledger may push native into the executor.
    function test_ReceiveLedgerOnly() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(executor).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(address(mledger));
        (ok,) = address(executor).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(executor).balance, 1 ether);
        // a direct push is not budget
        assertEq(executor.totalBudget(), 0);
    }

    /// L120 both arms against the real V3FeeLedger.
    function test_EnablePoolRealLedger() public {
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        BuybackBurnExecutor ex = new BuybackBurnExecutor(
            BuybackBurnExecutor.Config(
                address(this),
                address(token),
                address(ledger),
                address(router),
                keccak256("FIXED_POOL"),
                vm.addr(key),
                address(sink),
                address(desk)
            )
        );
        address r = address(new CovCFeeReceiver());
        bytes32 pool = keccak256("native-pool");
        // unregistered pool: beneficiaries[4] != executor
        vm.expectRevert(bytes("Wrong pool"));
        ex.enablePool(pool);
        // stock-quote pool where the executor is not bucket 4
        bytes32 stockPool = keccak256("stock-pool");
        ledger.registerPool(stockPool, address(token), 1, address(this), [r, r, r, r, r, r]);
        vm.expectRevert(bytes("Wrong pool"));
        ex.enablePool(stockPool);
        ledger.registerPool(pool, address(0), 0, address(this), [r, r, r, r, address(ex), r]);
        ex.enablePool(pool);
        assertTrue(ex.enabledPools(pool));
        assertTrue(ledger.controlledClaim(pool, 4));
        assertFalse(ex.enabledPools(stockPool));
    }

    /// L127 false arm: every conjunct of the "Unknown pool" guard rejects.
    function test_CollectLedgerUnknownPool() public {
        bytes32 pool = keccak256("p");
        _mockPool(pool);
        mledger.setAccrued(pool, 4, 10 ether);
        vm.expectRevert(bytes("Unknown pool"));
        executor.collectLedger(pool, 0); // amount == 0
        mledger.setControlled(pool, 4, false);
        vm.expectRevert(bytes("Unknown pool"));
        executor.collectLedger(pool, 1 ether); // not controlled
        address[6] memory b;
        b[4] = address(0xBEEF);
        mledger.setPool(pool, address(0), 0, address(1), b);
        mledger.setControlled(pool, 4, true);
        vm.expectRevert(bytes("Unknown pool"));
        executor.collectLedger(pool, 1 ether); // wrong beneficiary
        b[4] = address(executor);
        mledger.setPool(pool, address(token), 1, address(1), b);
        vm.expectRevert(bytes("Unknown pool"));
        executor.collectLedger(pool, 1 ether); // non-native quote
        assertEq(executor.totalBudget(), 0);
    }

    /// L133 false arm: ledger reports a failed (deferred) payment.
    function test_CollectLedgerPaymentFailed() public {
        bytes32 pool = keccak256("p");
        _mockPool(pool);
        mledger.setClaimBehaviour(false, 0, 0);
        vm.expectRevert(bytes("Ledger payment failed"));
        executor.collectLedger(pool, 1 ether);
        assertEq(executor.totalBudget(), 0);
        assertEq(executor.poolCollectionNonce(pool), 0);
    }

    /// L134 both arms: inexact native receipt is rejected; exact receipt funds a lot with a fresh nonce id.
    function test_CollectLedgerExactRevenue() public {
        bytes32 pool = keccak256("p");
        _mockPool(pool);
        mledger.setClaimBehaviour(true, 1, 0);
        vm.expectRevert(bytes("Inexact revenue"));
        executor.collectLedger(pool, 1 ether);
        mledger.setClaimBehaviour(true, 0, 1);
        vm.expectRevert(bytes("Inexact revenue"));
        executor.collectLedger(pool, 1 ether);
        mledger.setClaimBehaviour(true, 0, 0);
        bytes32 id = executor.collectLedger(pool, 1 ether);
        assertEq(id, keccak256(abi.encode(address(mledger), pool, uint256(1))));
        (uint256 budget,, bool pd,,) = executor.lots(id);
        assertEq(budget, 1 ether);
        assertFalse(pd);
        assertEq(executor.totalBudget(), 1 ether);
        assertEq(address(executor).balance, 1 ether);
    }

    /// L140 both arms.
    function test_FundFromConverterOnlyConverter() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("Converter only"));
        executor.fundFromConverter{value: 1 ether}(bytes32(uint256(1)));
        vm.prank(converter);
        executor.fundFromConverter{value: 1 ether}(bytes32(uint256(1)));
        assertEq(executor.totalBudget(), 1 ether);
        // duplicate / empty lot
        vm.prank(converter);
        vm.expectRevert(bytes("Invalid lot"));
        executor.fundFromConverter{value: 1 ether}(bytes32(uint256(1)));
        vm.prank(converter);
        vm.expectRevert(bytes("Invalid lot"));
        executor.fundFromConverter{value: 0}(bytes32(uint256(2)));
    }

    /// L145 both arms + protocol-desk destination of L185/L214 ternaries.
    function test_FundV2OnlyRouterAndDeskDestination() public {
        vm.deal(address(this), 100 ether);
        vm.expectRevert(bytes("V2 only"));
        executor.fundV2{value: 100 ether}(bytes32(uint256(5)), true);
        bytes32 id = bytes32(uint256(5));
        vm.prank(v2);
        executor.fundV2{value: 100 ether}(id, true);
        (,, bool pd,,) = executor.lots(id);
        assertTrue(pd);
        (BuybackBurnExecutor.Quote memory q, bytes memory sig) = _quote(id, 1, key);
        assertEq(executor.execute(q, sig), 100 ether);
        assertEq(token.balanceOf(address(desk)), 100 ether);
        assertEq(desk.got(id), 100 ether);
        assertEq(token.balanceOf(executor.vault()), 0);
        assertEq(token.allowance(address(executor), address(desk)), 0);
        assertEq(address(router).balance, 100 ether);
    }

    /// L202 both arms: a signature from any key other than the configured signer is rejected.
    function test_ExecuteRejectsWrongSigner() public {
        bytes32 id = bytes32(uint256(6));
        vm.prank(converter);
        executor.fundFromConverter{value: 100 ether}(id);
        (BuybackBurnExecutor.Quote memory q, bytes memory sig) = _quote(id, 1, key + 1);
        vm.expectRevert(bytes("Signature"));
        executor.execute(q, sig);
        assertFalse(executor.nonceUsed(1));
        assertEq(address(executor).balance, 100 ether);
        (q, sig) = _quote(id, 1, key);
        assertEq(executor.execute(q, sig), 100 ether);
        assertEq(token.balanceOf(executor.vault()), 100 ether);
    }

    /// L218 false arm: a destination that does not take the output leaves SOLON in the executor -> revert.
    function test_ExecuteUnconsumedOutputReverts() public {
        bytes32 id = bytes32(uint256(7));
        vm.prank(v2);
        executor.fundV2{value: 100 ether}(id, true);
        desk.setPull(false);
        (BuybackBurnExecutor.Quote memory q, bytes memory sig) = _quote(id, 1, key);
        vm.expectRevert(bytes("Unconsumed output"));
        executor.execute(q, sig);
        assertEq(address(executor).balance, 100 ether);
        assertEq(token.balanceOf(address(executor)), 0);
        assertFalse(executor.nonceUsed(1));
    }
}

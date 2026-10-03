// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BurnSink} from "../../src/v3/BurnSink.sol";
import {BuybackVault} from "../../src/v3/BuybackVault.sol";
import {BuybackBurnExecutor, IBuybackRoute} from "../../src/v3/BuybackBurnExecutor.sol";

contract BuybackToken is ERC20 {
    bool public blocked;
    constructor() ERC20("SOLON", "SOLON") {}

    function mint(address to, uint256 n) external {
        _mint(to, n);
    }

    function blockTransfers(bool value) external {
        blocked = value;
    }

    function _update(address from, address to, uint256 n) internal override {
        require(!blocked || from == address(0), "Frozen");
        super._update(from, to, n);
    }
}

contract BuybackTest is Test {
    BuybackToken token;
    BurnSink sink;
    BuybackVault vault;

    function setUp() public {
        token = new BuybackToken();
        sink = new BurnSink();
        vault = new BuybackVault(address(token), address(sink), address(this));
        token.mint(address(this), 200_000 ether);
        token.approve(address(vault), type(uint256).max);
    }

    function testDepositedLotBurnsOnlyIntoSinkWithoutSupplyReduction() public {
        vault.depositBuyback(bytes32(uint256(1)), 100_000 ether);
        assertEq(token.balanceOf(address(vault)), 100_000 ether);
        assertTrue(vault.burnPending(bytes32(uint256(1))));
        assertEq(token.balanceOf(address(sink)), 100_000 ether);
        assertEq(token.totalSupply(), 200_000 ether);
    }

    function testFrozenBurnRetainsPendingAndRetriesWithoutDoubleBurn() public {
        bytes32 id = keccak256("retry");
        vault.depositBuyback(id, 100 ether);
        token.blockTransfers(true);
        assertFalse(vault.burnPending(id));
        assertEq(vault.totalPending(), 100 ether);
        assertEq(vault.totalBurned(), 0);
        token.blockTransfers(false);
        assertTrue(vault.burnPending(id));
        vm.expectRevert();
        vault.burnPending(id);
        assertEq(vault.totalBurned(), 100 ether);
    }

    function testOnlyExecutorCanFundAndLotCannotReplay() public {
        vm.prank(address(42));
        vm.expectRevert();
        vault.depositBuyback(bytes32(uint256(1)), 1);
        vault.depositBuyback(bytes32(uint256(1)), 1);
        vm.expectRevert();
        vault.depositBuyback(bytes32(uint256(1)), 1);
    }

    function testFuzzSinkIncreaseEqualsFundedLot(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1, 200_000 ether);
        bytes32 id = keccak256(abi.encode(raw));
        vault.depositBuyback(id, amount);
        assertTrue(vault.burnPending(id));
        assertEq(vault.totalBurned(), amount);
        assertEq(token.balanceOf(address(sink)), amount);
        assertEq(vault.totalPending(), 0);
        assertEq(token.totalSupply(), 200_000 ether);
    }
}

contract BuybackRouteFixture is IBuybackRoute {
    BuybackToken token;
    uint256 public output = 100 ether;

    constructor(BuybackToken t) {
        token = t;
    }

    function setOutput(uint256 n) external {
        output = n;
    }

    function buy(address t, bytes32, address recipient, uint256) external payable returns (uint256) {
        require(t == address(token));
        token.mint(recipient, output);
        return output;
    }
}

contract BuybackExecutorTest is Test {
    BuybackToken token;
    BurnSink sink;
    BuybackRouteFixture router;
    BuybackBurnExecutor executor;
    uint256 key = 7123;

    function setUp() public {
        token = new BuybackToken();
        sink = new BurnSink();
        router = new BuybackRouteFixture(token);
        executor = new BuybackBurnExecutor(
            BuybackBurnExecutor.Config(
                address(this),
                address(token),
                address(11),
                address(router),
                keccak256("FIXED_POOL"),
                vm.addr(key),
                address(sink),
                address(12)
            )
        );
        executor.configureSources(address(this), address(this));
        vm.deal(address(this), 2000 ether);
    }

    function quote(bytes32 id, uint256 nonce)
        internal
        view
        returns (BuybackBurnExecutor.Quote memory q, bytes memory sig)
    {
        q = BuybackBurnExecutor.Quote(
            id, 100 ether, 90 ether, 1, vm.getBlockTimestamp(), vm.getBlockTimestamp() + 60, nonce
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, executor.quoteDigest(q));
        sig = abi.encodePacked(r, s, v);
    }

    function testSignedBuybackUsesActualOutputAndFixedVault() public {
        bytes32 id = keccak256("buy1");
        executor.fundFromConverter{value: 100 ether}(id);
        (BuybackBurnExecutor.Quote memory q, bytes memory sig) = quote(id, 1);
        assertEq(executor.execute(q, sig), 100 ether);
        assertEq(token.balanceOf(executor.vault()), 100 ether);
        assertEq(token.balanceOf(address(sink)), 0);
        assertTrue(BuybackVault(executor.vault()).burnPending(id));
        assertEq(token.balanceOf(address(sink)), 100 ether);
    }

    function testBadOutputRevertsWithoutSpendingBudgetAndQuoteCanRetry() public {
        bytes32 id = keccak256("buy2");
        executor.fundFromConverter{value: 100 ether}(id);
        (BuybackBurnExecutor.Quote memory q, bytes memory sig) = quote(id, 1);
        router.setOutput(80 ether);
        vm.expectRevert();
        executor.execute(q, sig);
        assertEq(address(executor).balance, 100 ether);
        assertFalse(executor.nonceUsed(1));
        router.setOutput(100 ether);
        executor.execute(q, sig);
        vm.expectRevert();
        executor.execute(q, sig);
    }

    function testLargeFundedLotExecutesInHardCappedSlices() public {
        bytes32 id = keccak256("big");
        executor.fundFromConverter{value: 1500 ether}(id);
        (BuybackBurnExecutor.Quote memory q,) = quote(id, 1);
        q.budget = 1000 ether;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, executor.quoteDigest(q));
        executor.execute(q, abi.encodePacked(r, s, v));
        assertEq(address(executor).balance, 500 ether);
        assertEq(executor.totalBudget(), 500 ether);
    }

    function testQuoteTamperingAndStalenessCannotSpend() public {
        bytes32 id = keccak256("invalid");
        executor.fundFromConverter{value: 100 ether}(id);
        (BuybackBurnExecutor.Quote memory q, bytes memory sig) = quote(id, 1);
        q.minOut = 1;
        vm.expectRevert();
        executor.execute(q, sig);
        (q, sig) = quote(id, 1);
        vm.warp(vm.getBlockTimestamp() + 61);
        vm.expectRevert();
        executor.execute(q, sig);
    }

    function testPriceSignerRotationWaits48HoursAndOldPolicyCannotExecute() public {
        (bool ok,) =
            address(executor).call(abi.encodeWithSignature("schedulePricePolicy(address,uint256)", vm.addr(22), 2));
        assertTrue(ok);
        bytes memory applyData = abi.encodeWithSignature("activatePricePolicy()");
        (ok,) = address(executor).call(applyData);
        assertFalse(ok);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        (ok,) = address(executor).call(applyData);
        assertTrue(ok);
        bytes32 id = keccak256("rotated");
        executor.fundFromConverter{value: 100 ether}(id);
        (BuybackBurnExecutor.Quote memory q, bytes memory sig) = quote(id, 1);
        vm.expectRevert();
        executor.execute(q, sig);
        q.pricePolicyVersion = 2;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(22, executor.quoteDigest(q));
        assertEq(executor.execute(q, abi.encodePacked(r, s, v)), 100 ether);
    }
}

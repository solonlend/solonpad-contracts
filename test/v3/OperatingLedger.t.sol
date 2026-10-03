// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {BuybackToken, BuybackRouteFixture} from "./Buyback.t.sol";
import {BurnSink} from "../../src/v3/BurnSink.sol";
import {BuybackBurnExecutor} from "../../src/v3/BuybackBurnExecutor.sol";
import {ProtocolVault} from "../../src/v3/ProtocolVault.sol";

contract OperatingFeeReceiver {
    function onFeeCredit(bytes32, address, uint8, uint256) external {}
}

contract OperatingLedgerTest is Test {
    function testNativeOperatingBucketsArePulledExactlyOnceByFixedModules() public {
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        BuybackToken token = new BuybackToken();
        BurnSink sink = new BurnSink();
        BuybackRouteFixture route = new BuybackRouteFixture(token);
        BuybackBurnExecutor buyer = new BuybackBurnExecutor(
            BuybackBurnExecutor.Config(
                address(this),
                address(token),
                address(ledger),
                address(route),
                keccak256("path"),
                address(123),
                address(sink),
                address(456)
            )
        );
        ProtocolVault protocol = new ProtocolVault(address(this), address(789), address(987), address(ledger));
        address receiver = address(new OperatingFeeReceiver());
        bytes32 pool = keccak256("pool");
        ledger.registerPool(
            pool,
            address(0),
            0,
            address(this),
            [receiver, address(2), receiver, receiver, address(buyer), address(protocol)]
        );
        bool ok;
        assertTrue(ledger.controlledClaim(pool, 4));
        assertTrue(ledger.controlledClaim(pool, 5));
        vm.deal(address(this), 100 ether);
        ledger.creditNative{value: 100 ether}(pool);
        vm.expectRevert();
        ledger.claim(pool, 4, 10 ether);
        (ok,) = address(buyer).call(abi.encodeWithSignature("collectLedger(bytes32,uint256)", pool, 10 ether));
        assertTrue(ok);
        (ok,) = address(protocol).call(abi.encodeWithSignature("collectLedger(bytes32,uint256)", pool, 7.5 ether));
        assertTrue(ok);
        assertEq(buyer.totalBudget(), 10 ether);
        assertEq(address(protocol).balance, 7.5 ether);
        assertEq(ledger.accrued(pool, 4), 0);
        assertEq(ledger.accrued(pool, 5), 0);
    }
}

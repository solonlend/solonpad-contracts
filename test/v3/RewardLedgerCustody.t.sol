// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {LedgerStock, LedgerReceiver} from "./V3FeeLedger.t.sol";

contract ControlledDeskReceiver {
    function feeCustodyMode() external pure returns (uint256) {
        return 3;
    }
    function onFeeCredit(bytes32, address, uint8, uint256) external {}

    function pull(V3FeeLedger ledger, bytes32 pool, uint256 amount) external {
        require(ledger.claim(pool, 2, amount));
    }
    receive() external payable {}
}

contract RewardLedgerCustodyTest is Test {
    function testNativeDeskBackingCannotBeClaimedAheadOfItsAccounting() public {
        _check(false);
    }

    function testRawDeskBackingCannotBeMistakenForRoyaltyByOutsiderPull() public {
        _check(true);
    }

    function _check(bool raw) internal {
        vm.deal(address(this), 100 ether);
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        LedgerStock stock = new LedgerStock();
        ControlledDeskReceiver receiver = new ControlledDeskReceiver();
        address observer = address(new LedgerReceiver());
        address[6] memory b;
        for (uint256 i; i < 6; ++i) {
            b[i] = observer;
        }
        b[2] = address(receiver);
        bytes32 pool = bytes32("desk custody");
        ledger.registerPool(pool, raw ? address(stock) : address(0), raw ? 1 : 0, address(this), b);
        if (raw) {
            stock.mint(address(this), 100 ether);
            stock.approve(address(ledger), 100 ether);
            ledger.creditStock(pool, 100 ether);
        } else {
            ledger.creditNative{value: 100 ether}(pool);
        }
        vm.prank(address(0xbad));
        (bool ok,) = address(ledger).call(abi.encodeCall(ledger.claim, (pool, uint8(2), 10 ether)));
        assertFalse(ok, "outsider consumed Desk backing");
        assertEq(ledger.accrued(pool, 2), 10 ether);
        receiver.pull(ledger, pool, 10 ether);
        assertEq(ledger.accrued(pool, 2), 0);
        assertEq(raw ? stock.balanceOf(address(receiver)) : address(receiver).balance, 10 ether);
        assertTrue(ledger.claim(pool, 1, 10 ether), "legacy receiver changed");
    }
}

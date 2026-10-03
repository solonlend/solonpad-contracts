// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {IV3FeeReceiver} from "../../src/v3/interfaces/IV3FeeLedger.sol";

contract LedgerInvariantRecipient is IV3FeeReceiver {
    bool public rejecting;

    function setRejecting(bool value) external {
        rejecting = value;
    }
    function onFeeCredit(bytes32, address, uint8, uint256) external {}

    receive() external payable {
        require(!rejecting, "blocked recipient");
    }
}

contract LedgerInvariantHandler is Test {
    V3FeeLedger public immutable ledger;
    bytes32 public constant POOL = keccak256("ledger-invariant-pool");
    uint256 public funded;
    uint256[6] public paid;
    LedgerInvariantRecipient[6] public recipients;

    constructor(V3FeeLedger ledger_, LedgerInvariantRecipient[6] memory recipients_) {
        ledger = ledger_;
        recipients = recipients_;
    }

    function credit(uint96 seed) external {
        uint256 amount = bound(uint256(seed), 1, 1e24);
        vm.deal(address(this), amount);
        ledger.creditNative{value: amount}(POOL);
        funded += amount;
    }

    function claim(uint8 seed, uint96 amountSeed, bool reject) external {
        uint8 bucket = uint8(uint256(seed) % 6);
        uint256 available = ledger.accrued(POOL, bucket);
        if (available == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, available);
        LedgerInvariantRecipient recipient = recipients[bucket];
        recipient.setRejecting(reject);
        uint256 beforeBalance = address(recipient).balance;
        // Both reverting and false-returning pull APIs must preserve failed debt.
        try ledger.claim(POOL, bucket, amount) returns (bool) {} catch {}
        paid[bucket] += address(recipient).balance - beforeBalance;
        recipient.setRejecting(false);
    }
}

contract V3FeeLedgerInvariantTest is StdInvariant, Test {
    V3FeeLedger ledger;
    LedgerInvariantHandler handler;
    LedgerInvariantRecipient[6] recipients;

    function setUp() public {
        ledger = new V3FeeLedger(address(this), address(0));
        address[6] memory addresses;
        for (uint256 i; i < 6; ++i) {
            recipients[i] = new LedgerInvariantRecipient();
            addresses[i] = address(recipients[i]);
        }
        handler = new LedgerInvariantHandler(ledger, recipients);
        ledger.registerPool(handler.POOL(), address(0), 0, address(handler), addresses);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.credit.selector;
        selectors[1] = handler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantEveryReceivedUnitIsEitherHeldOrPaid() public view {
        uint256 paid;
        for (uint256 i; i < 6; ++i) {
            paid += handler.paid(i);
        }
        assertEq(address(ledger).balance + paid, handler.funded());
    }

    function invariantBucketFractionsAndClaimsConserveAllFees() public view {
        uint256 outstanding;
        uint256 fractions;
        for (uint256 i; i < 6; ++i) {
            outstanding += ledger.accrued(handler.POOL(), i);
            fractions += ledger.remainder(handler.POOL(), i);
            assertLt(ledger.remainder(handler.POOL(), i), 10_000);
        }
        assertLe(outstanding, address(ledger).balance);
        assertEq(outstanding * 10_000 + fractions, address(ledger).balance * 10_000);
    }
}

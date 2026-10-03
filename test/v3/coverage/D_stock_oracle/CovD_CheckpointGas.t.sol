// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {StockSystemBase} from "../../ReserveVault.t.sol";

/// @notice Scalability check for ReserveVault.checkpoint(): it hashes every result since the last checkpoint in
///         one call (no batch bound). Measures gas per pending result so the keeper's cadence can be sized against
///         the reserve chain's per-transaction gas cap. `_results` (slot 18) is grown with vm.store; zeroed entries
///         cost the same cold SLOADs as real ones.
contract CovDCheckpointGasTest is StockSystemBase {
    uint256 constant RESULTS_SLOT = 18;

    function _checkpointGas(uint256 pending) internal returns (uint256 used) {
        vm.store(address(vault), bytes32(RESULTS_SLOT), bytes32(pending));
        uint256 g = gasleft();
        vault.checkpoint();
        used = g - gasleft();
    }

    function testCovD_CheckpointGasIsLinearInPendingResults() public {
        uint256 snap = vm.snapshotState();
        uint256 g100 = _checkpointGas(100);
        vm.revertToState(snap);
        uint256 g1000 = _checkpointGas(1000);
        vm.revertToState(snap);
        uint256 g2000 = _checkpointGas(2000);
        uint256 perResult = (g2000 - g1000) / 1000;
        console2.log("checkpoint gas: 100 ->", g100);
        console2.log("checkpoint gas: 1000 ->", g1000);
        console2.log("checkpoint gas: 2000 ->", g2000);
        console2.log("marginal gas per pending result", perResult);
        console2.log("max pending results under a 32M gas tx", 32_000_000 / perResult);
        // linear, not quadratic: a result costs about the same in the 100..1000 and 1000..2000 bands
        assertApproxEqRel(perResult, (g1000 - g100) / 900, 0.2e18);
        // no partial checkpoint exists: past this many pending results the canonical lane cannot advance
        assertLt(perResult, 16_000);
    }
}

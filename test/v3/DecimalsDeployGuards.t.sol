// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {V3ReserveDeployer} from "../../script/v3/DeployV3Reserve.s.sol";

contract ReserveDeployerHarness is V3ReserveDeployer {
    function deploy(ReserveCfg memory c) external returns (ReserveOut memory) {
        return _deployReserve(c);
    }
}

/// @notice Decimals fix M5 (docs/PLAN-v3-contracts.md "位数修复"): on path 2a Relay pays USDG into ReserveVault as a
///         plain transfer — nobody calls fund(ref) — and Relay's output is 6-dp and may undershoot the 18-dp principal
///         (launcher allows <= 1%). Only the RH float executes those buys; ReserveVault otherwise waits for
///         funding[ref] >= amountIn forever. RH_FLOAT_ENABLED defaulted to false, so a mainnet deploy that forgot it
///         would queue every buy. The deployer now refuses it on Robinhood Chain (4663).
contract DecimalsDeployGuardsTest is Test {
    ReserveDeployerHarness h;

    function setUp() public {
        h = new ReserveDeployerHarness();
    }

    function test_rhMainnetReserveDeployRequiresFloat() public {
        vm.chainId(4663);
        V3ReserveDeployer.ReserveCfg memory c;
        c.floatEnabled = false;
        vm.expectRevert(bytes("RH mainnet (path 2a) needs RH_FLOAT_ENABLED"));
        h.deploy(c);
    }
}

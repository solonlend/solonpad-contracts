// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployV3} from "../../script/v3/DeployV3.s.sol";
import {VerifyV3} from "../../script/v3/VerifyV3.s.sol";
import {SolonStockHub} from "../../src/v3/stock/SolonStockHub.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";
import {ReserveVault} from "../../src/v3/stock/robinhood/ReserveVault.sol";

/// @dev DeployV3 with the r13 launch parameters (path 2a, 2026-10-01). The values are set on the config struct
///      (not through vm.setEnv, which is process-wide while suites run in parallel), exactly where DeployV3 reads
///      L_RUN_USD / HUB_FLOAT_ENABLED / HUB_FLOAT_SEED_USD / HUB_PAY_FLOOR_USD.
contract DeployV3FloatHarness is DeployV3 {
    function _loadPoolAConfig() internal override {
        (cfg.poolAPoolUsd, cfg.poolAStockUsd, cfg.poolAReserveUsd, cfg.poolASeedStockRaw) = (1000, 1000, 1000, 0);
        cfg.poolASeedUsd = 3000;
        (cfg.hubFloatEnabled, cfg.hubFloatSeedUsd, cfg.hubPayFloorUsd, cfg.lRunUsd) = (true, 2000, 2000, 1000);
    }

    function addr(string memory name) external view returns (address a) {
        a = deployed[name];
        require(a != address(0), name);
    }

    function manifest() external view returns (string memory) {
        return manifestJson;
    }
}

contract DeployV3FloatModeTest is Test {
    uint256 constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // anvil #0
    DeployV3FloatHarness h;

    function setUp() public {
        vm.chainId(31337);
        vm.setEnv("LOCAL_STANDINS", "true");
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(bytes32(DEPLOYER_PK)));
        vm.warp(1_790_000_000);
        vm.deal(vm.addr(DEPLOYER_PK), 100_000 ether);
        h = new DeployV3FloatHarness();
        h.run();
    }

    function test_launchParams_floatsOn_lRun1000_payFloor2000_seeded() public view {
        SolonStockHub hub = SolonStockHub(payable(h.addr("SolonStockHub")));
        CapacityController cap = CapacityController(h.addr("CapacityController"));
        assertTrue(hub.floatEnabled(), "hub float on");
        assertEq(hub.available(), 2_000 ether, "hub float = deployer seed");
        assertEq(hub.escrowed(), 0, "nothing escrowed");
        assertEq(hub.payAllowance(), 2_000 ether, "daily float advance = max($2,000, 20% of $2,000)");
        assertEq(cap.lRun(), 1_000e18, "L_run $1,000");
        assertEq(cap.uRun(), 1_000_000e18, "uRun unchanged");
        assertEq(cap.totalCap(), 1_000_000e18, "total cap unchanged");
        (uint256 pl,,, uint64 eta) = cap.pendingLimits();
        assertEq(pl + eta, 0, "no pending raise");
        assertTrue(ReserveVault(payable(h.addr("ReserveVault"))).floatEnabled(), "local reserve follows the hub setting");
    }

    function test_lRun_capsSingleOrders_guardianLowersMore_raiseIs48h() public {
        CapacityController cap = CapacityController(h.addr("CapacityController"));
        cap.checkRun(1_000e18);
        vm.expectRevert(CapacityController.RunLimit.selector);
        cap.checkRun(1_000e18 + 1);
        (address guardian, address owner, uint256 uRun, uint256 total) = (cap.guardian(), cap.owner(), cap.uRun(), cap.totalCap());
        vm.prank(guardian);
        cap.lowerLimits(500e18, uRun, total);
        assertEq(cap.lRun(), 500e18, "guardian lowers at once");
        vm.prank(owner);
        cap.proposeLimits(1_000e18, uRun, total);
        vm.prank(owner);
        vm.expectRevert(CapacityController.Timelocked.selector);
        cap.executeLimits();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        cap.executeLimits();
        assertEq(cap.lRun(), 1_000e18, "raise back after 48h");
    }

    function test_verifyV3_assertsTheFloatLaunch() public {
        VerifyV3 v = new VerifyV3();
        v.runWith(h.manifest()); // not MANIFEST_JSON: process-wide, DeployV3ConfigTest uses it in parallel
        assertEq(v.checks() + v.reserveChecks(), 343, "VerifyV3 check count (float mode)");
    }
}

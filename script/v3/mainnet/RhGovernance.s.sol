// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {V3Governance} from "../../../src/v3/governance/V3Governance.sol";

interface IOwnable2Step {
    function acceptOwnership() external;
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/// @notice Mainnet: the "RH timelock" that DeployV3Reserve / DeployV3PriceSender hand ownership to. It is the same
///   audited V3Governance as on Arc (48h floor, proposer = 3/5 Safe, guardian = 2/3 Safe, open executor), deployed by
///   the deployer EOA with a short bootstrap so the two-step ownerships can be accepted at deploy time instead of a
///   48h operation. No contract change: this script only instantiates the existing contract.
///   Env: DEPLOYER_PRIVATE_KEY, MULTISIG, GUARDIAN, BOOTSTRAP_WINDOW (default 1 day).
contract DeployRhGovernance is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 deadline = block.timestamp + vm.envOr("BOOTSTRAP_WINDOW", uint256(1 days));
        vm.startBroadcast(pk);
        V3Governance gov = new V3Governance(vm.envAddress("MULTISIG"), vm.envAddress("GUARDIAN"), deployer, deadline);
        vm.stopBroadcast();
        console2.log("RhGovernance", address(gov));
    }
}

/// @notice Accepts ReserveVault + StockPriceSender ownership through the RH governance bootstrap, then closes the
///   bootstrap for good. Env: DEPLOYER_PRIVATE_KEY, RH_GOVERNANCE, RESERVE_VAULT, PRICE_SENDER.
contract AcceptRhOwnership is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        V3Governance gov = V3Governance(payable(vm.envAddress("RH_GOVERNANCE")));
        address vault = vm.envAddress("RESERVE_VAULT");
        address sender = vm.envAddress("PRICE_SENDER");
        require(IOwnable2Step(vault).pendingOwner() == address(gov), "vault pendingOwner != RH governance");
        require(IOwnable2Step(sender).pendingOwner() == address(gov), "sender pendingOwner != RH governance");
        vm.startBroadcast(pk);
        gov.bootstrapCall(vault, abi.encodeCall(IOwnable2Step.acceptOwnership, ()));
        gov.bootstrapCall(sender, abi.encodeCall(IOwnable2Step.acceptOwnership, ()));
        gov.closeBootstrap();
        vm.stopBroadcast();
        require(IOwnable2Step(vault).owner() == address(gov), "vault owner");
        require(IOwnable2Step(sender).owner() == address(gov), "sender owner");
        require(gov.bootstrapClosed(), "bootstrap open");
        console2.log("RH ownership accepted + bootstrap closed", address(gov));
    }
}

/// @notice Read-only check of the RH governance (run after AcceptRhOwnership).
contract VerifyRhGovernance is Script {
    function run() external view {
        V3Governance gov = V3Governance(payable(vm.envAddress("RH_GOVERNANCE")));
        address multisig = vm.envAddress("MULTISIG");
        address guardian = vm.envAddress("GUARDIAN");
        uint256 n;
        n += _ok(gov.getMinDelay() == 48 hours, "RH gov delay 48h");
        n += _ok(gov.hasRole(gov.PROPOSER_ROLE(), multisig), "RH gov proposer = multisig");
        n += _ok(gov.hasRole(gov.CANCELLER_ROLE(), multisig), "RH gov canceller = multisig");
        n += _ok(gov.hasRole(gov.GUARDIAN_ROLE(), guardian), "RH gov guardian");
        n += _ok(gov.hasRole(gov.EXECUTOR_ROLE(), address(0)), "RH gov open executor");
        n += _ok(!gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), gov.bootstrapper()), "RH gov: deployer is not admin");
        n += _ok(gov.bootstrapClosed(), "RH gov bootstrap closed");
        n += _ok(IOwnable2Step(vm.envAddress("RESERVE_VAULT")).owner() == address(gov), "ReserveVault owner = RH gov");
        n += _ok(IOwnable2Step(vm.envAddress("PRICE_SENDER")).owner() == address(gov), "StockPriceSender owner = RH gov");
        console2.log("VerifyRhGovernance checks passed:", n);
    }

    function _ok(bool c, string memory what) internal pure returns (uint256) {
        require(c, what);
        return 1;
    }
}

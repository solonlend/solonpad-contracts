// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IOwnable2Step {
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

/// @notice Hands every owned Radian contract to a multisig: the four Pons V2
/// contracts (Factory, Hook, Vault, Locker) plus RadianStaking and
/// RadianTreasury. All six are Ownable2Step, so this only sets the PENDING
/// owner — the multisig must then call `acceptOwnership()` on each address.
/// Run this AFTER the mainnet smoke test passes, launch is enabled, and the
/// flywheel is wired (hook.protocolFeeRecipient == treasury). Follow with
/// `VerifyOwnership.s.sol` once the multisig has accepted.
///
/// Env: PRIVATE_KEY (current owner/deployer), MULTISIG (Gnosis Safe address),
///      FACTORY, HOOK, VAULT, LOCKER, STAKING, TREASURY (deployed addresses).
contract TransferOwnership is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address multisig = vm.envAddress("MULTISIG");
        require(multisig != address(0), "set MULTISIG");
        require(multisig.code.length > 0, "MULTISIG must be a contract (Safe) - an EOA typo here is unrecoverable");

        address[6] memory targets = [
            vm.envAddress("FACTORY"),
            vm.envAddress("HOOK"),
            vm.envAddress("VAULT"),
            vm.envAddress("LOCKER"),
            vm.envAddress("STAKING"),
            vm.envAddress("TREASURY")
        ];
        string[6] memory names = ["Factory", "Hook", "Vault", "Locker", "RadianStaking", "RadianTreasury"];

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < targets.length; i++) {
            require(IOwnable2Step(targets[i]).owner() == vm.addr(pk), string.concat(names[i], ": deployer is not the owner"));
            IOwnable2Step(targets[i]).transferOwnership(multisig);
            console.log(names[i], "pending owner ->", IOwnable2Step(targets[i]).pendingOwner());
        }
        vm.stopBroadcast();

        console.log("");
        console.log("Pending owner set to multisig on all 6 contracts.");
        console.log("ACTION REQUIRED: the multisig must call acceptOwnership() on each:");
        for (uint256 i = 0; i < targets.length; i++) {
            console.log("  ", names[i], targets[i]);
        }
        console.log("Then run VerifyOwnership.s.sol.");
    }
}

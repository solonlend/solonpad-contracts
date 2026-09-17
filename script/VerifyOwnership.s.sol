// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IOwned {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
}

interface IHookView {
    function protocolFeeRecipient() external view returns (address);
}

interface ITreasuryView {
    function staking() external view returns (address);
    function keeper() external view returns (address);
}

interface IStakingView {
    function rewardsDistributor() external view returns (address);
}

/// @notice Read-only post-handover check. Reverts loudly if any owned contract
/// is not owned by MULTISIG, if a handover is still pending, or if the flywheel
/// is not wired (hook -> treasury -> staking -> treasury). Run with
/// `forge script script/VerifyOwnership.s.sol --rpc-url <chain>` (no broadcast).
///
/// Env: MULTISIG, FACTORY, HOOK, VAULT, LOCKER, STAKING, TREASURY.
contract VerifyOwnership is Script {
    function run() external view {
        address multisig = vm.envAddress("MULTISIG");
        address[6] memory targets = [
            vm.envAddress("FACTORY"),
            vm.envAddress("HOOK"),
            vm.envAddress("VAULT"),
            vm.envAddress("LOCKER"),
            vm.envAddress("STAKING"),
            vm.envAddress("TREASURY")
        ];
        string[6] memory names = ["Factory", "Hook", "Vault", "Locker", "RadianStaking", "RadianTreasury"];

        bool ok = true;
        for (uint256 i = 0; i < targets.length; i++) {
            address o = IOwned(targets[i]).owner();
            address p = IOwned(targets[i]).pendingOwner();
            bool good = o == multisig && p == address(0);
            console.log(good ? "OK  " : "FAIL", names[i], o);
            if (p != address(0)) console.log("     pending owner still set:", p);
            ok = ok && good;
        }

        address hook = targets[1];
        address staking = targets[4];
        address treasury = targets[5];
        bool wired = IHookView(hook).protocolFeeRecipient() == treasury && ITreasuryView(treasury).staking() == staking
            && IStakingView(staking).rewardsDistributor() == treasury;
        console.log(wired ? "OK  " : "FAIL", "flywheel wiring hook->treasury->staking->treasury");
        console.log("     treasury keeper:", ITreasuryView(treasury).keeper());
        ok = ok && wired;

        require(ok, "ownership/wiring check FAILED (see log)");
        console.log("All six contracts owned by the multisig; flywheel wired.");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V3QuoteFeeHook, IV3HookFeeLedger} from "../../src/v3/V3QuoteFeeHook.sol";

/// @notice CREATE2 mining shared by local tests and deployment preparation.
library V3HookMiner {
    uint160 internal constant MASK = 0x3fff;
    uint160 internal constant FLAGS = 0x28cc;
    error SaltNotFound();

    function find(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        internal
        view
        returns (address candidate, bytes32 salt)
    {
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            candidate =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (uint160(candidate) & MASK == FLAGS && candidate.code.length == 0) return (candidate, salt);
        }
        revert SaltNotFound();
    }
}

/// @notice Dry-run only: computes salt/address; never broadcasts or deploys.
/// @dev Set CREATE2_DEPLOYER, POOL_MANAGER, V3_FACTORY, V3_FEE_LEDGER.
/// SALT_START and SALT_ATTEMPTS default to 0 and 1,000,000. Constructor arguments,
/// compiler settings and exact creation bytecode MUST match the eventual deployment.
contract MineV3Hook is Script {
    function run() external view returns (address mined, bytes32 salt, bytes32 initCodeHash) {
        bytes memory initCode = abi.encodePacked(
            type(V3QuoteFeeHook).creationCode,
            abi.encode(
                IPoolManager(vm.envAddress("POOL_MANAGER")),
                vm.envAddress("V3_FACTORY"),
                IV3HookFeeLedger(vm.envAddress("V3_FEE_LEDGER"))
            )
        );
        initCodeHash = keccak256(initCode);
        (mined, salt) = V3HookMiner.find(
            vm.envAddress("CREATE2_DEPLOYER"),
            initCodeHash,
            vm.envOr("SALT_START", uint256(0)),
            vm.envOr("SALT_ATTEMPTS", uint256(1_000_000))
        );
        console2.log("Hook address", mined);
        console2.log("Salt");
        console2.logBytes32(salt);
        console2.log("Init code hash");
        console2.logBytes32(initCodeHash);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LaunchDeployer} from "../src/v2/PonsV2LaunchDeployer.sol";
import {PonsV2GraduationExecutor} from "../src/v2/PonsV2GraduationExecutor.sol";
import {PonsV2LaunchLocker} from "../src/v2/PonsV2LaunchLocker.sol";
import {PonsV2BuybackVault} from "../src/v2/PonsV2BuybackVault.sol";
import {PonsV2FeeEscrow} from "../src/v2/PonsV2FeeEscrow.sol";
import {PonsV2MemeHook} from "../src/v2/hooks/PonsV2MemeHook.sol";

/// @notice Mainnet deploy: wires the verified Pons V2 suite to Arc's CANONICAL
/// Uniswap V4 (Uniswap ships v4 on Arc mainnet), so we deploy no V4 base and
/// no test router. Everything is env-parameterised so the same script runs on
/// mainnet or a fork with different addresses/params.
///
/// Required env:
///   PRIVATE_KEY       deployer key (fresh, funded with mainnet USDC)
///   POOL_MANAGER      canonical Arc v4 PoolManager
///   POSITION_MANAGER  canonical Arc v4 PositionManager
/// Optional env (sane production defaults):
///   PERMIT2           default canonical 0x000000000022D473030F116dDEE9F6B43aC78BA3
///   PROTOCOL_RECIPIENT default = deployer (change to treasury/multisig)
///   LAUNCH_FEE_USDC   default 1      (native USDC, 18-dec)
///   PHANTOM_USDC      default 4000   (opening virtual reserve)
///   GRADUATION_USDC   default 10000  (real reserve to graduate)  [keeps Pons 2.5:1 shape]
contract DeployMainnet is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant SUPPLY = 1_000_000_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envOr("PERMIT2", address(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        address protocolRecipient = vm.envOr("PROTOCOL_RECIPIENT", owner);

        uint256 launchFee = vm.envOr("LAUNCH_FEE_USDC", uint256(1)) * 1e18;
        uint256 phantom = vm.envOr("PHANTOM_USDC", uint256(4_000)) * 1e18;
        uint256 graduation = vm.envOr("GRADUATION_USDC", uint256(10_000)) * 1e18;

        require(poolManager != address(0) && positionManager != address(0), "set POOL_MANAGER/POSITION_MANAGER");

        vm.startBroadcast(pk);

        PonsV2FeeEscrow feeEscrow = new PonsV2FeeEscrow();

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory hookInitcode = abi.encodePacked(
            type(PonsV2MemeHook).creationCode,
            abi.encode(IPoolManager(poolManager), feeEscrow, protocolRecipient, owner)
        );
        bytes32 salt = _mineHookSalt(hookInitcode, flags);
        PonsV2MemeHook hook =
            new PonsV2MemeHook{salt: salt}(IPoolManager(poolManager), feeEscrow, protocolRecipient, owner);
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags, "hook flags mismatch");

        PonsV2BuybackVault vault = new PonsV2BuybackVault(owner, hook, feeEscrow);
        PonsV2LaunchLocker locker = new PonsV2LaunchLocker(owner, positionManager);
        PonsV2LaunchFactory factory = new PonsV2LaunchFactory(
            owner,
            IPoolManager(poolManager),
            IPositionManager(positionManager),
            IAllowanceTransfer(permit2),
            locker,
            hook,
            feeEscrow,
            vault,
            launchFee
        );
        PonsV2GraduationExecutor executor = new PonsV2GraduationExecutor(
            IPositionManager(positionManager), IAllowanceTransfer(permit2), locker, address(factory)
        );
        PonsV2LaunchDeployer launchDeployer = new PonsV2LaunchDeployer(address(factory));

        factory.setGraduationExecutor(executor);
        factory.setLaunchDeployer(launchDeployer);
        hook.setFactory(address(factory));
        hook.setBuybackVault(vault);
        locker.setFactory(address(factory));
        vault.setFactory(address(factory));

        factory.addLaunchConfig(
            PonsV2LaunchFactory.LaunchConfig({
                supply: SUPPLY,
                curveFeeBps: 100,
                phantomQuote: phantom,
                graduationThreshold: graduation,
                poolFee: 0,
                tickSpacing: 200,
                enabled: true
            })
        );
        // On a chain where the native gas coin is NOT USDC (Base=ETH, BSC=BNB…),
        // approve that chain's USDC ERC-20 as a quote asset so launches keep the
        // "priced in real dollars" USP. Set QUOTE_TOKEN to the chain's USDC.
        // (On Arc, USDC is native — leave QUOTE_TOKEN unset.)
        address quoteToken = vm.envOr("QUOTE_TOKEN", address(0));
        if (quoteToken != address(0)) {
            uint8 qd = uint8(vm.envOr("QUOTE_DECIMALS", uint256(6)));
            uint256 qPhantom = vm.envOr("QUOTE_PHANTOM_USDC", uint256(4_000)) * (10 ** qd);
            uint256 qGrad = vm.envOr("QUOTE_GRADUATION_USDC", uint256(10_000)) * (10 ** qd);
            factory.setPairTokenEconomics(quoteToken, qPhantom, qGrad, qd);
            factory.setPairTokenApproved(quoteToken, true);
            console.log("approved USDC quote token:", quoteToken, "decimals", qd);
        }

        // Launch DISABLED at deploy — enable only after the smoke test passes.
        factory.setLaunchEnabled(false);

        vm.stopBroadcast();

        console.log("== Radian Pons V2 on Arc MAINNET ==");
        console.log("owner (deployer):   ", owner);
        console.log("protocolRecipient:  ", protocolRecipient);
        console.log("PoolManager (canon):", poolManager);
        console.log("PositionMgr (canon):", positionManager);
        console.log("Permit2:            ", permit2);
        console.log("PonsV2FeeEscrow:    ", address(feeEscrow));
        console.log("PonsV2MemeHook:     ", address(hook));
        console.log("PonsV2BuybackVault: ", address(vault));
        console.log("PonsV2LaunchLocker: ", address(locker));
        console.log("PonsV2LaunchFactory:", address(factory));
        console.log("GraduationExecutor: ", address(executor));
        console.log("LaunchDeployer:     ", address(launchDeployer));
        console.log("launchFee/phantom/grad:", launchFee, phantom, graduation);
        console.log("NEXT: smoke-test, then setLaunchEnabled(true), then transfer ownership to multisig");
    }

    function _mineHookSalt(bytes memory initcode, uint160 flags) internal pure returns (bytes32) {
        bytes32 initHash = keccak256(initcode);
        for (uint256 i = 0; i < 500_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags) return salt;
        }
        revert("no salt found");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2LaunchDeployer} from "../src/v2/PonsV2LaunchDeployer.sol";
import {PonsV2GraduationExecutor} from "../src/v2/PonsV2GraduationExecutor.sol";
import {PonsV2LaunchLocker} from "../src/v2/PonsV2LaunchLocker.sol";
import {PonsV2BuybackVault} from "../src/v2/PonsV2BuybackVault.sol";
import {PonsV2FeeEscrow} from "../src/v2/PonsV2FeeEscrow.sol";
import {PonsV2MemeHook} from "../src/v2/hooks/PonsV2MemeHook.sol";

/// Deploys the full Pons V2 stack to Arc testnet: Uniswap V4 base
/// (PoolManager + PositionManager, reusing canonical Permit2) plus the
/// verified Pons V2 suite, quoted in Arc's native USDC.
contract DeployPonsV2 is Script {
    // Canonical deployments already live on Arc testnet.
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // forge's deterministic CREATE2 deployer (exists on Arc), used for {salt:} deploys.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Launch economics for Arc testnet, in 18-dec native USDC units.
    // Curve shape matches production Robinhood Chain config (4.2 : 1.68),
    // scaled so a faucet wallet can graduate a launch: 20 : 8.
    uint256 constant LAUNCH_FEE = 1e18;
    uint256 constant PHANTOM = 8e18;
    uint256 constant GRADUATION = 20e18;
    uint256 constant SUPPLY = 1_000_000_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);

        PoolManager poolManager = new PoolManager(owner);
        PositionManager positionManager = new PositionManager(
            IPoolManager(address(poolManager)),
            IAllowanceTransfer(PERMIT2),
            300_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        PonsV2FeeEscrow feeEscrow = new PonsV2FeeEscrow();

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory hookInitcode = abi.encodePacked(
            type(PonsV2MemeHook).creationCode, abi.encode(IPoolManager(address(poolManager)), feeEscrow, owner, owner)
        );
        bytes32 salt = _mineHookSalt(hookInitcode, flags);
        PonsV2MemeHook hook =
            new PonsV2MemeHook{salt: salt}(IPoolManager(address(poolManager)), feeEscrow, owner, owner);
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags, "hook flags mismatch");

        PonsV2BuybackVault vault = new PonsV2BuybackVault(owner, hook, feeEscrow);
        PonsV2LaunchLocker locker = new PonsV2LaunchLocker(owner, address(positionManager));
        PonsV2LaunchFactory factory = new PonsV2LaunchFactory(
            owner,
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            IAllowanceTransfer(PERMIT2),
            locker,
            hook,
            feeEscrow,
            vault,
            LAUNCH_FEE
        );
        PonsV2GraduationExecutor executor = new PonsV2GraduationExecutor(
            IPositionManager(address(positionManager)), IAllowanceTransfer(PERMIT2), locker, address(factory)
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
                phantomQuote: PHANTOM,
                graduationThreshold: GRADUATION,
                poolFee: 0,
                tickSpacing: 200,
                enabled: true
            })
        );
        factory.setLaunchEnabled(true);

        vm.stopBroadcast();

        console.log("PoolManager:        ", address(poolManager));
        console.log("PositionManager:    ", address(positionManager));
        console.log("PoolSwapTest:       ", address(swapRouter));
        console.log("PonsV2FeeEscrow:    ", address(feeEscrow));
        console.log("PonsV2MemeHook:     ", address(hook));
        console.log("PonsV2BuybackVault: ", address(vault));
        console.log("PonsV2LaunchLocker: ", address(locker));
        console.log("PonsV2LaunchFactory:", address(factory));
        console.log("GraduationExecutor: ", address(executor));
        console.log("LaunchDeployer:     ", address(launchDeployer));
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

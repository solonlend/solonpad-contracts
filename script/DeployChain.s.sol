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
import {RadianLaunchRouter} from "../src/radian/RadianLaunchRouter.sol";
import {RadianExecutor} from "../src/radian/RadianExecutor.sol";
import {WallTreasury} from "../src/radian/wall/WallTreasury.sol";
import {WallStaking} from "../src/radian/wall/WallStaking.sol";
import {PoFVault} from "../src/radian/pof/PoFVault.sol";
import {MockStock} from "../src/mock/MockStock.sol";
import {MockUSD} from "../src/mock/MockUSD.sol";

/// @notice One-shot deploy of the whole Radian stack on any EVM chain that has
/// canonical Uniswap V4 + Permit2: the verified Pons V2 suite, the launch router
/// with the three templates, the delegated-buy executor, and (testnets only)
/// dollar / stock stand-ins approved as quote assets. All amounts are in wei of
/// the chain's native coin, so the same script serves an ETH-gas chain
/// (Robinhood) and a USDC-gas chain (Arc).
///
/// Required env:
///   PRIVATE_KEY, POOL_MANAGER, POSITION_MANAGER
///   LAUNCH_FEE_WEI, PHANTOM_WEI, GRADUATION_WEI   native-quote launch config
/// Optional env:
///   PERMIT2 (canonical default), PROTOCOL_RECIPIENT (= deployer), KEEPER (= deployer)
///   ENABLE_LAUNCH=true|false (default false — enable after the smoke test)
///   DEPLOY_STANDINS=true      deploy MockUSD "USDGx" (6-dec) + MockStock NVDAx/TSLAx/AAPLx and approve them
///   QUOTE_TOKEN + QUOTE_DECIMALS + QUOTE_PHANTOM_RAW + QUOTE_GRADUATION_RAW   approve a real ERC-20 dollar quote (mainnet)
contract DeployChain is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant SUPPLY = 1_000_000_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envOr("PERMIT2", address(0x000000000022D473030F116dDEE9F6B43aC78BA3));
        address protocolRecipient = vm.envOr("PROTOCOL_RECIPIENT", owner);
        address keeper = vm.envOr("KEEPER", owner);
        uint256 launchFee = vm.envUint("LAUNCH_FEE_WEI");
        uint256 phantom = vm.envUint("PHANTOM_WEI");
        uint256 graduation = vm.envUint("GRADUATION_WEI");
        bool enable = vm.envOr("ENABLE_LAUNCH", false);
        bool standins = vm.envOr("DEPLOY_STANDINS", false);
        require(poolManager.code.length > 0 && positionManager.code.length > 0, "no V4 at those addresses");
        require(permit2.code.length > 0, "no Permit2");

        vm.startBroadcast(pk);

        // ---- Pons V2 suite against the chain's canonical V4 ----
        PonsV2FeeEscrow feeEscrow = new PonsV2FeeEscrow();
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        bytes memory hookInitcode =
            abi.encodePacked(type(PonsV2MemeHook).creationCode, abi.encode(IPoolManager(poolManager), feeEscrow, protocolRecipient, owner));
        bytes32 salt = _mineHookSalt(hookInitcode, flags);
        PonsV2MemeHook hook = new PonsV2MemeHook{salt: salt}(IPoolManager(poolManager), feeEscrow, protocolRecipient, owner);
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags, "hook flags mismatch");

        PonsV2BuybackVault vault = new PonsV2BuybackVault(owner, hook, feeEscrow);
        PonsV2LaunchLocker locker = new PonsV2LaunchLocker(owner, positionManager);
        PonsV2LaunchFactory factory = new PonsV2LaunchFactory(
            owner, IPoolManager(poolManager), IPositionManager(positionManager), IAllowanceTransfer(permit2), locker, hook, feeEscrow, vault, launchFee
        );
        PonsV2GraduationExecutor executor =
            new PonsV2GraduationExecutor(IPositionManager(positionManager), IAllowanceTransfer(permit2), locker, address(factory));
        PonsV2LaunchDeployer launchDeployer = new PonsV2LaunchDeployer(address(factory));

        factory.setGraduationExecutor(executor);
        factory.setLaunchDeployer(launchDeployer);
        hook.setFactory(address(factory));
        hook.setBuybackVault(vault);
        locker.setFactory(address(factory));
        vault.setFactory(address(factory));
        factory.addLaunchConfig(
            PonsV2LaunchFactory.LaunchConfig({
                supply: SUPPLY, curveFeeBps: 100, phantomQuote: phantom, graduationThreshold: graduation, poolFee: 0, tickSpacing: 200, enabled: true
            })
        );

        // ---- templates + delegated buys ----
        address wallTreasuryImpl = address(new WallTreasury());
        address wallStakingImpl = address(new WallStaking());
        address pofVaultImpl = address(new PoFVault());
        RadianLaunchRouter router = new RadianLaunchRouter(factory, wallTreasuryImpl, wallStakingImpl, pofVaultImpl);
        factory.setLaunchForwarder(address(router));
        router.setKeeper(keeper);
        RadianExecutor ex = new RadianExecutor(factory);
        ex.setKeeper(keeper);

        // ---- quote assets ----
        address quoteToken = vm.envOr("QUOTE_TOKEN", address(0));
        if (quoteToken != address(0)) {
            uint8 qd = uint8(vm.envUint("QUOTE_DECIMALS"));
            factory.setPairTokenEconomics(quoteToken, vm.envUint("QUOTE_PHANTOM_RAW"), vm.envUint("QUOTE_GRADUATION_RAW"), qd);
            factory.setPairTokenApproved(quoteToken, true);
            console.log("approved quote token:", quoteToken);
        }
        address usd;
        address[3] memory stocks;
        if (standins) {
            MockUSD u = new MockUSD("Global Dollar (Radian testnet stand-in)", "USDGx");
            usd = address(u);
            factory.setPairTokenEconomics(usd, 4_000e6, 10_000e6, 6);
            factory.setPairTokenApproved(usd, true);
            string[3] memory names = ["Nvidia (Radian testnet stand-in)", "Tesla (Radian testnet stand-in)", "Apple (Radian testnet stand-in)"];
            string[3] memory syms = ["NVDAx", "TSLAx", "AAPLx"];
            for (uint256 i = 0; i < 3; i++) {
                MockStock st = new MockStock(names[i], syms[i]);
                stocks[i] = address(st);
                factory.setPairTokenEconomics(address(st), 20e18, 50e18, 18);
                factory.setPairTokenApproved(address(st), true);
            }
        }

        factory.setLaunchEnabled(enable);
        vm.stopBroadcast();

        console.log("== Radian on chain", block.chainid, "==");
        console.log("owner/deployer:     ", owner);
        console.log("PonsV2FeeEscrow:    ", address(feeEscrow));
        console.log("PonsV2MemeHook:     ", address(hook));
        console.log("PonsV2BuybackVault: ", address(vault));
        console.log("PonsV2LaunchLocker: ", address(locker));
        console.log("PonsV2LaunchFactory:", address(factory));
        console.log("GraduationExecutor: ", address(executor));
        console.log("LaunchDeployer:     ", address(launchDeployer));
        console.log("RadianLaunchRouter: ", address(router));
        console.log("PoFRouter:          ", address(router.pofRouter()));
        console.log("WallTreasury impl:  ", wallTreasuryImpl);
        console.log("WallStaking impl:   ", wallStakingImpl);
        console.log("PoFVault impl:      ", pofVaultImpl);
        console.log("RadianExecutor:     ", address(ex));
        console.log("keeper:             ", keeper);
        console.log("launchFee/phantom/grad (wei):", launchFee, phantom, graduation);
        console.log("launch enabled:     ", enable);
        if (standins) {
            console.log("USDGx (6-dec stand-in):", usd);
            console.log("NVDAx / TSLAx / AAPLx:", stocks[0], stocks[1], stocks[2]);
        }
    }

    function _mineHookSalt(bytes memory initcode, uint160 flags) internal pure returns (bytes32) {
        bytes32 initHash = keccak256(initcode);
        for (uint256 i = 0; i < 500_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags) return salt;
        }
        revert("no salt found");
    }
}

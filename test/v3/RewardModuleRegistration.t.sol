// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {StockAdapterRegistry} from "../../src/v3/StockAdapterRegistry.sol";

contract RewardRegistrationModule {
    function register(RewardPayoutVault payout, RewardRoundManager rounds, address source, bytes32 pool) external {
        payout.registerSource(source);
        rounds.registerSource(source, pool);
    }
}

contract ModuleOwnedSource {}

contract RewardModuleRegistrationTest is Test {
    function testFixedModulesRegisterNewRewardSourcesWithoutOngoingAdmin() public {
        EligibilityController controller = new EligibilityController(address(this));
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), controller);
        StockAdapterRegistry registry = new StockAdapterRegistry(address(this));
        RewardRoundManager rounds =
            new RewardRoundManager(address(this), address(registry), address(payout), address(77));
        RewardRegistrationModule desk = new RewardRegistrationModule();
        RewardRegistrationModule staking = new RewardRegistrationModule();
        bytes memory data =
            abi.encodeWithSignature("configureRewardModules(address,address)", address(desk), address(staking));
        (bool ok,) = address(payout).call(data);
        assertTrue(ok);
        (ok,) = address(rounds).call(data);
        assertTrue(ok);
        address source = address(new ModuleOwnedSource());
        bytes32 pool = keccak256("source");
        staking.register(payout, rounds, source, pool);
        assertTrue(payout.trustedSource(source));
        assertEq(rounds.sourcePool(source), pool);
        address unauthorizedSource = address(new ModuleOwnedSource());
        vm.prank(address(42));
        vm.expectRevert();
        payout.registerSource(unauthorizedSource);
        (ok,) = address(payout).call(data);
        assertFalse(ok);
        (ok,) = address(rounds).call(data);
        assertFalse(ok);
    }
}

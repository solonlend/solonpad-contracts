// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {EligibilityController} from "../../../../src/v3/EligibilityController.sol";
import {EligibilityRegistry} from "../../../../src/v3/EligibilityRegistry.sol";
import {StockAdapterRegistry} from "../../../../src/v3/StockAdapterRegistry.sol";
import {CovBStatus} from "./CovBHelpers.sol";

/// @notice Reward module stand-in for EligibilityRegistry pool binding + notification.
contract CovBEligModule {
    uint256 public notified;

    function bind(EligibilityRegistry r, address w) external {
        r.bindRewardPool(w);
    }

    function onEligibilityChange(address) external {
        ++notified;
    }
}

contract CovBEligibilityControllerTest is Test {
    EligibilityController controller;
    CovBStatus status;
    address stock = address(new CovBStatus()); // any address with code
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(10 days);
        controller = new EligibilityController(address(this));
        status = new CovBStatus();
    }

    function _enable() internal {
        controller.scheduleEnable(address(status), status.POLICY(), 13);
        vm.warp(13 days);
        assertTrue(controller.enabled());
    }

    /// line 35: constructor rejects zero governance (both arms).
    function testConstructorRequiresGovernance() public {
        vm.expectRevert();
        new EligibilityController(address(0));
        EligibilityController c = new EligibilityController(bob);
        assertEq(c.governance(), bob);
    }

    /// lines 21, 52, 74 (+40): every governance entrypoint rejects other callers with Unauthorized.
    function testGovernanceOnlyEntrypoints() public {
        vm.startPrank(bob);
        vm.expectRevert(EligibilityController.Unauthorized.selector);
        controller.bindSystemVault(stock, 1);
        vm.expectRevert(EligibilityController.Unauthorized.selector);
        controller.cancelEnable();
        vm.expectRevert(EligibilityController.Unauthorized.selector);
        controller.bindAsset(stock, 0);
        vm.expectRevert(EligibilityController.Unauthorized.selector);
        controller.scheduleEnable(address(status), bytes32(uint256(1)), 13);
        vm.stopPrank();
        assertEq(controller.systemVaultMask(stock), 0);
        assertEq(controller.assetIds(stock), 0);
        assertEq(controller.effectiveEpoch(), 0);
    }

    /// line 22 require arms: vault must have code, mask nonzero, not yet bound, and B-mode schedule unset.
    function testBindSystemVaultRules() public {
        vm.expectRevert(bytes("system vault"));
        controller.bindSystemVault(alice, 1); // EOA
        vm.expectRevert(bytes("system vault"));
        controller.bindSystemVault(stock, 0);
        controller.bindSystemVault(stock, 3);
        assertEq(controller.systemVaultMask(stock), 3);
        vm.expectRevert(bytes("system vault"));
        controller.bindSystemVault(stock, 1);
        controller.scheduleEnable(address(status), status.POLICY(), 13);
        vm.expectRevert(bytes("system vault"));
        controller.bindSystemVault(address(status), 1);
    }

    /// line 53: cancel only a scheduled, not-yet-effective switch.
    function testCancelEnableLifecycle() public {
        vm.expectRevert(EligibilityController.InvalidSchedule.selector);
        controller.cancelEnable();
        controller.scheduleEnable(address(status), status.POLICY(), 13);
        controller.cancelEnable();
        assertEq(controller.effectiveEpoch(), 0);
        assertEq(controller.registry(), address(0));
        assertEq(controller.policyHash(), bytes32(0));
        _enable();
        vm.expectRevert(EligibilityController.InvalidSchedule.selector);
        controller.cancelEnable();
        assertEq(controller.effectiveEpoch(), 13);
    }

    /// never-called modeGeneration(): 0 in B mode, 1 once A is effective.
    function testModeGeneration() public {
        assertEq(controller.modeGeneration(), 0);
        controller.scheduleEnable(address(status), status.POLICY(), 13);
        assertEq(controller.modeGeneration(), 0, "scheduled is not effective");
        vm.warp(13 days);
        assertEq(controller.modeGeneration(), 1);
        assertTrue(controller.eligibilityEnabled());
    }

    /// line 75: bindAsset rejects zero asset / rebinding / after the switch is scheduled.
    function testBindAssetRules() public {
        vm.expectRevert();
        controller.bindAsset(address(0), 1);
        controller.bindAsset(stock, 1);
        assertEq(controller.assetIds(stock), 2);
        vm.expectRevert();
        controller.bindAsset(stock, 2);
        controller.scheduleEnable(address(status), status.POLICY(), 13);
        vm.expectRevert();
        controller.bindAsset(address(status), 0);
    }

    /// lines 82-83: trade checks are skipped in B mode / for native quote, enforced on BOTH payer and recipient in A.
    function testCheckTradeEnforcesPayerAndRecipient() public {
        controller.bindAsset(stock, 0);
        controller.checkTrade(0, stock, alice, bob, true); // B mode: no-op
        _enable();
        controller.checkTrade(0, address(0), alice, bob, true); // native/meme quote is unrestricted
        vm.expectRevert(bytes("trade eligibility"));
        controller.checkTrade(0, stock, alice, bob, true);
        status.set(alice, true);
        vm.expectRevert(bytes("trade eligibility"));
        controller.checkTrade(0, stock, alice, bob, true); // recipient still ineligible
        vm.expectRevert(bytes("trade eligibility"));
        controller.checkTrade(0, stock, bob, alice, false); // payer ineligible
        status.set(bob, true);
        controller.checkTrade(0, stock, alice, bob, true);
        // Unbound asset is never receivable in A mode even with a credential.
        assertFalse(controller.canReceiveStock(address(status), alice));
    }

    /// line 89: a bound system vault receives its bound assets without a credential, but not other assets.
    function testSystemVaultBypassIsPerAsset() public {
        controller.bindAsset(stock, 0);
        controller.bindAsset(address(status), 1);
        address vault = address(new CovBStatus());
        controller.bindSystemVault(vault, 1); // bit 0 = stock only
        _enable();
        assertTrue(controller.canReceiveStock(stock, vault));
        assertFalse(controller.canReceiveStock(address(status), vault));
    }
}

contract CovBEligibilityRegistryTest is Test {
    EligibilityRegistry registry;
    uint256 constant USER_PK = 101;
    address user;

    function setUp() public {
        vm.warp(10 days);
        registry = new EligibilityRegistry(address(this));
        registry.scheduleIssuer(vm.addr(1), true);
        registry.scheduleIssuer(vm.addr(2), true);
        vm.warp(10 days + 48 hours);
        registry.executeIssuer(vm.addr(1));
        registry.executeIssuer(vm.addr(2));
        user = vm.addr(USER_PK);
    }

    function _sig(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function _att() internal view returns (EligibilityRegistry.Attestation memory a) {
        a = EligibilityRegistry.Attestation(
            block.chainid,
            address(registry),
            user,
            keccak256("beneficiary"),
            1,
            1,
            keccak256("policy"),
            vm.getBlockTimestamp(),
            vm.getBlockTimestamp() + 30 days,
            registry.nonces(user),
            keccak256("terms")
        );
    }

    function _issuers() internal pure returns (address[] memory i) {
        i = new address[](2);
        i[0] = vm.addr(1);
        i[1] = vm.addr(2);
    }

    function _sigs(bytes32 d) internal pure returns (bytes[] memory s) {
        s = new bytes[](2);
        s[0] = _sig(1, d);
        s[1] = _sig(2, d);
    }

    /// line 37: constructor rejects zero governance (both arms).
    function testConstructorRequiresGovernance() public {
        vm.expectRevert();
        new EligibilityRegistry(address(0));
        assertEq(new EligibilityRegistry(address(7)).governance(), address(7));
    }

    /// line 86: renew requires an existing credential; a valid renew bumps the generation.
    function testRenewRequiresRegistration() public {
        EligibilityRegistry.Attestation memory a = _att();
        bytes32 d = registry.digest(a);
        vm.expectRevert(bytes("unregistered"));
        registry.renew(a, _issuers(), _sigs(d), _sig(USER_PK, d));
        registry.register(a, _issuers(), _sigs(d), _sig(USER_PK, d));
        (,,, uint256 gen1,,,) = registry.credentials(user);
        assertEq(gen1, 1);
        a = _att();
        d = registry.digest(a);
        registry.renew(a, _issuers(), _sigs(d), _sig(USER_PK, d));
        (,,, uint256 gen2, bytes32 id,,) = registry.credentials(user);
        assertEq(gen2, 2);
        assertEq(id, d);
        assertEq(registry.nonces(user), 2);
    }

    /// line 114: the wallet itself must consent (a third-party signature fails).
    function testWalletConsentRequired() public {
        EligibilityRegistry.Attestation memory a = _att();
        bytes32 d = registry.digest(a);
        vm.expectRevert(bytes("wallet consent"));
        registry.register(a, _issuers(), _sigs(d), _sig(202, d));
        assertEq(registry.nonces(user), 0);
        (,,, uint256 gen,,,) = registry.credentials(user);
        assertEq(gen, 0);
    }

    /// line 145: only governance or an issuer may revoke.
    function testRevokeAuthority() public {
        EligibilityRegistry.Attestation memory a = _att();
        bytes32 d = registry.digest(a);
        registry.register(a, _issuers(), _sigs(d), _sig(USER_PK, d));
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("revoke authority"));
        registry.revoke(d, bytes32("x"));
        assertTrue(registry.status(user, 0, block.timestamp));
        vm.prank(vm.addr(1)); // an issuer may revoke
        registry.revoke(d, bytes32("x"));
        assertFalse(registry.status(user, 0, block.timestamp));
    }

    /// lines 181, 184, 186: unknown modules rejected; re-binding is idempotent; at most 8 pools per wallet;
    /// bound pools are notified on registration and revocation.
    function testRewardPoolBindingBounds() public {
        CovBEligModule m0 = new CovBEligModule();
        vm.expectRevert(bytes("unknown module"));
        m0.bind(registry, user);
        CovBEligModule[] memory mods = new CovBEligModule[](9);
        for (uint256 i; i < 9; ++i) {
            mods[i] = i == 0 ? m0 : new CovBEligModule();
            registry.allowRewardPool(address(mods[i]));
        }
        for (uint256 i; i < 8; ++i) {
            mods[i].bind(registry, user);
        }
        m0.bind(registry, user); // already bound: early return, no duplicate
        assertEq(registry.boundPools(user).length, 8);
        vm.expectRevert(bytes("pool capacity"));
        mods[8].bind(registry, user);
        EligibilityRegistry.Attestation memory a = _att();
        bytes32 d = registry.digest(a);
        registry.register(a, _issuers(), _sigs(d), _sig(USER_PK, d));
        registry.revoke(d, bytes32("r"));
        for (uint256 i; i < 8; ++i) {
            assertEq(mods[i].notified(), 2);
        }
        assertEq(mods[8].notified(), 0);
    }
}

contract CovBStockAdapterRegistryTest is Test {
    /// line 22: constructor rejects zero governance (both arms).
    function testConstructorRequiresGovernance() public {
        vm.expectRevert();
        new StockAdapterRegistry(address(0));
        assertEq(new StockAdapterRegistry(address(9)).governance(), address(9));
    }
}

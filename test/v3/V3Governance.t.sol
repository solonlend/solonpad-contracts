// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3Governance} from "../../src/v3/governance/V3Governance.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {ProtocolVault} from "../../src/v3/ProtocolVault.sol";
import {StockAdapterRegistry} from "../../src/v3/StockAdapterRegistry.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {RoundSource, RoundStock, RoundAdapter, RoundCapacity} from "./RewardRounds.t.sol";

contract GovernanceTarget {
    address public immutable governance;
    uint256 public value;

    constructor(address governance_) {
        governance = governance_;
    }

    function set(uint256 v) external {
        require(msg.sender == governance, "governance");
        value = v;
    }
}

/// @dev Phase-5 style target: pause/lowerCap are declared tighten-only in immutable code.
contract GuardedTarget {
    address public immutable governance;
    bool public paused;
    uint256 public cap = 100;

    constructor(address governance_) {
        governance = governance_;
    }

    modifier onlyGov() {
        require(msg.sender == governance, "governance");
        _;
    }

    function pause() external onlyGov {
        paused = true;
    }

    function unpause() external onlyGov {
        paused = false;
    }

    function lowerCap(uint256 n) external onlyGov {
        require(n < cap, "tighten only");
        cap = n;
    }

    function setCap(uint256 n) external onlyGov {
        cap = n;
    }

    function sweep(address payable to) external onlyGov {
        to.transfer(address(this).balance);
    }

    function guardianTightenOnly(bytes4 selector) external pure returns (bool) {
        return selector == this.pause.selector || selector == this.lowerCap.selector;
    }

    receive() external payable {}
}

contract V3GovernanceTest is Test {
    address multisig = address(0x5AFE);
    address guardian = address(0x6A2D);
    address deployer = address(0xD3910);
    address stranger = address(0xBAD);
    V3Governance gov;
    GovernanceTarget target;

    function setUp() public {
        vm.warp(100 days);
        vm.prank(deployer);
        gov = new V3Governance(multisig, guardian, deployer, vm.getBlockTimestamp() + 1 days);
        target = new GovernanceTarget(address(gov));
    }

    function _schedule(address to, bytes memory data, bytes32 salt) internal returns (bytes32 id) {
        id = gov.hashOperation(to, 0, data, 0, salt);
        vm.prank(multisig);
        gov.schedule(to, 0, data, 0, salt, 48 hours);
    }

    function testRolesAndFortyEightHourFloor() public view {
        assertEq(gov.getMinDelay(), 48 hours);
        assertTrue(gov.hasRole(gov.PROPOSER_ROLE(), multisig));
        assertTrue(gov.hasRole(gov.CANCELLER_ROLE(), multisig));
        assertTrue(gov.hasRole(gov.CANCELLER_ROLE(), guardian));
        assertTrue(gov.hasRole(gov.GUARDIAN_ROLE(), guardian));
        assertFalse(gov.hasRole(gov.PROPOSER_ROLE(), guardian));
        assertTrue(gov.hasRole(gov.EXECUTOR_ROLE(), address(0)), "execution is open after the delay");
        assertTrue(gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), address(gov)));
        assertFalse(gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(gov.hasRole(gov.DEFAULT_ADMIN_ROLE(), multisig));
    }

    function testSetterExecutesOnlyAfterFortyEightHours() public {
        bytes memory data = abi.encodeCall(GovernanceTarget.set, (7));
        vm.prank(multisig);
        vm.expectRevert("governance");
        target.set(7);
        vm.prank(multisig);
        vm.expectRevert();
        gov.schedule(address(target), 0, data, 0, 0, 48 hours - 1);
        _schedule(address(target), data, 0);
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert();
        gov.execute(address(target), 0, data, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(stranger);
        gov.execute(address(target), 0, data, 0, 0);
        assertEq(target.value(), 7);
    }

    function testGuardianCannotProposeOrExecuteEarly() public {
        bytes memory data = abi.encodeCall(GovernanceTarget.set, (9));
        vm.prank(guardian);
        vm.expectRevert();
        gov.schedule(address(target), 0, data, 0, 0, 48 hours);
        _schedule(address(target), data, 0);
        vm.prank(guardian);
        vm.expectRevert();
        gov.execute(address(target), 0, data, 0, 0);
    }

    function testGuardianCancelsPendingOperation() public {
        bytes memory data = abi.encodeCall(GovernanceTarget.set, (11));
        bytes32 id = _schedule(address(target), data, 0);
        vm.prank(guardian);
        gov.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert();
        gov.execute(address(target), 0, data, 0, 0);
        assertEq(target.value(), 0);
    }

    function testGuardianCannotCancelItsOwnRemoval() public {
        bytes memory data = abi.encodeCall(gov.revokeRole, (gov.GUARDIAN_ROLE(), guardian));
        bytes32 id = _schedule(address(gov), data, 0);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(V3Governance.ProtectedOperation.selector, id));
        gov.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        gov.execute(address(gov), 0, data, 0, 0);
        assertFalse(gov.hasRole(gov.GUARDIAN_ROLE(), guardian));
    }

    function testDelayCannotDropBelowFortyEightHoursEvenViaTimelock() public {
        bytes memory data = abi.encodeCall(gov.updateDelay, (1 hours));
        _schedule(address(gov), data, 0);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert();
        gov.execute(address(gov), 0, data, 0, 0);
        assertEq(gov.getMinDelay(), 48 hours);
        vm.prank(multisig);
        vm.expectRevert();
        gov.updateDelay(72 hours);
    }

    function testBootstrapCreatesAndWiresAsGovernanceOnlyForDeployer() public {
        address predicted = vm.computeCreateAddress(address(gov), vm.getNonce(address(gov)));
        bytes memory init = abi.encodePacked(type(GovernanceTarget).creationCode, abi.encode(address(gov)));
        vm.prank(multisig);
        vm.expectRevert(V3Governance.BootstrapUnavailable.selector);
        gov.bootstrapCreate(init);
        vm.prank(deployer);
        address created = gov.bootstrapCreate(init);
        assertEq(created, predicted);
        assertEq(GovernanceTarget(created).governance(), address(gov));
        bytes memory data = abi.encodeCall(GovernanceTarget.set, (5));
        vm.prank(guardian);
        vm.expectRevert(V3Governance.BootstrapUnavailable.selector);
        gov.bootstrapCall(created, data);
        vm.prank(deployer);
        gov.bootstrapCall(created, data);
        assertEq(GovernanceTarget(created).value(), 5);
    }

    function testBootstrapCannotAdministerGovernance() public {
        bytes memory data = abi.encodeCall(gov.grantRole, (gov.PROPOSER_ROLE(), deployer));
        vm.prank(deployer);
        vm.expectRevert(V3Governance.BootstrapUnavailable.selector);
        gov.bootstrapCall(address(gov), data);
        assertFalse(gov.hasRole(gov.PROPOSER_ROLE(), deployer));
    }

    function testBootstrapClosesForever() public {
        vm.prank(stranger);
        vm.expectRevert(V3Governance.BootstrapUnavailable.selector);
        gov.closeBootstrap();
        vm.prank(deployer);
        gov.closeBootstrap();
        assertTrue(gov.bootstrapClosed());
        vm.prank(deployer);
        vm.expectRevert(V3Governance.BootstrapUnavailable.selector);
        gov.bootstrapCall(address(target), abi.encodeCall(GovernanceTarget.set, (1)));
        assertEq(target.value(), 0);
    }

    function testBootstrapExpiresAtDeadlineAndAnyoneMayCloseIt() public {
        assertEq(gov.bootstrapper(), deployer);
        assertEq(gov.bootstrapDeadline(), vm.getBlockTimestamp() + 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.prank(deployer);
        vm.expectRevert(V3Governance.BootstrapUnavailable.selector);
        gov.bootstrapCall(address(target), abi.encodeCall(GovernanceTarget.set, (1)));
        vm.prank(stranger);
        gov.closeBootstrap();
        assertTrue(gov.bootstrapClosed());
    }

    function testBootstrapWindowIsBounded() public {
        vm.expectRevert(V3Governance.InvalidRole.selector);
        new V3Governance(multisig, guardian, deployer, vm.getBlockTimestamp() + 8 days);
    }

    function _allowGuardian(address to, bytes4 selector) internal returns (bytes memory data) {
        data = abi.encodeCall(V3Governance.setGuardianAction, (to, selector, true));
        _schedule(address(gov), data, selector);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        gov.execute(address(gov), 0, data, 0, selector);
    }

    function testGuardianPausesImmediatelyButRecoveryWaitsFortyEightHours() public {
        GuardedTarget t = new GuardedTarget(address(gov));
        vm.prank(guardian);
        vm.expectRevert();
        gov.guardianCall(address(t), abi.encodeCall(GuardedTarget.pause, ()));
        _allowGuardian(address(t), GuardedTarget.pause.selector);
        vm.prank(guardian);
        gov.guardianCall(address(t), abi.encodeCall(GuardedTarget.pause, ()));
        assertTrue(t.paused());
        bytes memory unpause = abi.encodeCall(GuardedTarget.unpause, ());
        vm.prank(guardian);
        vm.expectRevert();
        gov.guardianCall(address(t), unpause);
        _schedule(address(t), unpause, 0);
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert();
        gov.execute(address(t), 0, unpause, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        gov.execute(address(t), 0, unpause, 0, 0);
        assertFalse(t.paused());
    }

    function testGuardianCanOnlyLowerCaps() public {
        GuardedTarget t = new GuardedTarget(address(gov));
        _allowGuardian(address(t), GuardedTarget.lowerCap.selector);
        vm.prank(guardian);
        gov.guardianCall(address(t), abi.encodeCall(GuardedTarget.lowerCap, (40)));
        assertEq(t.cap(), 40);
        vm.prank(guardian);
        vm.expectRevert("tighten only");
        gov.guardianCall(address(t), abi.encodeCall(GuardedTarget.lowerCap, (500)));
        vm.prank(guardian);
        vm.expectRevert();
        gov.guardianCall(address(t), abi.encodeCall(GuardedTarget.setCap, (500)));
        assertEq(t.cap(), 40);
    }

    function testUndeclaredSelectorsCannotBeGrantedEvenByTimelock() public {
        GuardedTarget t = new GuardedTarget(address(gov));
        bytes memory data =
            abi.encodeCall(V3Governance.setGuardianAction, (address(t), GuardedTarget.sweep.selector, true));
        vm.prank(multisig);
        vm.expectRevert();
        gov.setGuardianAction(address(t), GuardedTarget.pause.selector, true);
        _schedule(address(gov), data, 0);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(
            abi.encodeWithSelector(V3Governance.NotTightenOnly.selector, address(t), GuardedTarget.sweep.selector)
        );
        gov.execute(address(gov), 0, data, 0, 0);
        bytes memory self = abi.encodeCall(V3Governance.setGuardianAction, (address(gov), gov.cancel.selector, true));
        _schedule(address(gov), self, bytes32(uint256(1)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert();
        gov.execute(address(gov), 0, self, 0, bytes32(uint256(1)));
    }

    function testGuardianCannotMoveFundsOrBypassTimelock() public {
        GuardedTarget t = new GuardedTarget(address(gov));
        vm.deal(address(t), 10 ether);
        vm.deal(address(gov), 5 ether);
        _allowGuardian(address(t), GuardedTarget.pause.selector);
        vm.startPrank(guardian);
        vm.expectRevert();
        gov.guardianCall(address(t), abi.encodeCall(GuardedTarget.sweep, (payable(guardian))));
        vm.expectRevert();
        gov.guardianCall(address(gov), abi.encodeCall(gov.updateDelay, (48 hours)));
        vm.expectRevert();
        gov.execute(address(t), 0, abi.encodeCall(GuardedTarget.sweep, (payable(guardian))), 0, 0);
        vm.expectRevert();
        gov.schedule(address(t), 0, abi.encodeCall(GuardedTarget.sweep, (payable(guardian))), 0, 0, 48 hours);
        vm.stopPrank();
        assertEq(address(t).balance, 10 ether);
        assertEq(address(gov).balance, 5 ether);
        assertEq(guardian.balance, 0);
    }

    function testRevokedGuardianLosesTightenPowers() public {
        GuardedTarget t = new GuardedTarget(address(gov));
        _allowGuardian(address(t), GuardedTarget.pause.selector);
        bytes memory data = abi.encodeCall(gov.revokeRole, (gov.GUARDIAN_ROLE(), guardian));
        _schedule(address(gov), data, bytes32(uint256(2)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        gov.execute(address(gov), 0, data, 0, bytes32(uint256(2)));
        bytes memory pause = abi.encodeCall(GuardedTarget.pause, ());
        vm.prank(guardian);
        vm.expectRevert();
        gov.guardianCall(address(t), pause);
        assertFalse(t.paused());
    }

    function _run(address to, bytes memory data, bytes32 salt) internal {
        _schedule(to, data, salt);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        gov.execute(to, 0, data, 0, salt);
    }

    function testEligibilityModeASwitchIsTimelockedAndGuardianCancellable() public {
        EligibilityController controller = new EligibilityController(address(gov));
        address registry = address(new GovernanceTarget(address(gov)));
        uint256 epoch = vm.getBlockTimestamp() / 1 days + 5;
        bytes memory data = abi.encodeCall(EligibilityController.scheduleEnable, (registry, keccak256("policy"), epoch));
        vm.prank(multisig);
        vm.expectRevert(EligibilityController.Unauthorized.selector);
        controller.scheduleEnable(registry, keccak256("policy"), epoch);
        bytes32 id = _schedule(address(controller), data, 0);
        vm.prank(guardian);
        gov.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert();
        gov.execute(address(controller), 0, data, 0, 0);
        assertEq(controller.effectiveEpoch(), 0, "default B kept");
        epoch = vm.getBlockTimestamp() / 1 days + 5;
        data = abi.encodeCall(EligibilityController.scheduleEnable, (registry, keccak256("policy"), epoch));
        _run(address(controller), data, bytes32(uint256(3)));
        assertEq(controller.effectiveEpoch(), epoch);
        assertFalse(controller.enabled(), "controller still enforces its own UTC >=48h boundary");
    }

    function testProtocolWithdrawalNeedsGovernanceDelayPlusVaultDelay() public {
        address treasury = address(0x7EA5);
        ProtocolVault vault = new ProtocolVault(address(gov), treasury, address(0x0995), address(0x1ED6));
        vm.deal(address(vault), 150 ether);
        bytes memory withdraw = abi.encodeCall(ProtocolVault.withdrawSurplus, (treasury, 50 ether));
        vm.prank(multisig);
        vm.expectRevert("Governance only");
        vault.schedule(keccak256(withdraw));
        _run(address(vault), abi.encodeCall(ProtocolVault.schedule, (keccak256(withdraw))), 0);
        _schedule(address(vault), withdraw, 0);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        gov.execute(address(vault), 0, withdraw, 0, 0);
        assertEq(treasury.balance, 50 ether);
        bytes memory steal = abi.encodeCall(ProtocolVault.withdrawSurplus, (guardian, 1 ether));
        vm.prank(guardian);
        vm.expectRevert();
        gov.guardianCall(address(vault), steal);
        bytes memory grant = abi.encodeCall(
            V3Governance.setGuardianAction, (address(vault), ProtocolVault.withdrawSurplus.selector, true)
        );
        _schedule(address(gov), grant, bytes32(uint256(4)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert();
        gov.execute(address(gov), 0, grant, 0, bytes32(uint256(4)));
    }

    function testOldOrdersKeepAdapterVersionAfterGovernanceAddsRoute() public {
        RoundStock stock = new RoundStock();
        RoundAdapter adapterV1 = new RoundAdapter(stock);
        RoundAdapter adapterV2 = new RoundAdapter(stock);
        StockAdapterRegistry registry = new StockAdapterRegistry(address(gov));
        RewardRoundManager manager =
            new RewardRoundManager(address(gov), address(registry), address(0xBEEF), address(0xFEE));
        RoundCapacity capacity = new RoundCapacity();
        RoundSource source = new RoundSource();
        StockAdapterRegistry.Route memory v1 = StockAdapterRegistry.Route(
            address(stock), address(0x4663), address(adapterV1), address(adapterV1), bytes32("Relay"), 4663, true, 0
        );
        vm.startPrank(deployer);
        gov.bootstrapCall(address(registry), abi.encodeCall(StockAdapterRegistry.register, (bytes32("NVDA"), 1, v1)));
        gov.bootstrapCall(
            address(manager), abi.encodeCall(RewardRoundManager.configureExecution, (address(this), address(capacity)))
        );
        gov.bootstrapCall(
            address(manager), abi.encodeCall(RewardRoundManager.registerSource, (address(source), bytes32("pool")))
        );
        gov.closeBootstrap();
        vm.stopPrank();
        vm.deal(address(source), 200 ether);
        uint256 entryId = manager.seal(address(source), 7, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 200 ether;
        uint256 roundId = manager.reserveBatch(ids, amounts, 5, vm.getBlockTimestamp() + 1 hours);
        assertEq(manager.round(roundId).adapter, address(adapterV1));

        StockAdapterRegistry.Route memory v2 = v1;
        v2.adapter = address(adapterV2);
        v2.hub = address(adapterV2);
        v2.path = bytes32("CCTP");
        _run(address(registry), abi.encodeCall(StockAdapterRegistry.register, (bytes32("NVDA"), 2, v2)), 0);
        assertEq(registry.resolve(bytes32("NVDA"), 2).adapter, address(adapterV2));
        bytes memory overwrite = abi.encodeCall(StockAdapterRegistry.register, (bytes32("NVDA"), 1, v2));
        _schedule(address(registry), overwrite, bytes32(uint256(5)));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(StockAdapterRegistry.InvalidRoute.selector);
        gov.execute(address(registry), 0, overwrite, 0, bytes32(uint256(5)));

        RewardRoundManager.Round memory r = manager.round(roundId);
        assertEq(r.adapter, address(adapterV1), "in-flight order keeps original adapter");
        assertEq(r.adapterVersion, 1);
        assertEq(manager.entry(entryId).adapterVersion, 1);
        assertEq(registry.resolve(bytes32("NVDA"), 1).adapter, address(adapterV1), "v1 route append-only");
        vm.deal(address(source), 200 ether);
        uint256 later = manager.seal(address(source), 8, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        ids[0] = later;
        uint256 laterRound = manager.reserveBatch(ids, amounts, 5, vm.getBlockTimestamp() + 1 hours);
        assertEq(manager.round(laterRound).adapter, address(adapterV1), "source policy pins version 1");
    }
}

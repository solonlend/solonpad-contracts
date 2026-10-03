// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3Governance} from "../../../../src/v3/governance/V3Governance.sol";

contract CovAGovProbe {
    address public immutable deployer;
    uint256 public value;

    constructor() {
        deployer = msg.sender;
    }

    function set(uint256 v) external returns (uint256) {
        value = v;
        return v + 1;
    }

    function boom() external pure {
        revert("probe boom");
    }
}

/// @notice Branch coverage for V3Governance bootstrap failure arms and scheduleBatch protection.
contract CovAGovernanceTest is Test {
    address multisig = address(0x5AFE);
    address guardian = address(0x6A2D);
    address deployer = address(0xD3910);
    V3Governance gov;

    function setUp() public {
        vm.warp(100 days);
        vm.prank(deployer);
        gov = new V3Governance(multisig, guardian, deployer, block.timestamp + 1 days);
    }

    // line 96: CREATE failure -> BootstrapUnavailable; success arm deploys with governance as msg.sender.
    function testBootstrapCreateRevertingInitcodeAndSuccess() public {
        bytes memory reverting = hex"60006000fd"; // PUSH1 0 PUSH1 0 REVERT
        vm.prank(deployer);
        vm.expectRevert(V3Governance.BootstrapUnavailable.selector);
        gov.bootstrapCreate(reverting);

        vm.prank(deployer);
        address deployed = gov.bootstrapCreate(type(CovAGovProbe).creationCode);
        assertTrue(deployed.code.length != 0);
        assertEq(CovAGovProbe(deployed).deployer(), address(gov));
    }

    // line 102 (EOA / self target) and line 105: failing target call bubbles its exact revert data.
    function testBootstrapCallBubblesTargetRevertAndReturnsData() public {
        CovAGovProbe probe = new CovAGovProbe();
        vm.prank(deployer);
        vm.expectRevert(bytes("probe boom"));
        gov.bootstrapCall(address(probe), abi.encodeCall(CovAGovProbe.boom, ()));

        vm.prank(deployer);
        vm.expectRevert(V3Governance.BootstrapUnavailable.selector);
        gov.bootstrapCall(address(0x1234), hex"");

        vm.prank(deployer);
        vm.expectRevert(V3Governance.BootstrapUnavailable.selector);
        gov.bootstrapCall(address(gov), abi.encodeWithSignature("closeBootstrap()"));

        vm.prank(deployer);
        bytes memory ret = gov.bootstrapCall(address(probe), abi.encodeCall(CovAGovProbe.set, (41)));
        assertEq(abi.decode(ret, (uint256)), 42);
        assertEq(probe.value(), 41);
    }

    function _batch(address second)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = address(0xAAAA);
        targets[1] = second;
        payloads[0] = hex"";
        payloads[1] = abi.encodeWithSelector(V3Governance.updateDelay.selector, uint256(72 hours));
    }

    // line 165: loop arms (target == governance -> protected + break; no self target -> not protected).
    function testScheduleBatchMarksOnlySelfTargetingBatchesProtected() public {
        (address[] memory t1, uint256[] memory v1, bytes[] memory p1) = _batch(address(gov));
        vm.prank(multisig);
        gov.scheduleBatch(t1, v1, p1, bytes32(0), bytes32("p"), 48 hours);
        bytes32 protectedId = gov.hashOperationBatch(t1, v1, p1, bytes32(0), bytes32("p"));
        assertTrue(gov.protectedOperation(protectedId));

        (address[] memory t2, uint256[] memory v2, bytes[] memory p2) = _batch(address(0xBBBB));
        vm.prank(multisig);
        gov.scheduleBatch(t2, v2, p2, bytes32(0), bytes32("o"), 48 hours);
        bytes32 ordinaryId = gov.hashOperationBatch(t2, v2, p2, bytes32(0), bytes32("o"));
        assertFalse(gov.protectedOperation(ordinaryId));
        assertTrue(gov.isOperationPending(ordinaryId));

        // Guardian cannot cancel the protected batch, but can cancel the ordinary one.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(V3Governance.ProtectedOperation.selector, protectedId));
        gov.cancel(protectedId);
        assertTrue(gov.isOperationPending(protectedId));
        vm.prank(guardian);
        gov.cancel(ordinaryId);
        assertFalse(gov.isOperation(ordinaryId));

        // Below-floor batch delay is rejected by the parent timelock.
        vm.prank(multisig);
        vm.expectRevert();
        gov.scheduleBatch(t2, v2, p2, bytes32(0), bytes32("x"), 48 hours - 1);

        // Executing the protected batch after 48h really changes the delay (end-to-end).
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.etch(address(0xAAAA), hex"00");
        gov.executeBatch(t1, v1, p1, bytes32(0), bytes32("p"));
        assertEq(gov.getMinDelay(), 72 hours);
    }
}

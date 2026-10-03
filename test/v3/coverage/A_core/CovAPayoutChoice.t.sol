// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {LaunchPayoutChoice} from "../../../../src/v3/LaunchPayoutChoice.sol";

contract CovAChoiceHub {
    mapping(address => bool) public closed;

    function setClosed(address a, bool c) external {
        closed[a] = c;
    }

    function stockState(address a) external view returns (bool, bool, uint256) {
        return (!closed[a], true, 1);
    }

    function underlyingOfToken(address) external pure returns (address) {
        return address(0);
    }
}

/// @notice Branch coverage for LaunchPayoutChoice: governance gates, id bounds, one-shot choice, views.
contract CovAPayoutChoiceTest is Test {
    LaunchPayoutChoice choice;
    CovAChoiceHub hub;
    address gov = address(0x6060);
    address factory = address(0xFAC7);
    address aapl = address(0xAA91);
    address tsla = address(0x75A1);

    function setUp() public {
        hub = new CovAChoiceHub();
        choice = new LaunchPayoutChoice(gov, address(hub));
    }

    function testConstructorRejectsZeroGovernanceOrHub() public {
        vm.expectRevert();
        new LaunchPayoutChoice(address(0), address(hub));
        vm.expectRevert();
        new LaunchPayoutChoice(gov, address(0));
    }

    // line 55 (NotGovernance) + line 56 (zero / second bind)
    function testBindFactoryGovernanceOnlyOnceNonZero() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(LaunchPayoutChoice.NotGovernance.selector);
        choice.bindFactory(factory);
        vm.prank(gov);
        vm.expectRevert();
        choice.bindFactory(address(0));
        assertEq(choice.factory(), address(0));
        vm.prank(gov);
        choice.bindFactory(factory);
        assertEq(choice.factory(), factory);
        vm.prank(gov);
        vm.expectRevert();
        choice.bindFactory(address(0xF2));
        assertEq(choice.factory(), factory);
    }

    // line 64: each of the three zero fields -> BadChoice(0); line 112: unlisted asset.
    function testApproveRejectsZeroFieldsAndUnlistedAsset() public {
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 0));
        choice.approve(aapl, 0, 1, bytes32("p"));
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 0));
        choice.approve(aapl, bytes32("AAPL"), 0, bytes32("p"));
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 0));
        choice.approve(aapl, bytes32("AAPL"), 1, 0);
        hub.setClosed(aapl, true);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.NotListed.selector, aapl));
        choice.approve(aapl, bytes32("AAPL"), 1, bytes32("p"));
        hub.setClosed(aapl, false);
        assertEq(choice.approve(aapl, bytes32("AAPL"), 1, bytes32("p")), 1);
        vm.stopPrank();
        assertEq(choice.choiceCount(), 1);
    }

    // line 72 (NotGovernance) + line 73 (id 0 / id > length)
    function testSetEnabledGovernanceAndBounds() public {
        vm.prank(gov);
        choice.approve(aapl, bytes32("AAPL"), 1, bytes32("p"));
        vm.prank(address(0xBAD));
        vm.expectRevert(LaunchPayoutChoice.NotGovernance.selector);
        choice.setEnabled(1, false);
        vm.startPrank(gov);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 0));
        choice.setEnabled(0, false);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 2));
        choice.setEnabled(2, false);
        choice.setEnabled(1, false);
        vm.stopPrank();
        assertFalse(choice.choice(1).enabled);
    }

    // line 82 (id bounds), line 83 (AlreadyChosen), line 85 (disabled), line 112 (delisted after approval)
    function testChooseBoundsOneShotDisabledAndDelisted() public {
        vm.startPrank(gov);
        choice.bindFactory(factory);
        choice.approve(aapl, bytes32("AAPL"), 1, bytes32("p"));
        choice.approve(tsla, bytes32("TSLA"), 2, bytes32("q"));
        vm.stopPrank();
        vm.startPrank(factory);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 0));
        choice.choose(address(1), 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 3));
        choice.choose(address(1), 3);
        LaunchPayoutChoice.Choice memory c = choice.choose(address(1), 2);
        assertEq(c.asset, tsla);
        assertEq(choice.choiceOf(address(1)), 2);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.AlreadyChosen.selector, address(1)));
        choice.choose(address(1), 1);
        assertEq(choice.choiceOf(address(1)), 2);
        vm.stopPrank();

        vm.prank(gov);
        choice.setEnabled(1, false);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 1));
        choice.choose(address(2), 1);

        hub.setClosed(tsla, true);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.NotListed.selector, tsla));
        choice.choose(address(2), 2);
        assertEq(choice.choiceOf(address(2)), 0);
    }

    // line 92 + never-called choice()/choiceCount(); choicesOf both arms of line 106.
    function testChoiceViewBoundsAndBatchView() public {
        assertEq(choice.choiceCount(), 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 0));
        choice.choice(0);
        vm.expectRevert(abi.encodeWithSelector(LaunchPayoutChoice.BadChoice.selector, 1));
        choice.choice(1);
        vm.startPrank(gov);
        choice.bindFactory(factory);
        choice.approve(aapl, bytes32("AAPL"), 7, bytes32("p"));
        vm.stopPrank();
        LaunchPayoutChoice.Choice memory c = choice.choice(1);
        assertEq(c.asset, aapl);
        assertEq(c.assetId, bytes32("AAPL"));
        assertEq(c.version, 7);
        assertEq(c.pricePolicy, bytes32("p"));
        assertTrue(c.enabled);
        assertEq(choice.choiceCount(), 1);
        vm.prank(factory);
        choice.choose(address(10), 1);
        address[] memory tokens = new address[](2);
        tokens[0] = address(10);
        tokens[1] = address(11);
        (uint256[] memory ids, address[] memory assets) = choice.choicesOf(tokens);
        assertEq(ids[0], 1);
        assertEq(assets[0], aapl);
        assertEq(ids[1], 0);
        assertEq(assets[1], address(0));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {LegacyFactoryTest} from "../../LegacyPool.t.sol";
import {V3LegacyPools} from "../../../../src/v3/libraries/V3LegacyPools.sol";
import {HookToken} from "../../helpers/HookHarness.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Branch coverage for V3LegacyPools admission (reuses LegacyFactoryTest's real-component fixture;
/// its three tests are inherited and re-run here).
contract CovALegacyPoolsTest is LegacyFactoryTest {
    function _req(address token, address quote, address sink, address creator, uint160 price)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "registerLegacyPool(address,address,address,address,uint160)", token, quote, sink, creator, price
        );
    }

    function _assertLegacyRevert(bytes memory data) internal {
        (bool ok, bytes memory err) = address(factory).call(data);
        assertFalse(ok);
        assertEq(bytes4(err), V3LegacyPools.InvalidLegacyPool.selector);
    }

    // line 36 + line 41 (codeless, duplicate) + line 48 (zero action)
    function testWhitelistAndScheduleGuards() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(V3LegacyPools.InvalidLegacyPool.selector);
        factory.whitelistLegacyToken(address(solon));
        vm.expectRevert(V3LegacyPools.InvalidLegacyPool.selector);
        factory.whitelistLegacyToken(address(0xDEAD));
        factory.whitelistLegacyToken(address(solon));
        vm.expectRevert(V3LegacyPools.InvalidLegacyPool.selector);
        factory.whitelistLegacyToken(address(solon));
        vm.expectRevert(V3LegacyPools.InvalidLegacyPool.selector);
        factory.scheduleLegacyPool(bytes32(0));
        factory.scheduleLegacyPool(bytes32(uint256(1)));
    }

    // line 67: timing arms (never scheduled / scheduled but early) and the exact 48h boundary
    function testRegisterTimelockArms() public {
        factory.whitelistLegacyToken(address(solon));
        bytes memory data = _req(address(solon), address(stock), address(staking), address(this), uint160(1 << 96));
        _assertLegacyRevert(data); // readyAt == 0
        factory.scheduleLegacyPool(keccak256(data));
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        _assertLegacyRevert(data); // one second early
        vm.warp(vm.getBlockTimestamp() + 1);
        (bool ok,) = address(factory).call(data);
        assertTrue(ok, "exactly 48h must be ready");
    }

    /// stockFeeConverter shares a packed slot with hasLaunched, so locate and zero just its 20 bytes.
    function _clearConverter(address converter) internal returns (bytes32 slot, bytes32 original) {
        vm.record();
        factory.stockFeeConverter();
        (bytes32[] memory reads,) = vm.accesses(address(factory));
        for (uint256 i; i < reads.length; ++i) {
            original = vm.load(address(factory), reads[i]);
            for (uint256 shift; shift <= 96; shift += 8) {
                if (address(uint160(uint256(original) >> shift)) == converter) {
                    uint256 mask = uint256(type(uint160).max) << shift;
                    vm.store(address(factory), reads[i], bytes32(uint256(original) & ~mask));
                    return (reads[i], original);
                }
            }
        }
        revert("converter slot");
    }

    // line 67: codehash drift, token == quote, price bounds, missing converter
    function testRegisterParameterArms() public {
        HookToken drift = new HookToken();
        factory.whitelistLegacyToken(address(drift));
        factory.whitelistLegacyToken(address(stock));
        factory.whitelistLegacyToken(address(solon));
        bytes[] memory bad = new bytes[](4);
        bad[0] = _req(address(drift), address(stock), address(staking), address(this), uint160(1 << 96));
        bad[1] = _req(address(stock), address(stock), address(staking), address(this), uint160(1 << 96));
        bad[2] = _req(address(solon), address(stock), address(staking), address(this), TickMath.MIN_SQRT_PRICE - 1);
        bad[3] = _req(address(solon), address(stock), address(staking), address(this), TickMath.MAX_SQRT_PRICE);
        for (uint256 i; i < bad.length; ++i) {
            factory.scheduleLegacyPool(keccak256(bad[i]));
        }
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.etch(address(drift), address(solon).code); // whitelisted codehash no longer matches
        for (uint256 i; i < bad.length; ++i) {
            _assertLegacyRevert(bad[i]);
        }
        // converter == 0 (factory configured without a stock fee converter)
        bytes memory good = _req(address(solon), address(stock), address(staking), address(this), TickMath.MIN_SQRT_PRICE);
        factory.scheduleLegacyPool(keccak256(good));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        address converter = factory.stockFeeConverter();
        (bytes32 slot, bytes32 original) = _clearConverter(converter);
        assertEq(factory.stockFeeConverter(), address(0));
        _assertLegacyRevert(good);
        vm.store(address(factory), slot, original);
        assertEq(factory.stockFeeConverter(), converter);
        // lowest legal price boundary is accepted
        (bool ok,) = address(factory).call(good);
        assertTrue(ok, "MIN_SQRT_PRICE must be accepted");
    }

    // line 71: holder sink staking a different token, or bound to a different ledger
    function testRegisterSinkIdentityArms() public {
        HookToken other = new HookToken();
        factory.whitelistLegacyToken(address(other));
        factory.whitelistLegacyToken(address(solon));
        bytes memory wrongToken = _req(address(other), address(stock), address(staking), address(this), uint160(1 << 96));
        bytes memory good = _req(address(solon), address(stock), address(staking), address(this), uint160(1 << 96));
        factory.scheduleLegacyPool(keccak256(wrongToken));
        factory.scheduleLegacyPool(keccak256(good));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _assertLegacyRevert(wrongToken);
        vm.mockCall(address(staking), abi.encodeWithSignature("ledger()"), abi.encode(address(0x1ED6E5)));
        _assertLegacyRevert(good);
        vm.clearMockedCalls();
        (bool ok,) = address(factory).call(good);
        assertTrue(ok);
    }
}

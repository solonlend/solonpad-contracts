// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CctpV2} from "../../../../src/v3/stock/libs/CctpV2.sol";
import {Messages} from "../../../../src/v3/stock/libs/Messages.sol";
import {AddressAlias} from "../../../../src/v3/stock/libs/Arbitrum.sol";
import {SolonStockToken} from "../../../../src/v3/stock/SolonStockToken.sol";

/// @notice External wrappers so library reverts can be asserted with expectRevert.
contract CovDLibsHarness {
    function parse(bytes memory m) external pure returns (CctpV2.Parsed memory) {
        return CctpV2.parse(m);
    }

    function decodeOrder(bytes memory m) external pure returns (Messages.Order memory) {
        return Messages.decodeOrder(m);
    }

    function decodeResult(bytes memory m) external pure returns (Messages.Result memory) {
        return Messages.decodeResult(m);
    }

    function decodeDeliver(bytes memory m) external pure returns (Messages.Deliver memory) {
        return Messages.decodeDeliver(m);
    }

    function decodeCheckpoint(bytes memory m) external pure returns (Messages.Checkpoint memory) {
        return Messages.decodeCheckpoint(m);
    }

    function kind(bytes memory m) external pure returns (uint8) {
        return Messages.kind(m);
    }

    function migrationRef(address u, uint64 n) external pure returns (bytes32) {
        return Messages.migrationRef(u, n);
    }

    function migrationUnderlying(bytes32 r) external pure returns (address) {
        return Messages.migrationUnderlying(r);
    }

    function isMigrationRef(bytes32 r) external pure returns (bool) {
        return Messages.isMigrationRef(r);
    }

    function applyAlias(address a) external pure returns (address) {
        return AddressAlias.applyL1ToL2Alias(a);
    }

    function undoAlias(address a) external pure returns (address) {
        return AddressAlias.undoL1ToL2Alias(a);
    }
}

contract CovDStockLibsTest is Test {
    CovDLibsHarness h;
    address constant U = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);

    function setUp() public {
        h = new CovDLibsHarness();
    }

    function _msg(bytes memory hook) internal pure returns (bytes memory) {
        return CctpV2.build(
            26, 0, bytes32(uint256(5)), bytes32(uint256(6)), bytes32(0), bytes32(0), 2000, 2000, bytes32(0),
            bytes32(uint256(7)), 123, bytes32(uint256(8)), hook
        );
    }

    // CctpV2 L55 both arms
    function test_cctpParse_tooShortReverts_minimumLengthParses() public {
        bytes memory full = _msg("");
        assertEq(full.length, 148 + 228);
        bytes memory short = new bytes(full.length - 1);
        for (uint256 i; i < short.length; ++i) {
            short[i] = full[i];
        }
        vm.expectRevert(abi.encodeWithSelector(CctpV2.MessageTooShort.selector, uint256(375)));
        h.parse(short);
        vm.expectRevert(abi.encodeWithSelector(CctpV2.MessageTooShort.selector, uint256(0)));
        h.parse("");
        CctpV2.Parsed memory p = h.parse(full);
        assertEq(p.sourceDomain, 26);
        assertEq(p.nonce, bytes32(uint256(5)));
        assertEq(p.amount, 123);
        assertEq(p.messageSender, bytes32(uint256(8)));
        assertEq(p.hookData.length, 0);
        p = h.parse(_msg(hex"aabb"));
        assertEq(p.hookData, hex"aabb");
    }

    // Messages L92/L98/L104/L110 both arms, plus kind
    function test_messages_decodeRejectsOtherTypes() public {
        bytes memory o = Messages.encode(Messages.Order(bytes32(uint256(1)), U, Messages.Side.Sell, 5, 6));
        bytes memory r = Messages.encode(Messages.Result(bytes32(uint256(2)), U, Messages.Outcome.Sold, 5, 6, 9));
        bytes memory d = Messages.encode(Messages.Deliver(bytes32(uint256(3)), U, 7, address(0xCAFE), Messages.DeliverMode.Settlement));
        bytes memory c = Messages.encode(Messages.Checkpoint(bytes32(uint256(4)), 1, 2));
        assertEq(h.kind(o), 1);
        assertEq(h.kind(r), 2);
        assertEq(h.kind(d), 3);
        assertEq(h.kind(c), 4);
        // Same payloads with only the leading type byte changed, so only the type check can fail.
        vm.expectRevert(abi.encodeWithSelector(Messages.BadMessageType.selector, uint8(9), uint8(1)));
        h.decodeOrder(_retype(o, 9));
        vm.expectRevert(abi.encodeWithSelector(Messages.BadMessageType.selector, uint8(9), uint8(2)));
        h.decodeResult(_retype(r, 9));
        vm.expectRevert(abi.encodeWithSelector(Messages.BadMessageType.selector, uint8(9), uint8(3)));
        h.decodeDeliver(_retype(d, 9));
        vm.expectRevert(abi.encodeWithSelector(Messages.BadMessageType.selector, uint8(9), uint8(4)));
        h.decodeCheckpoint(_retype(c, 9));
        // cross-type: a Result fed to the Order decoder (shape-compatible prefix) is rejected by type
        vm.expectRevert(abi.encodeWithSelector(Messages.BadMessageType.selector, uint8(2), uint8(1)));
        h.decodeOrder(r);
        assertEq(h.decodeOrder(o).amountIn, 5);
        assertEq(h.decodeResult(r).seq, 9);
        assertEq(h.decodeDeliver(d).to, address(0xCAFE));
        assertEq(h.decodeCheckpoint(c).toSeq, 2);
    }

    function _retype(bytes memory m, uint8 t) internal pure returns (bytes memory out) {
        out = bytes.concat(m);
        out[31] = bytes1(t);
    }

    // never-called migrationRef / migrationUnderlying
    function test_messages_migrationRefRoundTrip() public view {
        bytes32 ref = h.migrationRef(U, 42);
        assertTrue(h.isMigrationRef(ref));
        assertEq(h.migrationUnderlying(ref), U);
        assertEq(uint64(uint256(ref)), 42);
        assertFalse(h.isMigrationRef(bytes32(uint256(42))), "order refs are small ids");
        assertEq(h.migrationUnderlying(h.migrationRef(address(type(uint160).max), type(uint64).max)), address(type(uint160).max));
    }

    // never-called AddressAlias.undoL1ToL2Alias (incl. wraparound)
    function test_addressAlias_undoInvertsApply() public view {
        address a = address(0xB41D);
        assertEq(h.undoAlias(h.applyAlias(a)), a);
        assertEq(h.applyAlias(a), address(uint160(0xB41D) + uint160(0x1111000000000000000000000000000000001111)));
        address top = address(type(uint160).max);
        assertEq(h.undoAlias(h.applyAlias(top)), top, "wraps modulo 2^160 both ways");
        assertEq(h.undoAlias(address(0)), address(type(uint160).max - uint160(0x1111000000000000000000000000000000001111) + 1));
    }

    // never-called SolonStockToken.vault
    function test_stockToken_vaultIsTheHub() public {
        address hub = address(0x4B);
        SolonStockToken t = new SolonStockToken("NVDA", U, 4663, hub);
        assertEq(t.vault(), hub);
        assertEq(t.hub(), hub);
        assertEq(t.name(), "Solon NVDA");
        assertEq(t.symbol(), "NVDA.sol");
        vm.expectRevert(SolonStockToken.NotHub.selector);
        t.mint(address(this), 1);
        vm.prank(hub);
        t.mint(address(this), 1);
        assertEq(t.balanceOf(address(this)), 1);
    }
}

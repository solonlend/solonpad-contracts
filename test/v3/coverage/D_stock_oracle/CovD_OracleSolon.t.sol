// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SolonStockOracle} from "../../../../src/v3/oracle/SolonStockOracle.sol";
import {OracleRefTickSigner} from "../../../../src/v3/oracle/OracleRefTickSigner.sol";
import {IStockPriceSource, StockObservation} from "../../../../src/v3/oracle/IStockPriceSource.sol";
import {MockPriceSource, OracleTokenStub, OracleTestLib} from "../../helpers/OracleMocks.sol";

/// @notice Branch coverage for SolonStockOracle (L110, L131, L273, L274, latest/quoteOf/underlyings) and the
///         OracleRefTickSigner constructor (L38).
contract CovDOracleSolonTest is Test {
    address constant OWNER = address(0x71);
    address constant GUARDIAN = address(0x6A);
    address constant NVDA = address(0x1D);

    SolonStockOracle oracle;
    MockPriceSource mock;
    address token;

    function setUp() public {
        vm.warp(1_760_000_000);
        oracle = new SolonStockOracle(OWNER, GUARDIAN);
        mock = new MockPriceSource();
        token = address(new OracleTokenStub());
        vm.prank(OWNER);
        oracle.configureAsset(NVDA, token, mock, OracleTestLib.params());
        mock.set(NVDA, 180e18, 1);
    }

    // ---------------------------------------------------------------- configureAsset L110

    function test_configure_rejectsZeroUnderlyingAndCodelessTokenOrSource() public {
        address t2 = address(new OracleTokenStub());
        SolonStockOracle.Params memory p = OracleTestLib.params();
        vm.startPrank(OWNER);
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.configureAsset(address(0), t2, mock, p);
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.configureAsset(address(0xA1), address(0xE0A), mock, p); // token is an EOA
        vm.expectRevert(SolonStockOracle.BadParams.selector);
        oracle.configureAsset(address(0xA1), t2, IStockPriceSource(address(0x5005)), p); // source is an EOA
        vm.stopPrank();
        assertEq(oracle.underlyingOf(t2), address(0));
        assertEq(oracle.underlyings().length, 1);
        assertEq(uint8(oracle.status(address(0xA1))), uint8(SolonStockOracle.Status.None));
    }

    // ---------------------------------------------------------------- tighten L131

    function test_tighten_onlyGuardianOrOwner() public {
        SolonStockOracle.Params memory p = OracleTestLib.params();
        p.maxAge = 10 minutes;
        vm.prank(address(0xBAD));
        vm.expectRevert(SolonStockOracle.NotGuardian.selector);
        oracle.tighten(token, p);
        assertEq(oracle.assetOf(token).params.maxAge, 15 minutes); // unchanged

        vm.prank(OWNER); // owner arm of L131
        oracle.tighten(token, p);
        assertEq(oracle.assetOf(token).params.maxAge, 10 minutes);

        p.maxMoveBps = 500;
        vm.prank(GUARDIAN); // guardian arm
        oracle.tighten(NVDA, p); // underlying works as key too
        assertEq(oracle.assetOf(token).params.maxMoveBps, 500);
    }

    function test_tighten_unknownAssetReverts() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(SolonStockOracle.UnknownAsset.selector, address(0xDEAD)));
        oracle.tighten(address(0xDEAD), OracleTestLib.params());
    }

    /// pause L145 owner arm (existing suite only pauses as guardian).
    function test_pause_ownerMayPause() public {
        oracle.poke(token);
        vm.prank(OWNER);
        oracle.pause(NVDA, keccak256("halt"));
        assertTrue(oracle.assetOf(token).paused);
        assertTrue(oracle.isStale(token));
    }

    // ---------------------------------------------------------------- isStale L273/L274

    function test_isStale_keyedByUnderlyingAndUnknown() public {
        assertTrue(oracle.isStale(NVDA)); // underlying key (L273 true arm), no anchor yet: Suspect
        oracle.poke(token);
        assertFalse(oracle.isStale(NVDA)); // underlying key, Live
        assertFalse(oracle.isStale(token)); // token key (L273 false arm)
        assertTrue(oracle.isStale(address(0xDEAD))); // unknown (L274 true arm), never reverts
        assertTrue(oracle.isStale(address(0))); // zero key also unknown
        vm.warp(block.timestamp + 15 minutes + 1);
        assertTrue(oracle.isStale(NVDA)); // aged out
    }

    // ---------------------------------------------------------------- latest / quoteOf / underlyings

    function test_latest_returnsObservationAndStatus() public {
        (StockObservation memory o, SolonStockOracle.Status s) = oracle.latest(token);
        assertEq(o.price18, 180e18);
        assertEq(uint8(s), uint8(SolonStockOracle.Status.Suspect)); // no accepted price yet
        oracle.poke(token);
        (o, s) = oracle.latest(NVDA);
        assertEq(o.price18, 180e18);
        assertEq(o.observedAt, block.timestamp);
        assertEq(uint8(s), uint8(SolonStockOracle.Status.Live));
        mock.setFailing(NVDA, true); // failed read: zeroed observation, Stale
        (o, s) = oracle.latest(token);
        assertEq(o.price18, 0);
        assertEq(o.observedAt, 0);
        assertEq(uint8(s), uint8(SolonStockOracle.Status.Stale));
        vm.expectRevert(abi.encodeWithSelector(SolonStockOracle.UnknownAsset.selector, address(0xDEAD)));
        oracle.latest(address(0xDEAD));
    }

    function test_quoteOf_isTheAcceptedAnchor() public {
        SolonStockOracle.Quote memory q = oracle.quoteOf(token);
        assertEq(q.price18, 0);
        uint64 srcAt = uint64(block.timestamp) + 1; // MockPriceSource seq 1 -> now + 1
        oracle.poke(token);
        q = oracle.quoteOf(token);
        assertEq(q.price18, 180e18);
        assertEq(q.sourceUpdatedAt, srcAt);
        assertEq(q.updatedAt, block.timestamp);
        SolonStockOracle.Quote memory q2 = oracle.quoteOf(NVDA);
        assertEq(q2.price18, q.price18);
        assertEq(oracle.quoteOf(address(0xDEAD)).price18, 0); // unknown: zero, no revert
        // a jump stays a candidate and does not move quoteOf
        mock.set(NVDA, 250e18, 2);
        oracle.poke(token);
        assertEq(oracle.quoteOf(token).price18, 180e18);
        assertEq(oracle.candidateOf(token).price18, 250e18);
    }

    function test_underlyings_listsEachUnderlyingOnce() public {
        address[] memory u = oracle.underlyings();
        assertEq(u.length, 1);
        assertEq(u[0], NVDA);
        MockPriceSource other = new MockPriceSource();
        vm.prank(OWNER);
        oracle.configureAsset(NVDA, token, other, OracleTestLib.params()); // re-point: not listed again
        assertEq(oracle.underlyings().length, 1);
        address t2 = address(new OracleTokenStub());
        vm.prank(OWNER);
        oracle.configureAsset(address(0xA1), t2, mock, OracleTestLib.params());
        u = oracle.underlyings();
        assertEq(u.length, 2);
        assertEq(u[1], address(0xA1));
    }

    // ---------------------------------------------------------------- OracleRefTickSigner L38

    function test_signer_ctorRejectsZeroOracle() public {
        vm.expectRevert(); // bare require(address(oracle_) != address(0)): the only check in the constructor
        new OracleRefTickSigner(SolonStockOracle(address(0)));
        OracleRefTickSigner s = new OracleRefTickSigner(oracle);
        assertEq(address(s.oracle()), address(oracle));
    }
}

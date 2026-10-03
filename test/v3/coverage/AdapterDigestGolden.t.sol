// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FloorOracleStub, FLOOR_ORACLE} from "../helpers/OracleMocks.sol";
import {SolonStockAdapter} from "../../../src/v3/adapters/SolonStockAdapter.sol";
import {AdapterStock, FundingHubFixture} from "../StockAdapter.t.sol";

/// @dev Pins `SolonStockAdapter.quoteDigest` (the EIP-712 digest keepers sign) so the coverage-only split of its
///      17-word `abi.encode` cannot change a single byte: an independent word-by-word encoding and a golden value
///      captured from the pre-split code (5f81a74) must both match.
contract AdapterDigestGoldenTest is Test {
    SolonStockAdapter adapter;
    SolonStockAdapter.Config cfg;

    function setUp() public {
        vm.etch(FLOOR_ORACLE, type(FloorOracleStub).runtimeCode);
        vm.chainId(5042002);
        AdapterStock stock = new AdapterStock();
        FundingHubFixture hub = new FundingHubFixture(stock);
        cfg = SolonStockAdapter.Config(
            address(this),
            address(0xCAFE),
            address(stock),
            address(12),
            address(hub),
            vm.addr(77),
            keccak256("RELAY"),
            4663,
            address(0xBEEF),
            FLOOR_ORACLE
        );
        adapter = new SolonStockAdapter(cfg);
    }

    function _w(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _expected(SolonStockAdapter.SignedQuote memory q) private view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SolonStockAdapter"),
                keccak256("3"),
                block.chainid,
                address(adapter)
            )
        );
        bytes memory words = abi.encodePacked(
            adapter.QUOTE_TYPEHASH(), q.orderId, _w(cfg.asset), _w(cfg.underlying), _w(cfg.hub), cfg.path
        );
        words = abi.encodePacked(
            words,
            bytes32(cfg.destinationChain),
            _w(cfg.vault),
            _w(cfg.vault),
            bytes32(SolonStockAdapter.startFunding.selector),
            bytes32(q.budget18),
            bytes32(q.minRawOut)
        );
        words = abi.encodePacked(
            words,
            bytes32(q.deadline),
            bytes32(q.nonce),
            bytes32(q.fees18),
            bytes32(q.fixedCost18),
            _w(cfg.opsVault)
        );
        assertEq(words.length, 17 * 32);
        return keccak256(abi.encodePacked("\x19\x01", domain, keccak256(words)));
    }

    function testQuoteDigestMatchesIndependentEncodingAndGolden() public view {
        SolonStockAdapter.SignedQuote memory q = SolonStockAdapter.SignedQuote(
            keccak256("order1"), 100 ether, 6 ether, 1_800_000_000, 9, 1 ether, 0.5 ether
        );
        bytes32 got = adapter.quoteDigest(q);
        assertEq(got, _expected(q), "independent encoding");
        assertEq(got, GOLDEN, "golden (pre-split 5f81a74)");
    }

    function testFuzzQuoteDigestMatchesIndependentEncoding(SolonStockAdapter.SignedQuote memory q) public view {
        assertEq(adapter.quoteDigest(q), _expected(q));
    }

    bytes32 constant GOLDEN = 0x2da0f024842e1e165d2671b99fa9793b2d92e80052931906d6431822e0684c57;
}

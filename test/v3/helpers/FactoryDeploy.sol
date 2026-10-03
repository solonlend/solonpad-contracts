// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V3LaunchFactory} from "../../../src/v3/V3LaunchFactory.sol";
import {V3RewardToken} from "../../../src/v3/V3RewardToken.sol";
import {V3TokenCodeStore} from "../../../src/v3/V3TokenCodeStore.sol";

/// @notice Deploys V3LaunchFactory exactly like `new V3LaunchFactory(c, quotes)` (CREATE from the caller).
/// @dev Coverage-only shim. Under `forge coverage --ir-minimum` the unoptimised V3RewardToken creation code is
///      ~59 KB, beyond the factory's two 24,000-byte code stores (production: ~44 KB fits), so the constructor
///      cannot complete and every factory-dependent suite would fail in setUp. Only in that case, the 24,000
///      constant inside the V3TokenCodeStore initcode embedded in the factory *creation* code is raised to
///      65,535. Nothing in the factory runtime changes (the store and token initcode are constructor-only), so
///      coverage of all runtime paths is attributed to the genuine V3LaunchFactory bytecode. Constructor lines
///      are not attributed in that mode (patched creation code); they are audited in docs/COVERAGE-v3.md.
///      Production-profile `forge test` never takes the patched path.
library FactoryDeploy {
    uint256 internal constant PRODUCTION_TOKEN_CODE_LIMIT = 44000;

    function deploy(V3LaunchFactory.Components memory c, V3LaunchFactory.QuoteConfig[] memory quotes)
        internal
        returns (V3LaunchFactory factory)
    {
        bytes memory init = type(V3LaunchFactory).creationCode;
        if (type(V3RewardToken).creationCode.length > PRODUCTION_TOKEN_CODE_LIMIT) _raiseStoreLimit(init);
        init = abi.encodePacked(init, abi.encode(c, quotes));
        assembly ("memory-safe") {
            factory := create(0, add(init, 32), mload(init))
        }
        require(address(factory) != address(0), "factory deploy");
    }

    function _raiseStoreLimit(bytes memory init) private pure {
        bytes memory store = type(V3TokenCodeStore).creationCode;
        uint256 at = _find(init, store);
        uint256 hits;
        for (uint256 i = at; i + 2 < at + store.length; ++i) {
            // PUSH2 0x5dc0 (24000)
            if (init[i] == 0x61 && init[i + 1] == 0x5d && init[i + 2] == 0xc0) {
                init[i + 1] = 0xff;
                init[i + 2] = 0xff;
                ++hits;
            }
        }
        require(hits == 1, "store limit constant");
    }

    function _find(bytes memory hay, bytes memory needle) private pure returns (uint256) {
        bytes32 want = keccak256(needle);
        bytes32 head;
        assembly ("memory-safe") {
            head := mload(add(needle, 32))
        }
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bytes32 word;
            bytes32 h;
            assembly ("memory-safe") {
                let p := add(add(hay, 32), i)
                word := mload(p)
                if eq(word, head) { h := keccak256(p, mload(needle)) }
            }
            if (word == head && h == want) return i;
        }
        revert("store initcode not embedded");
    }
}

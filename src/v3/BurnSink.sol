// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Permanent economic destruction. No callable code, owner or upgrade path.
/// SOLON totalSupply is deliberately unaffected by transfers to this address.
contract BurnSink {}

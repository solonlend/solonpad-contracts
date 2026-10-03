// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Messages} from "../libs/Messages.sol";

/// @notice What the canonical lane calls on the reserve vault: hand stock (or its proceeds) to a holder.
interface IReserveVaultDeliver {
    function deliver(Messages.Deliver calldata d) external;
}

/// @notice What the reserve chain's outbox calls on the Ethereum bridger: a Merkle root of vault results.
interface IBridgerCheckpoint {
    function acceptCheckpoint(Messages.Checkpoint calldata c) external;
}

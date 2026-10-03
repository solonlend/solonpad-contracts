// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Messages — wire formats shared by the hub, the vault and the bridger
/// @notice Every cross-chain payload in ArcStocks v2 is one of these structs, abi-encoded with a
///         leading type byte. LayerZero carries Order and Result; the canonical lane carries Deliver
///         (Arc → Ethereum → Robinhood Chain as CCTP hook data, then retryable calldata) and
///         Checkpoint (Robinhood Chain → Ethereum → Arc as an outbox call, then CCTP hook data).
library Messages {
    uint8 internal constant T_ORDER = 1;
    uint8 internal constant T_RESULT = 2;
    uint8 internal constant T_DELIVER = 3;
    uint8 internal constant T_CHECKPOINT = 4;

    enum Side {
        Buy,
        Sell
    }

    enum Outcome {
        Bought,
        Sold,
        Failed
    }

    enum DeliverMode {
        Stock,
        Settlement
    }

    /// @dev Hub → vault. Buy: `amountIn` is settlement (6 dp), `minOut` is shares (18 dp).
    ///      Sell: `amountIn` is shares (18 dp), `minOut` is settlement (6 dp).
    struct Order {
        bytes32 ref;
        address underlying;
        Side side;
        uint128 amountIn;
        uint128 minOut;
    }

    /// @dev Vault → hub. Bought: `amountOut` shares. Sold: `amountOut` settlement (6 dp). Failed: 0.
    struct Result {
        bytes32 ref;
        address underlying;
        Outcome outcome;
        uint128 amountIn;
        uint128 amountOut;
        uint64 seq;
    }

    /// @dev Canonical redemption: hand `shares` of `underlying` (or their sale proceeds) to `to` on the reserve chain.
    struct Deliver {
        bytes32 ref;
        address underlying;
        uint128 shares;
        address to;
        DeliverMode mode;
    }

    /// @dev Merkle root of vault results with sequence numbers `fromSeq..toSeq` (inclusive).
    struct Checkpoint {
        bytes32 root;
        uint64 fromSeq;
        uint64 toSeq;
    }

    error BadMessageType(uint8 got, uint8 want);

    function encode(Order memory o) internal pure returns (bytes memory) {
        return abi.encode(T_ORDER, o);
    }

    function encode(Result memory r) internal pure returns (bytes memory) {
        return abi.encode(T_RESULT, r);
    }

    function encode(Deliver memory d) internal pure returns (bytes memory) {
        return abi.encode(T_DELIVER, d);
    }

    function encode(Checkpoint memory c) internal pure returns (bytes memory) {
        return abi.encode(T_CHECKPOINT, c);
    }

    function kind(bytes memory m) internal pure returns (uint8 t) {
        (t) = abi.decode(m, (uint8));
    }

    function decodeOrder(bytes memory m) internal pure returns (Order memory o) {
        uint8 t;
        (t, o) = abi.decode(m, (uint8, Order));
        if (t != T_ORDER) revert BadMessageType(t, T_ORDER);
    }

    function decodeResult(bytes memory m) internal pure returns (Result memory r) {
        uint8 t;
        (t, r) = abi.decode(m, (uint8, Result));
        if (t != T_RESULT) revert BadMessageType(t, T_RESULT);
    }

    function decodeDeliver(bytes memory m) internal pure returns (Deliver memory d) {
        uint8 t;
        (t, d) = abi.decode(m, (uint8, Deliver));
        if (t != T_DELIVER) revert BadMessageType(t, T_DELIVER);
    }

    function decodeCheckpoint(bytes memory m) internal pure returns (Checkpoint memory c) {
        uint8 t;
        (t, c) = abi.decode(m, (uint8, Checkpoint));
        if (t != T_CHECKPOINT) revert BadMessageType(t, T_CHECKPOINT);
    }

    /// @dev Migration results carry no order: their ref has the top bit set (order refs are small ids),
    ///      then the underlying and a per-underlying nonce, so every batch has a distinct, decodable ref.
    bytes32 internal constant MIGRATION_FLAG = bytes32(uint256(1) << 255);

    function migrationRef(address underlying, uint64 nonce) internal pure returns (bytes32) {
        return MIGRATION_FLAG | bytes32((uint256(uint160(underlying)) << 64) | uint256(nonce));
    }

    function isMigrationRef(bytes32 ref) internal pure returns (bool) {
        return (ref & MIGRATION_FLAG) != 0;
    }

    function migrationUnderlying(bytes32 ref) internal pure returns (address) {
        return address(uint160((uint256(ref) & ~uint256(MIGRATION_FLAG)) >> 64));
    }

    /// @notice Leaf of the reconciliation tree: one vault result. Double-hashed so a leaf can never be
    ///         confused with an internal node (OpenZeppelin MerkleProof convention).
    function leaf(Result memory r) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(r))));
    }
}

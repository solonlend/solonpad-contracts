// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {OAppReceiver, Origin} from "../stock/lz/OAppReceiver.sol";
import {OAppCore} from "../stock/lz/OAppCore.sol";
import {IStockPriceSource, StockObservation} from "./IStockPriceSource.sol";

/// @title RelayedStockSource — Arc side of the relayed Robinhood Chain Chainlink price (design r7 §12.2)
/// @notice Accepts observations only from the fixed `StockPriceSender` peer on Robinhood Chain (LayerZero,
///         same 2-of-3 DVN configuration as the stock hub). Nobody can write a price here: the sender reads
///         Chainlink on RH. Messages are applied per stock in RH block order; an older or replayed read is
///         ignored. `observedAt` is the RH read time (clamped to Arc time), so a message held back in transit
///         shows its true age. Non-proxy; peer changes wait 48h.
contract RelayedStockSource is OAppReceiver, Ownable2Step, IStockPriceSource {
    uint64 public constant CONFIG_DELAY = 48 hours;

    uint32 public immutable rhEid;

    struct PendingPeer {
        bytes32 peer;
        uint64 eta;
    }

    mapping(uint32 eid => PendingPeer) public pendingPeer;
    mapping(address underlying => StockObservation) private _latest;

    event Relayed(
        address indexed underlying, uint256 price18, uint64 sourceUpdatedAt, uint80 roundId, uint64 observedAt, uint64 rhBlock
    );
    event RelayIgnored(address indexed underlying, uint64 rhBlock, uint64 latestBlock);
    event PeerProposed(uint32 indexed eid, bytes32 peer, uint64 eta);

    error NoObservation(address underlying);
    error WrongSource(uint32 eid);
    error Timelocked();

    constructor(address endpoint, address owner_, uint32 rhEid_) OAppCore(endpoint, owner_) Ownable(owner_) {
        require(rhEid_ != 0);
        rhEid = rhEid_;
    }

    function observe(address underlying) external view returns (StockObservation memory o) {
        o = _latest[underlying];
        if (o.observedAt == 0) revert NoObservation(underlying);
    }

    function _lzReceive(Origin calldata origin, bytes32, bytes calldata message, address, bytes calldata)
        internal
        override
    {
        if (origin.srcEid != rhEid) revert WrongSource(origin.srcEid);
        (address[] memory keys, StockObservation[] memory obs) = abi.decode(message, (address[], StockObservation[]));
        require(keys.length == obs.length);
        for (uint256 i; i < keys.length; ++i) {
            StockObservation memory o = obs[i];
            uint64 last = _latest[keys[i]].sourceBlock;
            if (o.sourceBlock <= last || o.price18 == 0 || o.observedAt == 0) {
                emit RelayIgnored(keys[i], o.sourceBlock, last);
                continue;
            }
            if (o.observedAt > block.timestamp) o.observedAt = uint64(block.timestamp);
            _latest[keys[i]] = o;
            emit Relayed(keys[i], o.price18, o.sourceUpdatedAt, o.roundId, o.observedAt, o.sourceBlock);
        }
    }

    function setPeer(uint32 eid, bytes32 peer) public override onlyOwner {
        if (peers[eid] != bytes32(0)) revert Timelocked();
        _setPeer(eid, peer);
    }

    function proposePeer(uint32 eid, bytes32 peer) external onlyOwner {
        uint64 eta = uint64(block.timestamp) + CONFIG_DELAY;
        pendingPeer[eid] = PendingPeer(peer, eta);
        emit PeerProposed(eid, peer, eta);
    }

    function executePeer(uint32 eid) external onlyOwner {
        PendingPeer memory p = pendingPeer[eid];
        if (p.eta == 0 || block.timestamp < p.eta) revert Timelocked();
        delete pendingPeer[eid];
        _setPeer(eid, p.peer);
    }

    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}

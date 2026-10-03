// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {OApp, Origin, MessagingFee} from "../stock/lz/OApp.sol";
import {IStockPriceSource, StockObservation} from "./IStockPriceSource.sol";

/// @title StockPriceSender — Robinhood Chain side of the relayed stock price (design r7 §12.2)
/// @notice Anyone may `poke` with the LayerZero fee: the contract reads each requested stock from its fixed
///         Chainlink source (`ChainlinkStockSource` on RH: the RH equity feeds, fail-closed, wide staleness bound)
///         and sends the observations in one message to the fixed Arc peer (`RelayedStockSource`). The caller
///         chooses only which listed stocks and when; it never supplies a price. A stock whose read fails is
///         skipped (event) instead of blocking the others. There is no scheduled/hourly push: keepers poke on
///         demand (before a launch, a restock or a reward round). Non-proxy; peer changes wait 48h.
contract StockPriceSender is OApp, Ownable2Step {
    uint64 public constant CONFIG_DELAY = 48 hours;
    uint256 public constant MAX_ASSETS = 16;

    IStockPriceSource public immutable source;
    uint32 public immutable arcEid;
    /// @notice Executor options for the Arc side (lzReceive gas).
    bytes public options;

    struct PendingPeer {
        bytes32 peer;
        uint64 eta;
    }

    mapping(uint32 eid => PendingPeer) public pendingPeer;

    event PricesSent(bytes32 indexed guid, uint64 rhBlock, uint256 count, uint256 fee);
    event ObservationSkipped(address indexed underlying, bytes reason);
    event OptionsSet(bytes options);
    event PeerProposed(uint32 indexed eid, bytes32 peer, uint64 eta);

    error NothingToSend();
    error TooMany();
    error Timelocked();
    error NotReceiver();

    constructor(address endpoint, address owner_, IStockPriceSource source_, uint32 arcEid_, bytes memory options_)
        OApp(endpoint, owner_)
        Ownable(owner_)
    {
        require(address(source_) != address(0) && arcEid_ != 0);
        source = source_;
        arcEid = arcEid_;
        options = options_;
    }

    /// @notice The payload `poke` would send now, and how many stocks it carries.
    function collect(address[] calldata underlyings) public view returns (bytes memory payload, uint256 count) {
        if (underlyings.length == 0 || underlyings.length > MAX_ASSETS) revert TooMany();
        address[] memory keys = new address[](underlyings.length);
        StockObservation[] memory obs = new StockObservation[](underlyings.length);
        for (uint256 i; i < underlyings.length; ++i) {
            try source.observe(underlyings[i]) returns (StockObservation memory o) {
                keys[count] = underlyings[i];
                obs[count] = o;
                ++count;
            } catch {}
        }
        assembly ("memory-safe") {
            mstore(keys, count)
            mstore(obs, count)
        }
        payload = abi.encode(keys, obs);
    }

    function quote(address[] calldata underlyings) external view returns (uint256 nativeFee) {
        (bytes memory payload, uint256 count) = collect(underlyings);
        if (count == 0) revert NothingToSend();
        return _quote(arcEid, payload, options, false).nativeFee;
    }

    /// @notice Read and relay. Excess fee is refunded by the endpoint to the caller.
    function poke(address[] calldata underlyings) external payable returns (bytes32 guid) {
        (bytes memory payload, uint256 count) = collect(underlyings);
        if (count == 0) revert NothingToSend();
        if (count != underlyings.length) {
            for (uint256 i; i < underlyings.length; ++i) {
                try source.observe(underlyings[i]) returns (StockObservation memory) {}
                catch (bytes memory reason) {
                    emit ObservationSkipped(underlyings[i], reason);
                }
            }
        }
        guid = _lzSend(arcEid, payload, options, MessagingFee(msg.value, 0), payable(msg.sender)).guid;
        emit PricesSent(guid, uint64(block.number), count, msg.value);
    }

    function setOptions(bytes calldata options_) external onlyOwner {
        options = options_;
        emit OptionsSet(options_);
    }

    /// @notice The first peer per eid is set at deployment; any change waits 48h.
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

    /// @dev Send-only: nothing is accepted from Arc.
    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal pure override {
        revert NotReceiver();
    }

    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) onlyOwner {
        Ownable2Step.transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        Ownable2Step._transferOwnership(newOwner);
    }
}

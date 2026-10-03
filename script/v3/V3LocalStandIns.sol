// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice LOCAL ANVIL ONLY. Stand-ins for external dependencies that do not exist on a
/// fresh devnet (SOLON, RH stock tokens, Chainlink stock feeds, legacy SolonFeeRouter).
/// DeployV3 refuses to deploy these unless LOCAL_STANDINS=true on chainId 31337, and the
/// manifest flags every address that came from here. Never a production parameter.
contract V3StandInToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Phase-5 `stockState(asset)` boundary (SolonStockHub). Always open/transferable/version 1.
contract V3StandInStockStatus {
    function stockState(address) external pure returns (bool, bool, uint256) {
        return (true, true, 1);
    }
}

/// @dev Chainlink AggregatorV3 stand-in behind the local ChainlinkStockSource -> SolonStockOracle path: a fixed
/// 8-dp answer that always reads as just updated (a local devnet has no market hours).
contract V3StandInAggregator {
    uint8 public constant decimals = 8;
    int256 public immutable answer;

    constructor(int256 answer_) {
        answer = answer_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @dev Placeholder for the existing SolonFeeRouter; the buyback route only requires code
/// at deployment. Any swap through it reverts, so no local buyback can succeed by accident.
contract V3StandInFeeRouter {
    fallback() external payable {
        revert("local stand-in");
    }
}

/// @dev LayerZero EndpointV2 surface the stock layer touches at deployment: delegate registration by the
/// OApp constructor, ULN config writes by the OApp's delegate and config reads for VerifyV3. Records
/// config only; quotes and sends refuse (nothing crosses chains on a single local devnet).
contract V3StandInLzEndpoint {
    uint32 public immutable eid;
    mapping(address oapp => address) public delegates;
    mapping(bytes32 => bytes) internal configs;

    struct SetConfigParam {
        uint32 eid;
        uint32 configType;
        bytes config;
    }

    constructor(uint32 eid_) {
        eid = eid_;
    }

    function setDelegate(address d) external {
        delegates[msg.sender] = d;
    }

    function setConfig(address oapp, address lib, SetConfigParam[] calldata params) external {
        require(msg.sender == oapp || msg.sender == delegates[oapp], "not delegate");
        for (uint256 i; i < params.length; ++i) {
            configs[keccak256(abi.encode(oapp, lib, params[i].eid, params[i].configType))] = params[i].config;
        }
    }

    function getConfig(address oapp, address lib, uint32 eid_, uint32 configType) external view returns (bytes memory) {
        return configs[keccak256(abi.encode(oapp, lib, eid_, configType))];
    }

    // r12 (M2): pinned libraries; no default library on the local devnet (unset = (0, default)).
    mapping(address oapp => mapping(uint32 remoteEid => address)) internal sendLibs;
    mapping(address oapp => mapping(uint32 remoteEid => address)) internal receiveLibs;

    function setSendLibrary(address oapp, uint32 eid_, address lib) external {
        require(msg.sender == oapp || msg.sender == delegates[oapp], "not delegate");
        require(lib != address(0) && sendLibs[oapp][eid_] != lib, "same value");
        sendLibs[oapp][eid_] = lib;
    }

    function setReceiveLibrary(address oapp, uint32 eid_, address lib, uint256) external {
        require(msg.sender == oapp || msg.sender == delegates[oapp], "not delegate");
        require(lib != address(0) && receiveLibs[oapp][eid_] != lib, "same value");
        receiveLibs[oapp][eid_] = lib;
    }

    function getSendLibrary(address oapp, uint32 eid_) external view returns (address) {
        return sendLibs[oapp][eid_];
    }

    function isDefaultSendLibrary(address oapp, uint32 eid_) external view returns (bool) {
        return sendLibs[oapp][eid_] == address(0);
    }

    function getReceiveLibrary(address oapp, uint32 eid_) external view returns (address lib, bool isDefault) {
        lib = receiveLibs[oapp][eid_];
        isDefault = lib == address(0);
    }

    function lzToken() external pure returns (address) {
        return address(0);
    }

    fallback() external {
        revert("local stand-in endpoint");
    }
}

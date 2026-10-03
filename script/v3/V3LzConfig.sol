// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice LayerZero V2 ULN (DVN) configuration used by DeployV3 / DeployV3Reserve and checked by the
/// verifiers. Owner decision 2026-09-30: with the unreviewed cap raised to the total cap, the fast lane
/// must not trust a single verifier — every stock-layer OApp (Arc hub, RH reserve vault) requires one
/// fixed DVN plus 1-of-2 optional DVNs (2-of-3 overall), configured on both the send and receive library.
///
/// r9 (2026-10-01): real addresses from LayerZero's metadata API (deployments + dvns, snapshot in
/// docs/evidence/r9/lz-metadata-rh-arc.json) and checked on both chains (code present, dstConfig non-zero toward the
/// other eid). Robinhood Chain 4663 = eid 30416, Arc 5042 = eid 30417; EndpointV2 and the ULN302 libraries share one
/// address on both chains, the DVNs do not. LayerZero's default on this pathway is the Dead DVN in both directions,
/// so every OApp must set its own config on both libraries. Any other chain id (local devnet) keeps the placeholders.
library V3LzConfig {
    uint32 internal constant ULN_CONFIG_TYPE = 2;

    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    struct SetConfigParam {
        uint32 eid;
        uint32 configType;
        bytes config;
    }

    // Local devnet only (sorted ascending, as LayerZero requires).
    address internal constant DVN_PLACEHOLDER_A = address(uint160(0xD7A1));
    address internal constant DVN_PLACEHOLDER_B = address(uint160(0xD7B2));
    address internal constant DVN_PLACEHOLDER_C = address(uint160(0xD7C3));
    address internal constant SEND_LIB_PLACEHOLDER = address(uint160(0x5E4D));
    address internal constant RECEIVE_LIB_PLACEHOLDER = address(uint160(0xAEC1));

    uint256 internal constant RH_CHAIN_ID = 4663;
    uint256 internal constant ARC_CHAIN_ID = 5042;
    // Same address on Robinhood Chain and Arc.
    address internal constant ENDPOINT_V2 = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    address internal constant SEND_ULN302 = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;
    address internal constant RECEIVE_ULN302 = 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043;
    address internal constant EXECUTOR = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
    address internal constant DEAD_DVN = 0x6788f52439ACA6BFF597d3eeC2DC9a44B8FEE842; // LZDeadDVN (both chains)
    // Robinhood Chain DVNs (required: LayerZero Labs; optional 1-of-2: Nethermind, Horizen).
    address internal constant RH_DVN_LZ_LABS = 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12;
    address internal constant RH_DVN_NETHERMIND = 0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8;
    address internal constant RH_DVN_HORIZEN = 0x1258A278519c7f4bd997a9c3BFd4Aa802a028D89;
    // Arc DVNs. 0x282b…46b4 is the deprecated LayerZero Labs DVN (no dstConfig toward 30416): never use it.
    address internal constant ARC_DVN_LZ_LABS = 0xa2447e5B58D357c49Bf74B50B14421e6A100e525;
    address internal constant ARC_DVN_LZ_LABS_DEPRECATED = 0x282b3386571f7f794450d5789911a9804FA346b4;
    address internal constant ARC_DVN_NETHERMIND = 0x9E0E95Ede70F680f74480b510FF9f45C70e3da80;
    address internal constant ARC_DVN_HORIZEN = 0xd36246C322Ee102A2203bCA9cafb84c179D306F6;

    uint8 internal constant MIN_SIGNERS = 2;
    uint8 internal constant MIN_DVNS = 3;

    // ---- Testnets (2026-10-01, LayerZero metadata API + on-chain endpoint/ULN defaults). LayerZero has NOT opened the
    // Arc testnet <-> Robinhood testnet pathway (both endpoints: isSupportedEid == false, no default library or DVN),
    // so the cross-chain drill runs Arc testnet <-> Arbitrum Sepolia (Arbitrum Nitro like RH: ArbSys at 0x64,
    // block.number = L1 block) as the RH stand-in. Each testnet has exactly one live DVN (LayerZero Labs), so the
    // testnet profile is 1 required DVN, set explicitly on both libraries; the mainnet 2-of-3 cannot be reproduced.
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002; // eid 40434
    uint256 internal constant ARB_SEPOLIA_CHAIN_ID = 421614; // eid 40231 (RH stand-in)
    uint256 internal constant RH_TESTNET_CHAIN_ID = 46630; // eid 40451 (no pathway to Arc testnet)
    address internal constant ARC_TESTNET_ENDPOINT = 0x6C7Ab2202C98C4227C5c46f1417D81144DA716Ff;
    address internal constant ARC_TESTNET_SEND_ULN302 = 0xd682ECF100f6F4284138AA925348633B0611Ae21;
    address internal constant ARC_TESTNET_RECEIVE_ULN302 = 0xcF1B0F4106B0324F96fEfcC31bA9498caa80701C;
    address internal constant ARC_TESTNET_DVN_LZ_LABS = 0x88B27057A9e00c5F05DDa29241027afF63f9e6e0;
    address internal constant ARC_TESTNET_DEAD_DVN = 0xF49d162484290EAeAd7bb8C2c7E3a6f8f52e32d6;
    address internal constant ARB_SEPOLIA_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    address internal constant ARB_SEPOLIA_SEND_ULN302 = 0x4f7cd4DA19ABB31b0eC98b9066B9e857B1bf9C0E;
    address internal constant ARB_SEPOLIA_RECEIVE_ULN302 = 0x75Db67CDab2824970131D5aa9CECfC9F69c69636;
    address internal constant ARB_SEPOLIA_DVN_LZ_LABS = 0x53f488E93b4f1b60E8E83aa374dBe1780A1EE8a8;
    address internal constant ARB_SEPOLIA_DEAD_DVN = 0xA85BE08A6Ce2771C730661766AACf2c8Bb24C611;
    address internal constant RH_TESTNET_ENDPOINT = 0x3aCAAf60502791D199a5a5F0B173D78229eBFe32;
    address internal constant RH_TESTNET_SEND_ULN302 = 0x45841dd1ca50265Da7614fC43A361e526c0e6160;
    address internal constant RH_TESTNET_RECEIVE_ULN302 = 0xd682ECF100f6F4284138AA925348633B0611Ae21;
    address internal constant RH_TESTNET_DEAD_DVN = 0x88B27057A9e00c5F05DDa29241027afF63f9e6e0; // = Arc testnet LZ Labs!

    /// @notice 1 required + 1-of-2 optional DVNs of the current chain. `confirmations` must equal the REMOTE send
    ///         side for a receive config (DVNs attest with the sender's count; ReceiveUlnBase._verified needs >=).
    function defaults(uint64 confirmations) internal view returns (UlnConfig memory c) {
        (address a, address b, address d) = dvns(block.chainid);
        c.confirmations = confirmations;
        if (testnet(block.chainid)) {
            // Testnet profile: the only live DVN (LayerZero Labs) as the single required DVN, no optional set.
            c.requiredDVNCount = 1;
            c.requiredDVNs = new address[](1);
            c.requiredDVNs[0] = a;
            c.optionalDVNs = new address[](0);
            return c;
        }
        c.requiredDVNCount = 1;
        c.requiredDVNs = new address[](1);
        c.requiredDVNs[0] = a;
        c.optionalDVNCount = 2;
        c.optionalDVNs = new address[](2);
        c.optionalDVNs[0] = b;
        c.optionalDVNs[1] = d;
        c.optionalDVNThreshold = 1;
    }

    function dvns(uint256 chainId) internal pure returns (address required, address optionalA, address optionalB) {
        if (chainId == RH_CHAIN_ID) return (RH_DVN_LZ_LABS, RH_DVN_NETHERMIND, RH_DVN_HORIZEN);
        if (chainId == ARC_CHAIN_ID) return (ARC_DVN_LZ_LABS, ARC_DVN_NETHERMIND, ARC_DVN_HORIZEN);
        if (chainId == ARC_TESTNET_CHAIN_ID) return (ARC_TESTNET_DVN_LZ_LABS, address(0), address(0));
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return (ARB_SEPOLIA_DVN_LZ_LABS, address(0), address(0));
        return (DVN_PLACEHOLDER_A, DVN_PLACEHOLDER_B, DVN_PLACEHOLDER_C);
    }

    function live(uint256 chainId) internal pure returns (bool) {
        return chainId == RH_CHAIN_ID || chainId == ARC_CHAIN_ID || testnet(chainId);
    }

    /// @notice Arc testnet / Arbitrum Sepolia (RH stand-in): real LayerZero, single-DVN testnet profile.
    function testnet(uint256 chainId) internal pure returns (bool) {
        return chainId == ARC_TESTNET_CHAIN_ID || chainId == ARB_SEPOLIA_CHAIN_ID;
    }

    function endpoint(uint256 chainId) internal pure returns (address) {
        if (chainId == ARC_TESTNET_CHAIN_ID) return ARC_TESTNET_ENDPOINT;
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return ARB_SEPOLIA_ENDPOINT;
        if (chainId == RH_TESTNET_CHAIN_ID) return RH_TESTNET_ENDPOINT;
        return ENDPOINT_V2;
    }

    function sendLib(uint256 chainId) internal pure returns (address) {
        if (chainId == ARC_TESTNET_CHAIN_ID) return ARC_TESTNET_SEND_ULN302;
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return ARB_SEPOLIA_SEND_ULN302;
        if (chainId == RH_TESTNET_CHAIN_ID) return RH_TESTNET_SEND_ULN302;
        return live(chainId) ? SEND_ULN302 : SEND_LIB_PLACEHOLDER;
    }

    function receiveLib(uint256 chainId) internal pure returns (address) {
        if (chainId == ARC_TESTNET_CHAIN_ID) return ARC_TESTNET_RECEIVE_ULN302;
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return ARB_SEPOLIA_RECEIVE_ULN302;
        if (chainId == RH_TESTNET_CHAIN_ID) return RH_TESTNET_RECEIVE_ULN302;
        return live(chainId) ? RECEIVE_ULN302 : RECEIVE_LIB_PLACEHOLDER;
    }

    /// @notice True when any DVN is LayerZero's Dead DVN (of the current chain) or the deprecated Arc LZ Labs DVN.
    function dead(UlnConfig memory c) internal view returns (bool) {
        for (uint256 i; i < c.requiredDVNs.length; ++i) {
            if (_isDead(c.requiredDVNs[i])) return true;
        }
        for (uint256 i; i < c.optionalDVNs.length; ++i) {
            if (_isDead(c.optionalDVNs[i])) return true;
        }
        return false;
    }

    /// @notice On a live chain: exactly this chain's default DVN set (catches a config copied from the other chain).
    function matchesChain(UlnConfig memory c, uint256 chainId) internal pure returns (bool) {
        (address a, address b, address d) = dvns(chainId);
        if (testnet(chainId)) {
            return c.requiredDVNs.length == 1 && c.requiredDVNs[0] == a && c.optionalDVNs.length == 0
                && c.optionalDVNThreshold == 0;
        }
        return c.requiredDVNs.length == 1 && c.requiredDVNs[0] == a && c.optionalDVNs.length == 2
            && c.optionalDVNs[0] == b && c.optionalDVNs[1] == d && c.optionalDVNThreshold == 1;
    }

    /// @notice The DVN strength this chain must have: 2-of-3 on mainnet/devnet, the single live DVN on a testnet.
    function adequate(UlnConfig memory c) internal view returns (bool) {
        if (!testnet(block.chainid)) return strong(c);
        return c.requiredDVNs.length == 1 && c.requiredDVNCount == 1 && c.requiredDVNs[0] != address(0)
            && c.optionalDVNs.length == 0 && c.optionalDVNCount == 0 && c.optionalDVNThreshold == 0;
    }

    function _isDead(address a) private view returns (bool) {
        if (block.chainid == ARC_TESTNET_CHAIN_ID) return a == ARC_TESTNET_DEAD_DVN;
        if (block.chainid == ARB_SEPOLIA_CHAIN_ID) return a == ARB_SEPOLIA_DEAD_DVN;
        if (block.chainid == RH_TESTNET_CHAIN_ID) return a == RH_TESTNET_DEAD_DVN;
        return a == DEAD_DVN || a == ARC_DVN_LZ_LABS_DEPRECATED;
    }

    function params(uint32 remoteEid, UlnConfig memory c) internal pure returns (SetConfigParam[] memory p) {
        p = new SetConfigParam[](1);
        p[0] = SetConfigParam(remoteEid, ULN_CONFIG_TYPE, abi.encode(c));
    }

    /// @notice True when `c` needs at least 2 independent DVN signatures out of at least 3 DVNs, with
    ///         sorted, distinct, non-zero addresses.
    function strong(UlnConfig memory c) internal pure returns (bool) {
        if (c.requiredDVNs.length != c.requiredDVNCount || c.optionalDVNs.length != c.optionalDVNCount) return false;
        if (uint256(c.requiredDVNCount) + c.optionalDVNThreshold < MIN_SIGNERS) return false;
        if (uint256(c.requiredDVNCount) + c.optionalDVNCount < MIN_DVNS) return false;
        if (c.optionalDVNCount > 0 && (c.optionalDVNThreshold == 0 || c.optionalDVNThreshold > c.optionalDVNCount)) {
            return false;
        }
        return _sorted(c.requiredDVNs) && _sorted(c.optionalDVNs) && _disjoint(c.requiredDVNs, c.optionalDVNs);
    }

    function placeholder(UlnConfig memory c) internal pure returns (bool) {
        for (uint256 i; i < c.requiredDVNs.length; ++i) {
            if (_isPlaceholder(c.requiredDVNs[i])) return true;
        }
        for (uint256 i; i < c.optionalDVNs.length; ++i) {
            if (_isPlaceholder(c.optionalDVNs[i])) return true;
        }
        return false;
    }

    function _isPlaceholder(address a) private pure returns (bool) {
        return a == DVN_PLACEHOLDER_A || a == DVN_PLACEHOLDER_B || a == DVN_PLACEHOLDER_C;
    }

    function _sorted(address[] memory a) private pure returns (bool) {
        for (uint256 i; i < a.length; ++i) {
            if (a[i] == address(0) || (i > 0 && a[i] <= a[i - 1])) return false;
        }
        return true;
    }

    function _disjoint(address[] memory a, address[] memory b) private pure returns (bool) {
        for (uint256 i; i < a.length; ++i) {
            for (uint256 j; j < b.length; ++j) {
                if (a[i] == b[j]) return false;
            }
        }
        return true;
    }
}

/// @dev r12 (review M2): the MessageLibManager surface of EndpointV2 used to pin each OApp's libraries (an OApp left on
///      the default library would silently follow a LayerZero default change, with that library's default DVNs).
interface IV3LzEndpointConfig {
    function setConfig(address oapp, address lib, V3LzConfig.SetConfigParam[] calldata params) external;
    function setSendLibrary(address oapp, uint32 eid, address newLib) external;
    function setReceiveLibrary(address oapp, uint32 eid, address newLib, uint256 gracePeriod) external;
    function getSendLibrary(address sender, uint32 dstEid) external view returns (address lib);
    function isDefaultSendLibrary(address sender, uint32 dstEid) external view returns (bool);
    function getReceiveLibrary(address receiver, uint32 srcEid) external view returns (address lib, bool isDefault);
    function getConfig(address oapp, address lib, uint32 eid, uint32 configType) external view returns (bytes memory);
    function delegates(address oapp) external view returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice FORK-ONLY stand-ins for Arc's native-USDC system precompiles, installed with `anvil_setCode` on a local
///         anvil fork of Arc mainnet (never deployed anywhere). Arc's USDC ERC-20 view (0x3600…0000, FiatToken
///         implementation 0xC6AD…3cA6) moves the native balance through `NATIVE_COIN_AUTHORITY` (0x1800…0000) and
///         checks `NATIVE_COIN_CONTROL` (0x1800…0001). anvil has neither, so every ERC-20 `transfer` of USDC reverts
///         with OpcodeNotFound. Run anvil with `--celo`: its Celo transfer precompile at 0xfd moves native balances
///         from any caller, which is exactly the authority Arc's precompile gives the USDC contract.
/// @dev    Selectors are the ones the live implementation calls (decoded from its bytecode, 2026-10-01).
contract ArcNativeCoinAuthorityShim {
    /// @dev Native USDC minted on the fork comes out of this pre-funded reserve (anvil_setBalance).
    address public constant MINT_RESERVE = 0x18000000000000000000000000000000000000Ff;
    address public constant BURN_SINK = 0x18000000000000000000000000000000000000FE;

    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes4 sel = bytes4(data[:4]);
        if (sel == bytes4(keccak256("transfer(address,address,uint256)"))) {
            (address from, address to, uint256 v) = abi.decode(data[4:], (address, address, uint256));
            _move(from, to, v);
        } else if (sel == bytes4(keccak256("mint(address,uint256)"))) {
            (address to, uint256 v) = abi.decode(data[4:], (address, uint256));
            _move(MINT_RESERVE, to, v);
        } else if (sel == bytes4(keccak256("burn(address,uint256)"))) {
            (address from, uint256 v) = abi.decode(data[4:], (address, uint256));
            _move(from, BURN_SINK, v);
        } else {
            revert("ArcNativeCoinAuthorityShim: unknown selector");
        }
        return abi.encode(true);
    }

    function _move(address from, address to, uint256 v) private {
        if (v == 0) return;
        (bool ok,) = address(0xfd).call(abi.encode(from, to, v));
        require(ok, "celo transfer precompile failed (run anvil with --celo)");
    }
}

/// @notice FORK-ONLY: `NATIVE_COIN_CONTROL` (0x1800…0001). Nothing is blocklisted on the fork.
contract ArcNativeCoinControlShim {
    fallback(bytes calldata) external payable returns (bytes memory) {
        return abi.encode(false);
    }
}

/// @notice FORK-ONLY: Robinhood Chain's ArbSys precompile (0x64). On the real rollup it is native code; on an anvil
///         fork the address only holds Arbitrum's 0xfe stub, so `ReserveVault.checkpoint` (sendTxToL1) cannot run.
///         The shim keeps the outbound message as an event, which the fork harness then executes on the Ethereum fork
///         through the real Bridge (as the rollup's Outbox would after the 7-day challenge period).
contract RobinhoodArbSysShim {
    event L2ToL1Tx(address caller, address indexed destination, uint256 indexed position, uint256 callvalue, bytes data);

    uint256 public sent;

    function sendTxToL1(address destination, bytes calldata data) external payable returns (uint256 id) {
        id = sent++;
        emit L2ToL1Tx(msg.sender, destination, id, msg.value, data);
    }

    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function arbChainID() external view returns (uint256) {
        return block.chainid;
    }
}

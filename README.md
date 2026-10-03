# SolonPad — contracts

Every contract SolonPad runs in production, in the open: the V3 stock-reward
launchpad (`src/v3/`, see below), the Pons V2 curve engine port (`src/v2/`), the aggregator's `SolonFeeRouter` (`src/aggregator/`), and the
deployment/config scripts. Radian-lineage sources (`src/radian/`, root factory)
are kept for provenance; SolonPad does not deploy them.

## SolonPad V3 (`src/v3/`) — live on mainnet since 2026-10-03

SolonPad V3 is a stock-reward launchpad: every coin launched through `V3LaunchFactory` trades in a Uniswap v4
pool whose fee hook (`V3QuoteFeeHook`) books each fee into an immutable six-way ledger (`V3FeeLedger`), and the
holders' share is paid out in tokenized US stocks (NVDA / AAPL / TSLA, bought on Robinhood Chain and represented
on Arc by `SolonStockToken`).

### Fee split (hard-coded in `V3FeeLedger._credit`)

| Bucket | Share | Receiver (as wired by `V3LaunchFactory` / `script/v3/DeployV3.s.sol`) |
|---|---|---|
| 0 | 57.50% | Coin holders — the launched token itself, paid out as stock via reward rounds |
| 1 | 10.00% | Creator — holder of the coin's `CreatorRightsNFT` |
| 2 | 10.00% | Desk NFT holders — `DeskRewards` |
| 3 | 5.00% | SOLON stakers — `SolonStakingV2` |
| 4 | 10.00% | SOLON buyback & burn — `BuybackBurnExecutor` |
| 5 | 7.50% | Protocol — `ProtocolVault` |

For stock-quoted pools, buckets 4 and 5 go through `StockFeeConverter` first (stock → USDC), then on to the
buyback and protocol vaults. Rounding remainders stay per bucket in the ledger; they are never swept as surplus.

### Architecture (text)

```
Arc (5042)                                         Robinhood Chain (4663)            Ethereum (1)
──────────                                         ──────────────────────            ────────────
V3LaunchFactory ─ deploys coin + v4 pool           ReserveVault (USDG float,         EthereumBridger
V3QuoteFeeHook  ─ takes swap fee ─► V3FeeLedger      buys/sells stock via              (canonical lane:
V3FeeLedger ─► holders │ creator │ desk │ stake       RestrictedVenue / Uniswap V3)     CCTP v2 + RH L1
              │ buyback │ protocol                 ChainlinkStockSource ─►            inbox)
RewardRoundManager / RewardBatcher /                 StockPriceSender ── LayerZero ──► RelayedStockSource
  RewardDistributor ─ batch holder fees into       RelayFundingRoute (Relay fills)       └► SolonStockOracle (Arc)
  stock orders, pay holders in SolonStockToken
SolonStockHub ◄── LayerZero / Relay / CCTP ──────► ReserveVault
  (CapacityController limits, OrderScheduler,
   CanonicalGate, StockPoolVault = pool A)
Admin: V3Governance (48h timelock) on Arc and Robinhood Chain; EthereumBridger is owned by the proposer Safe.
```

Off-chain keepers (`keepers/v3/`, Node ≥ 20, ethers v6) only trigger permissionless or keeper-role
functions (reward rounds, payout push, oracle push, pool-A restock, fee ingress, refunds); they cannot move user
funds outside what the contracts allow. Each keeper reads its signing key from a file named by an environment
variable; see `keepers/v3/config/*.example.json`.

### Mainnet contracts

`src/v3/` is the frozen source of this deployment, built with the settings below. Two comment lines were edited for
publication; comments do not reach the bytecode (the build has no metadata), which the reproduction check below
confirms. Contracts in `src/v3/` that do not appear here are not part of the mainnet deployment.
"Etherscan" means the Etherscan V2 family (arc.etherscan.io, robin.etherscan.io, etherscan.io).

**Arc (chainId 5042)** — 60 contracts

| Contract | Address | Verification | Explorer |
|---|---|---|---|
| BurnSink | `0xa6fa998dedd85bd22454d42819c360b2e4fb4c8b` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xa6fa998dedd85bd22454d42819c360b2e4fb4c8b?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xa6fa998dedd85bd22454d42819c360b2e4fb4c8b) · [Etherscan](https://arc.etherscan.io/address/0xa6fa998dedd85bd22454d42819c360b2e4fb4c8b#code) |
| BuybackBurnExecutor | `0xfe3f4be4b1f6869721ab68cb3e0eae160225db09` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xfe3f4be4b1f6869721ab68cb3e0eae160225db09?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xfe3f4be4b1f6869721ab68cb3e0eae160225db09) · [Etherscan](https://arc.etherscan.io/address/0xfe3f4be4b1f6869721ab68cb3e0eae160225db09#code) |
| BuybackVault | `0x8f5abe9f9616b3cc4e86d86548e5063b97bf982c` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x8f5abe9f9616b3cc4e86d86548e5063b97bf982c?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x8f5abe9f9616b3cc4e86d86548e5063b97bf982c) · [Etherscan](https://arc.etherscan.io/address/0x8f5abe9f9616b3cc4e86d86548e5063b97bf982c#code) |
| CanonicalGate | `0x70ab3b995afd0313caa1f35d70a64a6bc8906915` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x70ab3b995afd0313caa1f35d70a64a6bc8906915?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x70ab3b995afd0313caa1f35d70a64a6bc8906915) · [Etherscan](https://arc.etherscan.io/address/0x70ab3b995afd0313caa1f35d70a64a6bc8906915#code) |
| CapacityController | `0xca6430bafb0fd871b3586ed4dc3bf7d684b8f4c5` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xca6430bafb0fd871b3586ed4dc3bf7d684b8f4c5?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xca6430bafb0fd871b3586ed4dc3bf7d684b8f4c5) · [Etherscan](https://arc.etherscan.io/address/0xca6430bafb0fd871b3586ed4dc3bf7d684b8f4c5#code) |
| CreatorRightsNFT | `0xb8fe6ac8e19669edd06179ba23509e88bd394627` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xb8fe6ac8e19669edd06179ba23509e88bd394627?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xb8fe6ac8e19669edd06179ba23509e88bd394627) · [Etherscan](https://arc.etherscan.io/address/0xb8fe6ac8e19669edd06179ba23509e88bd394627#code) |
| DeskNFT | `0x02c83604ba74a952f931ab3d77c1efe31935793d` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x02c83604ba74a952f931ab3d77c1efe31935793d?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x02c83604ba74a952f931ab3d77c1efe31935793d) · [Etherscan](https://arc.etherscan.io/address/0x02c83604ba74a952f931ab3d77c1efe31935793d#code) |
| DeskRewards | `0xa92ae21934504a8c10d917981498ce71956cd7d9` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xa92ae21934504a8c10d917981498ce71956cd7d9?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xa92ae21934504a8c10d917981498ce71956cd7d9) · [Etherscan](https://arc.etherscan.io/address/0xa92ae21934504a8c10d917981498ce71956cd7d9#code) |
| EligibilityController | `0x2c9dd95d4a06154a011d5a2c3fc3d33caa46e355` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x2c9dd95d4a06154a011d5a2c3fc3d33caa46e355?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x2c9dd95d4a06154a011d5a2c3fc3d33caa46e355) · [Etherscan](https://arc.etherscan.io/address/0x2c9dd95d4a06154a011d5a2c3fc3d33caa46e355#code) |
| EligibilityRegistry | `0xf29c57341b3750adc50da62ff76c01f0aef1f82d` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xf29c57341b3750adc50da62ff76c01f0aef1f82d?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xf29c57341b3750adc50da62ff76c01f0aef1f82d) · [Etherscan](https://arc.etherscan.io/address/0xf29c57341b3750adc50da62ff76c01f0aef1f82d#code) |
| FixedV4BuybackRoute | `0x093d4a2c9c4ddc8d29ca24a99313a0cb34c57b33` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x093d4a2c9c4ddc8d29ca24a99313a0cb34c57b33?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x093d4a2c9c4ddc8d29ca24a99313a0cb34c57b33) · [Etherscan](https://arc.etherscan.io/address/0x093d4a2c9c4ddc8d29ca24a99313a0cb34c57b33#code) |
| FixedV4FeeSellRoute (V2FeeSellRoute) | `0x75f72f72cb570c3dbd5b3bebe3d9d8078014616d` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x75f72f72cb570c3dbd5b3bebe3d9d8078014616d?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x75f72f72cb570c3dbd5b3bebe3d9d8078014616d) · [Etherscan](https://arc.etherscan.io/address/0x75f72f72cb570c3dbd5b3bebe3d9d8078014616d#code) |
| HubExits | `0x48b04ef8458863c8ed669c5facedf47f5bc179fe` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x48b04ef8458863c8ed669c5facedf47f5bc179fe?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x48b04ef8458863c8ed669c5facedf47f5bc179fe) · [Etherscan](https://arc.etherscan.io/address/0x48b04ef8458863c8ed669c5facedf47f5bc179fe#code) |
| HubSettlement | `0xa4dae7d084066700368931ace5a072778100fabe` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xa4dae7d084066700368931ace5a072778100fabe?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xa4dae7d084066700368931ace5a072778100fabe) · [Etherscan](https://arc.etherscan.io/address/0xa4dae7d084066700368931ace5a072778100fabe#code) |
| LaunchPayoutChoice | `0xfe3b45ebb4db154174a0448e2f259af1578881a0` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xfe3b45ebb4db154174a0448e2f259af1578881a0?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xfe3b45ebb4db154174a0448e2f259af1578881a0) · [Etherscan](https://arc.etherscan.io/address/0xfe3b45ebb4db154174a0448e2f259af1578881a0#code) |
| OpsVault | `0x0a0a192db331a3bc5da4dcf62f91214229e26477` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x0a0a192db331a3bc5da4dcf62f91214229e26477?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x0a0a192db331a3bc5da4dcf62f91214229e26477) · [Etherscan](https://arc.etherscan.io/address/0x0a0a192db331a3bc5da4dcf62f91214229e26477#code) |
| OracleRefTickSigner | `0x5b3ece4548587bbbd737654fd0e4de82c0366f54` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x5b3ece4548587bbbd737654fd0e4de82c0366f54?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x5b3ece4548587bbbd737654fd0e4de82c0366f54) · [Etherscan](https://arc.etherscan.io/address/0x5b3ece4548587bbbd737654fd0e4de82c0366f54#code) |
| OrderScheduler | `0x13abea7cd4a7ebb0a1b378225b42b6a37e4c5818` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x13abea7cd4a7ebb0a1b378225b42b6a37e4c5818?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x13abea7cd4a7ebb0a1b378225b42b6a37e4c5818) · [Etherscan](https://arc.etherscan.io/address/0x13abea7cd4a7ebb0a1b378225b42b6a37e4c5818#code) |
| PoolSwapTest (Uniswap v4-core test router, sell route) | `0x6f9df4dfc9402aec37915d5c7ccc15d96f9f4324` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x6f9df4dfc9402aec37915d5c7ccc15d96f9f4324?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x6f9df4dfc9402aec37915d5c7ccc15d96f9f4324) · [Etherscan](https://arc.etherscan.io/address/0x6f9df4dfc9402aec37915d5c7ccc15d96f9f4324#code) |
| ProtocolDeskVault | `0xec2e2f30d30cb658860158916ff3a922ee97a051` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xec2e2f30d30cb658860158916ff3a922ee97a051?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xec2e2f30d30cb658860158916ff3a922ee97a051) · [Etherscan](https://arc.etherscan.io/address/0xec2e2f30d30cb658860158916ff3a922ee97a051#code) |
| ProtocolVault | `0xf14a184b93a47de64d0f747c6cce5d38eb67082d` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xf14a184b93a47de64d0f747c6cce5d38eb67082d?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xf14a184b93a47de64d0f747c6cce5d38eb67082d) · [Etherscan](https://arc.etherscan.io/address/0xf14a184b93a47de64d0f747c6cce5d38eb67082d#code) |
| RelayedStockSource (StockPriceSource) | `0xbada494b74964f9b24dca02737dac68825835b7b` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xbada494b74964f9b24dca02737dac68825835b7b?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xbada494b74964f9b24dca02737dac68825835b7b) · [Etherscan](https://arc.etherscan.io/address/0xbada494b74964f9b24dca02737dac68825835b7b#code) |
| RelayFundingRoute | `0x6de85f5869be90cacd5b6cfb0e4e009a8d72e3e0` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x6de85f5869be90cacd5b6cfb0e4e009a8d72e3e0?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x6de85f5869be90cacd5b6cfb0e4e009a8d72e3e0) · [Etherscan](https://arc.etherscan.io/address/0x6de85f5869be90cacd5b6cfb0e4e009a8d72e3e0#code) |
| RewardAssetSchedule | `0x6206537d024ff083ff8353163e9a681eed28274a` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x6206537d024ff083ff8353163e9a681eed28274a?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x6206537d024ff083ff8353163e9a681eed28274a) · [Etherscan](https://arc.etherscan.io/address/0x6206537d024ff083ff8353163e9a681eed28274a#code) |
| RewardBatcher | `0x985cdee43c500b64b4a749262d26e440af6ab748` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x985cdee43c500b64b4a749262d26e440af6ab748?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x985cdee43c500b64b4a749262d26e440af6ab748) · [Etherscan](https://arc.etherscan.io/address/0x985cdee43c500b64b4a749262d26e440af6ab748#code) |
| RewardDistributor | `0x9b68469bbaced6dc92f5bb3cfe25e1097d193c9a` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x9b68469bbaced6dc92f5bb3cfe25e1097d193c9a?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x9b68469bbaced6dc92f5bb3cfe25e1097d193c9a) · [Etherscan](https://arc.etherscan.io/address/0x9b68469bbaced6dc92f5bb3cfe25e1097d193c9a#code) |
| RewardPayoutVault | `0x53ef255af936c28a6f6eade7bfb3ab3a6ecd58dd` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x53ef255af936c28a6f6eade7bfb3ab3a6ecd58dd?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x53ef255af936c28a6f6eade7bfb3ab3a6ecd58dd) · [Etherscan](https://arc.etherscan.io/address/0x53ef255af936c28a6f6eade7bfb3ab3a6ecd58dd#code) |
| RewardRoundManager | `0xe5fadf6e409e0ed9d544beb53cdac646b61efab6` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xe5fadf6e409e0ed9d544beb53cdac646b61efab6?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xe5fadf6e409e0ed9d544beb53cdac646b61efab6) · [Etherscan](https://arc.etherscan.io/address/0xe5fadf6e409e0ed9d544beb53cdac646b61efab6#code) |
| RewardVault | `0x38a42d8432fd8df79c26650d6c2b25ada1149f61` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x38a42d8432fd8df79c26650d6c2b25ada1149f61?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x38a42d8432fd8df79c26650d6c2b25ada1149f61) · [Etherscan](https://arc.etherscan.io/address/0x38a42d8432fd8df79c26650d6c2b25ada1149f61#code) |
| SolonStakingV2 | `0xd20a87639b5a3e86a815627e468072c3a3276172` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xd20a87639b5a3e86a815627e468072c3a3276172?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xd20a87639b5a3e86a815627e468072c3a3276172) · [Etherscan](https://arc.etherscan.io/address/0xd20a87639b5a3e86a815627e468072c3a3276172#code) |
| SolonStockAdapter | `0x7b5befdcabbd1d263f18d6daa03d066581ffc116` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x7b5befdcabbd1d263f18d6daa03d066581ffc116?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x7b5befdcabbd1d263f18d6daa03d066581ffc116) · [Etherscan](https://arc.etherscan.io/address/0x7b5befdcabbd1d263f18d6daa03d066581ffc116#code) |
| SolonStockAdapter (SolonStockAdapter_AAPL) | `0xc4657c216e531e19235469423da942ef5e527c15` | Etherscan Similar Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xc4657c216e531e19235469423da942ef5e527c15?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xc4657c216e531e19235469423da942ef5e527c15) · [Etherscan](https://arc.etherscan.io/address/0xc4657c216e531e19235469423da942ef5e527c15#code) |
| SolonStockAdapter (SolonStockAdapter_TSLA) | `0x1bfc189de75036c2d2ca4ae42ff3e92c932bf4a2` | Etherscan Similar Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x1bfc189de75036c2d2ca4ae42ff3e92c932bf4a2?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x1bfc189de75036c2d2ca4ae42ff3e92c932bf4a2) · [Etherscan](https://arc.etherscan.io/address/0x1bfc189de75036c2d2ca4ae42ff3e92c932bf4a2#code) |
| SolonStockHub | `0x9e8d7502a702d195631937acb69bf30ffad3786c` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x9e8d7502a702d195631937acb69bf30ffad3786c?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x9e8d7502a702d195631937acb69bf30ffad3786c) · [Etherscan](https://arc.etherscan.io/address/0x9e8d7502a702d195631937acb69bf30ffad3786c#code) |
| SolonStockOracle | `0xacc5c366a3bdf3b3c452a8f24548b14af16cb466` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xacc5c366a3bdf3b3c452a8f24548b14af16cb466?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xacc5c366a3bdf3b3c452a8f24548b14af16cb466) · [Etherscan](https://arc.etherscan.io/address/0xacc5c366a3bdf3b3c452a8f24548b14af16cb466#code) |
| SolonStockSellRoute (StockFeeSellRoute) | `0x97dfb4337b93b589a4b783a87424f6d51caf8294` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x97dfb4337b93b589a4b783a87424f6d51caf8294?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x97dfb4337b93b589a4b783a87424f6d51caf8294) · [Etherscan](https://arc.etherscan.io/address/0x97dfb4337b93b589a4b783a87424f6d51caf8294#code) |
| SolonStockToken (StockToken) | `0x2312290792cf429605d09a42fa43dab810486c18` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x2312290792cf429605d09a42fa43dab810486c18?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x2312290792cf429605d09a42fa43dab810486c18) · [Etherscan](https://arc.etherscan.io/address/0x2312290792cf429605d09a42fa43dab810486c18#code) |
| SolonStockToken (StockToken_AAPL) | `0x785415d2994222533e3a0eca9fe95cc41623d9cf` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x785415d2994222533e3a0eca9fe95cc41623d9cf?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x785415d2994222533e3a0eca9fe95cc41623d9cf) · [Etherscan](https://arc.etherscan.io/address/0x785415d2994222533e3a0eca9fe95cc41623d9cf#code) |
| SolonStockToken (StockToken_TSLA) | `0xaf91a1f046d7ab339b7ff71c0f4d9c166eb1f308` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xaf91a1f046d7ab339b7ff71c0f4d9c166eb1f308?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xaf91a1f046d7ab339b7ff71c0f4d9c166eb1f308) · [Etherscan](https://arc.etherscan.io/address/0xaf91a1f046d7ab339b7ff71c0f4d9c166eb1f308#code) |
| StakingRewardSourceFactory | `0x76fac7b94d7c6514522840b4cb3be2ea6c58dda5` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x76fac7b94d7c6514522840b4cb3be2ea6c58dda5?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x76fac7b94d7c6514522840b4cb3be2ea6c58dda5) · [Etherscan](https://arc.etherscan.io/address/0x76fac7b94d7c6514522840b4cb3be2ea6c58dda5#code) |
| StockAdapterRegistry | `0x9a89e458f00835e6b8c1c67cca009e135a47f43d` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x9a89e458f00835e6b8c1c67cca009e135a47f43d?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x9a89e458f00835e6b8c1c67cca009e135a47f43d) · [Etherscan](https://arc.etherscan.io/address/0x9a89e458f00835e6b8c1c67cca009e135a47f43d#code) |
| StockFeeConverter | `0xdf5ee72df3e5b4fb5fa56391bef23331eef65d1e` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xdf5ee72df3e5b4fb5fa56391bef23331eef65d1e?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xdf5ee72df3e5b4fb5fa56391bef23331eef65d1e) · [Etherscan](https://arc.etherscan.io/address/0xdf5ee72df3e5b4fb5fa56391bef23331eef65d1e#code) |
| StockPoolVault | `0x3a8fec5ca16ad845d7f9f6002d8ff4a64f73d3e2` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x3a8fec5ca16ad845d7f9f6002d8ff4a64f73d3e2?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x3a8fec5ca16ad845d7f9f6002d8ff4a64f73d3e2) · [Etherscan](https://arc.etherscan.io/address/0x3a8fec5ca16ad845d7f9f6002d8ff4a64f73d3e2#code) |
| V2FeeConverter | `0x92fcdd59420964bcdc0fd99067e4e604fc46e198` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x92fcdd59420964bcdc0fd99067e4e604fc46e198?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x92fcdd59420964bcdc0fd99067e4e604fc46e198) · [Etherscan](https://arc.etherscan.io/address/0x92fcdd59420964bcdc0fd99067e4e604fc46e198#code) |
| V2FeeIngress | `0x332cc2e07a80c57601617cd65dfe1cfff97c6551` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x332cc2e07a80c57601617cd65dfe1cfff97c6551?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x332cc2e07a80c57601617cd65dfe1cfff97c6551) · [Etherscan](https://arc.etherscan.io/address/0x332cc2e07a80c57601617cd65dfe1cfff97c6551#code) |
| V2PlatformRouter | `0x1490f4efd1a22c82f3dee1cee1f1d13675e934d2` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x1490f4efd1a22c82f3dee1cee1f1d13675e934d2?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x1490f4efd1a22c82f3dee1cee1f1d13675e934d2) · [Etherscan](https://arc.etherscan.io/address/0x1490f4efd1a22c82f3dee1cee1f1d13675e934d2#code) |
| V3FeeLedger | `0x70bb736ecbfbacf6bddfbfedd7e36d3dac59e088` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x70bb736ecbfbacf6bddfbfedd7e36d3dac59e088?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x70bb736ecbfbacf6bddfbfedd7e36d3dac59e088) · [Etherscan](https://arc.etherscan.io/address/0x70bb736ecbfbacf6bddfbfedd7e36d3dac59e088#code) |
| V3Governance | `0xf50875086526fc658d9c125b1d8e64fa32ae7ddf` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xf50875086526fc658d9c125b1d8e64fa32ae7ddf?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xf50875086526fc658d9c125b1d8e64fa32ae7ddf) · [Etherscan](https://arc.etherscan.io/address/0xf50875086526fc658d9c125b1d8e64fa32ae7ddf#code) |
| V3LaunchFactory | `0xdcfbd25f034d51af797dd7c5c914f16403b54e10` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xdcfbd25f034d51af797dd7c5c914f16403b54e10?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xdcfbd25f034d51af797dd7c5c914f16403b54e10) · [Etherscan](https://arc.etherscan.io/address/0xdcfbd25f034d51af797dd7c5c914f16403b54e10#code) |
| V3LaunchStrategy | `0x96f5df5a13d54cd2fc1e2b4847ee2d0f60df0fcb` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x96f5df5a13d54cd2fc1e2b4847ee2d0f60df0fcb?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x96f5df5a13d54cd2fc1e2b4847ee2d0f60df0fcb) · [Etherscan](https://arc.etherscan.io/address/0x96f5df5a13d54cd2fc1e2b4847ee2d0f60df0fcb#code) |
| V3LaunchValidation | `0x2cdc9eaec639aae869cac5a58d3f3b4e60d9cec7` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x2cdc9eaec639aae869cac5a58d3f3b4e60d9cec7?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x2cdc9eaec639aae869cac5a58d3f3b4e60d9cec7) · [Etherscan](https://arc.etherscan.io/address/0x2cdc9eaec639aae869cac5a58d3f3b4e60d9cec7#code) |
| V3LegacyPools | `0x96b2dc75df6b20eafbc7e098b0af982b08d08a49` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x96b2dc75df6b20eafbc7e098b0af982b08d08a49?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x96b2dc75df6b20eafbc7e098b0af982b08d08a49) · [Etherscan](https://arc.etherscan.io/address/0x96b2dc75df6b20eafbc7e098b0af982b08d08a49#code) |
| V3LPLocker | `0x09650be5c4866971abbd5c9e92ae495a118fd13f` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x09650be5c4866971abbd5c9e92ae495a118fd13f?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x09650be5c4866971abbd5c9e92ae495a118fd13f) · [Etherscan](https://arc.etherscan.io/address/0x09650be5c4866971abbd5c9e92ae495a118fd13f#code) |
| V3MultiHopRouter | `0x79921ce37bf624df9e7e5befade7f6e46b67a699` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x79921ce37bf624df9e7e5befade7f6e46b67a699?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x79921ce37bf624df9e7e5befade7f6e46b67a699) · [Etherscan](https://arc.etherscan.io/address/0x79921ce37bf624df9e7e5befade7f6e46b67a699#code) |
| V3QuoteFeeHook | `0x56071296f4aec96d61715bd906a17a05b75628cc` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x56071296f4aec96d61715bd906a17a05b75628cc?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x56071296f4aec96d61715bd906a17a05b75628cc) · [Etherscan](https://arc.etherscan.io/address/0x56071296f4aec96d61715bd906a17a05b75628cc#code) |
| V3Quoter | `0x70eb10ba50bd323d84c3e213b54e16d911658f48` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x70eb10ba50bd323d84c3e213b54e16d911658f48?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x70eb10ba50bd323d84c3e213b54e16d911658f48) · [Etherscan](https://arc.etherscan.io/address/0x70eb10ba50bd323d84c3e213b54e16d911658f48#code) |
| V3RewardWiring | `0xe59aed8bf93a50c0e1db9a8391c272a73cc23a65` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xe59aed8bf93a50c0e1db9a8391c272a73cc23a65?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xe59aed8bf93a50c0e1db9a8391c272a73cc23a65) · [Etherscan](https://arc.etherscan.io/address/0xe59aed8bf93a50c0e1db9a8391c272a73cc23a65#code) |
| V3Router | `0x0085dc0d8bff401da29591b746f40d5d3ec0d98d` | Etherscan Exact Match; Sourcify match; Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x0085dc0d8bff401da29591b746f40d5d3ec0d98d?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x0085dc0d8bff401da29591b746f40d5d3ec0d98d) · [Etherscan](https://arc.etherscan.io/address/0x0085dc0d8bff401da29591b746f40d5d3ec0d98d#code) |
| V3TokenCodeStore (token code chunk) | `0xfb6bc15d007064ac92cf6e88e11d6c6a86027016` | Etherscan not verified (data contract, runtime is not compiled code); Sourcify match (creation only); Blockscout partial | [Blockscout](https://explorer.arc.io/address/0xfb6bc15d007064ac92cf6e88e11d6c6a86027016?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0xfb6bc15d007064ac92cf6e88e11d6c6a86027016) · [Etherscan](https://arc.etherscan.io/address/0xfb6bc15d007064ac92cf6e88e11d6c6a86027016#code) |
| V3TokenCodeStore (token code chunk) | `0x75f2f0ff2798c5245fb2787d4c8b8621253e1080` | Etherscan not verified (data contract, runtime is not compiled code); Sourcify match (creation only); Blockscout partial | [Blockscout](https://explorer.arc.io/address/0x75f2f0ff2798c5245fb2787d4c8b8621253e1080?tab=contract) · [Sourcify](https://repo.sourcify.dev/5042/0x75f2f0ff2798c5245fb2787d4c8b8621253e1080) · [Etherscan](https://arc.etherscan.io/address/0x75f2f0ff2798c5245fb2787d4c8b8621253e1080#code) |

**Robinhood Chain (chainId 4663)** — 6 contracts

| Contract | Address | Verification | Explorer |
|---|---|---|---|
| ChainlinkStockSource | `0xda32f89eea36f94c9dbd1ad4f04440f2d7e54102` | Etherscan Exact Match; Sourcify match | [Sourcify](https://repo.sourcify.dev/4663/0xda32f89eea36f94c9dbd1ad4f04440f2d7e54102) · [Etherscan](https://robin.etherscan.io/address/0xda32f89eea36f94c9dbd1ad4f04440f2d7e54102#code) |
| RelayFundingRoute | `0x10f163619d966ceab83c47efddd07712145fd596` | Etherscan Exact Match; Sourcify match | [Sourcify](https://repo.sourcify.dev/4663/0x10f163619d966ceab83c47efddd07712145fd596) · [Etherscan](https://robin.etherscan.io/address/0x10f163619d966ceab83c47efddd07712145fd596#code) |
| ReserveVault | `0x3504aa69ca9c5a5bc3da312a6c761e9633251cfc` | Etherscan Exact Match; Sourcify match | [Sourcify](https://repo.sourcify.dev/4663/0x3504aa69ca9c5a5bc3da312a6c761e9633251cfc) · [Etherscan](https://robin.etherscan.io/address/0x3504aa69ca9c5a5bc3da312a6c761e9633251cfc#code) |
| RestrictedVenue | `0xdcccc83e518eec1a3ff9978eb2345014b24f85ab` | Etherscan Exact Match; Sourcify match | [Sourcify](https://repo.sourcify.dev/4663/0xdcccc83e518eec1a3ff9978eb2345014b24f85ab) · [Etherscan](https://robin.etherscan.io/address/0xdcccc83e518eec1a3ff9978eb2345014b24f85ab#code) |
| StockPriceSender | `0xd39b9fa95d28e262ee98a9b23fd0730123048d51` | Etherscan Exact Match; Sourcify match | [Sourcify](https://repo.sourcify.dev/4663/0xd39b9fa95d28e262ee98a9b23fd0730123048d51) · [Etherscan](https://robin.etherscan.io/address/0xd39b9fa95d28e262ee98a9b23fd0730123048d51#code) |
| V3Governance | `0x7505c46bdd74a17c5b8ad514899d5b4c00d705dc` | Etherscan Exact Match; Sourcify match | [Sourcify](https://repo.sourcify.dev/4663/0x7505c46bdd74a17c5b8ad514899d5b4c00d705dc) · [Etherscan](https://robin.etherscan.io/address/0x7505c46bdd74a17c5b8ad514899d5b4c00d705dc#code) |

**Ethereum (chainId 1)** — 1 contracts

| Contract | Address | Verification | Explorer |
|---|---|---|---|
| EthereumBridger | `0x7505c46bdd74a17c5b8ad514899d5b4c00d705dc` | Etherscan Exact Match; Sourcify match | [Sourcify](https://repo.sourcify.dev/1/0x7505c46bdd74a17c5b8ad514899d5b4c00d705dc) · [Etherscan](https://etherscan.io/address/0x7505c46bdd74a17c5b8ad514899d5b4c00d705dc#code) |

The two `V3TokenCodeStore` contracts are data contracts (the constructor returns a chunk of token bytecode as
runtime code), so only their creation code can match. Blockscout / Sourcify can only reach *partial* / *match*
(not *full* / *exact_match*) because the build has no CBOR metadata to compare (see below); the bytecode itself
matches.

### Governance

| Role | Address (same on Arc, Robinhood Chain and Ethereum) |
|---|---|
| Proposer / canceller — 3-of-5 Safe | `0x8798245d1606712828731a238e5414eefBbbB59C` |
| Guardian — 2-of-3 Safe | `0x544ebF74B3C00B5DB21E365B5258a589451529E4` |
| `V3Governance` timelock, Arc | `0xF50875086526FC658D9c125B1D8E64Fa32aE7ddf` |
| `V3Governance` timelock, Robinhood Chain | `0x7505c46BDD74a17c5b8ad514899D5b4C00d705Dc` |

`V3Governance` is an OpenZeppelin v5 `TimelockController` with a hard 48-hour floor (`MIN_DELAY`). Only the
3-of-5 Safe can propose; execution is open to anyone once the delay has passed. The 2-of-3 guardian can cancel
ordinary pending operations and call selectors that a target contract itself declares tighten-only (pause, lower
caps); it cannot propose, execute early or move value. Unpausing and raising limits are always ordinary 48-hour
operations. The deployer's one-shot bootstrap window is closed.

### Build and test

Toolchain: Foundry (checked with forge 1.8.1), solc **0.8.26**, `via_ir = true`, `evm_version = "cancun"`,
optimizer on, **200 runs**, `bytecode_hash = "none"`, `cbor_metadata = false` (all in `foundry.toml`).

```bash
git clone --recurse-submodules https://github.com/solonlend/solonpad-contracts
cd solonpad-contracts
# (existing clone: git submodule update --init --recursive)

forge build --skip 'src/quote-v4/**'
forge test  --skip 'src/quote-v4/**' --match-path 'test/v3/**'
FOUNDRY_PROFILE=deep forge test --skip 'src/quote-v4/**' --match-path 'test/v3/**'   # 10k fuzz / 1k×500 invariant

cd keepers/v3 && npm ci && npm test   # keeper unit tests (no network)
```

`src/quote-v4/` is a reviewable diff against `Uniswap/liquidity-launcher` and only compiles inside that repository,
hence the `--skip`. A via-IR build of the whole tree needs roughly 15 GB of RAM. Fork tests
(`*Fork.t.sol`) read their RPC URL from the environment and are skipped (or no-op) without it.

Dependencies are git submodules pinned to the commits used for the production build: forge-std `bf647bd`,
v4-core `46c6834`, v4-periphery `dce236d` (with its permit2 / v4-core submodules). `lib/openzeppelin-contracts/`
(the OpenZeppelin v5 files the contracts import) and `lib/v4-hooks-public/` (Uniswap `BaseHook`) are vendored
exactly as built; both are MIT.

**Reproducing the on-chain bytecode.** Without CBOR metadata the compiler output does not depend on file paths, so
any checkout reproduces the deployed code byte for byte:

1. `forge build --skip 'src/quote-v4/**'` and take `bytecode.object` from `out/<File>.sol/<Contract>.json`.
2. For contracts that use linked libraries (`SolonStockHub`: `HubExits`, `HubSettlement`; `V3LaunchFactory`:
   `V3LaunchValidation`, `V3LegacyPools`, `V3RewardWiring`), replace each `__$…$__` placeholder with the library
   address from the table above.
3. Get the creation code from the chain — the creation transaction's input for direct deployments, or the
   "Contract Creation Code" an explorer shows for contracts created by `V3Governance` during bootstrap.
4. The creation code starts with the linked compiler output, byte for byte; the remaining bytes are the
   ABI-encoded constructor arguments.

All 65 contracts created by the V3 deployment scripts (59 on Arc, 6 on Robinhood Chain) were checked this way
against this repository's build; `PoolSwapTest` (Arc) and `EthereumBridger` (Ethereum) were deployed separately and
are covered by the explorer verifications above.

## V2: verify against production

| Contract | Chain | Address |
|---|---|---|
| SolonFeeRouter | Arc (5042) | `0x96Ed755a4E176999A892F0E35b5FFf56D25F5D19` |
| SolonFeeRouter | Robinhood (4663) | `0xBef20379BdE976e807d8E6E9E831961512A02278` |
| PonsV2LaunchFactory (Solon Launch) | Arc | `0xd6b86b9B1bB64b941b21AaA6a0e3A673e8405A3b` |
| UERC20Factory (instant v4) | Arc | `0xF94bFe8D7583C2272527C9A45efa5c07b4a26c22` |
| InstantLaunchStrategy (1% LP) | Arc | `0xfA5997445db1E9FB7F7664FD176379B6B26497f0` |
| FeeSplitter (50/50) | Arc | `0xD6B05564ceA990b69ABF10B433279093758e2A54` |
| BeneficiaryVault | Arc | `0xC31c8853f6C0CA12421eb36906dB8BFaf89A85bA` |
| SolonStaking (`src/stake/`) | Arc | `0xB3E0b89b3Ba098D83072dd60c1946CFB3231688f` |
| UERC20Factory | Robinhood | `0x83922922776C121671072C9349D8Cc1867D4856f` |
| InstantLaunchStrategy | Robinhood | `0x3e93DF005AB38B4D0B1aD197Ee161E57A204a5e9` |
| FeeSplitter | Robinhood | `0x6A64C681606845E5Ed4E2340C59414b7d1810631` |
| BeneficiaryVault | Robinhood | `0x8aF664E15D27F6E126662D12D2Db9AedD8113424` |

The instant-v4 engine is the official Uniswap Liquidity Launcher (canonical
launcher `0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0` on both chains) with a
two-line fee constant diff (`LP_FEE = 10000`, `TICK_SPACING = 100`). The curve
engine is a whitespace-faithful port of the Sourcify `exact_match` sources of
the live Pons V2 factory on chain 4663.

## SOLON staking (`src/stake/`)

`SolonStaking` lets holders stake SOLON and earn SOLON: each day's platform-fee
buyback is injected with its buyback tx hash in `RewardAdded` and streamed over
7 days, alongside a one-off 12.69M SOLON genesis pool streamed over 30 days. No
lock, no cooldown — `unstake` returns principal plus accrued rewards in one tx,
and exits can never be paused. Principal and rewards are kept in separate
buckets; the owner cannot move SOLON. Sourcify-verified on Arc — creation and
runtime bytecode both `match`
([repo.sourcify.dev](https://repo.sourcify.dev/5042/0xB3E0b89b3Ba098D83072dd60c1946CFB3231688f)).
It is a partial match, not `exact_match`, because this repo's `foundry.toml`
builds without CBOR metadata, so there is no metadata hash to compare; the
bytecode itself matches. Unaudited. Stake at
https://solonpad.fun/stake; agent call sequences in `solonpad-skill` (§G).

## Build

```bash
git clone --recurse-submodules https://github.com/solonlend/solonpad-contracts
forge build --skip 'src/quote-v4/**'
forge test  --skip 'src/quote-v4/**'
```

Dependencies are pinned git submodules (forge-std `bf647bd`, v4-core `46c6834`, v4-periphery `dce236d`) plus the
vendored OpenZeppelin / `BaseHook` files in `lib/`; see the V3 build section above for details.

## Related

- Agent interface: https://github.com/solonlend/solonpad-skill
- App: https://solonpad.fun

## License and restricted regions

MIT, as stated in each file's SPDX header. Exceptions keep their upstream license: three files are
GPL-2.0-or-later (`src/v3/stock/interfaces/IV3SwapRouter.sol`, `src/v3/oracle/ChainlinkStockSource.sol`,
`src/v3/oracle/ChainlinkStockFeed.sol`) and the third-party notices for the stock layer are in
`src/v3/stock/NOTICE`. Unaudited; provided as is.

SolonPad is not offered to persons or entities in the United States, China, Japan, or any sanctioned
jurisdiction.

## Quote-denominated instant v4 launches (`src/quote-v4/`)

Variants of the official Uniswap Liquidity Launcher `InstantLaunchStrategy` /
`FeeSplitter` that accept an **ERC20 quote currency** (tokenized stocks, memes)
instead of hardcoded native: `currency0` becomes a constructor parameter with an
18-decimals check, and the splitter's native-side flows are generalized to the
quote ERC20. Generated as a reviewable scripted diff from the MIT upstream
(`Uniswap/liquidity-launcher`); everything else is byte-identical to the
audited original.

Live instances (Arc 5042) — strategy / splitter per quote asset:

| Quote | Strategy | FeeSplitter |
|---|---|---|
| CRCL | `0xDbb391B29CeCC76ddda15626bBcaAF9dA7f79ADc` (tick 167700) | `0xc6A82Ee0d461bB86f22f78e88BeaE1e2c6349867` |
| TSLA | `0x1c6BbE8Ab2A836D30ec2f9d0F1cA751360899a1e` (tick 181400) | `0x24b9a4C7B0f6b6dE129c2E9F25c6D2Fa495151F2` |

(NVDA / AAPL / SPY / ARGUS / LONG / DUKE instances and the full current address
book live in the `solonpad-skill` repo's `addresses.json`, which is the
authoritative, continuously updated table.)

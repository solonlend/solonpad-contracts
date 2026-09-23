# SolonPad — contracts

Every contract SolonPad runs in production, in the open: the Pons V2 curve engine
port (`src/v2/`), the aggregator's `SolonFeeRouter` (`src/aggregator/`), and the
deployment/config scripts. Radian-lineage sources (`src/radian/`, root factory)
are kept for provenance; SolonPad does not deploy them.

## Verify against production

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
forge install foundry-rs/forge-std Uniswap/v4-core Uniswap/v4-periphery \
  OpenZeppelin/openzeppelin-contracts
forge test
```

Dependency pins used in production builds: forge-std `bf647bd`,
v4-core `46c68346`, v4-periphery `dce236d4`.

## Related

- Agent interface: https://github.com/solonlend/solonpad-skill
- App: https://solonpad.fun

MIT. Not available to persons or entities in the United States, China, or
sanctioned jurisdictions.

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

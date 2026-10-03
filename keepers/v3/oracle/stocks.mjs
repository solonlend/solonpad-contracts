// The three launch stocks on Robinhood Chain (4663). Underlyings, Chainlink feed proxies (8 dp,
// us_equities_24/5) and the deepest stock/USDG Uniswap V3 pools, as used by test/v3/StockOracleFork.t.sol
// (re-checked on chain 2026-10-01: proxy descriptions "RHNVDA / USD", "Robinhood AAPL / USD", "RHTSLA / USD";
// proxy.aggregator() = DualAggregator 1.0.0, phaseId 1; real logs carry NewTransmission + NewRound + AnswerUpdated
// in one tx). `aggregator` is a hint for the log filter: the keeper re-resolves proxy.aggregator() at start.
export const STOCKS = Object.freeze([
  { symbol: 'NVDA', underlying: '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC', feed: '0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15', pool: '0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3', aggregator: '0xC9d16E4f2569b9E3ea0468fD85844953713DC2a2' },
  { symbol: 'AAPL', underlying: '0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9', feed: '0x6B22A786bAa607d76728168703a39Ea9C99f2cD0', pool: '0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D', aggregator: '0xBb11A21267cFDb63d4935d99a499133DD1744ACb' },
  { symbol: 'TSLA', underlying: '0x322F0929c4625eD5bAd873c95208D54E1c003b2d', feed: '0x4A1166a659A55625345e9515b32adECea5547C38', pool: '0xf4ACdAEEB7022862A763C9B1B885e11191c889E3', aggregator: '0x7A6b81ba7FbCB90104d8C496158Cf383cD7233b1' },
]);
export const RH_USDG_FEED = '0x61B7e5650328764B076A108EFF5fa7282a1B9aD2';
export const RH_LZ_ENDPOINT = '0x6F475642a6e85809B1c36Fa62763669b1b48DD5B'; // eid() = 30416 on chain, LayerZero metadata 2026-10-01
export const RH_ETH_USD_FEED = '0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9'; // "ETH / USD", 8 dp (Chainlink directory + on-chain description)

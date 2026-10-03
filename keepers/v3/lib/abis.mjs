// Minimal human-readable ABIs, copied from src/v3 signatures at 03d87c2.
const ENTRY = 'tuple(address source,bytes32 pool,uint256 epoch,uint8 cohort,uint256 budget18,uint256 creditTotal,uint256 allocationId,bytes32 assetId,uint32 adapterVersion,bytes32 pricePolicy,uint8 eligibilityMode)';
const ROUND = 'tuple(bytes32 entriesHash,uint256 entryCount,uint256 epochMin,uint256 epochMax,bytes32 assetId,uint32 adapterVersion,address asset,address adapter,uint256 budget18,uint256 minRawOut,uint256 deadline,bytes32 orderId,uint256 sourceNonce,uint256 delivered,uint256 refunded,uint8 status,uint256 submittedAt,bool cancelRequested)';
const ROUTE = 'tuple(address asset,address underlying,address hub,address adapter,bytes32 path,uint256 chainId,bool enabled,uint256 fixedCost18)';

export const ENTRY_TUPLE = ENTRY;

export const RoundManagerAbi = [
  'function nextEntryId() view returns (uint256)',
  'function nextRoundId() view returns (uint256)',
  `function entry(uint256) view returns (${ENTRY})`,
  `function round(uint256) view returns (${ROUND})`,
  'function roundSlices(uint256) view returns (tuple(uint256 entryId,uint256 budget18)[])',
  'function groupKey(uint256) view returns (bytes32)',
  'function available(uint256) view returns (uint256)',
  'function pending(uint256) view returns (uint256)',
  'function delivered(uint256) view returns (uint256)',
  'function minimumBudget(uint256) view returns (uint256)',
  'function runLimit() view returns (uint256)',
  'function executionNonce(bytes32) view returns (uint256)',
  'function orphanConsumed(uint256) view returns (bool)',
  'function sourcePool(address) view returns (bytes32)',
  'function registry() view returns (address)',
  'function vault() view returns (address)',
  'function batcher() view returns (address)',
  'function entryStatus(uint256) view returns (uint256 age,bool dormant,uint256 nextCheck,uint8 reason)',
  'function seal(address source,uint256 epoch,uint8 cohort,bytes32 assetId,uint32 version,bytes32 pricePolicy,uint8 mode) returns (uint256)',
  'function start(uint256 id,bytes quoteData)',
  'function poke(uint256 id)',
  'function submit(uint256 id)',
  'function cancelUnsent(uint256 id)',
  'function requestCancel(uint256 id)',
  'function finalize(uint256 id,bytes proof)',
  'event EntrySealed(uint256 indexed entryId,address indexed source,uint256 indexed epoch,uint8 cohort,uint256 budget18,uint256 creditTotal)',
  'event RoundState(uint256 indexed roundId,uint8 status)',
];

export const BatcherAbi = [
  'function nextToEnqueue() view returns (uint256)',
  'function enqueued(uint256) view returns (bool)',
  'function cursor(bytes32) view returns (uint256)',
  'function previewBatch(bytes32 group,uint256 maxBudget) view returns (uint256[] ids,uint256[] budgets,uint256 total)',
  'function enqueue(uint256 id)',
  'function advance(bytes32 group,uint256 max)',
  'function executeAndStart(uint256[] ids,uint256 maxBudget,uint256 minRaw,uint256 deadline,bytes quoteData) returns (uint256)',
];

export const RegistryAbi = [`function resolve(bytes32 assetId,uint32 version) view returns (${ROUTE})`];

export const StockAdapterAbi = [
  'function config() view returns (address coordinator,address vault,address asset,address underlying,address hub,address signer,bytes32 path,uint256 destinationChain,address opsVault,address oracle)',
  'function orders(bytes32) view returns (uint256 budget,uint256 minRaw,uint256 fees,uint8 state)',
  'function feeBalance(bytes32) view returns (uint256)',
  'function nonceUsed(uint256) view returns (bool)',
  'function funded(bytes32) view returns (bool)',
  'function quoteDigest(tuple(bytes32 orderId,uint256 budget18,uint256 minRawOut,uint256 deadline,uint256 nonce,uint256 fees18,uint256 fixedCost18) q) view returns (bytes32)',
  'function depositFees(bytes32 id) payable',
  'function refundUnusedFees(bytes32 id) returns (bool)',
  'function consumeResult(bytes32 id,bytes proof) returns (uint8 status,uint256 raw,uint256 refund18)',
];

export const RewardSourceAbi = [
  'function rewardPolicy(uint256 epoch,uint8 cohort) view returns (bytes32 assetId,uint32 version,bytes32 pricePolicy,uint8 mode)',
  'function epochBudget(uint256) view returns (uint256)',
  'function rewardSealed(uint256) view returns (bool)',
  'function nextRoundAt(uint256) view returns (uint256)',
  'function lastFeeAt() view returns (uint256)',
  'function queueSnapshot(uint256) view returns (uint256 upperBound,uint256 revision)',
  'function queueAsset(uint256) view returns (address)',
  'function participantAt(uint256) view returns (address)',
  'function participantCount() view returns (uint256)',
  'function settlementKind() view returns (uint8)',
];

export const RewardVaultAbi = [
  'function allocations(uint256) view returns (address source,uint256 epoch,uint8 cohort,address asset,uint256 creditTotal,uint256 cumulativeDelivered,uint256 revision)',
  'function creditedToPayout(uint256,address) view returns (uint256)',
  'function sourceCursor(address) view returns (uint256)',
  'function requiredSourceBound(address) view returns (uint256)',
  'function sourceBounds(uint256) view returns (uint256)',
  'function participantIndexSealed(uint256) view returns (bool)',
  'function participantUpperBound(uint256) view returns (uint256)',
  'function allocationStaged(uint256) view returns (uint256)',
  'function scopedParticipantIndex() view returns (bool)',
  'function participantAt(uint256 allocationId,uint256 i) view returns (address)',
  'function participantCount(address source) view returns (uint256)',
  'function queueSnapshot(uint256) view returns (uint256,uint256)',
  'function queueAsset(uint256) view returns (address)',
  'function registerParticipants(address source,uint256 max)',
  'function sealParticipantIndex(uint256 id)',
];

export const PayoutVaultAbi = [
  'function readyRaw(address,address) view returns (uint256)',
  'function paidTotal(address,address) view returns (uint256)',
  'function trustedSource(address) view returns (bool)',
  'function distributor() view returns (address)',
  'event Paid(address indexed account,address indexed asset,uint256 amount)',
];

export const DistributorAbi = [
  'function queues(uint256) view returns (address source,address asset,uint256 epoch,uint256 revision,uint256 upperBound,uint256 cursor)',
  'function queued(bytes32) view returns (bool)',
  'function scopedParticipantIndex(address) view returns (bool)',
  'function nextScanAt(uint256) view returns (uint256)',
  'function scanDay(uint256) view returns (uint256)',
  'function estimatedCostPerRecipient() view returns (uint256)',
  'function oracleMaxAge() view returns (uint256)',
  'function minimumUSD18() view returns (uint256)',
  'function oracle() view returns (address)',
  'function payout() view returns (address)',
  'function previewBatch(uint256 id) view returns (tuple(address source,address asset,uint256 epoch,uint256 revision,uint256 upperBound,uint256 cursor) queue,uint256 nextScan,uint256 day)',
  'function openQueue(address source,uint256 epoch,address asset) returns (uint256)',
  'function batchDistribute(uint256 id,uint256 maxAccounts,uint256 maxEpochs,uint256 gasBudget)',
  'event AccountProcessed(uint256 indexed queueId,address indexed account,uint8 outcome,bytes reason)',
  'event CycleComplete(uint256 indexed queueId,uint256 day,uint256 nextScanAt)',
];

export const PriceOracleAbi = ['function priceUSD18(address asset) view returns (uint256 price,uint256 updatedAt)'];
// SolonStockOracle reads used for the adapter floor (rawFor) and the M1 market gate (latest().sourceUpdatedAt).
export const StockOracleAbi = [
  'function rawFor(address asset,uint256 usd18) view returns (uint256)',
  'function latest(address asset) view returns (tuple(uint256 price18,uint256 multiplier,uint256 quoteUsd18,uint256 twapPrice18,uint64 sourceUpdatedAt,uint80 roundId,uint64 observedAt,uint64 sourceBlock) o, uint8 s)',
];
// SolonStockHub views for the reward-round cost model (fork F4).
export const StockHubFeeAbi = [
  'function fees() view returns (uint16 buyFeeBps,uint16 sellFeeBps,uint16 mintLimitBps)',
  'function quoteOrder(address underlying) view returns (uint256)',
];
export const Erc20Abi = [
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'event Transfer(address indexed from,address indexed to,uint256 value)',
];
// Reward-source discovery (round/sources.mjs).
export const LaunchFactoryAbi = ['event LaunchState(bytes32 indexed poolId,address indexed token,uint8 state)'];
export const StakingV2Abi = [
  'event SourceRegistered(bytes32 indexed key,bytes32 indexed source,address indexed asset,uint8 kind)',
  'function entrySource(bytes32 key) view returns (address)',
  'function createEntrySource(bytes32 key) returns (address)',
  'function creditTotal27(bytes32 key,uint256 epoch) view returns (uint256)',
  'function rewardSealed(bytes32 key,uint256 epoch) view returns (bool)',
  'function carryState(bytes32 key) view returns (uint256 deposited27,uint256 released27,uint256 clock,uint256 last,uint256 pendingEvents)',
  'function ledgerLane(bytes32 key) view returns (bool)',
  'function nativeAvailable(bytes32 key) view returns (uint256)',
  'function fundedAmount(bytes32 key) view returns (uint256)',
  'function totalStaged(bytes32 key) view returns (uint256)',
];

const EVIDENCE = 'tuple(bytes32 source,bytes32 collectTx,uint64 collectBlock,uint32 logIndex,address token,uint256 actualPlatformAmount,uint32 policyVersion)';
export const EVIDENCE_TUPLE = EVIDENCE;
export const V2IngressAbi = [
  'function sources(bytes32) view returns (uint256 chainId,address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks,uint256 positionId,address splitter,address platformRecipient,uint64 cutoverBlock,uint32 policyVersion,uint8 kind)',
  'function solonSourceKey() view returns (bytes32)',
  'function auditors(uint256) view returns (address)',
  `function evidenceDigest(${EVIDENCE} e) view returns (bytes32)`,
  `function lotInfo(bytes32 id) view returns (tuple(${EVIDENCE.slice(6, -1)}) evidence,uint8 state,bool admitted)`,
  'function receiptUsed(bytes32) view returns (bool)',
  `function recordLot(${EVIDENCE} e,tuple(uint8 auditor,bytes signature)[2] sigs) returns (bytes32)`,
  'function fundLot(bytes32 id) payable',
  'event Observed(bytes32 indexed id,bytes32 indexed source,bytes32 indexed collectTx,address token,uint256 amount,uint64 collectBlock,uint32 logIndex,bool admitted)',
];

export const V2RouterAbi = [
  'function state(bytes32) view returns (uint8)',
  'function pending(bytes32) view returns (address token,uint256 raw,uint8 kind)',
  'function nextConversionId(bytes32) view returns (bytes32)',
  'function assetConverter(address) view returns (address)',
  'function converter() view returns (address)',
  'function routeLot(bytes32 id)',
  'function convertLot(bytes32 id,bytes quoteData)',
  'function convertLot(bytes32 id,uint256 raw,bytes quoteData)',
  'event Converted(bytes32 indexed lot,uint256 actualUSDC18,uint8 kind)',
  'event ConversionSlice(bytes32 indexed sourceLot,bytes32 indexed conversionId,uint256 raw,uint256 residual)',
];

export const V2ConverterAbi = [
  'function router() view returns (address)',
  'function sellRoute() view returns (address)',
  'function signer() view returns (address)',
  'function ops() view returns (address)',
  'function path() view returns (bytes32)',
  'function version() view returns (uint32)',
  'function lpFeePpm() view returns (uint24)',
  'function feeBalance(bytes32) view returns (uint256)',
  'function quoteDigest(tuple(bytes32 lotId,address asset,uint256 raw,uint256 minUSDC18,uint256 value18,uint256 issuedAt,uint256 deadline,uint256 nonce,uint256 fees18) q) view returns (bytes32)',
  'function depositFees(bytes32 id) payable',
];

export const BuybackExecutorAbi = [
  'function config() view returns (address governance,address solon,address ledger,address router,bytes32 path,address signer,address sink,address protocolDesk)',
  'function vault() view returns (address)',
  'function lots(bytes32) view returns (uint256 budget,uint256 bought,bool protocolDesk,bool executed,uint256 spent)',
  'function pricePolicyVersion() view returns (uint256)',
  'function quoteDigest(tuple(bytes32 lotId,uint256 budget,uint256 minOut,uint256 pricePolicyVersion,uint256 quotedAt,uint256 deadline,uint256 nonce) q) view returns (bytes32)',
  'function execute(tuple(bytes32 lotId,uint256 budget,uint256 minOut,uint256 pricePolicyVersion,uint256 quotedAt,uint256 deadline,uint256 nonce) q,bytes signature) returns (uint256)',
  'event Funded(bytes32 indexed lotId,uint256 budget,bool protocolDesk)',
  'event Bought(bytes32 indexed lotId,uint256 spent,uint256 received,address destination)',
];

export const BuybackVaultAbi = [
  'function lots(bytes32) view returns (uint256 amount,uint8 state)',
  'function burnPending(bytes32 id) returns (bool)',
];

export const ProtocolDeskVaultAbi = [
  'function pendingSolon() view returns (uint256)',
  'function nft() view returns (address)',
  'function mintAvailable(uint256 maxCards) returns (uint256)',
  'function sweepOverflowToBurn() returns (uint256)',
];

export const DeskNftAbi = [
  'function SOLON_PER_DESK() view returns (uint256)',
  'function MAX_SUPPLY() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function protocolMinted() view returns (uint256)',
  // Desk 10% payout service (desk keeper)
  'function servicePolicy() view returns (address)',
  'function deskQueues(uint256) view returns (bytes32 stream,address asset,uint256 upperBound,uint256 cursor,uint256 nextScanAt)',
  'function deskQueueStreams(uint256 id) view returns (bytes32[],uint256[])',
  'function deskQueued(bytes32) view returns (bool)',
  'function openDeskQueue(bytes32[] keys) returns (uint256)',
  'function batchDistributeDesk(uint256 queueId,uint256 maxCards) returns (uint256 paid,uint256 failed)',
  'event DeskPushed(uint256 indexed tokenId,bytes32 indexed stream,uint256 amount)',
  'event DeskPushBlocked(uint256 indexed tokenId,bytes32 indexed stream,bytes reason)',
];

// DeskRewards (src/v3/DeskRewards.sol): per-(pool, UTC day, asset, kind) fee streams of the Desk 10% share.
export const DeskRewardsAbi = [
  'event DeskFeeCredit(bytes32 indexed stream,bytes32 indexed source,uint256 amount,uint256 counter,uint256 remainder)',
  'function streams(bytes32) view returns (bytes32 source,uint256 epoch,address asset,uint8 kind,uint256 counter,uint256 rem,uint256 supply,uint256 totalCredit27,uint256 received)',
  'function entrySources(bytes32) view returns (address)',
  'function streamSealed(bytes32) view returns (bool)',
  'function purchasedRaw(bytes32) view returns (uint256)',
  'function deliveryInfo(bytes32 key) view returns (address asset,uint256 revision)',
  'function delegatedCredit27(bytes32) view returns (uint256)',
  'function delegatedFunded(bytes32) view returns (uint256)',
  'function entrySource(bytes32 key) returns (address)',
  'function syncPurchased(bytes32 key,uint256 entryId)',
  'function fundProtocolDeskBudget(bytes32 key) returns (uint256)',
  'function forwardProtocolDesk(bytes32 key) returns (uint256)',
];

export const SplitterAbi = ['function collectFees(uint256[] tokenIds)'];

// ---------------------------------------------------------------- r13: stock lane (path 2a float launch)
const ORDER = 'tuple(address user,address underlying,uint8 kind,uint8 status,uint64 createdAt,uint64 settledAt,uint256 amountIn,uint256 minOut,uint256 amountOut,uint256 fee,uint128 rawOut,bool lzSettled,bool orphaned,uint64 dispatchedAt,uint8 lane,uint16 feeBps,bool cancelRequested,bool disputed,bool advanced,uint8 outcome,address route,uint256 extra,uint256 held,uint256 owed,uint256 custodyRaw,uint256 refundReady,bytes32 capKey,bool voided)';
const RESULT = 'tuple(bytes32 ref,address underlying,uint8 outcome,uint128 amountIn,uint128 amountOut,uint64 seq)';
export const RESULT_TUPLE = RESULT;
// HubSettlement.Status
export const HubStatus = Object.freeze({ Pending: 0, Dispatched: 1, Filled: 2, Cancelled: 3, Escalated: 4, Funded: 5, Returning: 6, Proceeds: 7 });
export const HubStatusName = Object.fromEntries(Object.entries(HubStatus).map(([k, v]) => [v, k]));
export const StockHubAbi = [
  `function getOrder(uint256 id) view returns (${ORDER})`,
  'function orderCount() view returns (uint256)',
  'function openOrders() view returns (uint256[])',
  'function quoteDispatch(uint256 id) view returns (uint256)',
  'function dispatch(uint256 id) payable',
  'function available() view returns (uint256)',
  'function escrowed() view returns (uint256)',
  'function accruedFees() view returns (uint256)',
  'function claimableTotal() view returns (uint256)',
  'function payAllowance() view returns (uint256)',
  'function floatEnabled() view returns (bool)',
  'function mintsHalted() view returns (bool)',
  'function paused() view returns (bool)',
  'function unreconciledCount() view returns (uint256)',
  'function checkStale()',
  'function reconciled(bytes32 ref) view returns (bool)',
  `function reconcile(${RESULT} r,uint256 checkpointIndex,bytes32[] proof)`,
  'function withdrawFloat(address to,uint256 amount)',
  'function fundFloat() payable',
  'function floatRecipientA() view returns (address)',
  'function floatRecipientB() view returns (address)',
  'function keeper() view returns (address)',
  'event Launched(uint256 indexed id, address indexed route, uint256 amountIn, uint256 routeFee, bytes32 transferId)',
];
export const SchedulerAbi = [
  'function nextLaunch() view returns (bool found,uint8 lane,uint256 id)',
  'function launchNext(uint256 expectedId,bytes routeData)',
  'function queueLength(uint8 lane) view returns (uint256 total,uint256 waiting)',
  'function skipClosed(uint8 lane,uint256 max)',
];
export const FundingRouteAbi = [
  'function quoteDigest(bytes32 ref,uint256 amountIn,uint256 fee,uint256 minOut,(bytes32 requestId,uint256 deadline,uint256 nonce) q) view returns (bytes32)',
  'function signer() view returns (address)',
  'function caller() view returns (address)',
  'function destination() view returns (address)',
  'function depository() view returns (address)',
  'function returnExecutor() view returns (address)',
  'function asset() view returns (address)',
  'function nativeToken() view returns (address)',
  'function receiveReturnFor(bytes32 ref) payable',
  'event Sent(bytes32 indexed ref, bytes32 indexed requestId, uint256 amountIn, uint256 fee, uint256 minOut)',
];
export const RelayDepositoryAbi = [
  'event RelayNativeDeposit(address from, uint256 amount, bytes32 id)',
  'event RelayErc20Deposit(address from, address token, uint256 amount, bytes32 id)',
];
// relay-periphery RelayRouter.multicall (no access control, N3): the Arc return executor of the route.
export const RelayRouterAbi = [
  'function multicall((address target,bool allowFailure,uint256 value,bytes callData)[] calls,address refundTo,address nftRecipient,bytes metadata) payable returns (bytes[])',
];
export const ReserveVaultAbi = [
  'function settled(bytes32 ref) view returns (bool)',
  'function funding(bytes32 ref) view returns (uint256)',
  'function proceeds(bytes32 ref) view returns (uint256)',
  'function advanced(bytes32 ref) view returns (uint256)',
  'function floatEnabled() view returns (bool)',
  'function freeSettlement() view returns (uint256)',
  'function settlementLiabilities() view returns (uint256)',
  'function settlement() view returns (address)',
  'function returnRoute() view returns (address)',
  `function waitingOrder(bytes32 ref) view returns (tuple(bytes32 ref,address underlying,uint8 side,uint128 amountIn,uint128 minOut))`,
  'function executeFunded(bytes32 ref)',
  'function returnFunds(bytes32 ref,uint256 minOut,bytes quote)',
  'function resultCount() view returns (uint256)',
  `function resultAt(uint256 seq) view returns (${RESULT})`,
  'function checkpointedThrough() view returns (uint64)',
  'function checkpoint() returns (bytes32 root,uint64 fromSeq,uint64 toSeq)',
  'function paused() view returns (bool)',
  'event OrderWaitingFunds(bytes32 indexed ref, uint256 needed, uint256 funded)',
  'event OrderExecuted(bytes32 indexed ref, address indexed underlying, uint8 outcome, uint128 amountIn, uint128 amountOut, uint64 seq, string reason)',
  'event Checkpointed(uint64 fromSeq, uint64 toSeq, bytes32 root)',
];
export const CanonicalGateAbi = [
  'function checkpointCount() view returns (uint256)',
  'function checkpointAt(uint256 i) view returns ((bytes32 root,uint64 fromSeq,uint64 toSeq))',
];

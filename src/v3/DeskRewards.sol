// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {RewardRoundManager} from "./RewardRoundManager.sol";
import {RewardAssetSchedule} from "./RewardAssetSchedule.sol";
import {RewardPayoutVault} from "./RewardPayoutVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V3FeeLedger} from "./V3FeeLedger.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DeskNFT} from "./DeskNFT.sol";

/// @notice Fee-time equal card accounting. Card history is indexed by immutable tokenId, never wallet.
contract DeskRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;
    // Recognized raw inventory is disjoint from purchased stock received through Payout.
    mapping(address => uint256) public rawCustody;
    mapping(address => uint256) public purchasedSpent;
    mapping(address => bool) public royaltyAsset;
    bool public royaltyAssetsConfigured;
    event RoyaltyAssetAdmitted(address indexed asset);
    event StockRoyaltyReceived(address indexed asset, uint256 actualRaw, bool directReceipt);

    function configureRoyaltyAssets(address[] calldata assets) external {
        require(
            msg.sender == governance && !royaltyAssetsConfigured && address(nft) != address(0)
                && nft.totalSupply() == 0,
            "royalty configuration"
        );
        royaltyAssetsConfigured = true;
        for (uint256 i; i < assets.length; ++i) {
            address asset = assets[i];
            require(
                asset.code.length != 0 && asset != address(nft.solon()) && !royaltyAsset[asset], "stock royalty asset"
            );
            royaltyAsset[asset] = true;
            emit RoyaltyAssetAdmitted(asset);
        }
    }

    function depositRoyalty(address asset, uint256 raw) external nonReentrant {
        require(royaltyAsset[asset] && raw != 0, "stock royalty asset");
        IERC20 token = IERC20(asset);
        uint256 beforeSelf = token.balanceOf(address(this));
        uint256 beforePayer = token.balanceOf(msg.sender);
        token.safeTransferFrom(msg.sender, address(this), raw);
        require(
            token.balanceOf(address(this)) == beforeSelf + raw && token.balanceOf(msg.sender) + raw == beforePayer,
            "royalty delta"
        );
        rawCustody[asset] += raw;
        _credit(ROYALTY, asset, 1, raw);
        emit StockRoyaltyReceived(asset, raw, false);
    }

    /// @notice ERC2981 markets may transfer ERC20 royalties directly. Only new unaccounted
    /// inventory is recognized; neither ledger backing nor already delivered purchase stock is royalty.
    function syncRoyalty(address asset) external nonReentrant returns (uint256 raw) {
        require(royaltyAsset[asset], "stock royalty asset");
        uint256 purchased =
            address(payout) == address(0) ? 0 : payout.paidTotal(address(this), asset) - purchasedSpent[asset];
        raw = IERC20(asset).balanceOf(address(this)) - rawCustody[asset] - purchased;
        if (raw != 0) {
            rawCustody[asset] += raw;
            _credit(ROYALTY, asset, 1, raw);
            emit StockRoyaltyReceived(asset, raw, true);
        }
    }

    function feeCustodyMode() external pure returns (uint8) {
        return 3;
    }

    uint256 public constant PRECISION = 1e27;
    bytes32 public constant ROYALTY = keccak256("DESK_ROYALTY");
    bytes32 public constant SURCHARGE = keccak256("DESK_SURCHARGE");
    V3FeeLedger public immutable ledger;
    DeskNFT public nft;
    address public immutable governance;

    struct Stream {
        bytes32 source;
        uint256 epoch;
        address asset;
        uint8 kind;
        uint256 counter;
        uint256 rem;
        uint256 supply;
        uint256 totalCredit27;
        uint256 received;
    }

    struct Generation {
        uint256 upperId;
        uint256 initialCounter;
    }
    mapping(bytes32 => Stream) public streams;
    mapping(bytes32 => Generation[]) private generations;
    mapping(bytes32 => uint256) public nextEpochRemainder;
    mapping(bytes32 => bytes32) public latestStream;
    mapping(uint256 => mapping(bytes32 => uint256)) public paidRaw;
    event DeskFeeCredit(
        bytes32 indexed stream, bytes32 indexed source, uint256 amount, uint256 counter, uint256 remainder
    );

    constructor(V3FeeLedger ledger_, address governance_) {
        require(address(ledger_).code.length > 0 && governance_ != address(0));
        ledger = ledger_;
        governance = governance_;
    }
    RewardRoundManager public rounds;
    RewardPayoutVault public payout;
    RewardAssetSchedule public schedule;
    mapping(bytes32 => address) public entrySources;
    mapping(bytes32 => bool) public streamSealed;
    mapping(bytes32 => uint256) public purchasedRaw;
    mapping(bytes32 => address) public purchasedAsset;
    mapping(address => uint256) public purchasedOutstanding;

    function configureRounds(address manager, address payout_, address schedule_) external {
        require(
            msg.sender == governance && address(rounds) == address(0) && manager.code.length > 0
                && payout_.code.length > 0 && schedule_.code.length > 0,
            "round configuration"
        );
        rounds = RewardRoundManager(payable(manager));
        payout = RewardPayoutVault(payout_);
        schedule = RewardAssetSchedule(schedule_);
    }

    function entrySource(bytes32 key) external returns (address source) {
        Stream storage s = streams[key];
        require(s.supply > 0 && s.kind == 0 && address(rounds) != address(0), "native source");
        source = entrySources[key];
        if (source == address(0)) {
            source = address(new DeskRewardEntry(this, key, s.epoch));
            entrySources[key] = source;
            rounds.registerSource(source, s.source);
        }
    }

    function sourcePolicy(uint256 epoch) external view returns (bytes32 id, uint32 version, bytes32 price, uint8 mode) {
        (, id, version, price) = schedule.resolve(epoch);
        if (
            nft.controller() != address(0) && IDeskMode(nft.controller()).eligibilityEnabled()
                && epoch >= IDeskMode(nft.controller()).effectiveEpoch()
        ) mode = 1;
    }

    function sealDesk(bytes32 key) external nonReentrant returns (uint256 budget, uint256 total) {
        Stream storage s = streams[key];
        require(
            msg.sender == entrySources[key] && !streamSealed[key] && block.timestamp >= (s.epoch + 1) * 1 days, "seal"
        );
        streamSealed[key] = true;
        total = s.totalCredit27;
        budget = total / PRECISION;
        require(budget > 0, "empty budget");
        _pull(s.source);
        (bool ok,) = msg.sender.call{value: budget}("");
        require(ok, "fund entry");
    }

    function streamCreditTotal(bytes32 key) external view returns (uint256) {
        return streams[key].totalCredit27;
    }

    function syncPurchased(bytes32 key, uint256 entryId) external nonReentrant {
        RewardRoundManager.Entry memory e = rounds.entry(entryId);
        require(e.source == entrySources[key] && e.source != address(0) && e.epoch == streams[key].epoch, "entry");
        uint256[] memory ids = new uint256[](1);
        ids[0] = entryId;
        address asset = rounds.vault().queueAsset(entryId);
        payout.stageCredit(address(rounds.vault()), address(this), ids, asset);
        payout.claimFor(address(this), asset);
        // Third parties may already have staged this entry, and the distributor may have paid it.
        // Authoritative cumulative delivery, rather than this call's staging delta, defines custody debt.
        uint256 cumulative = rounds.delivered(entryId);
        uint256 delta = cumulative - purchasedRaw[key];
        purchasedRaw[key] = cumulative;
        purchasedAsset[key] = asset;
        purchasedOutstanding[asset] += delta;
        require(IERC20(asset).balanceOf(address(this)) >= purchasedOutstanding[asset], "purchase coverage");
    }
    address public protocolStaking;

    function configureProtocolStaking(address staking) external {
        require(msg.sender == governance && protocolStaking == address(0) && staking.code.length > 0);
        protocolStaking = staking;
    }
    mapping(bytes32 => uint256) public delegatedCredit27;
    mapping(bytes32 => uint256) public delegatedFunded;

    function fundProtocolDeskBudget(bytes32 key) external nonReentrant returns (uint256) {
        require(streams[key].supply != 0 && streams[key].kind == 0, "native protocol budget");
        return _fundProtocol(key);
    }

    function forwardProtocolDesk(bytes32 key) external nonReentrant returns (uint256) {
        require(streams[key].supply != 0 && streams[key].kind == 1, "raw stock only");
        return _fundProtocol(key);
    }

    function _fundProtocol(bytes32 key) private returns (uint256 amount) {
        Stream storage s = streams[key];
        amount = delegatedCredit27[key] / PRECISION - delegatedFunded[key];
        if (amount == 0) return 0;
        _pull(s.source);
        delegatedFunded[key] += amount;
        if (s.kind == 0) {
            IProtocolStaking(protocolStaking).fundProtocolDesk{value: amount}(s.source, s.epoch, address(0), 0, amount);
        } else {
            rawCustody[s.asset] -= amount;
            IERC20(s.asset).forceApprove(protocolStaking, amount);
            uint256 beforeBalance = IERC20(s.asset).balanceOf(address(this));
            IProtocolStaking(protocolStaking).fundProtocolDesk(s.source, s.epoch, s.asset, 1, amount);
            require(IERC20(s.asset).balanceOf(address(this)) + amount == beforeBalance, "forward delta");
            IERC20(s.asset).forceApprove(protocolStaking, 0);
        }
    }

    /// @notice Credential changes gate delivery/transfer only; equal card rights are never reassigned.
    function onEligibilityChange(address) external view {
        require(nft.controller() != address(0) && msg.sender == IDeskMode(nft.controller()).registry(), "registry");
    }

    function configureNFT(DeskNFT nft_) external {
        require(msg.sender == governance && address(nft) == address(0) && address(nft_).code.length > 0);
        nft = nft_;
    }

    function recordMintSurcharge() external payable {
        require(msg.sender == address(nft), "nft");
        _credit(SURCHARGE, address(0), 0, msg.value);
    }

    function onFeeCredit(bytes32 source, address asset, uint8 kind, uint256 amount) external {
        require(msg.sender == address(ledger), "ledger");
        V3FeeLedger.Pool memory pool = ledger.poolInfo(source);
        require(pool.beneficiaries[2] == address(this) && pool.quote == asset && pool.settlementKind == kind, "source");
        _credit(source, asset, kind, amount);
    }

    function streamKey(bytes32 source, uint256 epoch, address asset, uint8 kind) public pure returns (bytes32) {
        return keccak256(abi.encode(source, epoch, asset, kind));
    }

    function _credit(bytes32 source, address asset, uint8 kind, uint256 amount) internal {
        if (amount == 0) return;
        uint256 n = nft.totalSupply();
        require(n > 0, "first Desk required");
        uint256 epoch = block.timestamp / 1 days;
        bytes32 key = streamKey(source, epoch, asset, kind);
        Stream storage s = streams[key];
        bytes32 base = keccak256(abi.encode(source, asset, kind));
        bytes32 previous = latestStream[base];
        uint256 rolled27;
        if (previous != bytes32(0) && previous != key) {
            Stream storage old = streams[previous];
            bytes32 carryKey = streamKey(source, old.epoch + 1, asset, kind);
            rolled27 = old.rem + nextEpochRemainder[carryKey];
            old.rem = 0;
            delete nextEpochRemainder[carryKey];
        }
        latestStream[base] = key;
        if (s.supply != n) {
            if (s.rem != 0) {
                nextEpochRemainder[streamKey(source, epoch + 1, asset, kind)] += s.rem;
                s.rem = 0;
            }
            generations[key].push(Generation(n, s.counter));
            s.supply = n;
        }
        s.source = source;
        s.epoch = epoch;
        s.asset = asset;
        s.kind = kind;
        uint256 numerator = amount * PRECISION + s.rem + rolled27;
        uint256 q = numerator / n;
        s.rem = numerator % n;
        s.counter += q;
        uint256 np = nft.protocolMinted();
        s.totalCredit27 += q * (n - np);
        s.received += amount;
        if (np != 0) {
            require(protocolStaking != address(0), "protocol staking missing");
            uint256 delegated = q * np;
            delegatedCredit27[key] += delegated;
            IProtocolStaking(protocolStaking).notifyProtocolDeskCredit(source, epoch, asset, kind, delegated);
        }
        emit DeskFeeCredit(key, source, amount, s.counter, s.rem);
    }

    function deliveryInfo(bytes32 key) external view returns (address asset, uint256 revision) {
        Stream storage s = streams[key];
        return s.kind == 1 ? (s.asset, s.counter) : (purchasedAsset[key], purchasedRaw[key]);
    }

    function claimable(uint256 id, bytes32 key) public view returns (uint256) {
        Stream storage s = streams[key];
        uint256 credit = credit27(id, key);
        uint256 owed = s.kind == 1
            ? credit / PRECISION
            : (s.totalCredit27 == 0 ? 0 : Math.mulDiv(credit, purchasedRaw[key], s.totalCredit27));
        return owed - paidRaw[id][key];
    }

    function pay(uint256 id, bytes32[] calldata keys, address owner) external nonReentrant returns (uint256 total) {
        require(msg.sender == address(nft) && nft.ownerOf(id) == owner && keys.length <= 20, "claim");
        for (uint256 i; i < keys.length; ++i) {
            bytes32 key = keys[i];
            Stream storage s = streams[key];
            address asset = s.kind == 1 ? s.asset : purchasedAsset[key];
            uint256 owed = s.kind == 1
                ? credit27(id, key) / PRECISION
                : (s.totalCredit27 == 0 ? 0 : Math.mulDiv(credit27(id, key), purchasedRaw[key], s.totalCredit27));
            uint256 amount = owed - paidRaw[id][key];
            if (amount == 0) continue;
            require(
                nft.controller() == address(0) || IDeskDelivery(nft.controller()).canReceiveStock(asset, owner),
                "delivery eligibility"
            );
            paidRaw[id][key] = owed;
            _pull(s.source);
            if (s.kind == 0) {
                purchasedOutstanding[asset] -= amount;
                purchasedSpent[asset] += amount;
            } else {
                rawCustody[asset] -= amount;
            }
            IERC20 token = IERC20(asset);
            uint256 beforeSelf = token.balanceOf(address(this));
            uint256 beforeOwner = token.balanceOf(owner);
            token.safeTransfer(owner, amount);
            require(
                token.balanceOf(address(this)) + amount == beforeSelf && token.balanceOf(owner) == beforeOwner + amount,
                "delivery delta"
            );
            total += amount;
        }
    }

    function _pull(bytes32 source) internal {
        uint256 due = ledger.accrued(source, 2);
        if (due == 0) return;
        V3FeeLedger.Pool memory pool = ledger.poolInfo(source);
        uint256 beforeBalance =
            pool.settlementKind == 1 ? IERC20(pool.quote).balanceOf(address(this)) : address(this).balance;
        require(ledger.claim(source, 2, due), "ledger pull");
        uint256 afterBalance =
            pool.settlementKind == 1 ? IERC20(pool.quote).balanceOf(address(this)) : address(this).balance;
        require(afterBalance == beforeBalance + due, "ledger delta");
        if (pool.settlementKind == 1) rawCustody[pool.quote] += due;
    }

    receive() external payable {
        if (msg.sender != address(ledger)) {
            require(!_reentrancyGuardEntered(), "reentrancy");
            _credit(ROYALTY, address(0), 0, msg.value);
        }
    }

    function credit27(uint256 id, bytes32 key) public view returns (uint256) {
        nft.ownerOf(id);
        Generation[] storage gs = generations[key];
        uint256 low;
        uint256 high = gs.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (gs[mid].upperId < id) low = mid + 1;
            else high = mid;
        }
        return low == gs.length ? 0 : streams[key].counter - gs[low].initialCounter;
    }
}

interface IDeskDelivery {
    function canReceiveStock(address asset, address owner) external view returns (bool);
}

interface IDeskMode {
    function eligibilityEnabled() external view returns (bool);
    function effectiveEpoch() external view returns (uint256);
    function registry() external view returns (address);
}

/// @dev Single ordinary-Desk stream adapter into the existing purchase and payout machinery.
/// Ownership never enters the account-keyed shared vault: the fixed card custodian receives it,
/// and final distribution remains tokenId-indexed in DeskRewards.
contract DeskRewardEntry {
    DeskRewards public immutable rewards;
    bytes32 public immutable key;
    uint256 public immutable epoch;

    constructor(DeskRewards rewards_, bytes32 key_, uint256 epoch_) {
        rewards = rewards_;
        key = key_;
        epoch = epoch_;
    }

    function lastFeeAt() external view returns (uint256) {
        return epoch * 1 days;
    }

    function rewardPolicy(uint256 e, uint8 cohort) external view returns (bytes32, uint32, bytes32, uint8) {
        require(e == epoch && cohort == 0);
        return rewards.sourcePolicy(epoch);
    }

    function sealReward(uint256 e, uint8 cohort) external returns (uint256 budget, uint256 total, uint8 kind) {
        require(msg.sender == address(rewards.rounds()) && e == epoch && cohort == 0);
        (budget, total) = rewards.sealDesk(key);
        (bool ok,) = msg.sender.call{value: budget}("");
        require(ok);
        kind = 0;
    }

    function creditOf(address account, uint256 e, uint8 cohort) external view returns (uint256) {
        return account == address(rewards) && e == epoch && cohort == 0 ? rewards.streamCreditTotal(key) : 0;
    }

    function deliveryAllowed(address, address) external pure returns (bool) {
        return true;
    }

    function queueSnapshot(uint256 e) external view returns (uint256, uint256) {
        require(e == epoch);
        return (1, 1);
    }

    function participantAt(uint256 i) external view returns (address) {
        require(i == 0);
        return address(rewards);
    }

    receive() external payable {
        require(msg.sender == address(rewards));
    }
}

interface IProtocolStaking {
    function notifyProtocolDeskCredit(bytes32 source, uint256 epoch, address asset, uint8 kind, uint256 credit27)
        external
        returns (uint256 assigned27);
    function fundProtocolDesk(bytes32 source, uint256 epoch, address asset, uint8 kind, uint256 amount) external payable;
}

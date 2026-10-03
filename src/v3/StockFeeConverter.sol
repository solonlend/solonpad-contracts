// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {V3FeeLedger} from "./V3FeeLedger.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    SignatureChecker
} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

interface IStockSellRoute {
    function requestSell(bytes32 order, address asset, uint256 raw, uint256 grossFloor, address receiver, bytes32 path)
        external
        payable;
    function claimSell(bytes32 order, bytes calldata proof)
        external
        returns (uint8 status, uint256 actualUSDC18, uint256 remintedRaw);
    /// @notice Largest signed sale value per order (the stock layer's single-order limit).
    function runLimit() external view returns (uint256);
}

/// @notice r7 (design §12.2): the SolonStockOracle execution-price read used as a floor (reverts unless Live).
interface IConverterPriceFloor {
    function usdFor(address asset, uint256 raw) external view returns (uint256);
}

interface IConverterDestination {
    function fundFromConverter(bytes32 lotId) external payable;
}

/// @notice Custody of verified ledger stock lots from only the two operating buckets.
contract StockFeeConverter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    V3FeeLedger public immutable ledger;
    address public immutable signer;
    address public immutable sellRoute;
    address public immutable buyback;
    address public immutable protocol;
    address public immutable ops;
    uint16 public immutable feeBps;
    uint32 public immutable routeVersion;
    bytes32 public immutable path;
    /// @notice SolonStockOracle: a signed sale value must be at least the oracle value less `ORACLE_FLOOR_BPS`.
    address public immutable oracle;
    uint256 public constant ORACLE_FLOOR_BPS = 100;

    struct Lot {
        address asset;
        uint8 bucket;
        uint8 state;
        uint256 raw;
        uint256 proceeds;
    }
    mapping(bytes32 => Lot) public lots;
    event StockReserved(
        bytes32 indexed id, bytes32 indexed pool, uint256 feeLot, uint8 bucket, address asset, uint256 raw
    );

    constructor(
        V3FeeLedger l,
        address s,
        address r,
        address b,
        address p,
        address o,
        uint16 f,
        uint32 v,
        bytes32 path_,
        address governor,
        address oracle_
    ) {
        require(
            address(l) != address(0) && s != address(0) && r.code.length != 0 && b != address(0) && p != address(0)
                && o != address(0) && governor != address(0) && f < 10000 && v != 0 && path_ != 0
                && oracle_.code.length != 0
        );
        oracle = oracle_;
        governance = governor;
        ledger = l;
        signer = s;
        sellRoute = r;
        buyback = b;
        protocol = p;
        ops = o;
        feeBps = f;
        routeVersion = v;
        path = path_;
    }

    function enablePool(bytes32 pool, uint8 bucket) external {
        ledger.enableStockLotCustody(pool, bucket);
    }

    function feeCustodyMode() external pure returns (uint8) {
        return 2;
    }

    function reserve(bytes32 pool, uint256 feeLot, uint8 bucket) external nonReentrant returns (bytes32 id) {
        require(bucket == 4 || bucket == 5);
        V3FeeLedger.Pool memory p = ledger.poolInfo(pool);
        require(p.settlementKind == 1 && p.beneficiaries[bucket] == address(this));
        id = keccak256(abi.encode(pool, feeLot, bucket, p.quote));
        require(lots[id].state == 0);
        uint256 beforeRaw = IERC20(p.quote).balanceOf(address(this));
        uint256 raw = ledger.claimStockLot(pool, feeLot, bucket);
        require(raw != 0 && IERC20(p.quote).balanceOf(address(this)) == beforeRaw + raw);
        lots[id] = Lot(p.quote, bucket, 1, raw, 0);
        emit StockReserved(id, pool, feeLot, bucket, p.quote, raw);
    }

    function lotRaw(bytes32 id) external view returns (uint256) {
        return lots[id].raw;
    }

    struct Quote {
        bytes32 orderId;
        address asset;
        bytes32 slicesHash;
        uint256 raw;
        uint256 minUSDC18;
        uint256 value18;
        uint256 issuedAt;
        uint256 deadline;
        uint256 nonce;
        uint256 fees18;
    }

    function quoteDigest(Quote memory q) public view returns (bytes32) {
        return keccak256(
            abi.encode(q, block.chainid, address(this), sellRoute, routeVersion, path, buyback, protocol, feeBps)
        );
    }

    struct Order {
        address asset;
        uint8 state;
        uint256 raw;
        uint256 minUSDC18;
        uint256 actualUSDC18;
    }
    bool public routePaused;
    address public immutable governance;
    uint256 public outstandingShortfalls;
    uint256 public resumeAfter;
    bytes32 public recoveryReview;
    event RouteResumeScheduled(bytes32 indexed reviewReceipt, uint256 executableAt);
    event RouteResumed(bytes32 indexed reviewReceipt);
    mapping(bytes32 => bool) public finalResult;
    mapping(bytes32 => Order) public orders;
    mapping(bytes32 => bytes32[]) private slices;
    mapping(bytes32 => uint256) public feeBalance;
    mapping(uint256 => bool) public nonceUsed;
    event Submitted(bytes32 indexed id, bytes32 slicesHash, uint256 raw, uint256 netMinimum, uint256 grossMinimum);
    event Result(bytes32 indexed id, uint8 state, uint256 actualUSDC18, uint256 remintedRaw);
    event Routed(bytes32 indexed id, bytes32 indexed lot, uint8 bucket, uint256 amount);

    receive() external payable {
        require(msg.sender == sellRoute);
    }

    function depositFees(bytes32 id) external payable {
        require(orders[id].state == 0);
        feeBalance[id] += msg.value;
    }

    function submit(Quote calldata q, bytes32[] calldata ids, bytes calldata sig) external nonReentrant {
        require(!routePaused && q.orderId != 0 && orders[q.orderId].state == 0 && ids.length > 0 && ids.length <= 16);
        require(
            q.slicesHash == keccak256(abi.encode(ids)) && q.raw > 0 && q.minUSDC18 > 0 && q.value18 > 0
                && q.value18 <= IStockSellRoute(sellRoute).runLimit()
        );
        require(
            block.timestamp >= q.issuedAt && block.timestamp <= q.deadline && q.deadline >= q.issuedAt
                && q.deadline - q.issuedAt <= 60
        );
        require(
            !nonceUsed[q.nonce] && feeBalance[q.orderId] >= q.fees18
                && SignatureChecker.isValidSignatureNow(signer, quoteDigest(q), sig)
        );
        require(q.minUSDC18 >= Math.mulDiv(q.value18, uint256(10000 - feeBps) * 9900, 100000000, Math.Rounding.Ceil));
        // r7 floor: the signer cannot value the lot more than 1% under the Chainlink execution price.
        require(
            q.value18
                >= Math.mulDiv(
                    IConverterPriceFloor(oracle).usdFor(q.asset, q.raw), 10000 - ORACLE_FLOOR_BPS, 10000, Math.Rounding.Ceil
                ),
            "oracle floor"
        );
        uint256 raw;
        for (uint256 i; i < ids.length; i++) {
            require(i == 0 || ids[i] > ids[i - 1]);
            Lot storage l = lots[ids[i]];
            require(l.state == 1 && l.asset == q.asset);
            raw += l.raw;
            l.state = 2;
            slices[q.orderId].push(ids[i]);
        }
        require(raw == q.raw);
        nonceUsed[q.nonce] = true;
        feeBalance[q.orderId] -= q.fees18;
        orders[q.orderId] = Order(q.asset, 3, raw, q.minUSDC18, 0);
        uint256 beforeRaw = IERC20(q.asset).balanceOf(address(this));
        IERC20(q.asset).forceApprove(sellRoute, raw);
        uint256 gross = grossFloor(q.minUSDC18);
        IStockSellRoute(sellRoute).requestSell{value: q.fees18}(q.orderId, q.asset, raw, gross, address(this), path);
        IERC20(q.asset).forceApprove(sellRoute, 0);
        require(IERC20(q.asset).balanceOf(address(this)) == beforeRaw - raw);
        for (uint256 i; i < ids.length; i++) {
            lots[ids[i]].state = 3;
        }
        emit Submitted(q.orderId, q.slicesHash, raw, q.minUSDC18, gross);
    }

    function applyResult(bytes32 id, bytes calldata proof) external nonReentrant {
        Order storage o = orders[id];
        require((o.state == 3 || o.state == 6) && !finalResult[id]);
        uint256 beforeRaw = IERC20(o.asset).balanceOf(address(this));
        uint256 beforeNative = address(this).balance;
        (uint8 status, uint256 paid, uint256 reminted) = IStockSellRoute(sellRoute).claimSell(id, proof);
        require(
            address(this).balance == beforeNative + paid
                && IERC20(o.asset).balanceOf(address(this)) == beforeRaw + reminted
        );
        if (status == 0) {
            require(paid == 0 && reminted == 0);
            o.state = 6;
            for (uint256 i; i < slices[id].length; i++) {
                lots[slices[id][i]].state = 6;
            }
        } else if (status == 2) {
            require(paid == 0 && reminted == o.raw);
            finalResult[id] = true;
            o.state = 7;
            for (uint256 i; i < slices[id].length; i++) {
                lots[slices[id][i]].state = 1;
            }
        } else {
            require(status == 1 && reminted == 0);
            finalResult[id] = true;
            o.actualUSDC18 = paid;
            if (paid < o.minUSDC18) {
                o.state = 6;
                routePaused = true;
                outstandingShortfalls++;
                delete resumeAfter;
                delete recoveryReview;
                for (uint256 i; i < slices[id].length; i++) {
                    lots[slices[id][i]].state = 6;
                }
            } else {
                o.state = 4;
                _allocate(id, paid);
            }
        }
        emit Result(id, o.state, paid, reminted);
    }

    function _allocate(bytes32 id, uint256 paid) private {
        bytes32[] storage ids = slices[id];
        uint256 total = orders[id].raw;
        uint256 allocated;
        uint256[] memory rem = new uint256[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            Lot storage l = lots[ids[i]];
            l.proceeds = Math.mulDiv(paid, l.raw, total);
            allocated += l.proceeds;
            rem[i] = mulmod(paid, l.raw, total);
            l.state = 4;
        }
        uint256 left = paid - allocated;
        for (uint256 j; j < left; j++) {
            uint256 winner;
            for (uint256 i = 1; i < ids.length; i++) {
                if (rem[i] > rem[winner]) winner = i;
            }
            lots[ids[winner]].proceeds++;
            rem[winner] = 0;
        }
    }

    function route(bytes32 id) external nonReentrant {
        require(orders[id].state == 4);
        orders[id].state = 5;
        bytes32[] storage ids = slices[id];
        for (uint256 i; i < ids.length; i++) {
            Lot storage l = lots[ids[i]];
            l.state = 5;
            if (l.proceeds != 0) {
                IConverterDestination(l.bucket == 4 ? buyback : protocol).fundFromConverter{value: l.proceeds}(ids[i]);
            }
            emit Routed(id, ids[i], l.bucket, l.proceeds);
        }
    }

    function grossFloor(uint256 n) public view returns (uint256) {
        uint256 gross = Math.mulDiv(n, 10000, 10000 - feeBps, Math.Rounding.Ceil);
        return Math.ceilDiv(gross, 1e12) * 1e12;
    }
    mapping(bytes32 => uint256) public subsidies;
    event ShortfallSubsidized(bytes32 indexed id, uint256 amount, uint256 actualTotal);

    function subsidizeShortfall(bytes32 id) external payable nonReentrant {
        Order storage o = orders[id];
        require(msg.sender == ops && msg.value != 0 && finalResult[id] && o.state == 6 && o.actualUSDC18 < o.minUSDC18);
        o.actualUSDC18 += msg.value;
        subsidies[id] += msg.value;
        emit ShortfallSubsidized(id, msg.value, o.actualUSDC18);
        if (o.actualUSDC18 >= o.minUSDC18) {
            outstandingShortfalls--;
            o.state = 4;
            _allocate(id, o.actualUSDC18);
        }
    }
    mapping(bytes32 => uint256) public splitNonce;
    mapping(bytes32 => bytes32) public parentLot;
    event LotSplit(bytes32 indexed parent, bytes32 indexed child, uint256 raw);

    /// @notice Operational splitting is signer-controlled so strangers cannot invalidate quotes by fragmenting inventory.
    function splitLot(bytes32 id, uint256 raw) external nonReentrant returns (bytes32 child) {
        require(msg.sender == signer || msg.sender == ops);
        Lot storage l = lots[id];
        require(l.state == 1 && raw > 0 && raw < l.raw);
        child = keccak256(abi.encode("StockFeeSlice", id, ++splitNonce[id]));
        require(lots[child].state == 0);
        l.raw -= raw;
        lots[child] = Lot(l.asset, l.bucket, 1, raw, 0);
        parentLot[child] = id;
        emit LotSplit(id, child, raw);
    }

    function scheduleRouteResume(bytes32 reviewReceipt) external {
        require(msg.sender == governance && routePaused && outstandingShortfalls == 0 && reviewReceipt != 0);
        recoveryReview = reviewReceipt;
        resumeAfter = block.timestamp + 48 hours;
        emit RouteResumeScheduled(reviewReceipt, resumeAfter);
    }

    function resumeRoute() external {
        require(routePaused && outstandingShortfalls == 0 && resumeAfter != 0 && block.timestamp >= resumeAfter);
        bytes32 review = recoveryReview;
        delete recoveryReview;
        delete resumeAfter;
        routePaused = false;
        emit RouteResumed(review);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    SignatureChecker
} from "../../lib/v4-core/lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

interface IV2FixedSellRoute {
    function feePpm() external view returns (uint24);
    function path() external view returns (bytes32);
    function sell(address asset, uint256 raw, uint256 minUSDC18, address recipient, bytes32 path)
        external
        payable
        returns (uint256 actualUSDC18);
}

/// @notice Atomic, manifest-bound v4/v3 route adapter. No arbitrary calldata/recipients and no estimated USDC credit.
/// The immutable route must enforce its own fixed PoolKey/path; manifest verification precedes deployment.
contract V2FeeConverter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Quote {
        bytes32 lotId;
        address asset;
        uint256 raw;
        uint256 minUSDC18;
        uint256 value18;
        uint256 issuedAt;
        uint256 deadline;
        uint256 nonce;
        uint256 fees18;
    }
    address public immutable router;
    address public immutable sellRoute;
    address public immutable signer;
    address public immutable ops;
    bytes32 public immutable path;
    uint32 public immutable version;
    uint24 public immutable lpFeePpm;
    mapping(uint256 => bool) public nonceUsed;
    mapping(bytes32 => bool) public converted;
    mapping(bytes32 => uint256) public feeBalance;
    event Converted(bytes32 indexed lotId, address indexed asset, uint256 raw, uint256 actualUSDC18, uint256 fees18);

    constructor(address router_, address route_, address signer_, address ops_, bytes32 path_, uint32 version_) {
        require(
            router_ != address(0) && route_.code.length != 0 && signer_ != address(0) && ops_ != address(0)
                && path_ != 0 && version_ != 0
        );
        lpFeePpm = IV2FixedSellRoute(route_).feePpm();
        require(lpFeePpm < 1_000_000 && IV2FixedSellRoute(route_).path() == path_);
        router = router_;
        sellRoute = route_;
        signer = signer_;
        ops = ops_;
        path = path_;
        version = version_;
    }

    receive() external payable {
        require(msg.sender == sellRoute);
    }

    function quoteDigest(Quote memory q) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("V2FeeConversionV1"),
                q,
                block.chainid,
                address(this),
                router,
                sellRoute,
                path,
                version,
                ops,
                lpFeePpm
            )
        );
    }

    function depositFees(bytes32 id) external payable {
        require(!converted[id]);
        feeBalance[id] += msg.value;
    }

    function convert(bytes32 id, address asset, uint256 raw, bytes calldata data)
        external
        nonReentrant
        returns (uint256 actual)
    {
        require(msg.sender == router && !converted[id] && raw != 0);
        (Quote memory q, bytes memory sig) = abi.decode(data, (Quote, bytes));
        require(
            q.lotId == id && q.asset == asset && q.raw == raw && q.minUSDC18 != 0 && q.value18 != 0
                && q.value18 <= 1000 ether
        );
        require(
            q.issuedAt <= block.timestamp && block.timestamp <= q.deadline && q.deadline >= q.issuedAt
                && q.deadline - q.issuedAt <= 60
        );
        require(
            q.minUSDC18
                    >= Math.mulDiv(q.value18, uint256(1_000_000 - lpFeePpm) * 9900, 10_000_000_000, Math.Rounding.Ceil)
                && !nonceUsed[q.nonce] && feeBalance[id] >= q.fees18
                && SignatureChecker.isValidSignatureNow(signer, quoteDigest(q), sig)
        );
        nonceUsed[q.nonce] = true;
        converted[id] = true;
        feeBalance[id] -= q.fees18;
        IERC20 token = IERC20(asset);
        uint256 beforeRaw = token.balanceOf(address(this));
        token.safeTransferFrom(router, address(this), raw);
        require(token.balanceOf(address(this)) == beforeRaw + raw);
        uint256 beforeNative = address(this).balance;
        token.forceApprove(sellRoute, raw);
        actual = IV2FixedSellRoute(sellRoute).sell{value: q.fees18}(asset, raw, q.minUSDC18, address(this), path);
        token.forceApprove(sellRoute, 0);
        require(
            actual >= q.minUSDC18 && address(this).balance == beforeNative - q.fees18 + actual
                && token.balanceOf(address(this)) == beforeRaw
        );
        (bool ok,) = router.call{value: actual}("");
        require(ok);
        emit Converted(id, asset, raw, actual, q.fees18);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RelayFundingRoute} from "../../src/v3/stock/RelayFundingRoute.sol";

/// @notice r12 (fork finding F1): RelayFundingRoute against the LIVE Relay depository v2 bytecode (Arc 5042 + RH 4663,
///   same address). Arc (r14): native USDC via `depositErc20(hub, 0x3600 view, amount6, id)` through the LIVE 0x3600
///   FiatToken view (Arc's native-coin precompile 0x1800…00 is stood in by a cheatcode shim, forge has no Arc
///   precompiles); RH: USDG via `depositErc20` (funded from the live Relay solver).
///   Each case asserts the depository's own deposit event (depositor = the route's caller, the signed request id) and
///   the exact balance delta, and shows the pre-r12 raw formats are not deposits. Needs ARC_FORK_RPC / RH_FORK_RPC
///   (skipped without them unless REQUIRE_RELAY_FORK=true).
/// @notice FORK-TEST-ONLY stand-in for Arc's NATIVE_COIN_AUTHORITY precompile (0x1800…0000): moves native balance
///         with cheatcodes (same selectors as script/v3/mainnet/ArcForkShims.sol, which uses anvil --celo instead).
contract ArcNativeCoinAuthorityCheatShim {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    fallback(bytes calldata data) external payable returns (bytes memory) {
        require(bytes4(data[:4]) == bytes4(keccak256("transfer(address,address,uint256)")), "shim: selector");
        (address from, address to, uint256 v) = abi.decode(data[4:], (address, address, uint256));
        vm.deal(from, from.balance - v);
        vm.deal(to, to.balance + v);
        return abi.encode(true);
    }
}

contract ArcNativeCoinControlCheatShim {
    fallback(bytes calldata) external payable returns (bytes memory) {
        return abi.encode(false);
    }
}

contract RelayDepositoryForkTest is Test {
    address constant ARC_USDC_VIEW = 0x3600000000000000000000000000000000000000;
    address constant DEPOSITORY = 0x4cD00E387622C35bDDB9b4c962C136462338BC31;
    address constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant RELAY_SOLVER = 0xf70da97812CB96acDF810712Aa562db8dfA3dbEF;
    uint256 constant SIGNER = 0x5161;

    event RelayNativeDeposit(address from, uint256 amount, bytes32 id);
    event RelayErc20Deposit(address from, address token, uint256 amount, bytes32 id);

    function _fork(string memory key, uint256 chainId) internal returns (bool) {
        string memory rpc = vm.envOr(key, string(""));
        if (bytes(rpc).length == 0) {
            if (vm.envOr("REQUIRE_RELAY_FORK", false)) revert(string.concat(key, " required"));
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, chainId, "fork chain");
        assertEq(DEPOSITORY.code.length, 8628, "Relay depository v2 bytecode");
        return true;
    }

    function _quote(RelayFundingRoute r, bytes32 ref, uint256 amountIn, uint256 fee, uint256 minOut, bytes32 requestId)
        internal
        view
        returns (bytes memory)
    {
        RelayFundingRoute.Quote memory q = RelayFundingRoute.Quote(requestId, block.timestamp + 600, 1);
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(SIGNER, r.quoteDigest(ref, amountIn, fee, minOut, q));
        return abi.encode(q, abi.encodePacked(rr, s, v));
    }

    function testArcNativeDepositIntoLiveDepository() public {
        if (!_fork("ARC_FORK_RPC", 5042)) return;
        vm.etch(0x1800000000000000000000000000000000000000, type(ArcNativeCoinAuthorityCheatShim).runtimeCode);
        vm.allowCheatcodes(0x1800000000000000000000000000000000000000);
        vm.etch(0x1800000000000000000000000000000000000001, type(ArcNativeCoinControlCheatShim).runtimeCode);
        assertEq(IERC20Decimals(ARC_USDC_VIEW).decimals(), 6, "0x3600 view is 6 dp");
        address hub = address(new HubLike());
        RelayFundingRoute route = new RelayFundingRoute(
            RelayFundingRoute.Config(
                hub, address(0), makeAddr("rhVault"), 4663, DEPOSITORY, vm.addr(SIGNER), address(1), ARC_USDC_VIEW
            )
        );
        // Pre-r12 format: raw value call with the request id as calldata -> the live depository reverts.
        vm.deal(hub, 30 ether);
        vm.prank(hub);
        (bool rawOk,) = DEPOSITORY.call{value: 1 ether}(abi.encodePacked(keccak256("rid-0")));
        assertFalse(rawOk, "raw value deposit must revert on v2");

        // r14: 20.05 USDC + 777 wei (sub-6-dp remainder) -> RelayErc20Deposit(hub, 0x3600, 20_050_000, rid).
        bytes32 rid = keccak256("solon-r14-arc-rid");
        uint256 total = 20.05 ether + 777;
        bytes memory q = _quote(route, bytes32(uint256(1)), 20 ether + 777, 0.05 ether, 19e6, rid);
        uint256 before = DEPOSITORY.balance;
        uint256 viewBefore = IERC20(ARC_USDC_VIEW).balanceOf(DEPOSITORY);
        uint256 hubBefore = hub.balance;
        vm.expectEmit(DEPOSITORY);
        emit RelayErc20Deposit(hub, ARC_USDC_VIEW, 20_050_000, rid);
        vm.prank(hub);
        route.send{value: total}(bytes32(uint256(1)), 20 ether + 777, 0.05 ether, 19e6, q);
        assertEq(DEPOSITORY.balance - before, 20.05 ether, "depository native delta");
        assertEq(IERC20(ARC_USDC_VIEW).balanceOf(DEPOSITORY) - viewBefore, 20_050_000, "depository 0x3600 delta");
        assertEq(hubBefore - hub.balance, 20.05 ether, "hub paid the deposit, got the 777 wei back");
        assertEq(address(route).balance, 0, "route holds nothing");
        assertEq(IERC20(ARC_USDC_VIEW).allowance(address(route), DEPOSITORY), 0, "no allowance left");
    }

    function testRhErc20DepositIntoLiveDepository() public {
        if (!_fork("RH_FORK_RPC", 4663)) return;
        address vault = makeAddr("reserveVault");
        RelayFundingRoute route = new RelayFundingRoute(
            RelayFundingRoute.Config(
                vault, RH_USDG, makeAddr("arcHub"), 5042, DEPOSITORY, vm.addr(SIGNER), address(0), address(0)
            )
        );
        vm.prank(RELAY_SOLVER);
        IERC20(RH_USDG).transfer(vault, 600e6);
        vm.prank(vault);
        IERC20(RH_USDG).approve(address(route), 500e6);

        bytes32 rid = keccak256("solon-r12-rh-rid");
        bytes memory q = _quote(route, bytes32(uint256(2)), 499e6, 1e6, 498e18, rid);
        uint256 before = IERC20(RH_USDG).balanceOf(DEPOSITORY);
        vm.expectEmit(DEPOSITORY);
        emit RelayErc20Deposit(vault, RH_USDG, 500e6, rid);
        vm.prank(vault);
        route.send(bytes32(uint256(2)), 499e6, 1e6, 498e18, q);
        assertEq(IERC20(RH_USDG).balanceOf(DEPOSITORY) - before, 500e6, "depository USDG delta");
        assertEq(IERC20(RH_USDG).balanceOf(address(route)), 0, "route holds nothing");
        assertEq(IERC20(RH_USDG).allowance(address(route), DEPOSITORY), 0, "no allowance left");
    }
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Accepts plain native transfers like the hub (`receive`), for the sub-6-dp remainder.
contract HubLike {
    receive() external payable {}
}

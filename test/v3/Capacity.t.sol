// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CapacityController} from "../../src/v3/stock/CapacityController.sol";
import {OrderScheduler, IScheduledHub} from "../../src/v3/stock/OrderScheduler.sol";

/// @dev Minimal hub double: the scheduler only reads order state and asks the hub to launch.
contract SchedHub is IScheduledHub {
    address constant ASSET = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC); // NVDA, uncapped here
    CapacityController public capacity;
    OrderScheduler public scheduler;
    mapping(uint256 => uint8) public laneOf;
    mapping(uint256 => uint256) public usdOf;
    mapping(uint256 => bool) public pending;
    uint256[] public launched;
    uint256 public next;

    constructor(CapacityController c) {
        capacity = c;
    }

    function setScheduler(OrderScheduler s) external {
        scheduler = s;
    }

    function place(uint8 lane, uint256 usd) external returns (uint256 id) {
        id = ++next;
        laneOf[id] = lane;
        usdOf[id] = usd;
        pending[id] = true;
        if (lane == 1) capacity.reserveFor(key(id), ASSET, usd);
        scheduler.enqueue(lane, id);
    }

    function cancel(uint256 id) external {
        pending[id] = false;
    }

    function key(uint256 id) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), id));
    }

    function scheduleInfo(uint256 id) external view returns (bool, uint8, uint256, bytes32) {
        return (pending[id], laneOf[id], usdOf[id], key(id));
    }

    function launch(uint256 id, bytes calldata) external {
        require(msg.sender == address(scheduler) && pending[id]);
        pending[id] = false;
        if (laneOf[id] == 0) capacity.reservePublicFor(key(id), ASSET, usdOf[id]);
        capacity.markSent(key(id));
        launched.push(id);
    }

    function launchedCount() external view returns (uint256) {
        return launched.length;
    }
}

contract CapacityTest is Test {
    CapacityController cap;
    address owner = address(0xA11CE);
    address guardian = address(0x6A);
    address hub = address(0x4B);
    address rewards = address(0x4E);
    address constant NVDA = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);

    function setUp() public {
        cap = new CapacityController(owner, guardian);
        vm.startPrank(owner);
        cap.bind(hub, rewards);
        vm.stopPrank();
    }

    function k(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("order", i));
    }

    function _issuePublic(uint256 i, uint256 usd) internal {
        vm.startPrank(hub);
        cap.reservePublicFor(k(i), NVDA, usd);
        cap.markSent(k(i));
        cap.finalizeBuy(k(i), NVDA, usd / 100); // 1 raw per $100 in this fixture
        cap.markReviewed(k(i));
        vm.stopPrank();
    }

    // ------------------------------------------------------------ r7 per-asset caps

    address constant AAPL = address(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9);
    address constant TSLA = address(0x322F0929c4625eD5bAd873c95208D54E1c003b2d);

    function _assetCaps() internal {
        vm.startPrank(owner);
        cap.setAssetCap(NVDA, 400_000e18);
        cap.setAssetCap(AAPL, 300_000e18);
        cap.setAssetCap(TSLA, 300_000e18);
        vm.stopPrank();
    }

    function _fill(address asset, uint256 from, uint256 usdTotal, uint8 lane) internal returns (uint256 i) {
        i = from;
        for (uint256 left = usdTotal; left > 0; ++i) {
            uint256 usd = left > 10_000e18 ? 10_000e18 : left;
            vm.prank(lane == 0 ? hub : rewards);
            if (lane == 0) cap.reservePublicFor(k(i), asset, usd);
            else cap.reserveFor(k(i), asset, usd);
            vm.startPrank(hub);
            cap.markSent(k(i));
            cap.finalizeBuy(k(i), asset, usd / 100);
            vm.stopPrank();
            left -= usd;
        }
    }

    function testAssetCapsAreTheOwnerApprovedNumbers() public {
        _assetCaps();
        (uint256 c1,) = cap.assetCap(NVDA);
        (uint256 c2,) = cap.assetCap(AAPL);
        (uint256 c3,) = cap.assetCap(TSLA);
        assertEq(c1 + c2 + c3, cap.totalCap(), "NVDA $400k + AAPL $300k + TSLA $300k = $1M");
        assertEq(cap.cappedAssets().length, 3);
        assertEq(cap.assetRoomUsd(address(0xBEEF)), type(uint256).max, "uncapped asset: global caps only");
    }

    function testNvdaAtItsCapDoesNotBlockAaplOrTsla() public {
        _assetCaps();
        uint256 i = _fill(NVDA, 1, 400_000e18, 0);
        assertEq(cap.assetExposureUsd(NVDA), 400_000e18);
        assertEq(cap.assetRoomUsd(NVDA), 0);
        assertFalse(cap.canReserveFor(0, NVDA, 20e18));
        assertFalse(cap.canReserveFor(1, NVDA, 20e18), "the reward lane respects the asset cap too");
        vm.prank(hub);
        vm.expectRevert(CapacityController.AssetLimit.selector);
        cap.reservePublicFor(k(i), NVDA, 20e18);
        vm.prank(rewards);
        vm.expectRevert(CapacityController.AssetLimit.selector);
        cap.reserveFor(k(i), NVDA, 20e18);
        assertTrue(cap.canReserveFor(0, AAPL, 10_000e18));
        i = _fill(AAPL, i, 300_000e18, 0);
        assertTrue(cap.canReserveFor(0, TSLA, 10_000e18));
        // $700k issued: the public lane still has $100k of its $800k, all usable by TSLA
        i = _fill(TSLA, i, 100_000e18, 0);
        assertFalse(cap.canReserveFor(0, TSLA, 10_000e18), "public $800k reached");
        assertTrue(cap.canReserveFor(1, TSLA, 10_000e18), "reward reserve remains for TSLA");
        _fill(TSLA, i, 200_000e18, 1);
        assertEq(cap.exposureUsd(), 1_000_000e18);
        assertFalse(cap.canReserveFor(1, TSLA, 1e18));
    }

    function testAssetExposureTracksInflightIssuedRedeemingAndReleases() public {
        _assetCaps();
        vm.prank(hub);
        cap.reservePublicFor(k(1), AAPL, 10_000e18);
        assertEq(cap.inflightUsdOf(AAPL), 10_000e18);
        vm.prank(hub);
        cap.releaseUnsent(k(1));
        assertEq(cap.assetExposureUsd(AAPL), 0, "unsent release frees the asset");
        _fill(AAPL, 2, 10_000e18, 0);
        assertEq(cap.issuedUsdOf(AAPL), 10_000e18);
        vm.prank(hub);
        cap.beginRedeem(k(100), AAPL, 50e18);
        assertEq(cap.redeemingUsdOf(AAPL), 5_000e18);
        assertEq(cap.assetExposureUsd(AAPL), 10_000e18, "redeeming still counts");
        vm.prank(hub);
        cap.revertRedeem(k(100));
        assertEq(cap.redeemingUsdOf(AAPL), 0);
        vm.prank(hub);
        cap.beginRedeem(k(101), AAPL, 100e18);
        vm.prank(hub);
        cap.finalizeRedeem(k(101), true);
        assertEq(cap.assetExposureUsd(AAPL), 0);
        // a proven-refund release frees the reservation as well
        vm.prank(hub);
        cap.reservePublicFor(k(102), AAPL, 10_000e18);
        vm.startPrank(hub);
        cap.markSent(k(102));
        cap.release(k(102));
        vm.stopPrank();
        assertEq(cap.assetExposureUsd(AAPL), 0);
    }

    function testAssetCapGuardianLowersRaiseWaitsFortyEightHours() public {
        _assetCaps();
        vm.prank(guardian);
        cap.lowerAssetCap(NVDA, 100_000e18);
        vm.prank(guardian);
        vm.expectRevert(CapacityController.OnlyLower.selector);
        cap.lowerAssetCap(NVDA, 200_000e18);
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.proposeAssetCap(NVDA, 500_000e18);
        vm.prank(owner);
        vm.expectRevert(CapacityController.Timelocked.selector);
        cap.setAssetCap(NVDA, 500_000e18); // first set only
        vm.startPrank(owner);
        cap.proposeAssetCap(NVDA, type(uint256).max);
        vm.expectRevert(CapacityController.Timelocked.selector);
        cap.executeAssetCap(NVDA);
        vm.warp(block.timestamp + 48 hours);
        cap.executeAssetCap(NVDA);
        vm.stopPrank();
        (uint256 c,) = cap.assetCap(NVDA);
        assertEq(c, type(uint256).max);
    }

    /// @dev r11: the asset-less `reserve(bytes32,uint256)` / `reservePublic(bytes32,uint256)` entries are gone
    ///      (no dispatcher entry, no fallback), and the asset entries refuse a zero asset, so no reservation
    ///      can bypass the per-asset cap whoever calls it.
    function testNoAssetlessReservationPathExists() public {
        _assetCaps();
        vm.prank(guardian);
        cap.lowerAssetCap(NVDA, 0);
        bytes4[2] memory legacy = [bytes4(keccak256("reserve(bytes32,uint256)")), bytes4(keccak256("reservePublic(bytes32,uint256)"))];
        address[2] memory callers = [hub, rewards];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                vm.prank(callers[j]);
                (bool ok, bytes memory ret) = address(cap).call(abi.encodeWithSelector(legacy[i], k(1), 10_000e18));
                assertFalse(ok, "legacy selector must not dispatch");
                assertEq(ret.length, 0, "no function behind it, only the empty dispatcher revert");
            }
        }
        vm.prank(hub);
        vm.expectRevert();
        cap.reservePublicFor(k(1), address(0), 10_000e18);
        vm.prank(rewards);
        vm.expectRevert();
        cap.reserveFor(k(1), address(0), 10_000e18);
        // the capped asset still refuses through both asset-carrying entries
        vm.prank(hub);
        vm.expectRevert(CapacityController.AssetLimit.selector);
        cap.reservePublicFor(k(1), NVDA, 10_000e18);
        vm.prank(rewards);
        vm.expectRevert(CapacityController.AssetLimit.selector);
        cap.reserveFor(k(1), NVDA, 10_000e18);
        assertEq(cap.exposureUsd(), 0);
        assertEq(cap.assetExposureUsd(NVDA), 0);
    }

    /// @dev Random reserve / send / fill / release / redeem sequences over three capped assets: an asset's
    ///      exposure never exceeds its cap (unless the guardian lowered it under existing exposure), the three
    ///      exposures always sum to the global exposure, and a full unwind leaves every asset at zero.
    function testFuzzAssetCapsHoldAndSumToGlobal(uint256 seed) public {
        _assetCaps();
        vm.prank(guardian);
        cap.lowerAssetCap(TSLA, 45_000e18); // make the asset caps bind before the global ones
        address[3] memory assets = [NVDA, AAPL, TSLA];
        uint256[3] memory caps = [uint256(400_000e18), 300_000e18, 45_000e18];
        uint8[64] memory st; // 0 none, 1 reserved, 2 sent, 3 issued, 4 redeeming, 5 closed
        uint8[64] memory which;
        for (uint256 step; step < 120; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 i = r % 64;
            uint8 a = uint8((r >> 8) % 3);
            uint256 usd = ((r >> 16) % 10_000 + 1) * 1e18;
            vm.startPrank(hub);
            if (st[i] == 0) {
                vm.stopPrank();
                bool can = cap.canReserveFor(uint8((r >> 40) % 2), assets[a], usd);
                vm.prank((r >> 40) % 2 == 0 ? hub : rewards);
                if ((r >> 40) % 2 == 0) {
                    try cap.reservePublicFor(k(i), assets[a], usd) {
                        st[i] = 1;
                        which[i] = a;
                    } catch {}
                } else {
                    try cap.reserveFor(k(i), assets[a], usd) {
                        st[i] = 1;
                        which[i] = a;
                    } catch {}
                }
                assertEq(st[i] == 1, can, "canReserveFor agrees with reserve");
                vm.startPrank(hub);
            } else if (st[i] == 1) {
                if (r % 5 == 0) {
                    cap.releaseUnsent(k(i));
                    st[i] = 5;
                } else {
                    cap.markSent(k(i));
                    st[i] = 2;
                }
            } else if (st[i] == 2) {
                if (r % 4 == 0) {
                    cap.release(k(i));
                    st[i] = 5;
                } else {
                    cap.finalizeBuy(k(i), assets[which[i]], 1e18);
                    st[i] = 3;
                }
            } else if (st[i] == 3) {
                cap.beginRedeem(keccak256(abi.encode("redeem", i)), assets[which[i]], 1e18);
                st[i] = 4;
            } else if (st[i] == 4) {
                cap.finalizeRedeem(keccak256(abi.encode("redeem", i)), true);
                st[i] = 5;
            }
            vm.stopPrank();
            uint256 sum;
            for (uint256 j; j < 3; ++j) {
                uint256 e = cap.assetExposureUsd(assets[j]);
                assertLe(e, caps[j], "asset cap");
                sum += e;
            }
            assertEq(sum, cap.exposureUsd(), "asset exposures sum to the global exposure");
        }
    }

    function testSingleOrderAtMostTenThousandDollars() public {
        vm.prank(hub);
        vm.expectRevert(CapacityController.RunLimit.selector);
        cap.reservePublicFor(k(1), NVDA, 10_000e18 + 1);
        vm.prank(rewards);
        vm.expectRevert(CapacityController.RunLimit.selector);
        cap.reserveFor(k(2), NVDA, 10_000e18 + 1);
        vm.prank(hub);
        cap.reservePublicFor(k(1), NVDA, 10_000e18);
        assertEq(cap.inflightUsd(), 10_000e18);
    }

    function testDefaultCapsAreTheOwnerApprovedNumbers() public view {
        assertEq(cap.lRun(), 10_000e18, "per order $10k");
        assertEq(cap.uRun(), 1_000_000e18, "unreviewed $1M (= total)");
        assertEq(cap.totalCap(), 1_000_000e18, "total issuance $1M");
        assertEq(cap.rewardReserve(), 200_000e18, "20% of the total for rewards");
        assertEq(cap.publicCap(), 800_000e18, "public global = total - reward reserve");
        assertEq(cap.rewardUnreviewedShare(), 200_000e18, "20% of U_run belongs to rewards");
    }

    function _reservePublicN(uint256 from, uint256 n, uint256 usd) internal {
        vm.startPrank(hub);
        for (uint256 i; i < n; ++i) {
            cap.reservePublicFor(k(from + i), NVDA, usd);
        }
        vm.stopPrank();
    }

    function testUnreviewedIsAbsoluteNotNettedAndPublicStopsAtItsShare() public {
        vm.prank(guardian);
        cap.lowerLimits(10_000e18, 100_000e18, 1_000_000e18); // public unreviewed share $80k
        _reservePublicN(0, 8, 10_000e18);
        vm.prank(hub);
        vm.expectRevert(CapacityController.UnreviewedLimit.selector);
        cap.reservePublicFor(k(8), NVDA, 1);
        // A redemption settled over LayerZero is unreviewed exposure too; it never nets a buy.
        vm.startPrank(hub);
        cap.markSent(k(0));
        cap.finalizeBuy(k(0), NVDA, 100e18);
        cap.markReviewed(k(0));
        cap.reservePublicFor(k(8), NVDA, 10_000e18);
        cap.beginRedeem(k(100), NVDA, 100e18);
        cap.finalizeRedeem(k(100), false);
        vm.stopPrank();
        assertEq(cap.unreviewedUsd(), 90_000e18, "sell adds, does not net");
        vm.prank(hub);
        vm.expectRevert(CapacityController.UnreviewedLimit.selector);
        cap.reservePublicFor(k(9), NVDA, 1);
        vm.prank(hub);
        cap.markReviewed(k(100));
        assertEq(cap.unreviewedUsd(), 80_000e18);
    }

    /// Review #4: public buys and round trips can no longer use up the unreviewed room the reward lane
    /// needs; the reward lane keeps 20% of U_run for itself until canonical review.
    function testPublicUnreviewedCannotStarveTheRewardLane() public {
        _reservePublicN(0, 80, 10_000e18);
        // Public round trips overflow the public share through redemptions (exits are never capped).
        vm.startPrank(hub);
        for (uint256 i; i < 5; ++i) {
            cap.markSent(k(i));
            cap.finalizeBuy(k(i), NVDA, 100e18);
            cap.beginRedeem(k(200 + i), NVDA, 100e18);
            cap.finalizeRedeem(k(200 + i), false);
        }
        vm.stopPrank();
        assertEq(cap.unreviewedUsd(), 850_000e18);
        assertEq(cap.unreviewedRewardUsd(), 0);
        for (uint256 i; i < 20; ++i) {
            vm.prank(rewards);
            cap.reserveFor(k(300 + i), NVDA, 10_000e18);
        }
        assertEq(cap.unreviewedRewardUsd(), 200_000e18, "the reward share is always available to rewards");
        vm.prank(rewards);
        vm.expectRevert(CapacityController.UnreviewedLimit.selector);
        cap.reserveFor(k(400), NVDA, 1);
        // Review releases the reward share for reuse.
        vm.startPrank(hub);
        cap.markSent(k(300));
        cap.finalizeBuy(k(300), NVDA, 100e18);
        cap.markReviewed(k(300));
        vm.stopPrank();
        assertEq(cap.unreviewedRewardUsd(), 190_000e18);
        vm.prank(rewards);
        cap.reserveFor(k(400), NVDA, 10_000e18);
    }

    function testRewardLaneMayUseIdlePublicUnreviewedRoom() public {
        vm.prank(guardian);
        cap.lowerLimits(10_000e18, 500_000e18, 1_000_000e18); // reward share $100k, public $400k
        for (uint256 i; i < 30; ++i) {
            vm.prank(rewards);
            cap.reserveFor(k(i), NVDA, 10_000e18);
        }
        assertEq(cap.unreviewedRewardUsd(), 300_000e18, "beyond its own share while U_run has room");
        // Public reaches only what U_run still has in total.
        _reservePublicN(100, 20, 10_000e18);
        vm.prank(hub);
        vm.expectRevert(CapacityController.UnreviewedLimit.selector);
        cap.reservePublicFor(k(999), NVDA, 1);
        vm.prank(rewards);
        vm.expectRevert(CapacityController.UnreviewedLimit.selector);
        cap.reserveFor(k(998), NVDA, 1);
    }

    function testPublicGlobalEightHundredThousandAndRewardReserveTwoHundred() public {
        for (uint256 i; i < 80; ++i) {
            _issuePublic(i, 10_000e18);
        }
        assertEq(cap.exposureUsd(), 800_000e18);
        assertFalse(cap.canReserve(0, 1));
        vm.prank(hub);
        vm.expectRevert(CapacityController.PublicLimit.selector);
        cap.reservePublicFor(k(80), NVDA, 1);
        // The reward lane may use the reserved 20% up to the $1M total.
        for (uint256 i; i < 20; ++i) {
            vm.prank(rewards);
            cap.reserveFor(k(100 + i), NVDA, 10_000e18);
            vm.startPrank(hub);
            cap.markSent(k(100 + i));
            cap.finalizeBuy(k(100 + i), NVDA, 100e18);
            cap.markReviewed(k(100 + i));
            vm.stopPrank();
        }
        assertEq(cap.exposureUsd(), 1_000_000e18);
        vm.prank(rewards);
        vm.expectRevert(CapacityController.TotalLimit.selector);
        cap.reserveFor(k(200), NVDA, 1);
    }

    function testPublicCannotBorrowRewardReserveEvenWhenRewardIdle() public {
        for (uint256 i; i < 79; ++i) {
            _issuePublic(i, 10_000e18);
        }
        vm.prank(hub);
        cap.reservePublicFor(k(98), NVDA, 5_000e18);
        vm.prank(hub);
        vm.expectRevert(CapacityController.PublicLimit.selector);
        cap.reservePublicFor(k(99), NVDA, 5_000e18 + 1);
        vm.prank(hub);
        cap.reservePublicFor(k(99), NVDA, 5_000e18);
        assertEq(cap.exposureUsd(), 800_000e18);
    }

    function testSentOrderCannotBeReleasedAsUnsentOrByTimeout() public {
        vm.prank(rewards);
        cap.reserveFor(k(1), NVDA, 500e18);
        vm.prank(hub);
        cap.markSent(k(1));
        vm.warp(block.timestamp + 30 days);
        vm.prank(rewards);
        vm.expectRevert(CapacityController.AlreadySent.selector);
        cap.releaseUnsent(k(1));
        assertEq(cap.inflightUsd(), 500e18, "unknown RH outcome keeps its reservation");
        vm.prank(rewards);
        vm.expectRevert(CapacityController.NotHub.selector);
        cap.release(k(1));
        vm.prank(hub);
        cap.release(k(1)); // hub only, after a proven refund / RH Failed result
        assertEq(cap.inflightUsd(), 0);
        assertEq(cap.inflightUsdOf(NVDA), 0, "per-asset inflight released with it");
        assertEq(cap.unreviewedUsd(), 0);
    }

    function testUnsentRewardReservationCanBeReleasedAndReused() public {
        vm.prank(rewards);
        cap.reserveFor(k(1), NVDA, 500e18);
        vm.prank(rewards);
        cap.releaseUnsent(k(1));
        assertEq(cap.inflightUsd(), 0);
        vm.prank(rewards);
        cap.reserveFor(k(1), NVDA, 400e18); // same order id may be reused after an unsent cancel
        assertEq(cap.inflightUsd(), 400e18);
        assertEq(cap.inflightUsdOf(NVDA), 400e18, "per-asset inflight follows the reuse");
    }

    function testOnlyRewardManagerUsesRewardLane() public {
        vm.prank(hub);
        vm.expectRevert(CapacityController.NotRewardManager.selector);
        cap.reserveFor(k(1), NVDA, 1);
        vm.prank(address(0xBAD));
        vm.expectRevert(CapacityController.NotHub.selector);
        cap.reservePublicFor(k(1), NVDA, 1);
    }

    function testRedeemUsesCostBasisAndFailedSellRestoresWithoutCapCheck() public {
        _issuePublic(1, 1_000e18); // 10 raw at $100
        _issuePublic(2, 500e18); // 5 raw at $100
        vm.startPrank(hub);
        uint256 usd = cap.beginRedeem(k(9), NVDA, 3e18); // 3 of 15 raw
        vm.stopPrank();
        assertEq(cap.issuedRaw(NVDA), 12e18);
        assertEq(usd, 300e18, "average cost basis, rounded up");
        // Guardian tightens the run limits; returning a failed sell must still succeed.
        vm.prank(guardian);
        cap.lowerLimits(0, 0, 0);
        vm.prank(hub);
        cap.revertRedeem(k(9));
        assertEq(cap.issuedRaw(NVDA), 15e18);
        assertEq(cap.exposureUsd(), 1_500e18);
    }

    function testFuzz_RedeemBasisConservesExposure(uint256 usdA, uint256 usdB, uint256 rawOut) public {
        usdA = bound(usdA, 1e18, 1_000e18);
        usdB = bound(usdB, 1e18, 1_000e18);
        _issuePublic(1, usdA);
        _issuePublic(2, usdB);
        uint256 issued = cap.issuedRaw(NVDA);
        rawOut = bound(rawOut, 1, issued);
        uint256 before = cap.exposureUsd();
        vm.prank(hub);
        uint256 usd = cap.beginRedeem(k(9), NVDA, rawOut);
        assertLe(usd, before);
        assertEq(cap.exposureUsd(), before, "moving to redeeming keeps total exposure");
        vm.prank(hub);
        cap.finalizeRedeem(k(9), true);
        assertEq(cap.exposureUsd(), before - usd);
        assertEq(cap.issuedRaw(NVDA), issued - rawOut);
        if (rawOut == issued) assertEq(cap.exposureUsd(), 0, "full redemption releases everything");
    }

    function testTransfersOfIssuedStockDoNotTouchCapacity() public {
        _issuePublic(1, 1_000e18);
        uint256 beforeExposure = cap.exposureUsd();
        // DirectStock fee movements are ERC20 transfers of already-issued supply: no controller call exists
        // for them, and a final redemption is the only release.
        vm.prank(hub);
        cap.beginRedeem(k(2), NVDA, 10e18);
        assertEq(cap.exposureUsd(), beforeExposure, "pending redeem still occupies");
        vm.prank(hub);
        cap.finalizeRedeem(k(2), true);
        assertEq(cap.exposureUsd(), 0);
    }

    function testGuardianLowersAtOnceRaisesWaitFortyEightHours() public {
        vm.prank(guardian);
        cap.lowerLimits(500e18, 5_000e18, 50_000e18);
        assertEq(cap.lRun(), 500e18);
        assertEq(cap.uRun(), 5_000e18);
        assertEq(cap.totalCap(), 50_000e18);
        vm.prank(guardian);
        vm.expectRevert(CapacityController.OnlyLower.selector);
        cap.lowerLimits(600e18, 5_000e18, 50_000e18);
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.proposeLimits(10_000e18, 1_000_000e18, 1_000_000e18);
        vm.prank(owner);
        cap.proposeLimits(10_000e18, 1_000_000e18, 1_000_000e18);
        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(owner);
        vm.expectRevert(CapacityController.Timelocked.selector);
        cap.executeLimits();
        vm.warp(block.timestamp + 1);
        vm.prank(guardian);
        vm.expectRevert(CapacityController.NotOwner.selector);
        cap.executeLimits();
        vm.prank(owner);
        cap.executeLimits();
        assertEq(cap.lRun(), 10_000e18);
        assertEq(cap.uRun(), 1_000_000e18);
        assertEq(cap.totalCap(), 1_000_000e18);
        vm.prank(owner);
        vm.expectRevert(CapacityController.Timelocked.selector);
        cap.executeLimits(); // a proposal executes once
    }

    function testCapsCanBeLiftedToUnlimitedThroughTheTimelock() public {
        uint256 max = type(uint256).max;
        vm.prank(owner);
        cap.proposeLimits(max, max, max);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        cap.executeLimits();
        assertEq(cap.publicCap(), max - max / 5);
        _issuePublic(1, 5_000_000e18);
        vm.prank(rewards);
        cap.reserveFor(k(2), NVDA, 7_000_000e18);
        assertEq(cap.exposureUsd(), 12_000_000e18);
        // The guardian can still pull them back down at once.
        vm.prank(guardian);
        cap.lowerLimits(10_000e18, 1_000_000e18, 1_000_000e18);
        assertFalse(cap.canReserve(0, 1));
    }

    /// Review #1: the RoundManager's finalize call exists on the real controller, is idempotent and only
    /// confirms what the hub already finalized (Issued or Closed); an unfinalized reservation reverts.
    function testReleaseFinalizedConfirmsTheHubsFinalizationOnly() public {
        vm.prank(rewards);
        cap.reserveFor(k(1), NVDA, 400e18);
        vm.prank(rewards);
        vm.expectRevert(CapacityController.NotFinalized.selector);
        cap.releaseFinalized(k(1));
        vm.prank(hub);
        vm.expectRevert(CapacityController.NotRewardManager.selector);
        cap.releaseFinalized(k(1));
        vm.startPrank(hub);
        cap.markSent(k(1));
        cap.finalizeBuy(k(1), NVDA, 4e18);
        vm.stopPrank();
        uint256 exposure = cap.exposureUsd();
        vm.startPrank(rewards);
        cap.releaseFinalized(k(1));
        cap.releaseFinalized(k(1));
        vm.stopPrank();
        assertEq(cap.exposureUsd(), exposure, "issued stock stays issued");
        // A refunded order: the hub already closed the ticket.
        vm.prank(rewards);
        cap.reserveFor(k(2), NVDA, 300e18);
        vm.startPrank(hub);
        cap.markSent(k(2));
        cap.release(k(2));
        vm.stopPrank();
        vm.prank(rewards);
        cap.releaseFinalized(k(2));
        assertEq(cap.inflightUsd(), 0);
    }

    function testFinalizeNeverRevertsOnUnknownTicket() public {
        vm.prank(hub);
        cap.finalizeBuy(k(77), NVDA, 5); // e.g. a late orphan whose ticket was already closed
        assertEq(cap.issuedRaw(NVDA), 5);
        assertEq(cap.exposureUsd(), 0);
    }
}

contract SchedulerTest is Test {
    CapacityController cap;
    SchedHub hub;
    OrderScheduler sched;
    address owner = address(0xA11CE);

    function setUp() public {
        cap = new CapacityController(owner, address(0x6A));
        hub = new SchedHub(cap);
        sched = new OrderScheduler(address(hub), cap);
        hub.setScheduler(sched);
        vm.prank(owner);
        cap.bind(address(hub), address(hub));
    }

    function _launchAll() internal returns (uint256[] memory order) {
        uint256 n;
        while (true) {
            (bool found,, uint256 id) = sched.nextLaunch();
            if (!found) break;
            sched.launchNext(id, "");
            ++n;
        }
        order = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            order[i] = hub.launched(i);
        }
    }

    function testThreePublicToOneReward() public {
        for (uint256 i; i < 8; ++i) {
            hub.place(0, 100e18); // ids 1..8 public
        }
        for (uint256 i; i < 3; ++i) {
            hub.place(1, 100e18); // ids 9..11 reward
        }
        uint256[] memory o = _launchAll();
        uint256[11] memory want = [uint256(1), 2, 3, 9, 4, 5, 6, 10, 7, 8, 11];
        assertEq(o.length, 11);
        for (uint256 i; i < 11; ++i) {
            assertEq(o[i], want[i]);
        }
    }

    function testEmptyQueueLendsItsSlotAndCancelledEntriesAreSkipped() public {
        hub.place(1, 100e18); // 1
        hub.place(1, 100e18); // 2
        uint256 c = hub.place(0, 100e18); // 3 public, cancelled before launch
        hub.cancel(c);
        uint256[] memory o = _launchAll();
        assertEq(o.length, 2);
        assertEq(o[0], 1);
        assertEq(o[1], 2);
    }

    function testCappedPublicDoesNotBlockReward() public {
        // Fill the public share: 80 x $10,000 issued and reviewed.
        for (uint256 i; i < 80; ++i) {
            uint256 id = hub.place(0, 10_000e18);
            sched.launchNext(id, "");
            vm.startPrank(address(hub));
            cap.finalizeBuy(hub.key(id), address(1), 10);
            cap.markReviewed(hub.key(id));
            vm.stopPrank();
        }
        uint256 blocked = hub.place(0, 10_000e18);
        uint256 reward = hub.place(1, 10_000e18);
        (bool found, uint8 lane, uint256 id) = sched.nextLaunch();
        assertTrue(found);
        assertEq(lane, 1);
        assertEq(id, reward);
        vm.expectRevert(OrderScheduler.NotNext.selector);
        sched.launchNext(blocked, "");
        sched.launchNext(reward, "");
        (found,,) = sched.nextLaunch();
        assertFalse(found, "public head waits for capacity; it is not skipped");
    }
}

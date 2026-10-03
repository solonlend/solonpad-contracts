// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OApp, Origin, MessagingFee} from "../../../../src/v3/stock/lz/OApp.sol";
import {OAppSender} from "../../../../src/v3/stock/lz/OAppSender.sol";
import {OAppReceiver} from "../../../../src/v3/stock/lz/OAppReceiver.sol";
import {OAppCore} from "../../../../src/v3/stock/lz/OAppCore.sol";
import {IOAppCore} from "../../../../src/v3/stock/lz/IOAppCore.sol";
import {MessagingParams, MessagingReceipt} from "../../../../src/v3/stock/lz/ILayerZeroEndpointV2.sol";
import {SolonStockHub} from "../../../../src/v3/stock/SolonStockHub.sol";
import {MockLzEndpoint} from "../../helpers/StockMocks.sol";

/// @dev Thin harness over the vendored LayerZero OApp base (src/v3/stock/lz/*). It adds nothing but
///      external entry points to the internal `_quote` / `_lzSend` and counts `_lzReceive` calls, so the
///      vendored branches are exercised exactly as the production OApps (hub, vault, sender…) use them.
contract CovDOAppHarness is OApp {
    uint256 public received;

    constructor(address ep, address owner_, address delegate_) OApp(ep, delegate_) Ownable(owner_) {}

    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal override {
        ++received;
    }

    function quoteSend(uint32 eid, bytes calldata m) external view returns (uint256) {
        return _quote(eid, m, "", false).nativeFee;
    }

    function send(uint32 eid, bytes calldata m) external payable {
        MessagingFee memory f = _quote(eid, m, "", false);
        _lzSend(eid, m, "", f, msg.sender);
    }

    function sendWithFee(uint32 eid, bytes calldata m, uint256 native, uint256 lzt) external payable {
        _lzSend(eid, m, "", MessagingFee(native, lzt), msg.sender);
    }
}

/// @dev Send-only and receive-only harnesses: the only way to reach the base `oAppVersion` overloads that
///      `OApp` overrides.
contract CovDSenderOnly is OAppSender {
    constructor(address ep, address owner_) OAppCore(ep, owner_) Ownable(owner_) {}
}

contract CovDReceiverOnly is OAppReceiver {
    constructor(address ep, address owner_) OAppCore(ep, owner_) Ownable(owner_) {}

    function _lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) internal override {}
}

contract CovDLzToken is ERC20("LZ", "LZ") {
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev Endpoint double that supports paying in an lzToken (MockLzEndpoint reports none).
contract CovDLzTokenEndpoint {
    address public lzToken;
    mapping(address => address) public delegates;
    uint256 public sends;

    constructor(address t) {
        lzToken = t;
    }

    function setDelegate(address d) external {
        delegates[msg.sender] = d;
    }

    function send(MessagingParams calldata, address) external payable returns (MessagingReceipt memory r) {
        ++sends;
        r.nonce = uint64(sends);
    }
}

contract CovDOAppBaseTest is Test {
    uint32 constant EID = 30417;
    uint32 constant REMOTE = 30416;
    MockLzEndpoint ep;
    CovDOAppHarness app;
    address owner = address(0xA11CE);
    address peer = address(0x7A017);

    function setUp() public {
        ep = new MockLzEndpoint(EID);
        app = new CovDOAppHarness(address(ep), owner, owner);
        vm.prank(owner);
        app.setPeer(REMOTE, bytes32(uint256(uint160(peer))));
    }

    /// OAppCore L31 (true arm): a zero delegate is refused by the vendored constructor.
    function testCovD_ZeroDelegateIsRefused() public {
        vm.expectRevert(IOAppCore.InvalidDelegate.selector);
        new CovDOAppHarness(address(ep), owner, address(0));
    }

    /// In every production OApp the delegate is `owner_` and `Ownable(owner_)` runs first (C3 order), so a
    /// zero owner is refused by Ownable before OAppCore L31 is even reached.
    function testCovD_ProductionOAppZeroOwnerFailsInOwnableFirst() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SolonStockHub(address(ep), address(0x7EA5), 25, address(0), address(0x0B5), [address(0xF1), address(0xF2)]);
    }

    function testCovD_SetDelegateOwnerOnly() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        app.setDelegate(address(0xD1));
        vm.prank(owner);
        app.setDelegate(address(0xD1));
        assertEq(ep.delegates(address(app)), address(0xD1));
    }

    function testCovD_VersionsAndReceiverViews() public {
        (uint64 s, uint64 r) = app.oAppVersion();
        assertEq(s, 1);
        assertEq(r, 2);
        CovDSenderOnly so = new CovDSenderOnly(address(ep), owner);
        (s, r) = so.oAppVersion();
        assertEq(s, 1);
        assertEq(r, 0);
        CovDReceiverOnly ro = new CovDReceiverOnly(address(ep), owner);
        (s, r) = ro.oAppVersion();
        assertEq(s, 0);
        assertEq(r, 2);
        Origin memory o = Origin(REMOTE, bytes32(uint256(uint160(peer))), 1);
        assertTrue(app.isComposeMsgSender(o, "", address(app)));
        assertFalse(app.isComposeMsgSender(o, "", address(this)));
        assertTrue(app.allowInitializePath(o));
        o.sender = bytes32(uint256(1));
        assertFalse(app.allowInitializePath(o));
        assertEq(app.nextNonce(REMOTE, bytes32(0)), 0);
    }

    function testCovD_LzReceiveGuards() public {
        Origin memory o = Origin(REMOTE, bytes32(uint256(uint160(peer))), 1);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, address(this)));
        app.lzReceive(o, bytes32(0), "", address(0), "");
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, uint32(5)));
        ep.inject(5, peer, address(app), "");
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, REMOTE, bytes32(uint256(0xBAD))));
        ep.inject(REMOTE, address(0xBAD), address(app), "");
        assertEq(app.received(), 0);
        ep.inject(REMOTE, peer, address(app), "");
        assertEq(app.received(), 1);
    }

    /// OAppSender L104 (default `_payNative`, used by StockPriceSender/FloatRebalancer): value must equal the fee.
    function testCovD_DefaultPayNativeNeedsExactFee() public {
        vm.deal(address(this), 1 ether);
        assertEq(app.quoteSend(REMOTE, "m"), 0.01 ether);
        vm.expectRevert(abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, 0.02 ether));
        app.send{value: 0.02 ether}(REMOTE, "m");
        vm.expectRevert(abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, 0.005 ether));
        app.send{value: 0.005 ether}(REMOTE, "m");
        app.send{value: 0.01 ether}(REMOTE, "m");
        assertEq(ep.packetCount(), 1);
        assertEq(address(ep).balance, 0.01 ether);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, uint32(9)));
        app.quoteSend(9, "m");
    }

    /// OAppSender L83/L118: an lzToken fee needs an endpoint that has an lzToken; with one, the caller pays it.
    function testCovD_LzTokenFeePaths() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(OAppSender.LzTokenUnavailable.selector);
        app.sendWithFee{value: 0.01 ether}(REMOTE, "m", 0.01 ether, 1);

        CovDLzToken t = new CovDLzToken();
        CovDLzTokenEndpoint tep = new CovDLzTokenEndpoint(address(t));
        CovDOAppHarness app2 = new CovDOAppHarness(address(tep), owner, owner);
        vm.prank(owner);
        app2.setPeer(REMOTE, bytes32(uint256(uint160(peer))));
        t.mint(address(this), 5);
        t.approve(address(app2), 5);
        app2.sendWithFee(REMOTE, "m", 0, 5);
        assertEq(t.balanceOf(address(tep)), 5, "lzToken fee pulled from the caller to the endpoint");
        assertEq(tep.sends(), 1);
    }
}

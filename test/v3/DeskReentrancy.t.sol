// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {LedgerStock, LedgerReceiver} from "./V3FeeLedger.t.sol";
import {DeskProtocolFixture} from "./helpers/DeskProtocolFixture.sol";

contract DeskReentrantHolder {
    bool public attempted;
    bool public succeeded;

    function onERC721Received(address, address, uint256 id, bytes calldata data) external returns (bytes4) {
        bytes32[] memory keys = abi.decode(data, (bytes32[]));
        attempted = true;
        (succeeded,) = msg.sender.call(abi.encodeWithSelector(DeskNFT.claim.selector, id, keys));
        return this.onERC721Received.selector;
    }

    function claim(DeskNFT nft, uint256 id, bytes32[] calldata keys) external {
        nft.claim(id, keys);
    }
}

contract DeskReentrancyTest is Test {
    DeskNFT nft;
    DeskRewards rewards;
    V3FeeLedger ledger;
    LedgerStock stock;
    address alice = address(0xa11ce);
    bytes32 constant POOL = keccak256("independent-desk-lock");

    function setUp() public {
        vm.warp(10 days);
        ledger = new V3FeeLedger(address(this), address(0));
        rewards = new DeskRewards(ledger, address(this));
        LedgerStock solon = new LedgerStock();
        stock = new LedgerStock();
        nft = new DeskNFT(
            address(this),
            address(solon),
            address(0xd00d),
            address(rewards),
            address(new DeskProtocolFixture()),
            address(0),
            DeskNFT.Quote(2 ether, 1 ether, 10 days, 1, keccak256("quote"))
        );
        rewards.configureNFT(nft);
        solon.mint(alice, 100000 ether);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        solon.approve(address(nft), type(uint256).max);
        nft.mint{value: 1 ether}(1, alice);
        vm.stopPrank();
        address[6] memory receivers;
        for (uint256 i; i < 6; ++i) {
            receivers[i] = address(new LedgerReceiver());
        }
        receivers[2] = address(rewards);
        ledger.registerPool(POOL, address(stock), 1, address(this), receivers);
        stock.mint(address(this), 1000);
        stock.approve(address(ledger), 1000);
        ledger.creditStock(POOL, 1000);
    }

    function _keys() internal view returns (bytes32[] memory keys) {
        keys = new bytes32[](1);
        keys[0] = rewards.streamKey(POOL, 10, address(stock), 1);
    }

    function testSafeTransferCallbackCannotClaimBeforeSharedLockReleases() public {
        DeskReentrantHolder receiver = new DeskReentrantHolder();
        bytes32[] memory keys = _keys();
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(receiver), 1, abi.encode(keys));
        assertTrue(receiver.attempted());
        assertFalse(receiver.succeeded());
        assertEq(rewards.paidRaw(1, keys[0]), 0);
        receiver.claim(nft, 1, keys);
        assertEq(stock.balanceOf(address(receiver)), 100);
        assertEq(stock.balanceOf(alice), 0);
    }

    function testBlockedStockDeliveryPreservesDebtAndCanRetry() public {
        bytes32[] memory keys = _keys();
        vm.mockCall(address(stock), abi.encodeWithSignature("transfer(address,uint256)", alice, 100), abi.encode(false));
        vm.prank(alice);
        vm.expectRevert();
        nft.claim(1, keys);
        assertEq(rewards.paidRaw(1, keys[0]), 0);
        assertEq(rewards.claimable(1, keys[0]), 100);
        vm.clearMockedCalls();
        vm.prank(alice);
        nft.claim(1, keys);
        assertEq(stock.balanceOf(alice), 100);
        assertEq(rewards.claimable(1, keys[0]), 0);
    }
}

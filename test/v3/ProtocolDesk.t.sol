// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {DeskProtocolFixture} from "./helpers/DeskProtocolFixture.sol";
import {Test} from "forge-std/Test.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {ProtocolDeskVault} from "../../src/v3/ProtocolDeskVault.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {SolonStakingV2} from "../../src/v3/SolonStakingV2.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {LedgerStock, LedgerReceiver} from "./V3FeeLedger.t.sol";

contract DeskOpsFixture {
    function payDeskSurcharge(bytes32, uint256, uint256 cards, address desk) external returns (uint256 amount) {
        amount = DeskNFT(desk).surchargeUSDC18() * cards;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
    receive() external payable {}
}

contract ProtocolDeskTest is Test {
    DeskNFT nft;
    DeskRewards rewards;
    ProtocolDeskVault vault;
    LedgerStock solon;
    LedgerStock stock;
    V3FeeLedger ledger;
    DeskOpsFixture ops;
    SolonStakingV2 staking;
    address alice = address(0xA11CE);
    address sink = address(0xDEAD);
    bytes32 constant POOL = keccak256("protocol-stock");

    function setUp() public {
        ledger = new V3FeeLedger(address(this), address(0));
        rewards = new DeskRewards(ledger, address(this));
        solon = new LedgerStock();
        stock = new LedgerStock();
        ops = new DeskOpsFixture();
        nft = new DeskNFT(
            address(this),
            address(solon),
            sink,
            address(rewards),
            address(new DeskProtocolFixture()),
            address(0),
            DeskNFT.Quote(2e18, 1e18, block.timestamp, 1, keccak256("quote"))
        );
        rewards.configureNFT(nft);
        vault = new ProtocolDeskVault(nft, solon, sink, address(this), address(ops));
        nft.configureProtocolVault(address(vault));
        EligibilityController controller = new EligibilityController(address(this));
        staking = new SolonStakingV2(address(solon), address(ledger), controller);
        staking.configureProtocolDesk(address(rewards), address(stock), bytes32("STOCK"), 1, bytes32("price"));
        rewards.configureProtocolStaking(address(staking));
        vm.deal(address(ops), 10000e18);
        solon.mint(address(this), 600000000e18);
        solon.approve(address(vault), type(uint256).max);
    }

    function testNativeProtocolBudgetIsSeparateFromRawStockForwarding() public {
        vault.depositBuyback(bytes32("native-buyback"), 100000e18);
        vault.mintAvailable(1);
        bytes32 key = rewards.streamKey(rewards.SURCHARGE(), block.timestamp / 1 days, address(0), 0);
        vm.expectRevert();
        rewards.forwardProtocolDesk(key);
        assertEq(rewards.fundProtocolDeskBudget(key), 0.9e18);
        assertEq(address(staking).balance, 0.9e18);
        assertEq(rewards.fundProtocolDeskBudget(key), 0);
    }

    function testProtocolCapSendsAllOverflowToSinkWithoutClaimingBurnEarly() public {
        vault.depositBuyback(bytes32("large-buyback"), 100150000e18);
        for (uint256 i; i < 50; ++i) {
            vault.mintAvailable(20);
        }
        assertEq(nft.balanceOf(address(vault)), 1000);
        assertEq(vault.mintAvailable(20), 0);
        assertEq(vault.pendingSolon(), 150000e18);
        assertEq(solon.balanceOf(sink), 100000000e18);
        uint256 supply = solon.totalSupply();
        assertEq(vault.sweepOverflowToBurn(), 150000e18);
        assertEq(vault.pendingSolon(), 0);
        assertEq(solon.totalSupply(), supply);
        vault.depositBuyback(bytes32("later-buyback"), 123e18);
        assertEq(vault.sweepOverflowToBurn(), 123e18);
        assertEq(solon.balanceOf(sink), 100150123e18);
    }

    function testProtocolFeeTimeRightsSurviveExitAndFundingCreatesNoNewRights() public {
        solon.mint(alice, 100001e18);
        vm.prank(alice);
        solon.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        staking.stake(1e18);
        vm.warp(block.timestamp + 1 hours);
        vm.deal(alice, 1e18);
        vm.prank(alice);
        solon.approve(address(nft), type(uint256).max);
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        vault.depositBuyback(bytes32("buyback-1"), 100000e18);
        vault.mintAvailable(1);
        address[6] memory receivers;
        for (uint256 i; i < 6; ++i) {
            receivers[i] = address(new LedgerReceiver());
        }
        receivers[2] = address(rewards);
        ledger.registerPool(POOL, address(stock), 1, address(this), receivers);
        stock.mint(address(this), 1000);
        stock.approve(address(ledger), 1000);
        ledger.creditStock(POOL, 1000);
        uint256 epoch = block.timestamp / 1 days;
        assertEq(staking.creditOf(staking.protocolSource(POOL), epoch, address(stock), 1, alice), 50e27);
        vm.prank(alice);
        staking.unstake(1e18, alice);
        bytes32 key = rewards.streamKey(POOL, epoch, address(stock), 1);
        assertEq(rewards.forwardProtocolDesk(key), 50);
        assertEq(stock.balanceOf(address(staking)), 50);
        assertEq(rewards.forwardProtocolDesk(key), 0);
        assertEq(staking.creditOf(staking.protocolSource(POOL), epoch, address(stock), 1, alice), 50e27);
        vm.prank(address(vault));
        vm.expectRevert();
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        nft.claim(2, keys);
    }

    function testProtocolCardsCannotTransferApproveOrReceiveOrdinaryCards() public {
        vault.depositBuyback(bytes32("buyback-1"), 100000e18);
        vault.mintAvailable(1);
        vm.prank(address(vault));
        vm.expectRevert();
        nft.transferFrom(address(vault), alice, 1);
        vm.prank(address(vault));
        vm.expectRevert();
        nft.approve(alice, 1);
        vm.prank(address(vault));
        vm.expectRevert();
        nft.setApprovalForAll(alice, true);
        solon.mint(alice, 200000e18);
        vm.deal(alice, 2e18);
        vm.prank(alice);
        solon.approve(address(nft), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert();
        nft.mint{value: 1e18}(1, address(vault));
        vm.prank(alice);
        nft.mint{value: 1e18}(1, alice);
        vm.prank(alice);
        vm.expectRevert();
        nft.transferFrom(alice, address(vault), 2);
    }

    function testBuybackOnlyMintsFullPriceAndKeepsPendingDust() public {
        vault.depositBuyback(bytes32("buyback-1"), 250000e18);
        vault.mintAvailable(20);
        assertEq(nft.balanceOf(address(vault)), 2);
        assertEq(vault.pendingSolon(), 50000e18);
        assertEq(solon.balanceOf(sink), 200000e18);
        assertEq(address(ops).balance, 9998e18);
    }
}

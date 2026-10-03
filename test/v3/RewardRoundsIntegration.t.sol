// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {RewardRoundManager} from "../../src/v3/RewardRoundManager.sol";
import {RoundStock, RoundRegistry, RoundAdapter, RoundCapacity} from "./RewardRounds.t.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";

contract RoundBucket {
    function onFeeCredit(bytes32, address, uint8, uint256) external {}
    receive() external payable {}
}

contract RewardRoundsIntegrationTest is Test {
    function onRoundFinalized(uint256) external {}

    function testRealTokenRoundConfiguration() public {
        RoundStock stock = new RoundStock();
        RoundAdapter adapter = new RoundAdapter(stock);
        RoundRegistry registry = new RoundRegistry(address(stock), address(adapter));
        RewardRoundManager rounds =
            new RewardRoundManager(address(this), address(registry), address(0xBEEF), address(0xFEE));
        V3RewardToken token = new V3RewardToken("Reward", "RWD", address(this), address(this), new address[](0));
        token.setDefaultRewardAsset(address(stock));
        token.configurePool(bytes32("pool"), address(0), 0);
        (bool ok,) = address(token)
            .call(
                abi.encodeWithSignature(
                    "configureRounds(address,bytes32,uint32,bytes32)",
                    address(rounds),
                    bytes32("NVDA"),
                    uint32(1),
                    bytes32("price")
                )
            );
        assertTrue(ok, "missing real token round configuration");
        (bool hasClock,) = address(token).staticcall(abi.encodeWithSignature("lastFeeAt()"));
        assertTrue(hasClock, "fee clock missing");
    }

    function testRealLedgerAndSoldOutHolderRetainOriginalStockRights() public {
        vm.warp(10 days);
        RoundStock stock = new RoundStock();
        RoundAdapter adapter = new RoundAdapter(stock);
        RoundRegistry registry = new RoundRegistry(address(stock), address(adapter));
        EligibilityController controller = new EligibilityController(address(this));
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), controller);
        payout.configureFactory(address(this));
        RewardRoundManager rounds =
            new RewardRoundManager(address(this), address(registry), address(payout), address(0xFEE));
        payout.registerSource(address(rounds.vault()));
        rounds.configureExecution(address(this), address(new RoundCapacity()));
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        V3RewardToken token = new V3RewardToken("Reward", "RWD", address(this), address(ledger), new address[](0));
        token.setDefaultRewardAsset(address(stock));
        token.configurePool(bytes32("pool"), address(0), 0);
        token.configureRounds(address(rounds), bytes32("NVDA"), 1, bytes32("price"));
        rounds.registerSource(address(token), bytes32("pool"));
        address[6] memory beneficiaries;
        beneficiaries[0] = address(token);
        for (uint256 i = 1; i < 6; ++i) {
            beneficiaries[i] = address(new RoundBucket());
        }
        ledger.registerPool(bytes32("pool"), address(0), 0, address(this), beneficiaries);
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        token.transfer(alice, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.deal(address(this), 400 ether);
        ledger.creditNative{value: 400 ether}(bytes32("pool"));
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertTrue(ledger.claim(bytes32("pool"), 0, 230 ether));
        vm.warp(11 days);
        uint256 e = rounds.seal(address(token), 10, 0, bytes32("NVDA"), 1, bytes32("price"), 0);
        assertEq(rounds.entry(e).budget18, 230 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = e;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 230 ether;
        uint256 r = rounds.reserveBatch(ids, amounts, 1, vm.getBlockTimestamp() + 1 hours);
        rounds.start(r, "");
        adapter.verifyFunding();
        rounds.poke(r);
        rounds.submit(r);
        adapter.setResult(1, 99, 0);
        rounds.finalize(r, "");
        payout.stageCredit(address(rounds.vault()), alice, ids, address(stock));
        payout.stageCredit(address(rounds.vault()), bob, ids, address(stock));
        assertEq(payout.readyRaw(alice, address(stock)), 99);
        assertEq(payout.readyRaw(bob, address(stock)), 0);
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        vm.prank(alice);
        payout.claim(assets);
        assertEq(stock.balanceOf(alice), 99);
        assertEq(stock.balanceOf(bob), 0);
        vm.prank(alice);
        vm.expectRevert();
        token.claim(ids, assets);
    }
}

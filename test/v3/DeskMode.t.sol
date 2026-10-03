// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {DeskNFT} from "../../src/v3/DeskNFT.sol";
import {DeskRewards} from "../../src/v3/DeskRewards.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";
import {EligibilityRegistry} from "../../src/v3/EligibilityRegistry.sol";
import {RewardAssetSchedule} from "../../src/v3/RewardAssetSchedule.sol";
import {LedgerStock} from "./V3FeeLedger.t.sol";
import {DeskProtocolFixture} from "./helpers/DeskProtocolFixture.sol";

contract DeskModeTest is Test {
    DeskRewards rewards;
    DeskNFT nft;
    EligibilityController controller;
    EligibilityRegistry registry;
    LedgerStock stock;

    function setUp() public {
        vm.warp(10 days);
        V3FeeLedger ledger = new V3FeeLedger(address(this), address(0));
        rewards = new DeskRewards(ledger, address(this));
        LedgerStock solon = new LedgerStock();
        stock = new LedgerStock();
        controller = new EligibilityController(address(this));
        registry = new EligibilityRegistry(address(this));
        controller.bindAsset(address(stock), 0);
        nft = new DeskNFT(
            address(this),
            address(solon),
            address(0xd00d),
            address(rewards),
            address(new DeskProtocolFixture()),
            address(controller),
            DeskNFT.Quote(2 ether, 1 ether, 10 days, 1, keccak256("quote"))
        );
        nft.bindEligibilityAsset(address(stock));
        rewards.configureNFT(nft);
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = keccak256("stock");
        uint32[] memory versions = new uint32[](1);
        versions[0] = 1;
        bytes32[] memory prices = new bytes32[](1);
        prices[0] = keccak256("price");
        RewardAssetSchedule schedule = new RewardAssetSchedule(10, 1, assets, ids, versions, prices);
        rewards.configureRounds(address(this), address(this), address(schedule));
        address alice = vm.addr(3);
        solon.mint(alice, 100000 ether);
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        solon.approve(address(nft), 100000 ether);
        nft.mint{value: 1 ether}(1, alice);
        vm.stopPrank();
        controller.scheduleEnable(address(registry), keccak256("policy"), 12);
    }

    function testOldBEpochRetainsItsModeAfterASwitch() public {
        vm.warp(12 days);
        (,,, uint8 mode) = rewards.sourcePolicy(10);
        assertEq(mode, 0, "old B epoch mislabeled A");
        (,,, mode) = rewards.sourcePolicy(12);
        assertEq(mode, 1);
    }

    function _sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _register(uint256 nonce) internal returns (bool ok) {
        EligibilityRegistry.Attestation memory a = EligibilityRegistry.Attestation(
            block.chainid,
            address(registry),
            vm.addr(3),
            keccak256("beneficiary"),
            1,
            1,
            keccak256("policy"),
            vm.getBlockTimestamp(),
            30 days,
            nonce,
            keccak256("terms")
        );
        bytes32 hash = registry.digest(a);
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(1);
        signers[1] = vm.addr(2);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sig(1, hash);
        signatures[1] = _sig(2, hash);
        (ok,) = address(registry).call(abi.encodeCall(registry.register, (a, signers, signatures, _sig(3, hash))));
    }

    function testCredentialRenewalWorksWithFixedDeskModule() public {
        registry.scheduleIssuer(vm.addr(1), true);
        registry.scheduleIssuer(vm.addr(2), true);
        vm.warp(12 days);
        registry.executeIssuer(vm.addr(1));
        registry.executeIssuer(vm.addr(2));
        assertTrue(_register(0));
        registry.setFixedModules(address(rewards), address(0));
        bytes32 key = rewards.streamKey(rewards.SURCHARGE(), 10, address(0), 0);
        uint256 credit = rewards.credit27(1, key);
        assertTrue(_register(1), "Desk callback blocks credential renewal");
        assertEq(rewards.credit27(1, key), credit);
    }
}

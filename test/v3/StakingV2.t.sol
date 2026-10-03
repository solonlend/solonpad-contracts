// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SolonStakingV2} from "../../src/v3/SolonStakingV2.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";
import {RewardAssetSchedule} from "../../src/v3/RewardAssetSchedule.sol";
import {V3FeeLedger} from "../../src/v3/V3FeeLedger.sol";
import {RewardRoundManager, IRoundRegistry} from "../../src/v3/RewardRoundManager.sol";
import {RewardPayoutVault} from "../../src/v3/RewardPayoutVault.sol";
import {EligibilityRegistry} from "../../src/v3/EligibilityRegistry.sol";
import {EligibilityController} from "../../src/v3/EligibilityController.sol";

contract StakeAsset is ERC20 {
    constructor() ERC20("Asset", "A") {}

    function mint(address who, uint256 amount) external {
        _mint(who, amount);
    }
}

contract StakingFeeObserver {
    function onFeeCredit(bytes32, address, uint8, uint256) external {}
}

contract StakingRouteRegistry {
    address public asset;

    constructor(address a) {
        asset = a;
    }

    function resolve(bytes32, uint32) external view returns (IRoundRegistry.Route memory) {
        return
            IRoundRegistry.Route(
                asset, asset, address(this), address(this), bytes32(uint256(1)), block.chainid, true, 0
            );
    }
}

contract StakingV2Test is Test {
    StakeAsset solon;
    StakeAsset stock;
    SolonStakingV2 staking;
    EligibilityController controller;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    function setUp() public {
        vm.warp(10 days);
        solon = new StakeAsset();
        stock = new StakeAsset();
        controller = new EligibilityController(address(this));
        staking = new SolonStakingV2(address(solon), address(this), controller);
        solon.mint(alice, 1000 ether);
        vm.prank(alice);
        solon.approve(address(staking), type(uint256).max);
    }

    function testPrincipalAlwaysImmediatelyWithdrawable() public {
        vm.prank(alice);
        (bool ok,) = address(staking).call(abi.encodeWithSignature("stake(uint256)", 100 ether));
        assertTrue(ok, "stake missing");
        vm.prank(alice);
        (ok,) = address(staking).call(abi.encodeWithSignature("unstake(uint256,address)", 100 ether, alice));
        assertTrue(ok, "principal exit missing");
        assertEq(solon.balanceOf(alice), 1000 ether);
    }

    function testStakeEarnsFromNextFeeWithoutActivation() public {
        bytes32 pool = bytes32(uint256(1));
        staking.configureSource(pool, address(stock), 1, address(stock), 0, 0, 0);
        solon.mint(bob, 100 ether);
        vm.startPrank(bob);
        solon.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();
        staking.onFeeCredit(pool, address(stock), 1, 10 ether);
        vm.prank(alice);
        staking.stake(100 ether);
        assertEq(staking.eligible(alice), 100 ether);
        assertEq(staking.totalEligible(), 200 ether);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        assertEq(staking.creditOf(pool, epoch, address(stock), 1, alice), 0, "earned fee before stake");
        staking.onFeeCredit(pool, address(stock), 1, 20 ether);
        assertEq(staking.creditOf(pool, epoch, address(stock), 1, alice), 10 ether * 1e27);
        assertEq(staking.creditOf(pool, epoch, address(stock), 1, bob), 20 ether * 1e27);
    }

    function testSameTransactionStakeThenUnstakeEarnsZero() public {
        bytes32 pool = bytes32(uint256(1));
        staking.configureSource(pool, address(stock), 1, address(stock), 0, 0, 0);
        solon.mint(bob, 100 ether);
        vm.startPrank(bob);
        solon.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();
        staking.onFeeCredit(pool, address(stock), 1, 10 ether);
        vm.startPrank(alice);
        staking.stake(1000 ether);
        staking.unstake(1000 ether, alice);
        vm.stopPrank();
        staking.onFeeCredit(pool, address(stock), 1, 10 ether);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        assertEq(staking.creditOf(pool, epoch, address(stock), 1, alice), 0);
        assertEq(staking.creditOf(pool, epoch, address(stock), 1, bob), 20 ether * 1e27);
        assertEq(staking.eligible(alice), 0);
        assertEq(staking.totalEligible(), 100 ether);
    }

    function testExcludedStakersEarnZeroAndActivationAbiIsRemoved() public {
        vm.prank(alice);
        staking.stake(100 ether);
        bytes[5] memory calls = [
            abi.encodeWithSignature("activate(uint256)", 100 ether),
            abi.encodeWithSignature("deactivate(uint256)", 100 ether),
            abi.encodeWithSignature("matureAt(address)", alice),
            abi.encodeWithSignature("pending(address)", alice),
            abi.encodeWithSignature("MATURITY()")
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok,) = address(staking).call(calls[i]);
            assertFalse(ok, "activation ABI still present");
        }
        // The ledger (this test) is a system address: its stake is principal only.
        solon.mint(address(this), 10 ether);
        solon.approve(address(staking), 10 ether);
        staking.stake(10 ether);
        assertEq(staking.stakedOf(address(this)), 10 ether);
        assertEq(staking.eligible(address(this)), 0);
        assertEq(staking.totalEligible(), 100 ether);
        staking.unstake(10 ether, address(this));
        assertEq(solon.balanceOf(address(this)), 10 ether);
    }

    function testFuzzEligibleTracksStakeInvariant(uint96[8] memory amounts, bool[8] memory exits) public {
        solon.mint(bob, 1e30);
        vm.prank(bob);
        solon.approve(address(staking), type(uint256).max);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 8; ++i) {
            address a = who[i % 2];
            if (exits[i] && staking.stakedOf(a) != 0) {
                uint256 out = bound(amounts[i], 1, staking.stakedOf(a));
                vm.prank(a);
                staking.unstake(out, a);
            } else {
                uint256 amount = bound(amounts[i], 1, solon.balanceOf(a) == 0 ? 1 : solon.balanceOf(a));
                if (solon.balanceOf(a) == 0) continue;
                vm.prank(a);
                staking.stake(amount);
            }
            assertEq(staking.eligible(alice), staking.stakedOf(alice));
            assertEq(staking.eligible(bob), staking.stakedOf(bob));
            assertEq(staking.totalEligible(), staking.totalStaked());
            assertLe(staking.totalStaked(), solon.balanceOf(address(staking)));
        }
    }

    function testFeeTimeCreditStaysWithWithdrawnStaker() public {
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(block.timestamp + 1 hours);
        (bool ok,) = address(staking)
            .call(
                abi.encodeWithSignature(
                    "configureSource(bytes32,address,uint8,address,bytes32,uint32,bytes32)",
                    bytes32(uint256(1)),
                    address(stock),
                    uint8(1),
                    address(stock),
                    bytes32(0),
                    uint32(0),
                    bytes32(0)
                )
            );
        assertTrue(ok, "source registration missing");
        (ok,) = address(staking)
            .call(
                abi.encodeWithSignature(
                    "onFeeCredit(bytes32,address,uint8,uint256)",
                    bytes32(uint256(1)),
                    address(stock),
                    uint8(1),
                    100 ether
                )
            );
        assertTrue(ok, "fee accounting missing");
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        vm.prank(alice);
        staking.unstake(100 ether, alice);
        bytes memory data;
        (ok, data) = address(staking)
            .staticcall(
                abi.encodeWithSignature(
                    "creditOf(bytes32,uint256,address,uint8,address)",
                    bytes32(uint256(1)),
                    epoch,
                    address(stock),
                    uint8(1),
                    alice
                )
            );
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), 100 ether * 1e27);
    }

    function testSponsoredDepositRequiresBoundBeneficiaryConsent() public {
        uint256 key = 123;
        address beneficiary = vm.addr(key);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Solon Staking V2"),
                keccak256("1"),
                block.chainid,
                address(staking)
            )
        );
        bytes32 body = keccak256(
            abi.encode(
                keccak256(
                    "StakeConsent(address sponsor,address beneficiary,uint256 amount,uint256 nonce,uint256 deadline)"
                ),
                alice,
                beneficiary,
                100 ether,
                uint256(0),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, body)));
        bytes memory data = abi.encodeWithSignature(
            "stake(uint256,address,uint256,bytes)", 100 ether, beneficiary, deadline, abi.encodePacked(r, sigS, v)
        );
        vm.prank(alice);
        (bool ok,) = address(staking).call(data);
        assertTrue(ok, "signed sponsorship missing");
        assertEq(staking.stakedOf(beneficiary), 100 ether);
        vm.prank(alice);
        (ok,) = address(staking).call(data);
        assertFalse(ok, "consent replay");
    }

    function testZeroWeightCarryWaitsSevenEffectiveDays() public {
        bytes32 pool = bytes32(uint256(1));
        staking.configureSource(pool, address(stock), 1, address(stock), 0, 0, 0);
        (bool ok,) = address(staking)
            .call(
                abi.encodeWithSignature(
                    "onFeeCredit(bytes32,address,uint8,uint256)", pool, address(stock), uint8(1), 70 ether
                )
            );
        assertTrue(ok, "zero weight fee must carry");
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staking.stake(100 ether);
        uint256 first = block.timestamp / 1 days;
        bytes32 lane = staking.laneKey(pool, address(stock), 1);
        (ok,) = address(staking).call(abi.encodeWithSignature("releaseCarry(bytes32,uint256)", lane, uint256(100)));
        assertTrue(ok);
        assertEq(staking.creditOf(pool, first, address(stock), 1, alice), 0);
        vm.warp(block.timestamp + 7 days);
        uint256 epoch = vm.getBlockTimestamp() / 1 days;
        (ok,) = address(staking).call(abi.encodeWithSignature("releaseCarry(bytes32,uint256)", lane, uint256(100)));
        assertTrue(ok);
        assertEq(staking.creditOf(pool, epoch, address(stock), 1, alice), 70 ether * 1e27);
    }

    function testEligibilitySwitchStopsOldWeightButPreservesPrincipal() public {
        bytes32 pool = bytes32(uint256(1));
        controller.bindAsset(address(stock), 0);
        staking.configureSource(pool, address(stock), 1, address(stock), 0, 0, 0);
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        staking.onFeeCredit(pool, address(stock), 1, 100 ether);
        EligibilityRegistry registry = new EligibilityRegistry(address(this));
        registry.setFixedModules(address(0), address(staking));
        controller.scheduleEnable(address(registry), keccak256("policy"), 13);
        vm.warp(13 days);
        staking.onFeeCredit(pool, address(stock), 1, 50 ether);
        assertEq(staking.creditOf(pool, 13, address(stock), 1, alice), 0, "B weight survives A switch");
        assertEq(staking.creditOf(pool, 10, address(stock), 1, alice), 100 ether * 1e27);
        vm.prank(alice);
        staking.unstake(100 ether, alice);
        assertEq(solon.balanceOf(alice), 1000 ether);
    }

    function testProtocolCreditIsPreciseAndFundingDoesNotReassign() public {
        vm.prank(alice);
        staking.stake(1);
        vm.warp(10 days + 1 hours);
        (bool ok,) = address(staking)
            .call(
                abi.encodeWithSignature(
                    "configureProtocolDesk(address,address,bytes32,uint32,bytes32)",
                    address(this),
                    address(stock),
                    keccak256("stock"),
                    uint32(1),
                    keccak256("price")
                )
            );
        assertTrue(ok, "protocol configuration missing");
        bytes32 pool = bytes32(uint256(99));
        (ok,) = address(staking)
            .call(
                abi.encodeWithSignature(
                    "notifyProtocolDeskCredit(bytes32,uint256,address,uint8,uint256)",
                    pool,
                    uint256(10),
                    address(stock),
                    uint8(1),
                    1e27 + 3
                )
            );
        assertTrue(ok);
        vm.prank(alice);
        staking.unstake(1, alice);
        stock.mint(address(this), 1);
        stock.approve(address(staking), 1);
        (ok,) = address(staking)
            .call(
                abi.encodeWithSignature(
                    "fundProtocolDesk(bytes32,uint256,address,uint8,uint256)",
                    pool,
                    uint256(10),
                    address(stock),
                    uint8(1),
                    uint256(1)
                )
            );
        assertTrue(ok);
        bytes32 source = keccak256(abi.encode(keccak256("PROTOCOL_DESK_STAKING"), pool));
        assertEq(staking.creditOf(source, 10, address(stock), 1, alice), 1e27 + 3);
    }

    function testV2BudgetUsesNotifyTimeAndRejectsDuplicateLot() public {
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        (bool ok,) = address(staking)
            .call(
                abi.encodeWithSignature(
                    "configureV2(address,address,bytes32,uint32,bytes32)",
                    address(this),
                    address(stock),
                    keccak256("stock"),
                    uint32(1),
                    keccak256("price")
                )
            );
        assertTrue(ok, "v2 configuration missing");
        vm.deal(address(this), 100 ether);
        bytes32 lot = keccak256("lot");
        (ok,) = address(staking).call{value: 30 ether}(
            abi.encodeWithSignature("notifyV2Budget(bytes32,uint256)", lot, 30 ether)
        );
        assertTrue(ok);
        vm.prank(alice);
        staking.unstake(100 ether, alice);
        assertEq(staking.creditOf(keccak256("SOLON_V2_STAKING"), 10, address(stock), 0, alice), 30 ether * 1e27);
        (ok,) = address(staking).call{value: 30 ether}(
            abi.encodeWithSignature("notifyV2Budget(bytes32,uint256)", lot, 30 ether)
        );
        assertFalse(ok, "duplicate lot");
        assertEq(address(staking).balance, 30 ether);
    }

    function testDirectSourceStagesOnceIntoExistingPayoutVault() public {
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        staking.configureProtocolDesk(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        bytes32 pool = bytes32(uint256(99));
        staking.notifyProtocolDeskCredit(pool, 10, address(stock), 1, 100 ether * 1e27);
        stock.mint(address(this), 100 ether);
        stock.approve(address(staking), 100 ether);
        staking.fundProtocolDesk(pool, 10, address(stock), 1, 100 ether);
        bytes32 key = staking.laneKey(staking.protocolSource(pool), address(stock), 1);
        (bool ok, bytes memory data) = address(staking).call(abi.encodeWithSignature("createEntrySource(bytes32)", key));
        assertTrue(ok, "reward source missing");
        address source = abi.decode(data, (address));
        address[] memory sources = new address[](1);
        sources[0] = source;
        RewardPayoutVault payout = new RewardPayoutVault(sources, controller);
        (ok,) = address(staking)
            .call(abi.encodeWithSignature("configureRewards(address,address)", address(this), address(payout)));
        assertTrue(ok);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 10;
        assertEq(payout.stageCredit(source, alice, epochs, address(stock)), 100 ether);
        assertEq(payout.stageCredit(source, alice, epochs, address(stock)), 0);
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        vm.prank(alice);
        payout.claim(assets);
        assertEq(stock.balanceOf(alice), 100 ether);
        assertEq(solon.balanceOf(address(staking)), 100 ether);
    }

    function testV2SourceSealsIntoExistingRoundManager() public {
        staking.configureV2(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 100 ether);
        staking.notifyV2Budget{value: 100 ether}(keccak256("lot"), 100 ether);
        bytes32 key = staking.v2Lane();
        address source = staking.createEntrySource(key);
        StakingRouteRegistry registry = new StakingRouteRegistry(address(stock));
        RewardRoundManager manager =
            new RewardRoundManager(address(this), address(registry), address(this), address(this));
        staking.configureRewards(address(manager), address(this));
        manager.registerSource(source, keccak256("SOLON_V2_STAKING"));
        vm.warp(11 days);
        (bool ok, bytes memory data) = address(manager)
            .call(
                abi.encodeCall(
                    manager.seal,
                    (source, uint256(10), uint8(0), keccak256("stock"), uint32(1), keccak256("price"), uint8(0))
                )
            );
        assertTrue(ok, "staking round integration missing");
        uint256 id = abi.decode(data, (uint256));
        RewardRoundManager.Entry memory entry = manager.entry(id);
        assertEq(entry.budget18, 100 ether);
        assertEq(entry.creditTotal, 100 ether * 1e27);
        assertEq(address(manager).balance, 100 ether);
        assertEq(address(staking).balance, 0);
    }

    function testStakingRuntimeFitsEIP170() public view {
        assertLe(address(staking).code.length, 24576, "staking cannot deploy on EIP170 chains");
    }

    function testManualClaimFromSourcePaysOnlyOriginalAccount() public {
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        staking.configureProtocolDesk(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        bytes32 pool = bytes32(uint256(99));
        staking.notifyProtocolDeskCredit(pool, 10, address(stock), 1, 100 ether * 1e27);
        stock.mint(address(this), 100 ether);
        stock.approve(address(staking), 100 ether);
        staking.fundProtocolDesk(pool, 10, address(stock), 1, 100 ether);
        bytes32 key = staking.laneKey(staking.protocolSource(pool), address(stock), 1);
        address source = staking.createEntrySource(key);
        address[] memory sources = new address[](1);
        sources[0] = source;
        RewardPayoutVault payout = new RewardPayoutVault(sources, controller);
        staking.configureRewards(address(this), address(payout));
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 10;
        address[] memory assets = new address[](1);
        assets[0] = address(stock);
        vm.prank(alice);
        (bool ok,) = source.call(abi.encodeWithSignature("claim(uint256[],address[])", epochs, assets));
        assertTrue(ok, "self claim missing");
        assertEq(stock.balanceOf(alice), 100 ether);
        assertEq(stock.balanceOf(address(this)), 0);
    }

    function _signed(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(pk, digest);
        return abi.encodePacked(r, ss, v);
    }

    function _enableA() internal returns (EligibilityRegistry registry) {
        controller.bindAsset(address(stock), 0);
        staking.configureSource(bytes32(uint256(1)), address(stock), 1, address(stock), 0, 0, 0);
        registry = new EligibilityRegistry(address(this));
        registry.scheduleIssuer(vm.addr(1), true);
        registry.scheduleIssuer(vm.addr(2), true);
        registry.setFixedModules(address(0), address(staking));
        controller.scheduleEnable(address(registry), keccak256("policy"), 13);
        vm.warp(13 days);
        registry.executeIssuer(vm.addr(1));
        registry.executeIssuer(vm.addr(2));
    }

    function _credential(EligibilityRegistry registry, uint256 pk, uint256 expiry)
        internal
        returns (address user, bytes32 id)
    {
        user = vm.addr(pk);
        EligibilityRegistry.Attestation memory a = EligibilityRegistry.Attestation(
            block.chainid,
            address(registry),
            user,
            keccak256("beneficiary"),
            1,
            1,
            keccak256("policy"),
            vm.getBlockTimestamp(),
            expiry,
            registry.nonces(user),
            keccak256("terms")
        );
        id = registry.digest(a);
        address[] memory issuers = new address[](2);
        issuers[0] = vm.addr(1);
        issuers[1] = vm.addr(2);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signed(1, id);
        sigs[1] = _signed(2, id);
        registry.register(a, issuers, sigs, _signed(pk, id));
    }

    function _stakeUser(address user, uint256 amount) internal {
        solon.mint(user, amount);
        vm.startPrank(user);
        solon.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function testExpiredWeightNeverEarnsAndPrincipalWithdraws() public {
        EligibilityRegistry registry = _enableA();
        (address user,) = _credential(registry, 101, 13 days + 2 hours);
        _stakeUser(user, 100 ether);
        vm.warp(13 days + 1 hours);
        staking.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 100 ether);
        vm.warp(13 days + 2 hours);
        staking.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 70 ether);
        assertEq(staking.effectiveEligible(), 0);
        assertEq(staking.creditOf(bytes32(uint256(1)), 13, address(stock), 1, user), 100 ether * 1e27);
        vm.prank(user);
        staking.unstake(100 ether, user);
        assertEq(solon.balanceOf(user), 100 ether);
    }

    function testRevokeAndRenewAtSameTimestampDoNotReassignOldCredit() public {
        EligibilityRegistry registry = _enableA();
        (address user, bytes32 id) = _credential(registry, 101, 30 days);
        _stakeUser(user, 100 ether);
        vm.warp(13 days + 1 hours);
        staking.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 100 ether);
        registry.revoke(id, keccak256("reason"));
        staking.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 70 ether);
        assertEq(staking.creditOf(bytes32(uint256(1)), 13, address(stock), 1, user), 100 ether * 1e27);
        _credential(registry, 101, 30 days);
        staking.syncEligibility(user);
        staking.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 30 ether);
        assertEq(staking.creditOf(bytes32(uint256(1)), 13, address(stock), 1, user), 130 ether * 1e27);
    }

    function testCarryConservativelyPausesWhenLastWeightExpires() public {
        EligibilityRegistry registry = _enableA();
        (address user,) = _credential(registry, 101, 13 days + 2 hours);
        bytes32 pool = bytes32(uint256(1));
        staking.onFeeCredit(pool, address(stock), 1, 70 ether);
        vm.warp(13 days + 1 hours);
        _stakeUser(user, 100 ether);
        bytes32 key = staking.laneKey(pool, address(stock), 1);
        staking.releaseCarry(key, 100);
        vm.warp(13 days + 3 hours);
        staking.releaseCarry(key, 100);
        (, uint256 released, uint256 clock,,) = staking.carryState(key);
        assertEq(released, 0);
        assertEq(clock, 0);
        assertEq(staking.creditOf(pool, 13, address(stock), 1, user), 0);
        vm.prank(user);
        staking.unstake(100 ether, user);
        assertEq(solon.balanceOf(user), 100 ether);
    }

    function testFirstLedgerFeeAutoRegistersAuthenticatedStockSource() public {
        V3FeeLedger realLedger = new V3FeeLedger(address(this), address(0));
        staking = new SolonStakingV2(address(solon), address(realLedger), controller);
        vm.startPrank(alice);
        solon.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();
        vm.warp(10 days + 1 hours);
        StakingFeeObserver observer = new StakingFeeObserver();
        address[6] memory beneficiaries = [address(observer), bob, address(observer), address(staking), bob, bob];
        bytes32 pool = keccak256("auto pool");
        realLedger.registerPool(pool, address(stock), 1, address(this), beneficiaries);
        stock.mint(address(this), 2000 ether);
        stock.approve(address(realLedger), 2000 ether);
        (bool ok,) = address(realLedger).call(abi.encodeCall(realLedger.creditStock, (pool, 2000 ether)));
        assertTrue(ok, "registered launch cannot pay first fee");
        assertEq(staking.creditOf(pool, 10, address(stock), 1, alice), 100 ether * 1e27);
    }

    function testNativeAutoSourceUsesHolderScheduleAndRotatesPerEpoch() public {
        V3FeeLedger realLedger = new V3FeeLedger(address(this), address(0));
        staking = new SolonStakingV2(address(solon), address(realLedger), controller);
        vm.startPrank(alice);
        solon.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();
        vm.warp(10 days + 1 hours);
        StakeAsset second = new StakeAsset();
        address[] memory assets = new address[](2);
        assets[0] = address(stock);
        assets[1] = address(second);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("stock");
        ids[1] = keccak256("second");
        uint32[] memory versions = new uint32[](2);
        versions[0] = 1;
        versions[1] = 1;
        bytes32[] memory prices = new bytes32[](2);
        prices[0] = keccak256("price");
        prices[1] = keccak256("price");
        RewardAssetSchedule schedule = new RewardAssetSchedule(10, 1, assets, ids, versions, prices);
        bytes32 pool = keccak256("native auto pool");
        V3RewardToken holder = new V3RewardToken("Holder", "H", address(this), address(realLedger), new address[](0));
        holder.setDefaultRewardAsset(address(stock));
        holder.configurePool(pool, address(0), 0);
        holder.configureRounds(address(this), ids[0], 1, prices[0]);
        holder.configureAssetSchedule(address(schedule));
        StakingFeeObserver observer = new StakingFeeObserver();
        address[6] memory beneficiaries = [address(holder), bob, address(observer), address(staking), bob, bob];
        realLedger.registerPool(pool, address(0), 0, address(this), beneficiaries);
        vm.deal(address(this), 6000 ether);
        realLedger.creditNative{value: 2000 ether}(pool);
        assertEq(staking.creditOf(pool, 10, address(stock), 0, alice), 100 ether * 1e27);
        vm.warp(11 days);
        realLedger.creditNative{value: 4000 ether}(pool);
        assertEq(
            staking.creditOf(pool, 11, address(second), 0, alice), 200 ether * 1e27, "staking failed epoch rotation"
        );
        assertEq(staking.creditOf(pool, 11, address(stock), 0, alice), 0);
    }

    function testCarrySourcesRemainIndependent() public {
        bytes32 p1 = bytes32(uint256(1));
        bytes32 p2 = bytes32(uint256(2));
        staking.configureSource(p1, address(stock), 1, address(stock), 0, 0, 0);
        staking.configureSource(p2, address(stock), 1, address(stock), 0, 0, 0);
        staking.onFeeCredit(p1, address(stock), 1, 70 ether);
        staking.onFeeCredit(p2, address(stock), 1, 140 ether);
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        vm.warp(17 days + 1 hours);
        staking.releaseCarry(staking.laneKey(p1, address(stock), 1), 100);
        assertEq(staking.creditOf(p1, 17, address(stock), 1, alice), 70 ether * 1e27);
        assertEq(staking.creditOf(p2, 17, address(stock), 1, alice), 0);
        staking.releaseCarry(staking.laneKey(p2, address(stock), 1), 100);
        assertEq(staking.creditOf(p2, 17, address(stock), 1, alice), 140 ether * 1e27);
    }

    function testPrincipalExitDoesNotLoopOver129RewardSources() public {
        for (uint256 i = 1; i <= 129; ++i) {
            staking.configureSource(bytes32(i), address(stock), 1, address(stock), 0, 0, 0);
        }
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        uint256 before = gasleft();
        vm.prank(alice);
        staking.unstake(100 ether, alice);
        uint256 used = before - gasleft();
        assertLt(used, 350000, "principal exit scales with sources");
        assertEq(solon.balanceOf(alice), 1000 ether);
    }

    function testNewStakeSharesOnlyLaterFees() public {
        bytes32 pool = bytes32(uint256(1));
        staking.configureSource(pool, address(stock), 1, address(stock), 0, 0, 0);
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        staking.onFeeCredit(pool, address(stock), 1, 100 ether);
        _stakeUser(bob, 900 ether);
        staking.onFeeCredit(pool, address(stock), 1, 100 ether);
        assertEq(staking.creditOf(pool, 10, address(stock), 1, alice), 110 ether * 1e27);
        assertEq(staking.creditOf(pool, 10, address(stock), 1, bob), 90 ether * 1e27);
        vm.prank(bob);
        staking.unstake(900 ether, bob);
        assertEq(solon.balanceOf(bob), 900 ether);
    }

    function testNativeCarryChoosesReleaseEpochStock() public {
        V3FeeLedger realLedger = new V3FeeLedger(address(this), address(0));
        staking = new SolonStakingV2(address(solon), address(realLedger), controller);
        vm.startPrank(alice);
        solon.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();
        vm.warp(10 days + 1 hours);
        StakeAsset second = new StakeAsset();
        address[] memory assets = new address[](2);
        assets[0] = address(stock);
        assets[1] = address(second);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("stock");
        ids[1] = keccak256("second");
        uint32[] memory versions = new uint32[](2);
        versions[0] = 1;
        versions[1] = 1;
        bytes32[] memory prices = new bytes32[](2);
        prices[0] = keccak256("price");
        prices[1] = keccak256("price");
        RewardAssetSchedule schedule = new RewardAssetSchedule(10, 1, assets, ids, versions, prices);
        bytes32 pool = keccak256("native auto pool");
        V3RewardToken holder = new V3RewardToken("Holder", "H", address(this), address(realLedger), new address[](0));
        holder.setDefaultRewardAsset(address(stock));
        holder.configurePool(pool, address(0), 0);
        holder.configureRounds(address(this), ids[0], 1, prices[0]);
        holder.configureAssetSchedule(address(schedule));
        StakingFeeObserver observer = new StakingFeeObserver();
        address[6] memory beneficiaries = [address(holder), bob, address(observer), address(staking), bob, bob];
        realLedger.registerPool(pool, address(0), 0, address(this), beneficiaries);
        vm.deal(address(this), 6000 ether);
        vm.prank(alice);
        staking.unstake(100 ether, alice);
        realLedger.creditNative{value: 2000 ether}(pool);
        vm.warp(10 days + 2 hours);
        vm.startPrank(alice);
        solon.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();
        vm.warp(17 days + 2 hours);
        staking.releaseCarry(staking.poolLane(pool), 100);
        assertEq(
            staking.creditOf(pool, 17, address(second), 0, alice),
            100 ether * 1e27,
            "native carry must use release epoch stock"
        );
        assertEq(staking.creditOf(pool, 17, address(stock), 0, alice), 0);
    }

    function testEntrySourceAutomaticallyRegistersWithPinnedModules() public {
        RewardPayoutVault payout = new RewardPayoutVault(new address[](0), controller);
        StakingRouteRegistry registry = new StakingRouteRegistry(address(stock));
        RewardRoundManager manager =
            new RewardRoundManager(address(this), address(registry), address(payout), address(this));
        payout.configureRewardModules(address(0), address(staking));
        manager.configureRewardModules(address(0), address(staking));
        staking.configureRewards(address(manager), address(payout));
        staking.configureV2(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        address source = staking.createEntrySource(staking.v2Lane());
        assertTrue(payout.trustedSource(source), "dynamic source not trusted by payout");
        assertEq(manager.sourcePool(source), keccak256("SOLON_V2_STAKING"));
        assertEq(staking.createEntrySource(staking.v2Lane()), source);
    }

    function testV2NativeBudgetsFollowConfiguredEpochSchedule() public {
        StakeAsset second = new StakeAsset();
        address[] memory assets = new address[](2);
        assets[0] = address(stock);
        assets[1] = address(second);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("stock");
        ids[1] = keccak256("second");
        uint32[] memory versions = new uint32[](2);
        versions[0] = 1;
        versions[1] = 2;
        bytes32[] memory prices = new bytes32[](2);
        prices[0] = keccak256("price");
        prices[1] = keccak256("price2");
        RewardAssetSchedule schedule = new RewardAssetSchedule(10, 1, assets, ids, versions, prices);
        staking.configureV2(address(this), address(stock), ids[0], 1, prices[0]);
        (bool ok,) = address(staking)
            .call(abi.encodeWithSignature("configureRewardSchedules(address,address)", address(schedule), address(0)));
        assertTrue(ok, "v2 reward schedule missing");
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 300 ether);
        staking.notifyV2Budget{value: 100 ether}(keccak256("lot1"), 100 ether);
        vm.warp(11 days);
        staking.notifyV2Budget{value: 200 ether}(keccak256("lot2"), 200 ether);
        assertEq(staking.creditOf(keccak256("SOLON_V2_STAKING"), 10, address(stock), 0, alice), 100 ether * 1e27);
        assertEq(staking.creditOf(keccak256("SOLON_V2_STAKING"), 11, address(second), 0, alice), 200 ether * 1e27);
        (, uint32 version,,) = staking.sourcePolicy(staking.v2Lane(), 11);
        assertEq(version, 2);
    }

    function testFutureRewardBasketMustBeCoveredByActivationCredential() public {
        StakeAsset futureStock = new StakeAsset();
        controller.bindAsset(address(futureStock), 1);
        address[] memory basket = new address[](1);
        basket[0] = address(futureStock);
        (bool ok,) = address(staking).call(abi.encodeWithSignature("configureEligibilityAssets(address[])", basket));
        assertTrue(ok, "future reward basket admission missing");
        EligibilityRegistry registry = _enableA();
        assertEq(staking.requiredAssetMask(), 3);
        (address user,) = _credential(registry, 101, 30 days);
        _stakeUser(user, 100 ether);
        vm.warp(13 days + 1 hours);
        assertEq(staking.stakedOf(user), 100 ether);
        assertEq(staking.eligible(user), 0, "credential without full basket earned");
        staking.syncEligibility(user);
        assertEq(staking.eligible(user), 0);
        vm.prank(user);
        staking.unstake(100 ether, user);
        assertEq(solon.balanceOf(user), 100 ether);
    }

    function testSameStockDifferentAdapterVersionsKeepEpochPolicy() public {
        address[] memory assets = new address[](2);
        assets[0] = address(stock);
        assets[1] = address(stock);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("stock");
        ids[1] = ids[0];
        uint32[] memory versions = new uint32[](2);
        versions[0] = 1;
        versions[1] = 2;
        bytes32[] memory prices = new bytes32[](2);
        prices[0] = keccak256("price");
        prices[1] = keccak256("price2");
        RewardAssetSchedule schedule = new RewardAssetSchedule(10, 1, assets, ids, versions, prices);
        staking.configureV2(address(this), address(stock), ids[0], 1, prices[0]);
        staking.configureRewardSchedules(address(schedule), address(0));
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        vm.deal(address(this), 300 ether);
        staking.notifyV2Budget{value: 100 ether}(keccak256("lot1"), 100 ether);
        vm.warp(11 days);
        staking.notifyV2Budget{value: 200 ether}(keccak256("lot2"), 200 ether);
        (, uint32 oldVersion, bytes32 oldPrice,) = staking.sourcePolicy(staking.v2Lane(), 10);
        (, uint32 newVersion, bytes32 newPrice,) = staking.sourcePolicy(staking.v2Lane(), 11);
        assertEq(oldVersion, 1);
        assertEq(newVersion, 2);
        assertEq(oldPrice, prices[0]);
        assertEq(newPrice, prices[1]);
    }

    function testPrincipalExitIgnoresBrokenCarryHelper() public {
        staking.configureV2(address(this), address(stock), keccak256("stock"), 1, keccak256("price"));
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(10 days + 1 hours);
        vm.mockCallRevert(address(staking.sourceFactory()), bytes(""), bytes("helper failure"));
        vm.prank(alice);
        staking.unstake(100 ether, alice);
        assertEq(solon.balanceOf(alice), 1000 ether);
    }
}

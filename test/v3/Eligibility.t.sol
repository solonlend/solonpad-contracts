// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V3RewardToken} from "../../src/v3/V3RewardToken.sol";

contract EligibilityTest is Test {
    function testPayoutStagesOnlyIncrementalDirectStockCredit() public {
        V3RewardToken t = new V3RewardToken("Reward", "R", address(this), address(this), new address[](0));
        EligibilityStock stock = new EligibilityStock();
        t.configurePool(bytes32(uint256(1)), address(stock), 1);
        t.configurePayout(address(this));
        address user = address(123);
        t.transfer(user, 100);
        vm.warp(block.timestamp + 1 hours);
        t.onFeeCredit(bytes32(uint256(1)), address(stock), 1, 10);
        stock.mint(address(t), 10);
        uint256[] memory epochs = new uint256[](1);
        epochs[0] = block.timestamp / 1 days;
        (bool ok, bytes memory data) = address(t)
            .call(abi.encodeWithSignature("stageCredit(address,uint256[],address)", user, epochs, address(stock)));
        assertTrue(ok, "staging absent");
        assertEq(abi.decode(data, (uint256)), 10);
        assertEq(stock.balanceOf(address(this)), 10);
        (ok, data) = address(t)
            .call(abi.encodeWithSignature("stageCredit(address,uint256[],address)", user, epochs, address(stock)));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint256)), 0);
    }

    function testConfiguredBasketIncludesEveryDeclaredAsset() public {
        vm.warp(10 days);
        EligibilityController controller = new EligibilityController(address(this));
        EligibilityStock first = new EligibilityStock();
        EligibilityStock second = new EligibilityStock();
        controller.bindAsset(address(first), 0);
        controller.bindAsset(address(second), 1);
        V3RewardToken t = new V3RewardToken("Reward", "R", address(this), address(this), new address[](0));
        t.setDefaultRewardAsset(address(first));
        t.configurePool(bytes32(uint256(1)), address(0), 0);
        t.configureEligibility(controller);
        t.configureRounds(address(this), keccak256("first"), 1, keccak256("price"));
        t.declareEpochRewardPolicy(11, address(second), keccak256("second"), 1, keccak256("price"));
        (bool ok, bytes memory data) = address(t).staticcall(abi.encodeWithSignature("requiredAssetMask()"));
        assertTrue(ok, "basket mask missing");
        assertEq(abi.decode(data, (uint256)), 3);
        t.transfer(address(123), 100);
        vm.warp(block.timestamp + 1 hours);
        EligibilityStock third = new EligibilityStock();
        controller.bindAsset(address(third), 2);
        vm.expectRevert();
        t.declareEpochRewardPolicy(12, address(third), keccak256("third"), 1, keccak256("price"));
        t.declareEpochRewardPolicy(12, address(first), keccak256("first"), 2, keccak256("new price"));
    }

    function testParticipantBoundIsFrozenAtEpochEnd() public {
        vm.warp(10 days);
        V3RewardToken t = new V3RewardToken("Reward", "R", address(this), address(this), new address[](0));
        t.transfer(address(123), 100);
        vm.warp(10 days + 1 hours);
        vm.warp(11 days);
        t.transfer(address(124), 100);
        vm.warp(11 days + 1 hours);
        (bool ok, bytes memory data) = address(t).staticcall(abi.encodeWithSignature("queueSnapshot(uint256)", 10));
        assertTrue(ok, "queue snapshot absent");
        (uint256 upper, uint256 revision) = abi.decode(data, (uint256, uint256));
        assertEq(upper, 1);
        assertGe(revision, 1);
    }

    function testFixedPayoutConfigurationCannotBeRebound() public {
        V3RewardToken t = new V3RewardToken("Reward", "R", address(this), address(this), new address[](0));
        (bool ok,) = address(t).call(abi.encodeWithSignature("configurePayout(address)", address(this)));
        assertTrue(ok, "payout wiring absent");
        (ok,) = address(t).call(abi.encodeWithSignature("configurePayout(address)", address(this)));
        assertFalse(ok);
    }

    function testDefaultBReportsEffectiveWeightWithoutCredential() public {
        V3RewardToken t = new V3RewardToken("Reward", "R", address(this), address(this), new address[](0));
        address user = address(123);
        t.transfer(user, 100);
        vm.warp(block.timestamp + 1 hours);
        (bool ok, bytes memory data) = address(t).staticcall(abi.encodeWithSignature("effectiveEligible()"));
        assertTrue(ok, "missing effective eligibility denominator");
        assertEq(abi.decode(data, (uint256)), 100);
    }
}

import {EligibilityController} from "../../src/v3/EligibilityController.sol";

contract ControllerTest is Test {
    function testTradeGateSkipsNativeQuoteAndUsesRealStockParties() public {
        vm.warp(10 days);
        EligibilityController c = new EligibilityController(address(this));
        EligibilityRegistry r = new EligibilityRegistry(address(this));
        (bool ok,) = address(c)
            .staticcall(
                abi.encodeWithSignature(
                    "checkTrade(bytes32,address,address,address,bool)",
                    bytes32(uint256(1)),
                    address(123),
                    address(1),
                    address(2),
                    true
                )
            );
        assertTrue(ok, "B trade interface missing");
        c.bindAsset(address(123), 0);
        c.scheduleEnable(address(r), keccak256("policy"), 12);
        vm.warp(12 days);
        (ok,) = address(c)
            .staticcall(
                abi.encodeWithSignature(
                    "checkTrade(bytes32,address,address,address,bool)",
                    bytes32(uint256(1)),
                    address(0),
                    address(1),
                    address(2),
                    false
                )
            );
        assertTrue(ok);
        (ok,) = address(c)
            .staticcall(
                abi.encodeWithSignature(
                    "checkTrade(bytes32,address,address,address,bool)",
                    bytes32(uint256(1)),
                    address(123),
                    address(1),
                    address(2),
                    true
                )
            );
        assertFalse(ok);
    }

    function testOnlyExplicitSystemVaultHasAssetScopedExemption() public {
        vm.warp(10 days);
        EligibilityController c = new EligibilityController(address(this));
        EligibilityRegistry r = new EligibilityRegistry(address(this));
        EligibilityWallet1271 vault = new EligibilityWallet1271();
        EligibilityWallet1271 ordinary = new EligibilityWallet1271();
        c.bindAsset(address(123), 0);
        c.bindAsset(address(124), 1);
        (bool ok,) = address(c).call(abi.encodeWithSignature("bindSystemVault(address,uint256)", address(vault), 1));
        assertTrue(ok, "system vault role missing");
        c.scheduleEnable(address(r), keccak256("policy"), 12);
        vm.warp(12 days);
        assertTrue(c.canReceiveStock(address(123), address(vault)));
        assertFalse(c.canReceiveStock(address(124), address(vault)));
        assertFalse(c.canReceiveStock(address(123), address(ordinary)));
        (ok,) = address(c).call(abi.encodeWithSignature("bindSystemVault(address,uint256)", address(ordinary), 1));
        assertFalse(ok);
    }

    function testRejectsEarlyEnableAndLateCancel() public {
        vm.warp(10 days + 1);
        EligibilityController c = new EligibilityController(address(this));
        vm.expectRevert();
        c.scheduleEnable(address(this), keccak256("policy"), 12);
        c.scheduleEnable(address(this), keccak256("policy"), 13);
        c.cancelEnable();
        assertFalse(c.enabled());
        c.scheduleEnable(address(this), keccak256("policy"), 13);
        vm.warp(13 days);
        vm.expectRevert();
        c.cancelEnable();
        vm.expectRevert();
        c.scheduleEnable(address(this), keccak256("policy"), 16);
    }

    function testScheduledModeActivatesOnlyAtUtcBoundary() public {
        vm.warp(10 days + 1);
        EligibilityController c = new EligibilityController(address(this));
        c.scheduleEnable(address(this), keccak256("policy"), 13);
        assertFalse(c.enabled());
        vm.warp(13 days);
        assertTrue(c.enabled(), "scheduled A must become effective without keeper");
    }
}
import {EligibilityRegistry} from "../../src/v3/EligibilityRegistry.sol";

contract RegistryTest is Test {
    function testSignedRegistrationBindsWalletAndRejectsReplay() public {
        EligibilityRegistry r = new EligibilityRegistry(address(this));
        r.scheduleIssuer(vm.addr(1), true);
        r.scheduleIssuer(vm.addr(2), true);
        vm.warp(block.timestamp + 48 hours);
        r.executeIssuer(vm.addr(1));
        r.executeIssuer(vm.addr(2));
        EligibilityRegistry.Attestation memory a = EligibilityRegistry.Attestation(
            block.chainid,
            address(r),
            vm.addr(3),
            bytes32(uint256(42)),
            1,
            1,
            keccak256("policy"),
            block.timestamp,
            block.timestamp + 30 days,
            0,
            keccak256("terms")
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Solon Eligibility"),
                keccak256("1"),
                block.chainid,
                address(r)
            )
        );
        bytes32 hash = keccak256(
            abi.encode(
                keccak256(
                    "Eligibility(uint256 chainId,address registry,address wallet,bytes32 beneficiaryCommitment,uint256 assetMask,uint256 investorClass,bytes32 jurisdictionPolicyHash,uint256 issuedAt,uint256 validUntil,uint256 nonce,bytes32 termsHash)"
                ),
                a
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, hash));
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(1);
        signers[1] = vm.addr(2);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = sig(1, digest);
        sigs[1] = sig(2, digest);
        r.register(a, signers, sigs, sig(3, digest));
        assertTrue(r.status(a.wallet, 0, block.timestamp), "signed registration missing");
        assertFalse(r.status(a.wallet, 1, block.timestamp));
        assertFalse(r.status(a.wallet, 0, a.validUntil));
        vm.expectRevert();
        r.register(a, signers, sigs, sig(3, digest));
    }

    function sig(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function testIssuerApprovalRequiresDelay() public {
        EligibilityRegistry r = new EligibilityRegistry(address(this));
        (bool ok,) = address(r).call(abi.encodeWithSignature("scheduleIssuer(address,bool)", vm.addr(1), true));
        assertTrue(ok, "issuer schedule absent");
        (ok,) = address(r).call(abi.encodeWithSignature("executeIssuer(address)", vm.addr(1)));
        assertFalse(ok);
        vm.warp(block.timestamp + 48 hours);
        (ok,) = address(r).call(abi.encodeWithSignature("executeIssuer(address)", vm.addr(1)));
        assertTrue(ok);
    }

    function testEmptySignaturesCannotCreateCredential() public {
        EligibilityRegistry r = new EligibilityRegistry(address(this));
        EligibilityRegistry.Attestation memory a;
        a.wallet = address(123);
        a.chainId = block.chainid;
        a.registry = address(r);
        a.issuedAt = block.timestamp;
        a.validUntil = block.timestamp + 30 days;
        vm.expectRevert();
        r.register(a, new address[](0), new bytes[](0), "");
    }
}

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract EligibilityStock is ERC20 {
    constructor() ERC20("Stock", "STK") {}

    function mint(address who, uint256 n) external {
        _mint(who, n);
    }
}

contract EligibilityWallet1271 {
    bytes32 public approved;

    function approve(bytes32 hash) external {
        approved = hash;
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return hash == approved ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract CallbackPool {
    EligibilityRegistry public registry;
    uint256 public calls;
    bool public fails;

    constructor(EligibilityRegistry r) {
        registry = r;
    }

    function bind(address wallet) external {
        registry.bindRewardPool(wallet);
    }

    function unbind(address wallet) external {
        registry.unbindRewardPool(wallet);
    }

    function setFail(bool value) external {
        fails = value;
    }

    function onEligibilityChange(address) external {
        require(msg.sender == address(registry));
        require(!fails, "callback failed");
        ++calls;
    }
}

contract RegistryPoolFactory {
    function register(EligibilityRegistry registry, address pool) external {
        registry.allowRewardPool(pool);
    }
}

contract RegistryBoundaryTest is Test {
    EligibilityRegistry r;
    address[] signers;
    bytes[] signatures;

    function setUp() public {
        r = new EligibilityRegistry(address(this));
        r.scheduleIssuer(vm.addr(1), true);
        r.scheduleIssuer(vm.addr(2), true);
        vm.warp(block.timestamp + 48 hours);
        r.executeIssuer(vm.addr(1));
        r.executeIssuer(vm.addr(2));
        signers.push(vm.addr(1));
        signers.push(vm.addr(2));
    }

    function attestation(address wallet) internal view returns (EligibilityRegistry.Attestation memory) {
        return EligibilityRegistry.Attestation(
            block.chainid,
            address(r),
            wallet,
            keccak256("beneficiary"),
            1,
            1,
            keccak256("policy"),
            block.timestamp,
            block.timestamp + 30 days,
            r.nonces(wallet),
            keccak256("terms")
        );
    }

    function sig(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 x, bytes32 y) = vm.sign(key, hash);
        return abi.encodePacked(x, y, v);
    }

    function sign(EligibilityRegistry.Attestation memory a) internal {
        delete signatures;
        signatures.push(sig(1, r.digest(a)));
        signatures.push(sig(2, r.digest(a)));
    }

    function testOnlyGovernanceCanBindOneFactoryForPoolRegistration() public {
        RegistryPoolFactory factory = new RegistryPoolFactory();
        CallbackPool pool = new CallbackPool(r);
        vm.prank(address(123));
        vm.expectRevert();
        r.allowRewardPool(address(pool));
        vm.prank(address(123));
        (bool ok,) = address(r).call(abi.encodeWithSignature("configureFactory(address)", address(factory)));
        assertFalse(ok);
        (ok,) = address(r).call(abi.encodeWithSignature("configureFactory(address)", address(factory)));
        assertTrue(ok, "factory registration wiring missing");
        factory.register(r, address(pool));
        assertTrue(r.rewardModule(address(pool)));
        (ok,) = address(r).call(abi.encodeWithSignature("configureFactory(address)", address(factory)));
        assertFalse(ok);
        RegistryPoolFactory stranger = new RegistryPoolFactory();
        vm.expectRevert();
        stranger.register(r, address(pool));
    }

    function testContractWalletConsentAndWrongBeneficiary() public {
        EligibilityWallet1271 wallet = new EligibilityWallet1271();
        EligibilityRegistry.Attestation memory a = attestation(address(wallet));
        sign(a);
        vm.expectRevert();
        r.register(a, signers, signatures, "");
        wallet.approve(r.digest(a));
        r.register(a, signers, signatures, "");
        assertTrue(r.status(address(wallet), 0, block.timestamp));
        a = attestation(address(wallet));
        a.beneficiaryCommitment = keccak256("changed controller beneficiary");
        sign(a);
        vm.expectRevert();
        r.renew(a, signers, signatures, "");
    }

    function testEightPoolsPlusFixedModulesAndAtomicFailedRevocation() public {
        address user = vm.addr(3);
        CallbackPool first;
        for (uint256 i; i < 8; ++i) {
            CallbackPool pool = new CallbackPool(r);
            if (i == 0) first = pool;
            r.allowRewardPool(address(pool));
            pool.bind(user);
        }
        CallbackPool ninth = new CallbackPool(r);
        r.allowRewardPool(address(ninth));
        vm.expectRevert();
        ninth.bind(user);
        CallbackPool desk = new CallbackPool(r);
        CallbackPool staking = new CallbackPool(r);
        r.setFixedModules(address(desk), address(staking));
        EligibilityRegistry.Attestation memory a = attestation(user);
        sign(a);
        r.register(a, signers, signatures, sig(3, r.digest(a)));
        uint256 beforeCalls = first.calls();
        first.setFail(true);
        bytes32 id = r.digest(a);
        vm.expectRevert();
        r.revoke(id, keccak256("reason"));
        assertTrue(r.status(user, 0, block.timestamp));
        assertEq(first.calls(), beforeCalls);
        first.setFail(false);
        r.revoke(r.digest(a), keccak256("reason"));
        assertFalse(r.status(user, 0, block.timestamp));
        assertEq(first.calls(), beforeCalls + 1);
        assertEq(desk.calls(), 2);
        assertEq(staking.calls(), 2);
        first.unbind(user);
        ninth.bind(user);
        assertEq(r.boundPools(user).length, 8);
    }

    function testSignatureDomainNonceAndDuplicateIssuersAreBound() public {
        address user = vm.addr(3);
        EligibilityRegistry.Attestation memory a = attestation(user);
        sign(a);
        address[] memory duplicate = new address[](2);
        duplicate[0] = signers[0];
        duplicate[1] = signers[0];
        bytes32 hash = r.digest(a);
        vm.expectRevert();
        r.register(a, duplicate, signatures, sig(3, hash));
        a.chainId += 1;
        hash = r.digest(a);
        vm.expectRevert();
        r.register(a, signers, signatures, sig(3, hash));
        a.chainId = block.chainid;
        sign(a);
        hash = r.digest(a);
        vm.expectRevert();
        r.register(a, signers, signatures, sig(4, hash));
        r.register(a, signers, signatures, sig(3, r.digest(a)));
        assertEq(r.nonces(user), 1);
    }
}

import {RewardAssetSchedule} from "../../src/v3/RewardAssetSchedule.sol";

contract RewardAssetScheduleTest is Test {
    receive() external payable {}

    function claim(bytes32, uint8, uint256 amount) external returns (bool) {
        (bool ok,) = msg.sender.call{value: amount}("");
        return ok;
    }

    function testTokenUsesCalendarAssetsAndWaitsForIntervalEnd() public {
        vm.warp(10 days);
        vm.deal(address(this), 100 ether);
        address[] memory assets = new address[](2);
        assets[0] = address(new EligibilityStock());
        assets[1] = address(new EligibilityStock());
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("one");
        ids[1] = keccak256("two");
        uint32[] memory versions = new uint32[](2);
        versions[0] = 1;
        versions[1] = 2;
        bytes32[] memory prices = new bytes32[](2);
        prices[0] = keccak256("price one");
        prices[1] = keccak256("price two");
        RewardAssetSchedule schedule = new RewardAssetSchedule(10, 2, assets, ids, versions, prices);
        V3RewardToken t = new V3RewardToken("Reward", "R", address(this), address(this), new address[](0));
        t.setDefaultRewardAsset(assets[0]);
        t.configurePool(bytes32(uint256(1)), address(0), 0);
        t.configureRounds(address(this), ids[0], 1, prices[0]);
        (bool ok,) = address(t).call(abi.encodeWithSignature("configureAssetSchedule(address)", address(schedule)));
        assertTrue(ok, "token calendar wiring missing");
        t.transfer(address(123), 100);
        vm.warp(10 days + 1 hours);
        t.onFeeCredit(bytes32(uint256(1)), address(0), 0, 10);
        assertEq(t.epochAsset(10), assets[0]);
        vm.warp(11 days);
        vm.expectRevert();
        t.sealReward(10, 0);
        vm.warp(12 days);
        t.sealReward(10, 0);
        t.onFeeCredit(bytes32(uint256(1)), address(0), 0, 10);
        assertEq(t.epochAsset(12), assets[1]);
        (bytes32 id, uint32 version, bytes32 price,) = t.rewardPolicy(12, 0);
        assertEq(id, ids[1]);
        assertEq(version, 2);
        assertEq(price, prices[1]);
        vm.warp(14 days);
        t.onFeeCredit(bytes32(uint256(1)), address(0), 0, 10);
        assertEq(t.epochAsset(14), assets[0]);
    }

    function testCyclicCalendarIsDeterministicAndGateUsesIntervalEnd() public {
        address[] memory assets = new address[](2);
        assets[0] = address(new EligibilityStock());
        assets[1] = address(new EligibilityStock());
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = keccak256("one");
        ids[1] = keccak256("two");
        uint32[] memory versions = new uint32[](2);
        versions[0] = 1;
        versions[1] = 2;
        bytes32[] memory prices = new bytes32[](2);
        prices[0] = keccak256("price one");
        prices[1] = keccak256("price two");
        RewardAssetSchedule schedule = new RewardAssetSchedule(10, 2, assets, ids, versions, prices);
        assertEq(schedule.rotationIndex(9), 0);
        assertEq(schedule.rotationIndex(10), 0);
        assertEq(schedule.rotationIndex(12), 1, "missing cyclic rotation");
        assertEq(schedule.rotationIndex(14), 0);
        assertEq(schedule.nextRoundAt(9), 10 days);
        assertEq(schedule.nextRoundAt(10), 12 days);
        assertEq(schedule.nextRoundAt(13), 14 days);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {V2FeeIngress} from "../../src/v3/V2FeeIngress.sol";
import {V2PlatformRouter} from "../../src/v3/V2PlatformRouter.sol";
import {V2FeeConverter} from "../../src/v3/V2FeeConverter.sol";
import {LedgerStock} from "./V3FeeLedger.t.sol";

contract V2SwapMock {
    function feePpm() external pure returns (uint24) {
        return 10000;
    }

    function path() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
    bool public lie;

    function setLie(bool yes) external {
        lie = yes;
    }
    uint256 public output;

    function setOutput(uint256 amount) external {
        output = amount;
    }

    function sell(address token, uint256 amount, uint256 minOut, address recipient, bytes32)
        external
        payable
        returns (uint256)
    {
        require(output >= minOut);
        LedgerStock(token).transferFrom(msg.sender, address(this), amount);
        if (!lie) {
            (bool ok,) = recipient.call{value: output}("");
            require(ok);
        }
        return output;
    }
    receive() external payable {}
}

contract V2StakingReceiver {
    mapping(bytes32 => uint256) public credited;

    function notifyV2Budget(bytes32 id, uint256 amount) external payable {
        require(msg.value == amount && credited[id] == 0);
        credited[id] = amount;
    }
}

contract V2BuybackReceiver {
    mapping(bytes32 => uint256) public credited;
    mapping(bytes32 => bool) public desk;

    function fundV2(bytes32 id, bool toDesk) external payable {
        require(credited[id] == 0);
        credited[id] = msg.value;
        desk[id] = toDesk;
    }
}

contract V2IngressTest is Test {
    V2FeeIngress ingress;
    V2PlatformRouter router;
    V2StakingReceiver staking;
    V2BuybackReceiver buyback;

    function setUp() public {
        vm.chainId(5042);
        address[3] memory auditors = [vm.addr(101), vm.addr(102), vm.addr(103)];
        ingress = new V2FeeIngress(address(this), auditors, address(this), uint64(block.number));
        staking = new V2StakingReceiver();
        buyback = new V2BuybackReceiver();
        router =
            new V2PlatformRouter(address(this), address(ingress), address(staking), address(buyback), address(0xdead));
        ingress.setRouter(address(router));
        vm.deal(address(this), 1000 ether);
    }

    function _evidence(address token, uint256 amount) internal view returns (V2FeeIngress.Evidence memory) {
        return V2FeeIngress.Evidence(
            ingress.solonSourceKey(), keccak256("collect"), uint64(block.number), 0, token, amount, 1
        );
    }

    function _sign(V2FeeIngress.Evidence memory e) internal view returns (V2FeeIngress.AuditSignature[2] memory sigs) {
        for (uint256 i; i < 2; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(101 + i, ingress.evidenceDigest(e));
            sigs[i] = V2FeeIngress.AuditSignature(uint8(i), abi.encodePacked(r, s, v));
        }
    }

    function test_ObservedHasNoRewardAndExactFundingNotifiesHalfImmediately() public {
        V2FeeIngress.Evidence memory e = _evidence(address(0), 100 ether);
        bytes32 id = ingress.recordLot(e, _sign(e));
        assertEq(staking.credited(id), 0);
        vm.expectRevert();
        ingress.fundLot{value: 99 ether}(id);
        ingress.fundLot{value: 100 ether}(id);
        assertEq(staking.credited(id), 50 ether, "funding did not notify half");
        assertEq(buyback.credited(id), 50 ether);
        assertFalse(buyback.desk(id));
        vm.expectRevert();
        ingress.fundLot{value: 100 ether}(id);
    }

    function test_OtherSourceTimelockAndAllNativeProceedsGoProtocolDeskBuyback() public {
        V2FeeIngress.Source memory source = V2FeeIngress.Source(
            5042,
            address(0),
            address(0x1234),
            10000,
            100,
            address(0),
            123,
            address(0x55),
            address(this),
            uint64(block.number),
            1,
            2
        );
        ingress.scheduleSource(source);
        vm.expectRevert();
        ingress.activateSource(source);
        vm.warp(block.timestamp + 48 hours);
        ingress.activateSource(source);
        V2FeeIngress.Evidence memory e = _evidence(address(0), 33 ether);
        e.source = ingress.sourceKey(source);
        bytes32 id = ingress.recordLot(e, _sign(e));
        ingress.fundLot{value: 33 ether}(id);
        assertEq(staking.credited(id), 0);
        assertEq(buyback.credited(id), 33 ether);
        assertTrue(buyback.desk(id));
    }

    function test_SOLONRawHalfBurnHalfActualConversionNotifiesOnlyAfterSale() public {
        address solon = ingress.SOLON();
        LedgerStock template = new LedgerStock();
        vm.etch(solon, address(template).code);
        LedgerStock token = LedgerStock(solon);
        token.mint(address(this), 100 ether);
        token.approve(address(ingress), 100 ether);
        V2SwapMock swap = new V2SwapMock();
        V2FeeConverter converter =
            new V2FeeConverter(address(router), address(swap), vm.addr(777), address(this), bytes32(uint256(1)), 1);
        router.setConverter(address(converter));
        V2FeeIngress.Evidence memory e = _evidence(solon, 100 ether);
        bytes32 id = ingress.recordLot(e, _sign(e));
        ingress.fundLot(id);
        assertEq(staking.credited(id), 0);
        router.routeLot(id);
        assertEq(token.balanceOf(address(0xdead)), 50 ether);
        assertEq(token.balanceOf(address(router)), 50 ether);
        V2FeeConverter.Quote memory q =
            V2FeeConverter.Quote(id, solon, 50 ether, 99 ether, 100 ether, block.timestamp, block.timestamp + 60, 0, 0);
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(777, converter.quoteDigest(q));
        swap.setOutput(100 ether);
        vm.deal(address(swap), 100 ether);
        router.convertLot(id, abi.encode(q, abi.encodePacked(r, sigS, v)));
        assertEq(staking.credited(id), 100 ether);
        assertEq(buyback.credited(id), 0);
        assertEq(token.balanceOf(address(swap)), 50 ether);
        assertEq(token.balanceOf(address(router)), 0);
        vm.expectRevert();
        router.routeLot(id);
        vm.expectRevert();
        router.convertLot(id, abi.encode(q, abi.encodePacked(r, sigS, v)));
    }

    function test_IndependentAuditorsAndTamperedAmountsAreRejected() public {
        V2FeeIngress.Evidence memory e = _evidence(address(0), 100 ether);
        V2FeeIngress.AuditSignature[2] memory sigs = _sign(e);
        sigs[1] = sigs[0];
        vm.expectRevert();
        ingress.recordLot(e, sigs);
        sigs = _sign(e);
        e.actualPlatformAmount++;
        vm.expectRevert();
        ingress.recordLot(e, sigs);
    }

    function test_UnknownAndPreCutoverEvidenceCannotFund() public {
        V2FeeIngress.Evidence memory e = _evidence(address(0), 100 ether);
        e.source = keccak256("unknown");
        bytes32 id = ingress.recordLot(e, _sign(e));
        assertFalse(ingress.lotInfo(id).admitted);
        vm.expectRevert();
        ingress.fundLot{value: 100 ether}(id);
        e = _evidence(address(0), 100 ether);
        e.collectBlock = 0;
        id = ingress.recordLot(e, _sign(e));
        vm.expectRevert();
        ingress.fundLot{value: 100 ether}(id);
    }

    function test_ReceiptCannotReplayUnderNewPolicyAndWrongFunderCannotPay() public {
        V2FeeIngress.Evidence memory e = _evidence(address(0), 100 ether);
        bytes32 id = ingress.recordLot(e, _sign(e));
        e.policyVersion = 2;
        V2FeeIngress.AuditSignature[2] memory sigs = _sign(e);
        vm.expectRevert();
        ingress.recordLot(e, sigs);
        vm.deal(address(55), 100 ether);
        vm.prank(address(55));
        vm.expectRevert();
        ingress.fundLot{value: 100 ether}(id);
    }

    function test_CanonicalSOLONIdentityAndNoCreatorTokenInjection() public {
        assertEq(
            keccak256(abi.encode(address(0), ingress.SOLON(), uint24(10000), int24(100), address(0))),
            ingress.SOLON_POOL()
        );
        V2FeeIngress.Evidence memory e = _evidence(address(0xFADE), 100 ether);
        bytes32 id = ingress.recordLot(e, _sign(e));
        assertFalse(ingress.lotInfo(id).admitted);
        vm.expectRevert();
        ingress.fundLot(id);
    }

    function test_LargeOtherRawLotConvertsInCappedSlicesPreservingResidualAndProvenance() public {
        LedgerStock token = new LedgerStock();
        V2FeeIngress.Source memory source = V2FeeIngress.Source(
            5042,
            address(0),
            address(token),
            10000,
            100,
            address(0),
            123,
            address(0x55),
            address(this),
            uint64(block.number),
            1,
            2
        );
        ingress.scheduleSource(source);
        vm.warp(block.timestamp + 48 hours);
        ingress.activateSource(source);
        V2SwapMock swap = new V2SwapMock();
        V2FeeConverter converter =
            new V2FeeConverter(address(router), address(swap), vm.addr(777), address(this), bytes32(uint256(1)), 1);
        router.setConverter(address(converter));
        token.mint(address(this), 2000 ether);
        token.approve(address(ingress), 2000 ether);
        V2FeeIngress.Evidence memory e = _evidence(address(token), 2000 ether);
        e.source = ingress.sourceKey(source);
        bytes32 id = ingress.recordLot(e, _sign(e));
        ingress.fundLot(id);
        router.routeLot(id);
        swap.setOutput(1000 ether);
        vm.deal(address(swap), 2000 ether);
        V2FeeConverter.Quote memory q = V2FeeConverter.Quote(
            id, address(token), 1000 ether, 990 ether, 1000 ether, block.timestamp, block.timestamp + 60, 0, 0
        );
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(777, converter.quoteDigest(q));
        bytes memory encoded = abi.encode(q, abi.encodePacked(r, sigS, v));
        swap.setLie(true);
        vm.expectRevert();
        router.convertLot(id, 1000 ether, encoded);
        assertEq(token.balanceOf(address(router)), 2000 ether);
        assertEq(router.conversionCount(id), 0);
        swap.setLie(false);
        router.convertLot(id, 1000 ether, encoded);
        assertEq(token.balanceOf(address(router)), 1000 ether, "partial converter missing");
        assertEq(router.rawLiability(address(token)), 1000 ether);
        assertEq(buyback.credited(id), 1000 ether);
        assertTrue(buyback.desk(id));
        bytes32 next = router.nextConversionId(id);
        assertTrue(next != id);
        q.lotId = next;
        q.nonce = 1;
        (v, r, sigS) = vm.sign(777, converter.quoteDigest(q));
        router.convertLot(id, 1000 ether, abi.encode(q, abi.encodePacked(r, sigS, v)));
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(buyback.credited(next), 1000 ether);
        assertEq(staking.credited(next), 0);
    }

    function test_HalfSplitCarriesOddDustAcrossLots() public {
        V2FeeIngress.Evidence memory e = _evidence(address(0), 1);
        bytes32 first = ingress.recordLot(e, _sign(e));
        ingress.fundLot{value: 1}(first);
        e.collectTx = keccak256("second");
        bytes32 second = ingress.recordLot(e, _sign(e));
        ingress.fundLot{value: 1}(second);
        assertEq(staking.credited(first) + staking.credited(second), 1, "half-share dust lost");
        assertEq(buyback.credited(first) + buyback.credited(second), 1);
    }
}

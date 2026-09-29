// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId, nTableIds} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// Reviewer scratch suite for a1f9809: voidReference griefing / phase edges / void+other market.
contract TreatyVoidTest is Test, TreatyFixture {
    MockUSDG usdg;
    MockFeed feed;
    MockFeed feedB;
    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");
    uint256 constant FRI = 1_790_294_400;
    uint256 constant CLOSE = FRI + 20 hours;
    uint256 constant EXPIRY = FRI + 3 days + 13 hours + 30 minutes;
    uint80 constant P1 = uint80(uint256(1) << 64);
    uint80 constant P2 = uint80(uint256(2) << 64);

    function _deploy(uint256 n) internal returns (Treaty t, Capacity c) {
        usdg = new MockUSDG();
        feed = new MockFeed();
        feedB = new MockFeed();
        address[] memory feeds = new address[](n);
        feeds[0] = address(feed);
        if (n > 1) feeds[1] = address(feedB);
        t = deployTreaty(address(usdg), address(new Pricer(n == 1 ? oneTableId() : nTableIds(n))), feeds, 50, address(0));
        c = t.capacity();
        usdg.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(address(c), type(uint256).max);
        c.deposit(500_000e6, writer);
        vm.stopPrank();
        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(c), type(uint256).max);
    }

    function _bind(Treaty t, uint256 n) internal returns (uint256 id) {
        int256[] memory e = new int256[](n);
        for (uint256 i; i < n; i++) e[i] = 1_000_000e6;
        vm.warp(CLOSE - 1 hours);
        vm.prank(buyer);
        id = t.bind(e, 0, 60_000e6);
    }

    /// V1: on-time crossing, ITM layer. No round in the phase can be voided (fuzz the round id and
    /// the time); the buyer's payout path stays open and settles.
    function testFuzz_V1_voidNeverHitsReferenceableMarket(uint8 which, uint32 later) public {
        (Treaty t,) = _deploy(1);
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours); // the round genuinely in effect at close
        uint256 id = _bind(t, 1);
        feed.set(P1 | 2, 770e8, CLOSE + 35 hours); // first round after close, well after MAX_ROUND_AGE
        feed.set(P1 | 3, 770e8, CLOSE + 59 hours);
        feed.set(P1 | 4, 700e8, EXPIRY + 5 minutes); // -9%: ITM
        feed.set(P1 | 5, 700e8, EXPIRY + 1 days);
        vm.warp(EXPIRY + 3 days + uint256(later));
        uint80 r = P1 | uint80(bound(which, 0, 6));
        vm.expectRevert();
        t.voidReference(id, 0, r);
        t.setReference(id, 0, P1 | 1);
        t.fix(id, 0, P1 | 4);
        (,,,,, Treaty.State st,,,,,) = t.layers(id);
        assertEq(uint8(st), uint8(Treaty.State.Settled));
    }

    /// V2: phase change after close to an aggregator whose own crossing is late. Void is allowed,
    /// but only because setReference is equally impossible in the new phase (checked first).
    function test_V2_phaseChangeVoidOnlyWhenUnreferenceable() public {
        (Treaty t,) = _deploy(1);
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours); // would have been in effect at close...
        uint256 id = _bind(t, 1);
        feed.set(P1 | 2, 771e8, CLOSE + 1 hours); // ...but the phase already crossed
        feed.set(P2 | 1, 771e8, CLOSE + 2 hours); // phase 2's own first round prints after close: stranded
        feed.set(P2 | 2, 771e8, CLOSE + 40 hours);
        vm.warp(CLOSE + 41 hours);
        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 0, P1 | 1); // old phase, unreachable via the current-phase lookup
        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 0, P2 | 2); // current phase but late
        t.voidReference(id, 0, P2 | 1); // phase proof: phase 2's own first round is already post-close
        vm.expectRevert(Treaty.ReferenceIsVoid.selector);
        t.setReference(id, 0, P2 | 2);
    }

    /// V3: A referenced (ITM), B void. fix(A) is impossible, only cancel; buyer refunded in full,
    /// capital unlocked, gate reopens.
    function test_V3_voidPlusReferencedOtherOnlyCancels() public {
        (Treaty t, Capacity c) = _deploy(2);
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours); // market0: fresh, in effect at close
        feedB.set(P1 | 1, 100e8, CLOSE - 27 hours); // market1: silent for >26h before close
        uint256 id = _bind(t, 2);
        uint256 buyerAfterBind = usdg.balanceOf(buyer);
        feed.set(P1 | 2, 771e8, CLOSE + 1 hours);
        feedB.set(P1 | 2, 90e8, CLOSE + 40 hours); // market1's next round only prints after close
        vm.warp(CLOSE + 41 hours);
        t.setReference(id, 0, P1 | 1); // market0 settles off the round in effect at close
        t.voidReference(id, 1, P1 | 1); // market1: stale proof
        feed.set(P1 | 3, 700e8, EXPIRY + 5 minutes);
        vm.warp(EXPIRY + 1 hours);
        vm.expectRevert(Treaty.ReferenceNotSet.selector);
        t.fix(id, 0, P1 | 3);
        vm.warp(EXPIRY + 3 days);
        t.cancel(id);
        (,,,,,,,, uint256 limit, uint256 premium,) = t.layers(id);
        assertEq(usdg.balanceOf(buyer), buyerAfterBind + premium, "premium refunded");
        assertEq(c.locked(), 0);
        assertGt(c.maxRedeem(writer), 0, "gate reopened");
        limit;
    }

    /// V4: the first round after close is late AND carries a zero answer. setReference rejects it
    /// (bad answer) and so would a price-checking void; void only proves timing, so it must still
    /// succeed and let cancel unlock the vault instead of leaving the layer Bound forever.
    function test_V4_lateZeroAnswerRoundIsVoidableThenCancels() public {
        (Treaty t, Capacity c) = _deploy(1);
        feed.set(P1 | 1, 0, CLOSE - 27 hours); // the round in effect at close: stale AND a bad answer
        uint256 id = _bind(t, 1);
        vm.warp(CLOSE + 41 hours);
        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 0, P1 | 1);
        t.voidReference(id, 0, P1 | 1);
        vm.warp(EXPIRY + 3 days);
        t.cancel(id);
        (,,,,, Treaty.State st,,,,,) = t.layers(id);
        assertEq(uint8(st), uint8(Treaty.State.Cancelled));
        assertGt(c.maxDeposit(writer), 0);
    }
}

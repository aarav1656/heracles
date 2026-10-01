// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";
import {BreakableFeed} from "./Round6.t.sol";

/// Independent v3 review, findings H-1 (the buyer could see the reference round before binding),
/// L-1 (the 30-day cancel backstop cancelled layers that `fix` could still settle) and L-2 (no
/// premium cap on `bind`). Every test here goes red on 881c1df's Treaty and green on the fix; the
/// two new errors are referenced by raw selector so the file also compiles against the old source.
///
/// Calendar (week of 2026-09-21, EDT): Thu 19:30 UTC is the new bind deadline, Fri 20:00 UTC the
/// close, Mon 13:30 UTC the expiry.
contract V3ReviewTest is Test, TreatyFixture {
    bytes4 constant KNOWN_AT_BIND = bytes4(keccak256("ReferenceKnownAtBind()"));
    bytes4 constant PREMIUM_TOO_HIGH = bytes4(keccak256("PremiumTooHigh()"));

    uint256 constant FRI = 1_790_294_400; // Fri 2026-09-25 00:00 UTC
    uint256 constant BIND_DEADLINE = FRI - 4 hours - 30 minutes; // Thu 19:30 UTC
    uint256 constant THU_1900 = FRI - 5 hours;
    uint256 constant CLOSE = FRI + 20 hours;
    uint256 constant EXPIRY = FRI + 3 days + 13 hours + 30 minutes;

    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    MockUSDG usdg;
    Treaty t;
    Capacity fl;
    Capacity sr;
    Pricer pricer;
    MockFeed feed;
    MockFeed live;

    function _deploy(address market, address liveness) internal {
        usdg = new MockUSDG();
        pricer = new Pricer(oneTableId());
        address[] memory feeds = new address[](1);
        feeds[0] = market;
        t = deployTreaty(address(usdg), address(pricer), feeds, 50, address(0), liveness);
        fl = Capacity(t.firstLossVault(0));
        sr = Capacity(t.seniorVault(0));
        usdg.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(address(fl), type(uint256).max);
        usdg.approve(address(sr), type(uint256).max);
        fl.deposit(300_000e6, writer);
        sr.deposit(700_000e6, writer);
        vm.stopPrank();
        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(t), type(uint256).max);
    }

    function _deployMock() internal {
        feed = new MockFeed();
        live = new MockFeed();
        _deploy(address(feed), address(live));
    }

    function _exposure(int256 e) internal pure returns (int256[] memory x) {
        x = new int256[](1);
        x[0] = e;
    }

    /// The single `bind` call site. Binds at the current block time.
    function _bindAt(int256 e, uint256 retention, uint256 limit, uint256 maxPremium) internal returns (uint256 id) {
        vm.prank(buyer);
        id = t.bind(0, _exposure(e), retention, limit, maxPremium);
    }

    function _bind() internal returns (uint256) {
        return _bindAt(1_000_000e6, 20_000e6, 60_000e6, type(uint256).max);
    }

    function _layer(uint256 id) internal view returns (Treaty.State s, uint256 premium, uint256 payout) {
        (,,,,, s,,,, premium, payout) = layerBasics(t, id);
    }

    // ------------------------------------------------------------------------------------------
    // H-1. The bind deadline moved from Friday 19:30 UTC to Thursday 19:30 UTC, and a round whose
    // own updatedAt is at or before that deadline can never be the reference.
    // ------------------------------------------------------------------------------------------

    function test_H1_bindWindowClosesThursday1930() public {
        _deployMock();
        feed.set(1, 770e8, THU_1900 - 1 hours);

        uint256 snap = vm.snapshotState();

        vm.warp(BIND_DEADLINE - 1);
        uint256 id = _bind();
        (Treaty.State s,,) = _layer(id);
        assertEq(uint8(s), uint8(Treaty.State.Bound), "one second before the deadline still binds");
        (, uint40 cutoff,,,,,,,,,) = layerBasics(t, id);
        assertEq(cutoff, FRI + 19 hours + 30 minutes, "the layer still keys on the Friday 19:30 anchor");

        vm.revertToState(snap);
        vm.warp(BIND_DEADLINE);
        vm.expectRevert(Treaty.BadTiming.selector);
        _bind();

        vm.warp(FRI + 19 hours); // the old window: Friday 19:00 UTC, 30 minutes before the old deadline
        vm.expectRevert(Treaty.BadTiming.selector);
        _bind();
    }

    /// The H-1 attack as the review describes it: a deviation-triggered feed is silent inside its
    /// 0.5% band, so at Friday 19:00 the round that will be in effect at the 20:00 close is already
    /// on chain. The buyer reads it (770), knows the live spot (772), and picks the exposure sign
    /// that pays on that drift, with the reference fixed in advance. Run end to end on the old
    /// code the Friday bind is accepted and settles with a payout; the bind window now shuts first.
    function test_H1_PoC_fridayBindAgainstVisibleInEffectRoundIsRefused() public {
        _deployMock();
        feed.set(1, 770e8, FRI + 18 hours); // in effect at the close, visible at bind time
        vm.warp(FRI + 19 hours);
        int256 shortExposure = -5_000_000e6; // loses when the price rises: 770 -> 772 pays it

        vm.prank(buyer);
        try t.bind(0, _exposure(shortExposure), 0, 60_000e6, type(uint256).max) returns (uint256 id) {
            vm.warp(CLOSE + 1);
            t.setReference(id, 0, 1);
            feed.set(2, 772e8, EXPIRY + 5 minutes); // flat-ish weekend, +0.26%
            vm.warp(EXPIRY + 10 minutes);
            t.fix(id, 0, 2);
            (, uint256 premium, uint256 payout) = _layer(id);
            fail(
                string.concat(
                    "H-1: Friday bind against a visible reference accepted, buyer paid ",
                    vm.toString(premium),
                    " and was owed ",
                    vm.toString(payout),
                    " on a +0.26% weekend"
                )
            );
        } catch (bytes memory ret) {
            assertEq(bytes4(ret), Treaty.BadTiming.selector, "the Friday bind must die on BadTiming");
        }
    }

    /// Defence in depth: a feed that stalls defeats the one-heartbeat margin. A round printed at
    /// Thu 18:00 UTC is exactly 26h old at Friday's close, so rule 5 (<= 26h) accepts it on the old
    /// code, yet the buyer saw it when binding at Thu 19:00. `setReference` must refuse it by round
    /// data, `voidReference` must accept it under the new known-at-bind proof, and cancel must give
    /// the premium back in full.
    function test_H1_stalledFeedKnownAtBindRoundCannotBeReferenceAndVoidsToFullRefund() public {
        _deployMock();
        feed.set(1, 770e8, CLOSE - 26 hours); // Thu 18:00 UTC, silent for the whole window
        vm.warp(THU_1900);
        uint256 buyerBefore = usdg.balanceOf(buyer);
        uint256 id = _bind();
        (, uint256 premium,) = _layer(id);
        assertEq(buyerBefore - usdg.balanceOf(buyer), premium, "bind pulled the premium");

        vm.warp(CLOSE + 1);
        vm.expectRevert(KNOWN_AT_BIND);
        t.setReference(id, 0, 1);
        assertFalse(t.referenceSet(id, 0), "no reference was recorded");

        t.voidReference(id, 0, 1); // the round is not stale (exactly 26h), so only known-at-bind can void it
        assertTrue(t.referenceVoid(id, 0));
        vm.expectRevert(Treaty.ReferenceIsVoid.selector);
        t.setReference(id, 0, 1);

        live.set(1, 1e8, EXPIRY + 3 days); // chain proven live past expiry + 26h
        vm.warp(EXPIRY + 3 days);
        t.cancel(id);
        (Treaty.State s,,) = _layer(id);
        assertEq(uint8(s), uint8(Treaty.State.Cancelled));
        vm.prank(buyer);
        t.claim(id);
        assertEq(usdg.balanceOf(buyer), buyerBefore, "known-at-bind void refunds the whole premium");
        assertEq(fl.locked() + sr.locked(), 0, "capital unlocked");
        assertGt(fl.maxRedeem(writer), 0, "first-loss gate reopened");
        assertGt(sr.maxRedeem(writer), 0, "senior gate reopened");
    }

    /// Exact boundary, `updatedAt <= bind deadline`: a round printed at Thu 19:30:00 (after a
    /// 19:00 bind) is known at bind, one printed a second later is not.
    function test_H1_boundaryRoundAtDeadlineIsKnownOneSecondLaterIsNot() public {
        _deployMock();
        feed.set(1, 770e8, THU_1900 - 30 minutes);
        vm.warp(THU_1900);
        uint256 id = _bind();
        uint256 snap = vm.snapshotState();

        feed.set(2, 771e8, BIND_DEADLINE);
        vm.warp(CLOSE + 1);
        vm.expectRevert(KNOWN_AT_BIND);
        t.setReference(id, 0, 2);
        t.voidReference(id, 0, 2);
        assertTrue(t.referenceVoid(id, 0));

        vm.revertToState(snap);
        feed.set(2, 771e8, BIND_DEADLINE + 1);
        vm.warp(CLOSE + 1);
        t.setReference(id, 0, 2);
        assertEq(t.fridayPrice(id, 0), 771e8);
        vm.expectRevert(Treaty.AlreadyFixed.selector);
        t.voidReference(id, 0, 2);
    }

    /// Exclusivity fuzz over the new boundary. The round in effect at close is printed `age`
    /// before the close. Exactly one of setReference / voidReference must succeed for it, the loser
    /// must stay shut afterwards, and the side is decided by `updatedAt > bind deadline`.
    function testFuzz_H1_exactlyOneOfSetOrVoidAtBindDeadline(uint256 ageSeed, bool voidFirst) public {
        uint256 age = bound(ageSeed, 1, 50 hours); // 50h keeps the round fresh enough to bind against
        _deployMock();
        uint256 updatedAt = CLOSE - age;
        feed.set(1, 770e8, updatedAt);
        vm.warp(THU_1900);
        uint256 id = _bind();
        vm.warp(CLOSE + 1);

        bool referenceable = updatedAt > BIND_DEADLINE;
        if (voidFirst) {
            (bool ok,) = address(t).call(abi.encodeCall(Treaty.voidReference, (id, 0, 1)));
            assertEq(ok, !referenceable, "void succeeds exactly when the round is known at bind (or stale)");
            if (ok) {
                vm.expectRevert(Treaty.ReferenceIsVoid.selector);
                t.setReference(id, 0, 1);
            } else {
                t.setReference(id, 0, 1);
            }
        } else {
            (bool ok,) = address(t).call(abi.encodeCall(Treaty.setReference, (id, 0, 1)));
            assertEq(ok, referenceable, "set succeeds exactly when the round printed after the bind deadline");
            if (ok) {
                vm.expectRevert(Treaty.AlreadyFixed.selector);
                t.voidReference(id, 0, 1);
            } else {
                t.voidReference(id, 0, 1);
            }
        }
        assertTrue(t.referenceSet(id, 0) != t.referenceVoid(id, 0), "exactly one outcome, never both, never neither");
        assertEq(t.referenceSet(id, 0), referenceable);
    }

    // ------------------------------------------------------------------------------------------
    // L-1. cancel never skips the fixable check, and a reverting market feed cannot block it.
    // ------------------------------------------------------------------------------------------

    /// An out-of-the-money buyer used to wait 30 days and cancel for the whole premium instead of
    /// letting `fix` settle at a zero payout. A layer that is still fixable must stay Bound no
    /// matter how long it sits, and `fix` must then hand the premium to the writers.
    function test_L1_cancelPastBackstopIsRefusedWhileFixableAndFixPaysWriters() public {
        _deployMock();
        live.set(1, 1e8, EXPIRY + 40 days); // the liveness feed keeps printing: only the fixable check can stop cancel
        feed.set(1, 770e8, THU_1900 - 1 hours);
        vm.warp(THU_1900);
        uint256 id = _bind();
        (, uint256 premium,) = _layer(id);
        feed.set(2, 771e8, FRI + 19 hours);
        vm.warp(CLOSE + 1);
        t.setReference(id, 0, 2);
        feed.set(3, 780e8, EXPIRY + 5 minutes); // up 1.2%: the long buyer is out of the money
        feed.set(4, 781e8, EXPIRY + 40 days);

        uint256 writersBefore = fl.totalAssets() + sr.totalAssets();
        uint256 buyerBefore = usdg.balanceOf(buyer);

        vm.warp(EXPIRY + 30 days + 1);
        vm.expectRevert(Treaty.StillFixable.selector);
        t.cancel(id);
        vm.warp(EXPIRY + 365 days);
        vm.expectRevert(Treaty.StillFixable.selector);
        t.cancel(id);
        (Treaty.State s,,) = _layer(id);
        assertEq(uint8(s), uint8(Treaty.State.Bound), "still Bound after a year");

        t.fix(id, 0, 3);
        (Treaty.State s2,, uint256 payout) = _layer(id);
        assertEq(uint8(s2), uint8(Treaty.State.Settled));
        assertEq(payout, 0, "out of the money: zero payout");
        assertEq(usdg.balanceOf(buyer), buyerBefore, "the buyer got nothing back");
        assertEq(fl.totalAssets() + sr.totalAssets(), writersBefore + premium, "the writers keep the whole premium");
    }

    /// `_isMarketDead` read `latestRoundData()` bare, so a market proxy that reverts blocked cancel
    /// forever (before the backstop, and after it too once the fixable check became unconditional).
    function test_L1_revertingMarketFeedReadsAsDeadNotAsBlocker() public {
        BreakableFeed bf = new BreakableFeed();
        live = new MockFeed();
        _deploy(address(bf), address(live));
        bf.set(1, 770e8, THU_1900 - 1 hours);
        vm.warp(THU_1900);
        uint256 id = _bind();
        bf.set(2, 771e8, FRI + 19 hours);
        vm.warp(CLOSE + 1);
        t.setReference(id, 0, 2);
        live.set(1, 1e8, EXPIRY + 3 days + 1); // chain proven live past expiry + 26h
        bf.breakIt(); // proxy decommissioned after the reference was set

        vm.warp(EXPIRY + 3 days + 1); // GRACE elapsed, well before the 30-day backstop
        t.cancel(id);
        (Treaty.State s,,) = _layer(id);
        assertEq(uint8(s), uint8(Treaty.State.Cancelled));
        assertGt(fl.maxRedeem(writer), 0, "gate reopened");
    }

    // ------------------------------------------------------------------------------------------
    // L-2. bind(..., maxPremium) reverts PremiumTooHigh above the caller's ceiling.
    // ------------------------------------------------------------------------------------------

    function _quietHistory(uint256 rounds) internal {
        for (uint256 i = 1; i <= rounds; i++) {
            feed.set(uint80(i), int256(770e8 + (i % 2) * 1e6), THU_1900 - 2 hours + i);
        }
    }

    /// The review's sequence: the buyer quotes on a quiet feed, a violent round lands before the
    /// bind transaction, the pricer's realised-vol scale reprices the layer above the quote. With a
    /// ceiling the bind reverts; without one it silently charged the higher premium.
    function test_L2_roundBetweenQuoteAndBindCannotRepriceAboveCeiling() public {
        _deployMock();
        _quietHistory(8);
        vm.warp(THU_1900);
        address[] memory fs = new address[](1);
        fs[0] = address(feed);
        (uint256 quoted,,) = pricer.quote(_exposure(1_000_000e6), fs, 20_000e6, 60_000e6);

        feed.set(9, 847e8, THU_1900 - 1 minutes); // +10% in one round: the 8-round realised vol rises about 2.5x
        (uint256 repriced,,) = pricer.quote(_exposure(1_000_000e6), fs, 20_000e6, 60_000e6);
        assertGt(repriced, quoted, "precondition: the landed round raises the premium");

        vm.expectRevert(PREMIUM_TOO_HIGH);
        _bindAt(1_000_000e6, 20_000e6, 60_000e6, quoted);

        uint256 buyerBefore = usdg.balanceOf(buyer);
        uint256 id = _bindAt(1_000_000e6, 20_000e6, 60_000e6, repriced);
        (, uint256 premium,) = _layer(id);
        assertEq(premium, repriced);
        assertEq(buyerBefore - usdg.balanceOf(buyer), premium, "charged exactly the premium, within the ceiling");
    }

    /// Ceiling edges: premium itself passes, premium - 1 and zero revert.
    function test_L2_ceilingBoundary() public {
        _deployMock();
        feed.set(1, 770e8, THU_1900 - 1 hours);
        vm.warp(THU_1900);
        uint256 snap = vm.snapshotState();
        uint256 id = _bind();
        (, uint256 premium,) = _layer(id);
        assertGt(premium, 1);

        vm.revertToState(snap);
        vm.expectRevert(PREMIUM_TOO_HIGH);
        _bindAt(1_000_000e6, 20_000e6, 60_000e6, premium - 1);
        vm.expectRevert(PREMIUM_TOO_HIGH);
        _bindAt(1_000_000e6, 20_000e6, 60_000e6, 0);
        uint256 id2 = _bindAt(1_000_000e6, 20_000e6, 60_000e6, premium);
        (, uint256 premium2,) = _layer(id2);
        assertEq(premium2, premium, "premium == ceiling binds");
    }

    /// The ceiling is checked against the premium actually charged, which includes the H2 floor.
    /// A retention above every historical loss quotes only a tiny capital charge, the floor
    /// (0.5% of the limit) is what binds. A ceiling set at the raw quote must still revert.
    function test_L2_ceilingAppliesToTheFlooredPremium() public {
        _deployMock();
        feed.set(1, 770e8, THU_1900 - 1 hours);
        vm.warp(THU_1900);
        address[] memory fs = new address[](1);
        fs[0] = address(feed);
        uint256 retention = 147_500e6;
        uint256 limit = 100_000e6;
        (uint256 rawQuote,,) = pricer.quote(_exposure(1_000_000e6), fs, retention, limit);
        uint256 floor_ = limit * t.minRateOnLineBps() / 1e4;
        assertLt(rawQuote, floor_, "precondition: the floor, not the quote, sets the premium");

        vm.expectRevert(PREMIUM_TOO_HIGH);
        _bindAt(1_000_000e6, retention, limit, rawQuote);
        uint256 id = _bindAt(1_000_000e6, retention, limit, floor_);
        (, uint256 premium,) = _layer(id);
        assertEq(premium, floor_);
    }
}

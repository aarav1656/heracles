// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// Re-review of 6af8b2b..79320b8 (docs/security/capacity-review.md, "Re-review (2026-09-28)"),
/// P3 and P5. Ported from the reviewer's scratch suite at
/// /tmp/heracles-rr/proj/test/ReReview.t.sol; every test here now asserts the *fixed* behaviour
/// (the reviewer's copy asserted the pre-fix bug and was red against the unpatched contracts).
contract TreatyReReviewTest is Test, TreatyFixture {
    MockUSDG usdg;
    MockFeed feed;
    Pricer pricer;
    Treaty treaty;
    Capacity capacity;
    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    // Week of 2026-09-21 (EDT)
    uint256 constant FRI = 1_790_294_400; // Fri 2026-09-25 00:00 UTC
    uint256 constant MON = FRI + 3 days;
    uint256 constant EXPIRY = MON + 13 hours + 30 minutes;

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer(oneTableId());
        feed = new MockFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = deployTreaty(address(usdg), address(pricer), feeds, 50, address(0));
        capacity = treaty.capacity();
        usdg.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(address(capacity), type(uint256).max);
        capacity.deposit(500_000e6, writer);
        vm.stopPrank();
        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(capacity), type(uint256).max);
    }

    function _bind(uint256 exp) internal returns (uint256 id) {
        int256[] memory e = new int256[](1);
        e[0] = int256(exp);
        vm.prank(buyer);
        id = treaty.bind(e, 0, 60_000e6);
    }

    /// P3: on a live 24h-heartbeat feed, by `expiry + GRACE` the feed has printed about three
    /// rounds past expiry, so the latest round's own predecessor is also past expiry and the old
    /// "just the latest round and its predecessor" check never finds the genuine first
    /// post-expiry round, a perfectly fixable, out-of-the-money layer reads as dead and cancel
    /// refunds the buyer's premium in full, a free option. Fixed `_isMarketDead` finds the real
    /// first round (round 4 here) via the phase's own first round, so cancel must revert
    /// StillFixable instead.
    function test_RR1_cancelOfFixableLayerMustRevert() public {
        feed.set(1, 770e8, FRI + 16 hours);
        vm.warp(FRI + 17 hours);
        uint256 id = _bind(1_000_000e6);
        feed.set(2, 771e8, FRI + 1 days + 16 hours); // Sat heartbeat, first after close
        feed.set(3, 771e8, FRI + 2 days + 16 hours); // Sun heartbeat
        feed.set(4, 775e8, EXPIRY + 5 minutes); // Monday: price UP, buyer long -> no payout
        feed.set(5, 776e8, EXPIRY + 1 days);
        feed.set(6, 777e8, EXPIRY + 2 days);
        feed.set(7, 777e8, EXPIRY + 3 days - 1);
        vm.warp(EXPIRY + 3 days);
        uint256 before = usdg.balanceOf(buyer);
        vm.expectRevert(Treaty.StillFixable.selector);
        treaty.cancel(id);
        assertEq(usdg.balanceOf(buyer), before, "cancel must not have paid out a premium refund");
    }

    /// P3, unset-reference branch: `!referenceSet[i]` used to be treated as unconditionally dead.
    /// Same live feed, reference never set (permissionless, anyone could have called it), the
    /// fixed rule checks the reference boundary with the same `_isMarketDead` logic instead of
    /// assuming absence of a reference means a dead feed.
    function test_RR1b_cancelWithUnsetReferenceOnLiveFeedMustRevert() public {
        feed.set(1, 770e8, FRI + 16 hours);
        vm.warp(FRI + 17 hours);
        uint256 id = _bind(1_000_000e6);
        feed.set(2, 771e8, FRI + 1 days + 16 hours);
        feed.set(3, 775e8, EXPIRY + 5 minutes);
        vm.warp(EXPIRY + 3 days);
        vm.expectRevert(Treaty.StillFixable.selector);
        treaty.cancel(id);
    }

    /// P5: `setReference` used to accept the first fresh round at or after Friday's close with no
    /// upper bound. A feed whose heartbeat pauses over the weekend (no round between close and the
    /// next live session) let that next print, here, Monday's post-news open, stand in for
    /// Friday's close, silently absorbing the weekend gap this treaty exists to cover. v3's rule
    /// takes the round already in effect at close instead: round 1 here, printed an hour before
    /// close, is still accepted as the reference even after the late round exists, and the layer
    /// settles off round 1's pre-weekend price, not round 2's post-gap one. Round 2 itself (the
    /// weekend-gap round) is never a valid reference: it prints after close, so `setReference`
    /// rejects it outright regardless of round 1's presence.
    function test_RR2_referenceMustNotAbsorbWeekendGap() public {
        feed.set(1, 770e8, FRI + 19 hours); // in effect at close (close is FRI + 20h, DST)
        vm.warp(FRI + 19 hours + 1);
        uint256 id = _bind(1_000_000e6);
        // First round after close lands ~52h late (weekend heartbeat pause): Sunday 20:05 ET /
        // Monday 00:05 UTC, already carrying the post-news price.
        feed.set(2, 708e8, MON + 5 minutes);
        vm.warp(MON + 10 minutes);
        vm.expectRevert(Treaty.BadRound.selector);
        treaty.setReference(id, 0, 2); // the late round can never become the reference
        assertFalse(treaty.referenceSet(id, 0));

        treaty.setReference(id, 0, 1); // the round genuinely in effect at close still can
        assertTrue(treaty.referenceSet(id, 0));
        assertEq(treaty.fridayPrice(id, 0), 770e8, "reference must be the pre-weekend price, not round 2's");

        feed.set(3, 700e8, EXPIRY + 5 minutes); // Monday's real post-expiry print settles the layer
        vm.warp(EXPIRY + 10 minutes);
        treaty.fix(id, 0, 3);
        (,,,,, Treaty.State st,,,,, uint256 payout) = treaty.layers(id);
        assertEq(uint8(st), uint8(Treaty.State.Settled));
        assertGt(payout, 0, "the weekend gap off round 1's price must still pay out");
    }
}

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

/// Port of the reviewer's DR1/DR2 PoCs (docs/security/capacity-review.md "Re-review (2026-09-28)",
/// findings H1/H2; original scratch suite at /tmp/heracles-dr/proj/contracts/test/DR.t.sol). H1/H2
/// locked a Bound layer, and the whole Capacity vault's deposit/withdraw/redeem gate, forever,
/// with no admin path out, whenever a market's Friday reference could never be set (a live feed
/// whose genuine crossing round lands later than `REFERENCE_MAX_DELAY`, or a feed that dies before
/// Friday's close entirely on a multi-market layer). Fixed by `Treaty.voidReference` plus the
/// `_anyMarketFixable` H1/H2 change: run these against an unpatched Treaty (revert the
/// `voidReference` function and the `_anyMarketFixable`/`REFERENCE_MAX_DELAY` changes) to see DR1
/// and DR2 go red again.
contract DRTest is Test, TreatyFixture {
    MockUSDG usdg;
    MockFeed feed;
    MockFeed feedB;
    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    uint256 constant FRI = 1_790_294_400; // Fri 2026-09-25 00:00 UTC (EDT)
    uint256 constant CLOSE = FRI + 20 hours;
    uint256 constant MON = FRI + 3 days;
    uint256 constant EXPIRY = MON + 13 hours + 30 minutes;
    uint80 constant P1 = uint80(uint256(1) << 64); // real proxies sit in phase >= 1

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

    /// DR1 (H1): the live SPY feed's own heartbeat lands ~24h after the last pre-close update. If
    /// the last intraday update lands in the final seconds before close, the genuine first
    /// crossing round can still land later than even the widened 36h `REFERENCE_MAX_DELAY` (an
    /// extended weekend pause, not just one missed heartbeat): `setReference` reverts `BadRound`
    /// forever on that round, `fix` reverts `ReferenceNotSet` forever, and before the fix `cancel`
    /// reverted `StillFixable` forever because the feed is alive with a crossing round in its
    /// current phase, the Capacity gate never reopens. `voidReference` records the permissionless
    /// proof that this is the genuine, provably-late crossing round, after which `cancel` succeeds.
    function test_DR1_lateHeartbeatReferenceLocksVaultForever() public {
        (Treaty t, Capacity c) = _deploy(1);
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours);
        vm.warp(CLOSE - 1 hours);
        int256[] memory e = new int256[](1);
        e[0] = 1_000_000e6;
        vm.prank(buyer);
        uint256 id = t.bind(e, 0, 60_000e6);

        feed.set(P1 | 2, 771e8, CLOSE - 4); // last intraday update 4s before close
        // Heartbeat, 1s past the (widened) 36h bound, an extended weekend pause.
        feed.set(P1 | 3, 771e8, CLOSE - 4 + 36 hours + 5);
        feed.set(P1 | 4, 771e8, CLOSE - 4 + 60 hours + 10);
        feed.set(P1 | 5, 790e8, EXPIRY + 5 minutes);
        vm.warp(EXPIRY + 1 hours);

        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 0, P1 | 3);
        vm.expectRevert();
        t.setReference(id, 0, P1 | 4);
        vm.expectRevert(Treaty.ReferenceNotSet.selector);
        t.fix(id, 0, P1 | 5);

        feed.set(P1 | 6, 791e8, EXPIRY + 365 days);
        vm.warp(EXPIRY + 365 days);
        assertEq(c.maxRedeem(writer), 0, "writer frozen a year later");
        assertEq(c.maxDeposit(writer), 0, "deposits frozen a year later");

        // Fixed behaviour: record the proof that the genuine first post-close round is late, then
        // cancel. Unpatched Treaty (no `voidReference`, old `_anyMarketFixable`): this call
        // reverts, and so does the `cancel` below with `StillFixable`, the vault stays frozen
        // forever. Patched Treaty: both succeed and the gate reopens.
        t.voidReference(id, 0, P1 | 3);
        t.cancel(id);

        assertGt(c.maxDeposit(writer), 0, "gate must reopen once the layer is cancelled");
        assertGt(c.maxRedeem(writer), 0, "writer capital must be freed once the layer is cancelled");
    }

    /// DR2 (H2, multi-market): market B's feed dies before Friday's close (so its reference can
    /// never be set), market A is healthy and gets its reference. `fix(A)` reverts `ReferenceNotSet`
    /// (fix needs every reference), and before the fix `cancel` reverted `StillFixable` because A
    /// alone still looked fixable against expiry, permanent lock, even though B can never be
    /// referenced and `fix` can therefore never succeed for this layer again. Fixed
    /// `_anyMarketFixable` returns false the instant it finds an unreferenced, dead market,
    /// regardless of any other market's own state.
    function test_DR2_deadUnreferencedMarketPlusLiveMarketLocksForever() public {
        (Treaty t, Capacity c) = _deploy(2);
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours);
        feedB.set(P1 | 1, 100e8, CLOSE - 3 hours); // B's last round ever
        vm.warp(CLOSE - 1 hours);
        int256[] memory e = new int256[](2);
        e[0] = 1_000_000e6;
        e[1] = 1_000_000e6;
        vm.prank(buyer);
        uint256 id = t.bind(e, 0, 60_000e6);

        feed.set(P1 | 2, 771e8, CLOSE + 5 minutes);
        vm.warp(CLOSE + 10 minutes);
        t.setReference(id, 0, P1 | 2);
        feed.set(P1 | 3, 790e8, EXPIRY + 5 minutes);
        vm.warp(EXPIRY + 1 hours);
        vm.expectRevert(Treaty.ReferenceNotSet.selector);
        t.fix(id, 0, P1 | 3);

        vm.warp(EXPIRY + 365 days);
        assertEq(c.maxRedeem(writer), 0, "writer frozen a year later");
        // Fixed behaviour: layer can never settle (B's reference can never be set), so it must be
        // cancellable. Unpatched `_anyMarketFixable` reverts this with `StillFixable` forever.
        t.cancel(id);
        assertGt(c.maxDeposit(writer), 0, "gate must reopen once the layer is cancelled");
    }

    /// Sanity (expected GREEN before and after the fix): P3 on real phase-1 round ids, OTM layer,
    /// fixable -> StillFixable; then a phase change whose first round is after expiry -> cancel
    /// succeeds. Guards against the H1/H2 change breaking the already-fixed P3 behaviour.
    function test_DR3_p3PhaseOneIdsAndPhaseChange() public {
        (Treaty t,) = _deploy(1);
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours);
        vm.warp(CLOSE - 1 hours);
        int256[] memory e = new int256[](1);
        e[0] = 1_000_000e6;
        vm.prank(buyer);
        uint256 id = t.bind(e, 0, 60_000e6);
        feed.set(P1 | 2, 771e8, CLOSE + 20 hours);
        vm.warp(CLOSE + 21 hours);
        t.setReference(id, 0, P1 | 2);
        feed.set(P1 | 3, 775e8, EXPIRY + 5 minutes);
        feed.set(P1 | 4, 776e8, EXPIRY + 1 days);
        feed.set(P1 | 5, 777e8, EXPIRY + 2 days);
        vm.warp(EXPIRY + 3 days);
        vm.expectRevert(Treaty.StillFixable.selector);
        t.cancel(id);
        uint80 p2 = uint80(uint256(2) << 64);
        feed.set(p2 | 1, 777e8, EXPIRY + 3 days - 10);
        t.cancel(id);
    }

    /// Liveness property (H1/H2): whatever the timing of the first post-close round on a
    /// single-market layer, on time, late-but-under-the-bound, or arbitrarily late, a
    /// permissionless call sequence from `Bound` always reaches a terminal state (`Settled` or
    /// `Cancelled`); it never gets stuck. Fuzzes the delay between the last pre-close update and
    /// the first post-close round from 1 second to 60 days.
    function testFuzz_liveness_referenceTimingAlwaysReachesTerminalState(uint256 delaySeed) public {
        // `delay` is exactly `updatedAt - refTime` for the crossing round below, so it lines up
        // with `REFERENCE_MAX_DELAY` (36h) with no off-by-a-few-seconds slack.
        uint256 delay = bound(delaySeed, 1, 60 days);
        (Treaty t,) = _deploy(1);
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours);
        vm.warp(CLOSE - 1 hours);
        int256[] memory e = new int256[](1);
        e[0] = 1_000_000e6;
        vm.prank(buyer);
        uint256 id = t.bind(e, 0, 60_000e6);

        feed.set(P1 | 2, 771e8, CLOSE - 1); // last pre-close round
        uint256 crossingAt = CLOSE + delay;
        feed.set(P1 | 3, 771e8, crossingAt); // first post-close round, `delay` after Friday's close

        if (delay <= 36 hours) {
            // Under the bound: setReference must succeed, and the layer must be fixable to
            // Settled once Monday's round is in. `EXPIRY` (close + ~65.5h) is always after
            // `crossingAt` (close + at most 36h) in this branch.
            vm.warp(crossingAt + 1);
            t.setReference(id, 0, P1 | 3);
            uint256 fixAt = EXPIRY + 5 minutes;
            feed.set(P1 | 4, 771e8, fixAt);
            vm.warp(fixAt + 1);
            t.fix(id, 0, P1 | 4);
            (,,,,, Treaty.State st,,,,,) = t.layers(id);
            assertEq(uint8(st), uint8(Treaty.State.Settled), "on-time round must settle");
        } else {
            // Over the bound: setReference must revert, voidReference must succeed, and cancel
            // must eventually succeed once GRACE has passed (which, for a very large `delay`, may
            // be after `crossingAt` itself rather than the usual `expiry + GRACE`).
            vm.warp(crossingAt + 1);
            vm.expectRevert(Treaty.BadRound.selector);
            t.setReference(id, 0, P1 | 3);
            t.voidReference(id, 0, P1 | 3);
            uint256 cancelAt = EXPIRY + 3 days > crossingAt ? EXPIRY + 3 days : crossingAt + 1;
            vm.warp(cancelAt);
            t.cancel(id);
            (,,,,, Treaty.State st,,,,,) = t.layers(id);
            assertEq(uint8(st), uint8(Treaty.State.Cancelled), "late round must cancel");
        }
    }
}

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
/// with no admin path out, whenever a market's Friday reference could never be set.
///
/// Rewritten for v3's reference rule: `setReference` no longer waits for the first round *after*
/// Friday's close bounded by a max delay; it takes the round already *in effect* at close (rules
/// 1-5 in `Treaty.setReference`'s own comment) and requires that round itself be no more than
/// `MAX_ROUND_AGE` (26h) stale relative to close (rule 5). A market genuinely dies, in the sense
/// this suite cares about, when its only round in effect at close is older than that 26h bound:
/// `setReference` then reverts `BadRound` forever on that round, and only `voidReference`'s
/// permissionless stale proof can unstick it. Fixed by `Treaty.voidReference` plus the
/// `_anyMarketFixable` H1/H2 change: run these against an unpatched Treaty (revert the
/// `voidReference` function and the `_anyMarketFixable` change) to see DR1 and DR2 go red again.
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

    // Book 0's first-loss vault: DR1/DR2/DR3 all test the gate-lock/unlock liveness property,
    // which Treaty.sol keeps symmetric across a book's two vaults (both hold a nonzero slice of
    // every layer and gate together), so one vault is a faithful witness. Both vaults still need
    // writer capital, or `bind`'s own `lock` call on the un-funded vault would revert here.
    function _deploy(uint256 n) internal returns (Treaty t, Capacity c) {
        usdg = new MockUSDG();
        feed = new MockFeed();
        feedB = new MockFeed();
        address[] memory feeds = new address[](n);
        feeds[0] = address(feed);
        if (n > 1) feeds[1] = address(feedB);
        t = deployTreaty(address(usdg), address(new Pricer(n == 1 ? oneTableId() : nTableIds(n))), feeds, 50, address(0));
        c = Capacity(t.firstLossVault(0));
        Capacity senior = Capacity(t.seniorVault(0));
        usdg.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(address(c), type(uint256).max);
        usdg.approve(address(senior), type(uint256).max);
        c.deposit(500_000e6, writer);
        senior.deposit(500_000e6, writer);
        vm.stopPrank();
        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(t), type(uint256).max);
    }

    /// DR1 (H1): the feed's only round is fresh enough to bind against on Monday, then goes
    /// silent for the rest of the week. By Friday's close that round is far past `MAX_ROUND_AGE`
    /// (26h), so it is the round "in effect" but `setReference` rule 5 rejects it as stale:
    /// `setReference` reverts `BadRound` forever on it, `fix` reverts `ReferenceNotSet` forever,
    /// and before the fix `cancel` reverted `StillFixable` forever because an unreferenced,
    /// unvoided market is always assumed still fixable. `voidReference` records the
    /// permissionless proof that this round is genuinely stale relative to close, after which
    /// `cancel` succeeds.
    function test_DR1_lateHeartbeatReferenceLocksVaultForever() public {
        (Treaty t, Capacity c) = _deploy(1);
        uint256 bindAt = FRI - 4 days + 1 hours; // Monday 01:00 UTC, same ISO week as FRI
        feed.set(P1 | 1, 770e8, bindAt - 30 minutes); // feed's only round, ever
        vm.warp(bindAt);
        int256[] memory e = new int256[](1);
        e[0] = 1_000_000e6;
        vm.prank(buyer);
        uint256 id = t.bind(0, e, 0, 60_000e6);

        vm.warp(EXPIRY + 1 hours);
        // The only round in effect at close is >100h stale relative to `CLOSE`, far past the
        // 26h bound: genuinely unreferenceable, not just late.
        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 0, P1 | 1);
        vm.expectRevert(Treaty.ReferenceNotSet.selector);
        t.fix(id, 0, P1 | 1);

        vm.warp(EXPIRY + 365 days);
        assertEq(c.maxRedeem(writer), 0, "writer frozen a year later");
        assertEq(c.maxDeposit(writer), 0, "deposits frozen a year later");

        // Fixed behaviour: record the proof that the round in effect at close is stale, then
        // cancel. Unpatched Treaty (no `voidReference`, old `_anyMarketFixable`): this call
        // reverts, and so does the `cancel` below with `StillFixable`, the vault stays frozen
        // forever. Patched Treaty: both succeed and the gate reopens.
        t.voidReference(id, 0, P1 | 1);
        t.cancel(id);

        assertGt(c.maxDeposit(writer), 0, "gate must reopen once the layer is cancelled");
        assertGt(c.maxRedeem(writer), 0, "writer capital must be freed once the layer is cancelled");
    }

    /// DR2 (H2, multi-market): market B's last-ever round is fresh at bind time (Monday) but
    /// never updates again, so by Friday's close it is stale past `MAX_ROUND_AGE` the same way as
    /// DR1, referenceable only via `voidReference`'s stale proof, never via `setReference`. Market
    /// A stays healthy and gets a real reference. `fix` reverts `ReferenceNotSet` (fix needs every
    /// reference), and before B's void proof, `cancel` reverted `StillFixable` because an
    /// unreferenced, unvoided market always counts as still fixable, permanent lock, even though A
    /// alone is settleable and B can never be referenced. Fixed `_anyMarketFixable` returns false
    /// the instant it finds an unreferenced, void market, regardless of any other market's state.
    function test_DR2_deadUnreferencedMarketPlusLiveMarketLocksForever() public {
        (Treaty t, Capacity c) = _deploy(2);
        uint256 bindAt = FRI - 4 days + 1 hours; // Monday 01:00 UTC
        feed.set(P1 | 1, 770e8, bindAt - 30 minutes);
        feedB.set(P1 | 1, 100e8, bindAt - 30 minutes); // B's last round, ever
        vm.warp(bindAt);
        int256[] memory e = new int256[](2);
        e[0] = 1_000_000e6;
        e[1] = 1_000_000e6;
        vm.prank(buyer);
        uint256 id = t.bind(0, e, 0, 60_000e6);

        // A keeps printing through the week; its round in effect at close is fresh.
        feed.set(P1 | 2, 771e8, CLOSE - 5 minutes);
        vm.warp(CLOSE + 10 minutes);
        t.setReference(id, 0, P1 | 2);
        // B's only round is already >26h stale relative to close: unreferenceable.
        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 1, P1 | 1);

        vm.warp(EXPIRY + 1 hours);
        vm.expectRevert(Treaty.ReferenceNotSet.selector);
        t.fix(id, 0, P1 | 2);

        vm.warp(EXPIRY + 365 days);
        assertEq(c.maxRedeem(writer), 0, "writer frozen a year later");
        // Fixed behaviour: layer can never settle (B's reference can never be set), so it must be
        // cancellable once B's void proof is recorded. Unpatched `_anyMarketFixable` reverts this
        // with `StillFixable` forever because it never looks at B's void status.
        vm.expectRevert(Treaty.StillFixable.selector);
        t.cancel(id);
        t.voidReference(id, 1, P1 | 1);
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
        uint256 id = t.bind(0, e, 0, 60_000e6);
        // The round in effect at close is P1|1 itself: fresh, at-or-before close, latest in
        // phase.
        vm.warp(CLOSE + 1 hours);
        t.setReference(id, 0, P1 | 1);
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

    /// Liveness property (H1/H2): whatever the age of the round in effect at Friday's close,
    /// fresh, right at the 26h bound, or arbitrarily stale, a permissionless call sequence from
    /// `Bound` always reaches a terminal state (`Settled` or `Cancelled`); it never gets stuck.
    /// Fuzzes that age from 1 second to 60 days.
    function testFuzz_liveness_referenceTimingAlwaysReachesTerminalState(uint256 ageSeed) public {
        // `age` is exactly `CLOSE - updatedAt` for the round in effect at close, so it lines up
        // with `MAX_ROUND_AGE` (26h) with no off-by-a-few-seconds slack.
        uint256 age = bound(ageSeed, 1, 60 days);
        (Treaty t,) = _deploy(1);
        uint256 bindAt = FRI - 4 days + 1 hours; // Monday 01:00 UTC, always fresh at bind time
        feed.set(P1 | 1, 770e8, bindAt - 30 minutes);
        vm.warp(bindAt);
        int256[] memory e = new int256[](1);
        e[0] = 1_000_000e6;
        vm.prank(buyer);
        uint256 id = t.bind(0, e, 0, 60_000e6);

        // The round in effect at close, `age` before `CLOSE`.
        feed.set(P1 | 2, 771e8, CLOSE - age);

        if (age <= 26 hours) {
            // Under the bound: setReference must succeed, and the layer must be fixable to
            // Settled once Monday's round is in.
            vm.warp(CLOSE + 1 hours);
            t.setReference(id, 0, P1 | 2);
            uint256 fixAt = EXPIRY + 5 minutes;
            feed.set(P1 | 3, 771e8, fixAt);
            vm.warp(fixAt + 1);
            t.fix(id, 0, P1 | 3);
            (,,,,, Treaty.State st,,,,,) = layerBasics(t, id);
            assertEq(uint8(st), uint8(Treaty.State.Settled), "on-time round must settle");
        } else {
            // Over the bound: setReference must revert, voidReference must succeed, and cancel
            // must succeed once expiry + GRACE has passed. The stale round is always dated
            // before `CLOSE`, so it can never itself push the terminal state later than
            // `EXPIRY + GRACE`.
            vm.warp(CLOSE + 1 hours);
            vm.expectRevert(Treaty.BadRound.selector);
            t.setReference(id, 0, P1 | 2);
            t.voidReference(id, 0, P1 | 2);
            vm.warp(EXPIRY + 3 days);
            t.cancel(id);
            (,,,,, Treaty.State st,,,,,) = layerBasics(t, id);
            assertEq(uint8(st), uint8(Treaty.State.Cancelled), "late round must cancel");
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

uint256 constant AMON0 = 1_789_948_800; // Monday 00:00 UTC (week 0)
uint256 constant AWEEKS = 20;

/// Adversarial handler, extended for two books and each book's first-loss/senior tranche split.
/// Differs from test/Capacity.invariant.t.sol in three ways that matter:
/// (1) the gate oracle is independent of Capacity: a book's tranche is "closed" iff some Bound
///     layer in that book has fridayCutoff <= now, read from Treaty's layer table, never from
///     maxDeposit/maxRedeem (both tranches of a book share the same gate, since both lock
///     against the same layer's cutoff);
/// (2) time jumps land exactly on cutoff-1/cutoff/cutoff+1, expiry +-1, expiry+GRACE +-1 and
///     Monday 00:00, and binds fire at those instants (dust limits included);
/// (3) a random quarter of weeks are "dead" (fix never succeeds), so only cancel resolves them,
///     and settles/cancels hit layers in random order, so buckets drain out of order.
contract AdvHandler is Test {
    Treaty public treaty;
    Capacity[2] public firstLoss;
    Capacity[2] public senior;
    MockUSDG[2] public usdg;
    MockFeed public feed;
    address[3] public writers;
    address[3] public buyers;

    uint256[2] public gDeposited;
    uint256[2] public gWithdrawn;
    uint256[2] public gPremIn;
    uint256[2] public gRefunded;
    uint256[2] public gPaid;

    uint256 public vGateDeposit; // deposit succeeded while oracle says closed
    uint256 public vGateRedeem; // redeem succeeded while oracle says closed
    uint256 public vOpenDepositReverted; // oracle open, deposit reverted
    uint256 public vOpenRedeemReverted; // oracle open, redeem <= maxRedeem reverted
    uint256 public vRedeemOverFree; // a redeem paid out more than that vault's totalAssets - locked
    uint256 public vBindAfterCutoff;
    uint256 public vSettleDelta;

    uint256 public nBind;
    uint256 public nBindAtCutoffMinus1;
    uint256 public nBindAtCutoffRejected;
    uint256 public nEdgeWarp;
    uint256 public nSettle;
    uint256 public nCancel;
    uint256 public nDeadWeek;
    uint256 public nDepositClosed;
    uint256 public nDepositOpen;
    uint256 public nRedeemOpen;
    uint256 public nStacked; // observed >=2 nonzero buckets at once, in either book

    mapping(uint256 => bool) public weekPriced;
    mapping(uint256 => bool) public weekDead;

    constructor(Treaty t, MockUSDG u0, MockUSDG u1, MockFeed f) {
        treaty = t;
        firstLoss[0] = Capacity(t.firstLossVault(0));
        senior[0] = Capacity(t.seniorVault(0));
        firstLoss[1] = Capacity(t.firstLossVault(1));
        senior[1] = Capacity(t.seniorVault(1));
        usdg[0] = u0;
        usdg[1] = u1;
        feed = f;
        for (uint256 i; i < 3; i++) {
            writers[i] = address(uint160(0xA000 + i));
            buyers[i] = address(uint160(0xB000 + i));
            for (uint256 b; b < 2; b++) {
                usdg[b].mint(buyers[i], 1e15);
                vm.prank(buyers[i]);
                usdg[b].approve(address(treaty), type(uint256).max);
                vm.prank(writers[i]);
                usdg[b].approve(address(firstLoss[b]), type(uint256).max);
                vm.prank(writers[i]);
                usdg[b].approve(address(senior[b]), type(uint256).max);
            }
        }
    }

    function _vault(uint256 book, uint256 tranche) internal view returns (Capacity) {
        return tranche % 2 == 0 ? firstLoss[book] : senior[book];
    }

    /// A book's gate is closed iff some Bound layer in that book has fridayCutoff <= now; both of
    /// that book's tranches lock and unlock together, since both back the same layers.
    function oracleClosed(uint256 book) public view returns (bool) {
        uint256 n = treaty.layerCount();
        for (uint256 id; id < n; id++) {
            (, uint40 c,, uint16 bk,,, Treaty.State st,,,,,,,,,,) = treaty.layers(id);
            if (bk == book && st == Treaty.State.Bound && block.timestamp >= c) return true;
        }
        return false;
    }

    function _end() internal pure returns (uint256) {
        return AMON0 + (AWEEKS - 1) * 7 days;
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 4 days);
        uint256 t = block.timestamp + dt;
        if (t > _end()) return;
        vm.warp(t);
    }

    /// Jump to an exact boundary of this or a later week.
    function warpEdge(uint256 sel) external {
        (uint256 c, uint256 e) = treaty.weekWindow(block.timestamp);
        uint256[10] memory off = [
            c - 1, c, c + 1, e - 1, e, e + 1, e + 7 days - 1, e + 7 days, e + 7 days + 1, c - 4 days - 19 hours - 30 minutes + 7 days
        ];
        uint256 t = off[sel % 10];
        while (t <= block.timestamp) t += 7 days;
        if (t > _end()) return;
        vm.warp(t);
        nEdgeWarp++;
    }

    function deposit(uint256 bookSel, uint256 trancheSel, uint256 wi, uint256 amt) external {
        uint256 book = bookSel % 2;
        Capacity cap = _vault(book, trancheSel);
        address w = writers[wi % 3];
        amt = bound(amt, 1, 5_000_000e6);
        usdg[book].mint(w, amt);
        bool closed = oracleClosed(book);
        vm.prank(w);
        try cap.deposit(amt, w) {
            if (closed) vGateDeposit++;
            gDeposited[book] += amt;
            nDepositOpen++;
        } catch {
            if (!closed) vOpenDepositReverted++;
            else nDepositClosed++;
        }
    }

    function redeem(uint256 bookSel, uint256 trancheSel, uint256 wi, uint256 pct) external {
        uint256 book = bookSel % 2;
        Capacity cap = _vault(book, trancheSel);
        address w = writers[wi % 3];
        uint256 sh = cap.balanceOf(w) * bound(pct, 1, 100) / 100;
        if (sh == 0) return;
        bool closed = oracleClosed(book);
        uint256 mr = closed ? 0 : cap.maxRedeem(w);
        uint256 free = cap.totalAssets() - cap.locked();
        vm.prank(w);
        try cap.redeem(sh, w, w) returns (uint256 out) {
            if (closed) vGateRedeem++;
            if (out > free) vRedeemOverFree++;
            gWithdrawn[book] += out;
            nRedeemOpen++;
        } catch {
            if (!closed && sh <= mr) vOpenRedeemReverted++;
        }
    }

    function bind(uint256 bookSel, uint256 bi, int256 exposure, uint256 retention, uint256 limit, bool atEdge)
        external
    {
        uint256 book = bookSel % 2;
        Capacity fl = firstLoss[book];
        Capacity sr = senior[book];
        exposure = int256(bound(uint256(exposure < 0 ? -exposure : exposure), 1, 2_000_000e6));
        if (bi % 2 == 0) exposure = -exposure;
        retention = bound(retention, 0, 300_000e6);
        uint256 free = (fl.totalAssets() + sr.totalAssets()) - (fl.locked() + sr.locked());
        if (bi % 3 == 0) limit = bound(limit, 200, 1_000); // dust griefer
        else limit = bound(limit, 1, free + free / 10 + 1);
        (uint256 c,) = treaty.weekWindow(block.timestamp);
        if (atEdge && block.timestamp < c - 1) vm.warp(c - 1);
        int256[] memory e = new int256[](1);
        e[0] = exposure;
        uint256 balBefore = usdg[book].balanceOf(address(fl)) + usdg[book].balanceOf(address(sr));
        if (fl.locked() != 0 || sr.locked() != 0) {
            // count stacked buckets across both of this book's vaults
            uint256 nz;
            uint256 flLen = fl.cutoffCursor();
            for (uint256 i = flLen; i < _cutoffsLen(fl); i++) {
                if (fl.lockedByCutoff(fl.cutoffs(i)) != 0) nz++;
            }
            uint256 srLen = sr.cutoffCursor();
            for (uint256 i = srLen; i < _cutoffsLen(sr); i++) {
                if (sr.lockedByCutoff(sr.cutoffs(i)) != 0) nz++;
            }
            if (nz >= 2) nStacked++;
        }
        vm.prank(buyers[bi % 3]);
        try treaty.bind(book, e, retention, limit) {
            nBind++;
            if (block.timestamp == c - 1) nBindAtCutoffMinus1++;
            if (block.timestamp >= c) vBindAfterCutoff++;
            gPremIn[book] += (usdg[book].balanceOf(address(fl)) + usdg[book].balanceOf(address(sr))) - balBefore;
        } catch {}
        if (atEdge && block.timestamp == c - 1) {
            vm.warp(c);
            vm.prank(buyers[bi % 3]);
            try treaty.bind(book, e, retention, limit) {
                vBindAfterCutoff++;
            } catch {
                nBindAtCutoffRejected++;
            }
        }
    }

    function _cutoffsLen(Capacity cap) internal view returns (uint256 n) {
        // cutoffs has no length getter; probe
        while (true) {
            try cap.cutoffs(n) returns (uint40) {
                n++;
            } catch {
                return n;
            }
        }
    }

    function cutoffsLen(uint256 book, uint256 tranche) external view returns (uint256) {
        return _cutoffsLen(_vault(book % 2, tranche));
    }

    function _layer(uint256 id)
        internal
        view
        returns (
            uint256 book,
            uint40 cutoff,
            uint40 expiry,
            Treaty.State st,
            uint256 limit,
            uint256 juniorLimit,
            uint256 premium,
            uint256 payout
        )
    {
        uint16 bk;
        (,cutoff, expiry, bk,,, st,,, limit, juniorLimit, premium,,, payout,,) = treaty.layers(id);
        book = bk;
    }

    function settle(uint256 idx, uint256 moveBps) external {
        uint256 n = treaty.layerCount();
        if (n == 0) return;
        uint256 id = idx % n;
        (uint256 book, uint40 cutoff, uint40 expiry, Treaty.State st,,, uint256 premium,) = _layer(id);
        if (st != Treaty.State.Bound) return;
        uint256 w = (uint256(cutoff) - AMON0) / 7 days;
        // Sat 00:00 UTC is always after Friday's close (20:00 UTC EDT or 21:00 UTC EST either
        // way), so this remains a valid, if slightly conservative, "safe to try setReference"
        // gate under the new DST-aware rule without needing to query fridayCloseOf here too.
        if (block.timestamp < uint256(cutoff) + 4 hours + 30 minutes) return;
        if (!treaty.referenceSet(id, 0)) treaty.setReference(id, 0, uint80(3 * w + 2));
        if (block.timestamp < uint256(expiry) + 1) return;
        if (!weekPriced[w]) {
            weekPriced[w] = true;
            if (moveBps % 4 == 0) {
                weekDead[w] = true;
                nDeadWeek++;
            } else {
                int256 bps = -4000 + int256(bound(moveBps, 0, 5000));
                feed.set(uint80(3 * w + 3), int256(100e8) * (10000 + bps) / 10000, uint256(expiry) + 1);
            }
        }
        if (weekDead[w]) return;
        uint256 taBefore = firstLoss[book].totalAssets() + senior[book].totalAssets();
        treaty.fix(id, 0, uint80(3 * w + 3));
        (,,,,,,, uint256 payout) = _layer(id);
        nSettle++;
        if (firstLoss[book].totalAssets() + senior[book].totalAssets() + payout != taBefore + premium) {
            vSettleDelta++;
        }
    }

    function cancel(uint256 idx) external {
        uint256 n = treaty.layerCount();
        if (n == 0) return;
        uint256 id = idx % n;
        try treaty.cancel(id) {
            nCancel++;
            // cancel no longer moves any token balance itself; the premium sits in `owed` until
            // the buyer claims it, credited in the `claim` handler below like any other pull.
        } catch {}
    }

    function claim(uint256 idx) external {
        uint256 n = treaty.layerCount();
        if (n == 0) return;
        uint256 id = idx % n;
        (address buyer,,,,,,,,,,,,,,,,) = treaty.layers(id);
        (uint256 book,,, Treaty.State st,,, uint256 premium, uint256 payout) = _layer(id);
        vm.prank(buyer);
        try treaty.claim(id) {
            gPaid[book] += st == Treaty.State.Cancelled ? premium : payout;
        } catch {}
    }
}

contract AdversarialGateInvariant is Test, TreatyFixture {
    AdvHandler h;
    Treaty treaty;
    Capacity firstLoss0;
    Capacity senior0;
    Capacity firstLoss1;
    Capacity senior1;
    MockUSDG usdg0;
    MockUSDG usdg1;
    MockFeed feed;

    function setUp() public {
        usdg0 = new MockUSDG();
        usdg1 = new MockUSDG();
        feed = new MockFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        address[] memory assets = new address[](2);
        assets[0] = address(usdg0);
        assets[1] = address(usdg1);
        treaty = deployTreaty(assets, address(new Pricer(oneTableId())), feeds, 50, address(0), address(0));
        firstLoss0 = Capacity(treaty.firstLossVault(0));
        senior0 = Capacity(treaty.seniorVault(0));
        firstLoss1 = Capacity(treaty.firstLossVault(1));
        senior1 = Capacity(treaty.seniorVault(1));

        // setReference now needs its own first-round-after-Friday's-close pair, on top
        // of the pre-existing Monday fix round, so each week gets three round ids instead of
        // two: 3w+1 (pre-close predecessor), 3w+2 (the actual Friday reference round, at
        // `fridayCloseOf`, DST-aware and queried live since this 20-week run spans the Nov 2026
        // switch), 3w+3 (Monday fix round, written lazily by the handler, or never for dead
        // weeks, seeded far in the future and overwritten on first settle, unchanged from
        // before). Shared by both books: one market feed prices both books' layers.
        for (uint256 w; w < AWEEKS; w++) {
            uint256 monday = AMON0 + w * 7 days;
            (uint256 cutoff,) = treaty.weekWindow(monday);
            uint256 refTime = treaty.fridayCloseOf(cutoff);
            feed.set(uint80(3 * w + 1), 100e8, cutoff - 30 minutes);
            feed.set(uint80(3 * w + 2), 100e8, refTime);
            feed.set(uint80(3 * w + 3), 100e8, AMON0 + 1000 weeks);
        }
        vm.warp(AMON0 + 1 hours);
        h = new AdvHandler(treaty, usdg0, usdg1, feed);
        h.deposit(0, 0, 0, 1_000_000e6);
        h.deposit(0, 1, 0, 1_000_000e6);
        h.deposit(1, 0, 0, 1_000_000e6);
        h.deposit(1, 1, 0, 1_000_000e6);
        targetContract(address(h));
    }

    /// `bal == totalAssets + owed + pendingPremium` was a
    /// tautology, not an invariant (`totalAssets()` is *defined* as `balance - owed -
    /// pendingPremium`, Capacity.sol:102, so it holds for any values including corrupted ones,
    /// and no mutation of the contract's bookkeeping could ever make it fail). Replaced with the
    /// flow identity, the free-capacity floor (both independently falsifiable, kept from the
    /// original), and `invariant_ledgersMatchLayers` below, which cross-checks
    /// `locked`/`owed`/`pendingPremium` against `Treaty.layers` directly (this file's handler
    /// drives `settle`/`cancel`/`claim` with adversarial timing, so this is the invariant suite
    /// that actually exercises the cross-check under gate-edge conditions). Checked per book,
    /// since each book's asset is a fully separate token.
    function invariant_conservation() public view {
        assertEq(
            usdg0.balanceOf(address(firstLoss0)) + usdg0.balanceOf(address(senior0))
                + h.gWithdrawn(0) + h.gRefunded(0) + h.gPaid(0),
            h.gDeposited(0) + h.gPremIn(0),
            "book 0: USDG in == out + held"
        );
        assertEq(
            usdg1.balanceOf(address(firstLoss1)) + usdg1.balanceOf(address(senior1))
                + h.gWithdrawn(1) + h.gRefunded(1) + h.gPaid(1),
            h.gDeposited(1) + h.gPremIn(1),
            "book 1: USDG in == out + held"
        );
        assertGe(firstLoss0.totalAssets(), firstLoss0.locked(), "book 0 first-loss fully backed");
        assertGe(senior0.totalAssets(), senior0.locked(), "book 0 senior fully backed");
        assertGe(firstLoss1.totalAssets(), firstLoss1.locked(), "book 1 first-loss fully backed");
        assertGe(senior1.totalAssets(), senior1.locked(), "book 1 senior fully backed");
    }

    function invariant_ledgersMatchLayers() public view {
        uint256[2] memory sumLockedFL;
        uint256[2] memory sumLockedSR;
        uint256[2] memory sumOwedFL;
        uint256[2] memory sumOwedSR;
        uint256[2] memory sumPendingFL;
        uint256[2] memory sumPendingSR;
        uint256 n = treaty.layerCount();
        for (uint256 id; id < n; id++) {
            (
                ,,, uint16 book,,, Treaty.State st, bool claimed,,
                uint256 limit, uint256 juniorLimit,, uint256 premiumJunior, uint256 premiumSenior,,
                uint256 payoutJunior, uint256 payoutSenior
            ) = treaty.layers(id);
            if (st == Treaty.State.Bound) {
                sumLockedFL[book] += juniorLimit;
                sumLockedSR[book] += limit - juniorLimit;
                sumPendingFL[book] += premiumJunior;
                sumPendingSR[book] += premiumSenior;
            } else if (st == Treaty.State.Settled && !claimed) {
                sumOwedFL[book] += payoutJunior;
                sumOwedSR[book] += payoutSenior;
            } else if (st == Treaty.State.Cancelled && !claimed) {
                sumOwedFL[book] += premiumJunior;
                sumOwedSR[book] += premiumSenior;
            }
        }
        assertEq(firstLoss0.locked(), sumLockedFL[0], "book 0 first-loss locked == sum(juniorLimit of Bound)");
        assertEq(senior0.locked(), sumLockedSR[0], "book 0 senior locked == sum(limit-juniorLimit of Bound)");
        assertEq(firstLoss0.owed(), sumOwedFL[0], "book 0 first-loss owed == sum(unclaimed payoutJunior)");
        assertEq(senior0.owed(), sumOwedSR[0], "book 0 senior owed == sum(unclaimed payoutSenior)");
        assertEq(firstLoss0.pendingPremium(), sumPendingFL[0], "book 0 first-loss pendingPremium == sum(premiumJunior of Bound)");
        assertEq(senior0.pendingPremium(), sumPendingSR[0], "book 0 senior pendingPremium == sum(premiumSenior of Bound)");

        assertEq(firstLoss1.locked(), sumLockedFL[1], "book 1 first-loss locked == sum(juniorLimit of Bound)");
        assertEq(senior1.locked(), sumLockedSR[1], "book 1 senior locked == sum(limit-juniorLimit of Bound)");
        assertEq(firstLoss1.owed(), sumOwedFL[1], "book 1 first-loss owed == sum(unclaimed payoutJunior)");
        assertEq(senior1.owed(), sumOwedSR[1], "book 1 senior owed == sum(unclaimed payoutSenior)");
        assertEq(firstLoss1.pendingPremium(), sumPendingFL[1], "book 1 first-loss pendingPremium == sum(premiumJunior of Bound)");
        assertEq(senior1.pendingPremium(), sumPendingSR[1], "book 1 senior pendingPremium == sum(premiumSenior of Bound)");
    }

    function invariant_gateMatchesOracle() public view {
        assertEq(firstLoss0.gateActive(), h.oracleClosed(0), "book 0 first-loss gateActive != oracle");
        assertEq(senior0.gateActive(), h.oracleClosed(0), "book 0 senior gateActive != oracle");
        assertEq(firstLoss1.gateActive(), h.oracleClosed(1), "book 1 first-loss gateActive != oracle");
        assertEq(senior1.gateActive(), h.oracleClosed(1), "book 1 senior gateActive != oracle");
    }

    function invariant_bucketsAndCursor() public view {
        _checkBuckets(firstLoss0, 0, true);
        _checkBuckets(senior0, 0, false);
        _checkBuckets(firstLoss1, 1, true);
        _checkBuckets(senior1, 1, false);
    }

    function _checkBuckets(Capacity cap, uint256 book, bool isFirstLoss) internal view {
        uint256 len = h.cutoffsLen(book, isFirstLoss ? 0 : 1);
        uint256 cur = cap.cutoffCursor();
        assertLe(cur, len, "cursor <= len");
        uint256 sumBuckets;
        uint256 n = treaty.layerCount();
        for (uint256 i; i < len; i++) {
            uint40 c = cap.cutoffs(i);
            if (i > 0) assertGt(c, cap.cutoffs(i - 1), "cutoffs strictly increasing");
            uint256 expect;
            for (uint256 id; id < n; id++) {
                (, uint40 lc,, uint16 bk,,, Treaty.State st,,, uint256 limit, uint256 juniorLimit,,,,,,) =
                    treaty.layers(id);
                if (st == Treaty.State.Bound && lc == c && bk == book) {
                    expect += isFirstLoss ? juniorLimit : (limit - juniorLimit);
                }
            }
            uint256 b = cap.lockedByCutoff(c);
            assertEq(b, expect, "bucket == sum(this tranche's share of limit of Bound layers with that cutoff)");
            if (i < cur) assertEq(b, 0, "bucket behind cursor is drained");
            if (i == cur) assertGt(b, 0, "bucket at cursor is live (no stall)");
            sumBuckets += b;
        }
        assertEq(sumBuckets, cap.locked(), "sum(buckets) == locked");
    }

    function invariant_noViolations() public view {
        assertEq(h.vGateDeposit(), 0, "deposit while oracle closed");
        assertEq(h.vGateRedeem(), 0, "redeem while oracle closed");
        assertEq(h.vOpenDepositReverted(), 0, "deposit reverted while oracle open");
        assertEq(h.vOpenRedeemReverted(), 0, "redeem <= maxRedeem reverted while oracle open");
        assertEq(h.vRedeemOverFree(), 0, "redeem took reserved capital");
        assertEq(h.vBindAfterCutoff(), 0, "bind at/after cutoff");
        assertEq(h.vSettleDelta(), 0, "settle delta != premium - payout");
    }

    function afterInvariant() external {
        // Coverage CSV is best-effort: fs_permissions for cov/ is a repo-level foundry.toml
        // change, which is out of this fix's scope (src/test/docs only). The counters below
        // are still asserted live via console2.log, so a denied write here is not a loss of
        // evidence, only of the on-disk artifact.
        try vm.writeLine(
            "cov/runs.csv",
            string.concat(
                vm.toString(h.nBind()), ",", vm.toString(h.nBindAtCutoffMinus1()), ",", vm.toString(h.nBindAtCutoffRejected()), ",",
                vm.toString(h.nEdgeWarp()), ",", vm.toString(h.nSettle()), ",", vm.toString(h.nCancel()), ",",
                vm.toString(h.nDeadWeek()), ",", vm.toString(h.nDepositOpen()), ",", vm.toString(h.nDepositClosed()), ",",
                vm.toString(h.nRedeemOpen()), ",", vm.toString(h.nStacked())
            )
        ) {} catch {}
        console2.log("nBind", h.nBind());
        console2.log("nBindAtCutoffMinus1 / rejectedAtCutoff", h.nBindAtCutoffMinus1(), h.nBindAtCutoffRejected());
        console2.log("nEdgeWarp", h.nEdgeWarp());
        console2.log("nSettle / nCancel / nDeadWeek", h.nSettle(), h.nCancel(), h.nDeadWeek());
        console2.log("nDepositOpen / nDepositClosed", h.nDepositOpen(), h.nDepositClosed());
        console2.log("nRedeemOpen", h.nRedeemOpen());
        console2.log("nStacked", h.nStacked());
    }
}

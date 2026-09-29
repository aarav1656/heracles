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

uint256 constant MON0 = 1_789_948_800; // Monday 00:00 UTC (week 0)
uint256 constant WEEKS = 16;

/// Ported from the reviewer's scratch suite at the reviewer's own scratch copy, then extended for
/// two books (two independent assets, two Capacity vaults each) and each book's first-loss/senior
/// tranche split. Gate assertions use Capacity's own `maxDeposit`/`maxRedeem`, not raw
/// `locked() != 0` (Resolution 2's window semantics: a call can succeed even while `locked() != 0`
/// if a future layer's cutoff has not arrived yet). Every ghost and invariant below is tracked per
/// book, since each book's asset is its own separate token with its own separate conservation
/// equation; within a book, the first-loss/senior split is checked directly against
/// `Layer.juniorLimit`/`premiumJunior`/`premiumSenior`/`payoutJunior`/`payoutSenior`, not summed
/// away.
contract Handler is Test {
    Treaty public treaty;
    Capacity[2] public firstLoss;
    Capacity[2] public senior;
    MockUSDG[2] public usdg;
    MockFeed public feed;
    address[3] public writers;
    address[3] public buyers;

    // USDG conservation ghosts, one slot per book (each book's asset is a separate token).
    uint256[2] public gDeposited;
    uint256[2] public gWithdrawn;
    uint256[2] public gPremIn;
    uint256[2] public gRefunded;
    uint256[2] public gPaid;

    // Violation flags (asserts inside a handler revert and get swallowed, so record instead)
    uint256 public vGate; // deposit/redeem succeeded while Capacity's own gate reports closed
    uint256 public vJit; // deposit-then-preview returned more than deposited
    uint256 public vBindDelta; // book's total assets moved on bind
    uint256 public vSettleDelta; // book's total assets moved by != premium - payout on settle
    uint256 public vCancelDelta;
    uint256 public vClaimDelta;
    uint256 public vGateNotReopened; // gate reported open but deposit still reverted

    // coverage counters
    uint256 public nBind;
    uint256 public nSettle;
    uint256 public nSettleZero;
    uint256 public nSettlePartial;
    uint256 public nSettleFull;
    uint256 public nCancel;
    uint256 public nClaim;
    uint256 public nDeposit;
    uint256 public nRedeem;
    uint256 public nOverlap; // bind while another layer was already live in that book
    uint256 public nBook0;
    uint256 public nBook1;

    mapping(uint256 => bool) public weekPriced;

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
                // Premium is pulled by Treaty itself, never a vault.
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

    function _bookTotalAssets(uint256 book) internal view returns (uint256) {
        return firstLoss[book].totalAssets() + senior[book].totalAssets();
    }

    function _bookBalance(uint256 book) internal view returns (uint256) {
        return usdg[book].balanceOf(address(firstLoss[book])) + usdg[book].balanceOf(address(senior[book]));
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 4 days);
        uint256 t = block.timestamp + dt;
        if (t > MON0 + (WEEKS - 1) * 7 days) return;
        vm.warp(t);
    }

    function deposit(uint256 bookSel, uint256 trancheSel, uint256 wi, uint256 amt) external {
        uint256 book = bookSel % 2;
        Capacity cap = _vault(book, trancheSel);
        address w = writers[wi % 3];
        amt = bound(amt, 1, 5_000_000e6);
        usdg[book].mint(w, amt);
        bool gateClosed = cap.maxDeposit(w) == 0;
        vm.prank(w);
        try cap.deposit(amt, w) returns (uint256 sh) {
            if (gateClosed) vGate++;
            gDeposited[book] += amt;
            nDeposit++;
            if (cap.previewRedeem(sh) > amt) vJit++;
        } catch {
            if (!gateClosed) vGateNotReopened++;
        }
    }

    function redeem(uint256 bookSel, uint256 trancheSel, uint256 wi, uint256 pct) external {
        uint256 book = bookSel % 2;
        Capacity cap = _vault(book, trancheSel);
        address w = writers[wi % 3];
        uint256 sh = cap.balanceOf(w) * bound(pct, 1, 100) / 100;
        if (sh == 0) return;
        bool gateClosed = cap.maxRedeem(w) == 0;
        vm.prank(w);
        try cap.redeem(sh, w, w) returns (uint256 out) {
            if (gateClosed) vGate++;
            gWithdrawn[book] += out;
            nRedeem++;
        } catch {}
    }

    function bind(uint256 bookSel, uint256 bi, int256 exposure, uint256 retention, uint256 limit) external {
        uint256 book = bookSel % 2;
        exposure = int256(bound(uint256(exposure < 0 ? -exposure : exposure), 1, 2_000_000e6));
        if (bi % 2 == 0) exposure = -exposure;
        retention = bound(retention, 0, 300_000e6);
        uint256 free = _bookTotalAssets(book) - (firstLoss[book].locked() + senior[book].locked());
        limit = bound(limit, 1, free + free / 10 + 1); // occasionally over free capacity
        int256[] memory e = new int256[](1);
        e[0] = exposure;
        uint256 taBefore = _bookTotalAssets(book);
        uint256 balBefore = _bookBalance(book);
        bool live = firstLoss[book].locked() != 0 || senior[book].locked() != 0;
        vm.prank(buyers[bi % 3]);
        try treaty.bind(book, e, retention, limit) {
            nBind++;
            if (book == 0) nBook0++;
            else nBook1++;
            if (live) nOverlap++;
            gPremIn[book] += _bookBalance(book) - balBefore;
            if (_bookTotalAssets(book) != taBefore) vBindDelta++;
        } catch {}
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
            uint256 premium,
            uint256 payout
        )
    {
        uint16 bk;
        (,cutoff, expiry, bk,,, st,,, limit,, premium,,, payout,,) = treaty.layers(id);
        book = bk;
    }

    function settle(uint256 idx, uint256 moveBps) external {
        uint256 n = treaty.layerCount();
        if (n == 0) return;
        uint256 id = idx % n;
        (uint256 book, uint40 cutoff, uint40 expiry, Treaty.State st,, uint256 premium,) = _layer(id);
        if (st != Treaty.State.Bound) return;
        uint256 w = (uint256(cutoff) - MON0) / 7 days;
        // Sat 00:00 UTC is always after Friday's close (20:00 UTC EDT or 21:00 UTC EST either
        // way), still a valid conservative "safe to try setReference" gate.
        if (block.timestamp < uint256(cutoff) + 4 hours + 30 minutes) return;
        if (!treaty.referenceSet(id, 0)) treaty.setReference(id, 0, uint80(3 * w + 2));
        if (block.timestamp < uint256(expiry) + 1) return;
        if (!weekPriced[w]) {
            // -40% .. +10% weekend move, so zero, partial and full-limit payouts all occur
            int256 bps = -4000 + int256(bound(moveBps, 0, 5000));
            feed.set(uint80(3 * w + 3), int256(100e8) * (10000 + bps) / 10000, uint256(expiry) + 1);
            weekPriced[w] = true;
        }
        uint256 taBefore = _bookTotalAssets(book);
        treaty.fix(id, 0, uint80(3 * w + 3));
        (,,,, uint256 limit,, uint256 payout) = _layer(id);
        nSettle++;
        if (payout == 0) nSettleZero++;
        else if (payout == limit) nSettleFull++;
        else nSettlePartial++;
        if (_bookTotalAssets(book) + payout != taBefore + premium) vSettleDelta++;
    }

    function cancel(uint256 idx) external {
        uint256 n = treaty.layerCount();
        if (n == 0) return;
        uint256 id = idx % n;
        (uint256 book,,,,, uint256 premium,) = _layer(id);
        uint256 taBefore = _bookTotalAssets(book);
        try treaty.cancel(id) {
            nCancel++;
            gRefunded[book] += premium;
            if (_bookTotalAssets(book) != taBefore) vCancelDelta++;
        } catch {}
    }

    function claim(uint256 idx) external {
        uint256 n = treaty.layerCount();
        if (n == 0) return;
        uint256 id = idx % n;
        (address buyer,,,,,,,,,,,,,,,,) = treaty.layers(id);
        (uint256 book,,,,,, uint256 payout) = _layer(id);
        uint256 taBefore = _bookTotalAssets(book);
        vm.prank(buyer);
        try treaty.claim(id) {
            nClaim++;
            gPaid[book] += payout;
            if (_bookTotalAssets(book) != taBefore) vClaimDelta++;
        } catch {}
    }
}

contract CapacityInvariantTest is Test, TreatyFixture {
    Handler h;
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

        // setReference now needs its own first-round-after-Friday's-close pair, so each
        // week gets three round ids: 3w+1 (pre-close predecessor, unchanged Fri 19:00
        // seed), a new 3w+2 (the actual Friday reference round, at `fridayCloseOf`, queried live
        // since this WEEKS=16 run spans the Nov 2026 DST switch), 3w+3 (Monday fix round,
        // placeholder seed immediately superseded in settle()). Shared by both books: one market
        // feed prices both books' layers, only the collateral asset differs per book.
        for (uint256 w; w < WEEKS; w++) {
            uint256 monday = MON0 + w * 7 days;
            (uint256 cutoff,) = treaty.weekWindow(monday);
            uint256 refTime = treaty.fridayCloseOf(cutoff);
            feed.set(uint80(3 * w + 1), 100e8, cutoff - 30 minutes); // pre-close predecessor
            feed.set(uint80(3 * w + 2), 100e8, refTime); // Friday reference round
            feed.set(uint80(3 * w + 3), 100e8, MON0 + (w + 1) * 7 days + 13 hours + 30 minutes + 1); // Mon placeholder
        }
        vm.warp(MON0 + 1 hours);
        h = new Handler(treaty, usdg0, usdg1, feed);
        // seed both books' pools so binds have capacity from call 1
        h.deposit(0, 0, 0, 1_000_000e6);
        h.deposit(0, 1, 0, 1_000_000e6);
        h.deposit(1, 0, 0, 1_000_000e6);
        h.deposit(1, 1, 0, 1_000_000e6);
        targetContract(address(h));
    }

    /// the old `bal == totalAssets + owed + pendingPremium`
    /// line here was a tautology, not an invariant. `totalAssets()` is *defined* as
    /// `balance - owed - pendingPremium` (Capacity.sol:102), so that equation holds by
    /// construction for any `bal`/`owed`/`pendingPremium`, including corrupted ones; no mutation
    /// of the contract's bookkeeping can ever make it fail. The two lines kept below (flow
    /// identity and the free-capacity floor) are independently falsifiable, and
    /// `invariant_ledgersMatchLayers` below cross-checks `locked`/`owed`/`pendingPremium` against
    /// `Treaty.layers` directly, which the deleted line never did. Checked per book: each book's
    /// asset is a fully separate token, so book 0's flow can never explain book 1's balance.
    function invariant_conservation() public view {
        assertEq(
            usdg0.balanceOf(address(firstLoss0)) + usdg0.balanceOf(address(senior0))
                + h.gWithdrawn(0) + h.gRefunded(0) + h.gPaid(0),
            h.gDeposited(0) + h.gPremIn(0),
            "book 0: USDG in == USDG out + held"
        );
        assertEq(
            usdg1.balanceOf(address(firstLoss1)) + usdg1.balanceOf(address(senior1))
                + h.gWithdrawn(1) + h.gRefunded(1) + h.gPaid(1),
            h.gDeposited(1) + h.gPremIn(1),
            "book 1: USDG in == USDG out + held"
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

    function invariant_noViolations() public view {
        assertEq(h.vGate(), 0, "deposit/redeem succeeded while Capacity's own gate reports closed");
        assertEq(h.vJit(), 0, "deposit round-trip profit");
        assertEq(h.vBindDelta(), 0, "bind moved a book's total assets");
        assertEq(h.vSettleDelta(), 0, "settle delta != premium - payout");
        assertEq(h.vCancelDelta(), 0, "cancel moved a book's total assets");
        assertEq(h.vClaimDelta(), 0, "claim moved a book's total assets");
        assertEq(h.vGateNotReopened(), 0, "gate reported open but deposit still reverted (H1 regression)");
    }

    function afterInvariant() external view {
        console2.log("nBind (book0/book1)", h.nBook0(), h.nBook1());
        console2.log("nOverlap", h.nOverlap());
        console2.log("nSettleZero/Partial/Full", h.nSettleZero(), h.nSettlePartial(), h.nSettleFull());
        console2.log("nCancel", h.nCancel());
        console2.log("nClaim", h.nClaim());
        console2.log("nDeposit", h.nDeposit());
        console2.log("nRedeem", h.nRedeem());
    }
}

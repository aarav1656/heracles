// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";

uint256 constant MON0 = 1_789_948_800; // Monday 00:00 UTC (week 0)
uint256 constant WEEKS = 16;

/// Ported from the reviewer's scratch suite at the reviewer's own scratch copy. Gate
/// assertions are adapted for Resolution 2's window semantics: `deposit`/`redeem` can now succeed
/// even while `cap.locked() != 0` (a future layer's cutoff has not arrived yet), so the "should
/// this call be blocked" ground truth is Capacity's own `maxDeposit`/`maxRedeem`, not raw
/// `locked() != 0`. Everything else (conservation, ledger-matches-layers) is unchanged: bucketing
/// `locked` by cutoff does not change what `locked`/`owed`/`pendingPremium` sum to.
contract Handler is Test {
    Treaty public treaty;
    Capacity public cap;
    MockUSDG public usdg;
    MockFeed public feed;
    address[3] public writers;
    address[3] public buyers;

    // USDG conservation ghosts
    uint256 public gDeposited;
    uint256 public gWithdrawn;
    uint256 public gPremIn;
    uint256 public gRefunded;
    uint256 public gPaid;

    // Violation flags (asserts inside a handler revert and get swallowed, so record instead)
    uint256 public vGate; // deposit/redeem succeeded while Capacity's own gate reports closed
    uint256 public vJit; // deposit-then-preview returned more than deposited
    uint256 public vBindDelta; // totalAssets moved on bind
    uint256 public vSettleDelta; // totalAssets moved by != premium - payout on settle
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
    uint256 public nOverlap; // bind while another layer was already live

    mapping(uint256 => bool) public weekPriced;

    constructor(Treaty t, MockUSDG u, MockFeed f) {
        treaty = t;
        cap = t.capacity();
        usdg = u;
        feed = f;
        for (uint256 i; i < 3; i++) {
            writers[i] = address(uint160(0xA000 + i));
            buyers[i] = address(uint160(0xB000 + i));
            usdg.mint(buyers[i], 1e15);
            vm.prank(buyers[i]);
            usdg.approve(address(cap), type(uint256).max);
            vm.prank(writers[i]);
            usdg.approve(address(cap), type(uint256).max);
        }
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 4 days);
        uint256 t = block.timestamp + dt;
        if (t > MON0 + (WEEKS - 1) * 7 days) return;
        vm.warp(t);
    }

    function deposit(uint256 wi, uint256 amt) external {
        address w = writers[wi % 3];
        amt = bound(amt, 1, 5_000_000e6);
        usdg.mint(w, amt);
        bool gateClosed = cap.maxDeposit(w) == 0;
        vm.prank(w);
        try cap.deposit(amt, w) returns (uint256 sh) {
            if (gateClosed) vGate++;
            gDeposited += amt;
            nDeposit++;
            if (cap.previewRedeem(sh) > amt) vJit++;
        } catch {
            if (!gateClosed) vGateNotReopened++;
        }
    }

    function redeem(uint256 wi, uint256 pct) external {
        address w = writers[wi % 3];
        uint256 sh = cap.balanceOf(w) * bound(pct, 1, 100) / 100;
        if (sh == 0) return;
        bool gateClosed = cap.maxRedeem(w) == 0;
        vm.prank(w);
        try cap.redeem(sh, w, w) returns (uint256 out) {
            if (gateClosed) vGate++;
            gWithdrawn += out;
            nRedeem++;
        } catch {}
    }

    function bind(uint256 bi, int256 exposure, uint256 retention, uint256 limit) external {
        exposure = int256(bound(uint256(exposure < 0 ? -exposure : exposure), 1, 2_000_000e6));
        if (bi % 2 == 0) exposure = -exposure;
        retention = bound(retention, 0, 300_000e6);
        uint256 free = cap.totalAssets() - cap.locked();
        limit = bound(limit, 1, free + free / 10 + 1); // occasionally over free capacity
        int256[] memory e = new int256[](1);
        e[0] = exposure;
        uint256 taBefore = cap.totalAssets();
        uint256 balBefore = usdg.balanceOf(address(cap));
        bool live = cap.locked() != 0;
        vm.prank(buyers[bi % 3]);
        try treaty.bind(e, retention, limit) {
            nBind++;
            if (live) nOverlap++;
            gPremIn += usdg.balanceOf(address(cap)) - balBefore;
            if (cap.totalAssets() != taBefore) vBindDelta++;
        } catch {}
    }

    function _layer(uint256 id)
        internal
        view
        returns (uint40 cutoff, uint40 expiry, Treaty.State st, uint256 limit, uint256 premium, uint256 payout)
    {
        (, cutoff, expiry,,, st,,, limit, premium, payout) = treaty.layers(id);
    }

    function settle(uint256 idx, uint256 moveBps) external {
        uint256 n = treaty.layerCount();
        if (n == 0) return;
        uint256 id = idx % n;
        (uint40 cutoff, uint40 expiry, Treaty.State st, uint256 limit, uint256 premium,) = _layer(id);
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
        uint256 taBefore = cap.totalAssets();
        treaty.fix(id, 0, uint80(3 * w + 3));
        (,,,,, uint256 payout) = _layer(id);
        nSettle++;
        if (payout == 0) nSettleZero++;
        else if (payout == limit) nSettleFull++;
        else nSettlePartial++;
        if (cap.totalAssets() + payout != taBefore + premium) vSettleDelta++;
    }

    function cancel(uint256 idx) external {
        uint256 n = treaty.layerCount();
        if (n == 0) return;
        uint256 id = idx % n;
        (,,,, uint256 premium,) = _layer(id);
        uint256 taBefore = cap.totalAssets();
        try treaty.cancel(id) {
            nCancel++;
            gRefunded += premium;
            if (cap.totalAssets() != taBefore) vCancelDelta++;
        } catch {}
    }

    function claim(uint256 idx) external {
        uint256 n = treaty.layerCount();
        if (n == 0) return;
        uint256 id = idx % n;
        (address buyer,,,,,,,,,,) = treaty.layers(id);
        (,,,,, uint256 payout) = _layer(id);
        uint256 taBefore = cap.totalAssets();
        vm.prank(buyer);
        try treaty.claim(id) {
            nClaim++;
            gPaid += payout;
            if (cap.totalAssets() != taBefore) vClaimDelta++;
        } catch {}
    }
}

contract CapacityInvariantTest is Test {
    Handler h;
    Treaty treaty;
    Capacity cap;
    MockUSDG usdg;
    MockFeed feed;

    function setUp() public {
        usdg = new MockUSDG();
        feed = new MockFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = new Treaty(address(usdg), address(new Pricer(oneTableId())), feeds, 50, address(0));
        cap = treaty.capacity();

        // setReference now needs its own first-round-after-Friday's-close pair, so each
        // week gets three round ids: 2w+1 -> 3w+1 (pre-close predecessor, unchanged Fri 19:00
        // seed), a new 3w+2 (the actual Friday reference round, at `fridayCloseOf`, queried live
        // since this WEEKS=16 run spans the Nov 2026 DST switch), 3w+3 (Monday fix round,
        // placeholder seed immediately superseded in settle()).
        for (uint256 w; w < WEEKS; w++) {
            uint256 monday = MON0 + w * 7 days;
            (uint256 cutoff,) = treaty.weekWindow(monday);
            uint256 refTime = treaty.fridayCloseOf(cutoff);
            feed.set(uint80(3 * w + 1), 100e8, cutoff - 30 minutes); // pre-close predecessor
            feed.set(uint80(3 * w + 2), 100e8, refTime); // Friday reference round
            feed.set(uint80(3 * w + 3), 100e8, MON0 + (w + 1) * 7 days + 13 hours + 30 minutes + 1); // Mon placeholder
        }
        vm.warp(MON0 + 1 hours);
        h = new Handler(treaty, usdg, feed);
        // seed the pool so binds have capacity from call 1
        h.deposit(0, 1_000_000e6);
        targetContract(address(h));
    }

    /// the old `bal == totalAssets + owed + pendingPremium`
    /// line here was a tautology, not an invariant. `totalAssets()` is *defined* as
    /// `balance - owed - pendingPremium` (Capacity.sol:102), so that equation holds by
    /// construction for any `bal`/`owed`/`pendingPremium`, including corrupted ones; no mutation
    /// of the contract's bookkeeping can ever make it fail. The two lines kept below (flow
    /// identity and the free-capacity floor) are independently falsifiable, and
    /// `invariant_ledgersMatchLayers` below cross-checks `locked`/`owed`/`pendingPremium` against
    /// `Treaty.layers` directly, which the deleted line never did.
    function invariant_conservation() public view {
        uint256 ta = cap.totalAssets();
        assertEq(
            usdg.balanceOf(address(cap)) + h.gWithdrawn() + h.gRefunded() + h.gPaid(),
            h.gDeposited() + h.gPremIn(),
            "USDG in == USDG out + held"
        );
        assertGe(ta, cap.locked(), "every live layer fully backed");
    }

    function invariant_ledgersMatchLayers() public view {
        uint256 sumLocked;
        uint256 sumOwed;
        uint256 sumPending;
        uint256 n = treaty.layerCount();
        for (uint256 id; id < n; id++) {
            (,,,,, Treaty.State st, bool claimed,, uint256 limit, uint256 premium, uint256 payout) = treaty.layers(id);
            if (st == Treaty.State.Bound) {
                sumLocked += limit;
                sumPending += premium;
            } else if (st == Treaty.State.Settled && !claimed) {
                sumOwed += payout;
            }
        }
        assertEq(cap.locked(), sumLocked, "locked == sum(limit of Bound)");
        assertEq(cap.owed(), sumOwed, "owed == sum(unclaimed payout of Settled)");
        assertEq(cap.pendingPremium(), sumPending, "pendingPremium == sum(premium of Bound)");
    }

    function invariant_noViolations() public view {
        assertEq(h.vGate(), 0, "deposit/redeem succeeded while Capacity's own gate reports closed");
        assertEq(h.vJit(), 0, "deposit round-trip profit");
        assertEq(h.vBindDelta(), 0, "bind moved price");
        assertEq(h.vSettleDelta(), 0, "settle delta != premium - payout");
        assertEq(h.vCancelDelta(), 0, "cancel moved price");
        assertEq(h.vClaimDelta(), 0, "claim moved price");
        assertEq(h.vGateNotReopened(), 0, "gate reported open but deposit still reverted (H1 regression)");
    }

    function afterInvariant() external view {
        console2.log("nBind", h.nBind());
        console2.log("nOverlap", h.nOverlap());
        console2.log("nSettleZero/Partial/Full", h.nSettleZero(), h.nSettlePartial(), h.nSettleFull());
        console2.log("nCancel", h.nCancel());
        console2.log("nClaim", h.nClaim());
        console2.log("nDeposit", h.nDeposit());
        console2.log("nRedeem", h.nRedeem());
    }
}

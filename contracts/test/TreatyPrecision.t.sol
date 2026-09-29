// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";

/// (Slither divide-before-multiply, Treaty.sol:357-358
/// pre-fix): proves the old two-step formula (`gapBps = diff * 10000 / friday; pnl = exposure *
/// gapBps / 10000;`) and the fixed single-division formula (`pnl = exposure * diff / friday;`,
/// now live in `Treaty._settle`) are NOT the same function, the old one truncates the gap to
/// whole basis points before ever touching `exposure`, always rounding the loss down (i.e.
/// toward the writers, away from the buyer). This test computes both formulas over the exact
/// same inputs and shows they diverge by a nonzero, non-rounding-noise amount; it then drives the
/// real deployed contract through bind -> setReference -> fix and shows the live payout matches
/// only the new formula, never the old one.
contract TreatyPrecisionTest is Test {
    uint256 constant T0 = 1_790_000_000; // a Monday; that week's Fri 19:30/Mon 13:30 below
    uint256 constant CUTOFF = 1_790_364_600; // Fri 2026-09-25 19:30 UTC (T0's week)
    uint256 constant SAT_MIDNIGHT = CUTOFF + 4 hours + 30 minutes;
    uint256 constant REF_TIME = CUTOFF + 30 minutes; // Fri 2026-09-25 20:00 UTC (EDT close)
    uint40 constant EXPIRY = uint40(1_790_602_200); // Mon 2026-09-28 13:30 UTC

    // Deliberately an extreme, not-a-realistic-weekend gap: chosen to push the true gap fraction
    // (diff/friday = -0.99999999) right up against a whole-basis-point boundary
    // (gapBps_true = -9999.9999), which is exactly where the old two-step formula's truncation
    // error is largest. A realistic 10-40% weekend gap (see GuardMutation.t.sol,
    // GapTreaty.fork.t.sol) diverges too, just by a smaller, harder-to-see-by-hand amount; this
    // picks the inputs that make the bug legible in one test.
    int256 constant FRIDAY_PRICE = 100_000_000; // 1e8
    int256 constant MONDAY_PRICE = 1;

    uint256 constant RETENTION = 0;
    uint256 constant LIMIT = 2_500_000e6; // above the expected payout so it is never clamped
    int256 constant EXPOSURE = 2_000_000e6;

    // Hand-computed (see the commit message / final report for the full derivation):
    //   diff       = MONDAY_PRICE - FRIDAY_PRICE = -99_999_999
    //   pnl_new    = EXPOSURE * diff / FRIDAY_PRICE     = -1_999_999_980_000
    //   gapBps_old = diff * 10000 / FRIDAY_PRICE         = -9999   (true value -9999.9999, truncated)
    //   pnl_old    = EXPOSURE * gapBps_old / 10000       = -1_999_800_000_000
    //   |pnl_new - pnl_old|                               =       199_980_000  (0.19998 USDG, 6dp... )
    // note EXPOSURE/FRIDAY_PRICE/10000 are all denominated so the raw integers above are already
    // in USDG's 6dp base units; 199_980_000 base units = 199.98 USDG.
    int256 constant EXPECTED_PNL_NEW = -1_999_999_980_000;
    int256 constant EXPECTED_PNL_OLD = -1_999_800_000_000;
    uint256 constant EXPECTED_DIVERGENCE = 199_980_000;

    MockUSDG usdg;
    MockFeed feed;
    Pricer pricer;
    Treaty treaty;
    Capacity capacity;

    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer(oneTableId());
        feed = new MockFeed();
        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);

        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = new Treaty(address(usdg), address(pricer), feeds, 50, address(0));
        capacity = treaty.capacity();

        usdg.mint(writer, 10_000_000e6);
        vm.prank(writer);
        usdg.approve(address(capacity), type(uint256).max);
        vm.prank(writer);
        capacity.deposit(5_000_000e6, writer);

        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(capacity), type(uint256).max);

        vm.warp(T0);
    }

    /// The two formulas as pure integer math, isolated from the contract entirely: proves the
    /// bug (and the fix) exist independent of any Solidity storage or contract wiring.
    function test_formulasDivergeOnTheSameInputs() public pure {
        int256 diff = MONDAY_PRICE - FRIDAY_PRICE;

        int256 pnlNew = (EXPOSURE * diff) / FRIDAY_PRICE;
        assertEq(pnlNew, EXPECTED_PNL_NEW, "single-division formula");

        int256 gapBpsOld = (diff * 10_000) / FRIDAY_PRICE;
        int256 pnlOld = (EXPOSURE * gapBpsOld) / 10_000;
        assertEq(pnlOld, EXPECTED_PNL_OLD, "two-step bps-truncating formula");

        assertTrue(pnlNew != pnlOld, "the two formulas must not be the same function");
        uint256 divergence = uint256(pnlNew - pnlOld < 0 ? pnlOld - pnlNew : pnlNew - pnlOld);
        assertEq(divergence, EXPECTED_DIVERGENCE, "exact size of the truncation error");
        // Old always loses less (rounds toward the writers): the buyer is underpaid by exactly
        // the divergence under the old formula, for every settlement where the true gap isn't a
        // whole number of basis points.
        assertTrue(pnlOld > pnlNew, "old formula must under-report the loss, not over-report it");
    }

    /// Drives the real, deployed contract through the same inputs and shows the live `_settle`
    /// payout equals the new formula's loss (less RETENTION=0, unclamped by LIMIT), never the old
    /// one, proof this isn't just an offline math exercise, the fix is what actually executes.
    function test_livePayoutMatchesNewFormulaNotOld() public {
        vm.prank(buyer);
        int256[] memory exposure = new int256[](1);
        exposure[0] = EXPOSURE;
        uint256 id = treaty.bind(exposure, RETENTION, LIMIT);

        // round 2: first round at/after Friday's close (REF_TIME); round 1 (setUp, Friday
        // CUTOFF - 1 hours) is its required strictly-earlier predecessor.
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);

        feed.set(3, MONDAY_PRICE, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        treaty.fix(id, 0, 3);

        (,,,,, Treaty.State state,,,,, uint256 payout) = treaty.layers(id);
        assertEq(uint8(state), uint8(Treaty.State.Settled));

        uint256 expectedPayoutNew = uint256(-EXPECTED_PNL_NEW); // retention 0, well under LIMIT
        uint256 expectedPayoutOld = uint256(-EXPECTED_PNL_OLD);
        assertLt(expectedPayoutNew, LIMIT, "fixture must not clamp, or the divergence is hidden");

        assertEq(payout, expectedPayoutNew, "live contract must settle with the fixed formula");
        assertTrue(payout != expectedPayoutOld, "live contract must not match the old, buggy formula");
        assertEq(payout - expectedPayoutOld, EXPECTED_DIVERGENCE, "same divergence as the offline proof above");
    }
}

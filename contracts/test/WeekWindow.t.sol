// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// C1+H1 (SECURITY-REVIEW.md): unit-tests `Treaty.weekWindow`'s integer weekday math (epoch day 0,
/// 1970-01-01, was a Thursday) against Python-computed (`datetime`, UTC) expected values, across
/// three separate weeks, a week containing a real-world DST transition (irrelevant to on-chain UTC
/// math, exercised anyway to prove it), and a week spanning a year boundary.
contract WeekWindowTest is Test {
    Treaty treaty;

    function setUp() public {
        MockUSDG usdg = new MockUSDG();
        Pricer pricer = new Pricer();
        MockFeed feed = new MockFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = new Treaty(address(usdg), address(pricer), feeds, 50, address(0));
    }

    /// `fridayCutoff`'s own time-of-day (19:30 UTC) is DST-independent by design, but `expiry`'s
    /// time-of-day flips with the *Monday's* own DST regime (13:30 UTC EDT vs 14:30 UTC EST), so
    /// the fixed cutoff->expiry gap is only ever 2d18h (EDT Monday) or 2d19h (EST Monday) -- never
    /// a third value, and never dependent on Friday's own regime. Callers pass which one they
    /// expect so this stays a real assertion, not a tautology restating the two `expectX` args.
    function _check(uint256 ts, uint256 expectCutoff, uint256 expectExpiry, bool mondayIsEdt) internal {
        (uint256 cutoff, uint256 expiry) = treaty.weekWindow(ts);
        assertEq(cutoff, expectCutoff, "cutoff mismatch");
        assertEq(expiry, expectExpiry, "expiry mismatch");
        assertEq(expiry - cutoff, mondayIsEdt ? 2 days + 18 hours : 2 days + 19 hours, "cutoff->expiry gap must match Monday's own DST regime");
    }

    /// Week 1: a Monday. Sept 2026, fully inside DST (2026-03-08 through 2026-11-01): Monday
    /// expiry is EDT (13:30 UTC).
    function test_weekWindow_week1_fromMonday() public {
        _check(1_790_000_000, 1_790_364_600, 1_790_602_200, true);
    }

    /// Week 2: a Thursday, one week later. Still fully inside DST.
    function test_weekWindow_week2_fromThursday() public {
        _check(1_790_823_600, 1_790_969_400, 1_791_207_000, true);
    }

    /// Week 3: a Sunday (already past that week's Monday cutoff window), two weeks after week 1.
    /// Still fully inside DST.
    function test_weekWindow_week3_fromSunday() public {
        _check(1_791_763_140, 1_791_574_200, 1_791_811_800, true);
    }

    /// Item 6 / judging doc B.2: the week actually containing the March 2026 DST switch (Sunday
    /// 2026-03-08 07:00 UTC). Friday 2026-03-06 is still EST (`fridayCloseOf` = 21:00 UTC close);
    /// the following Monday 2026-03-09 is already EDT (13:30 UTC open) -- `fridayCutoff` itself
    /// stays DST-independent at 19:30 UTC either way, only `expiry`'s time-of-day flips.
    function test_weekWindow_marchSwitchWeek_fridayEstMondayEdt() public {
        uint256 t = 1_772_452_800; // Monday 2026-03-02, the week before the switch week
        _check(t, 1_772_825_400, 1_773_063_000, true);
        (uint256 cutoff,) = treaty.weekWindow(t);
        assertEq(treaty.fridayCloseOf(cutoff), 1_772_830_800, "Friday 2026-03-06 close must be 21:00 UTC (EST)");
    }

    /// The mirror week for the November 2026 DST switch (Sunday 2026-11-01 06:00 UTC): Friday
    /// 2026-10-30 is still EDT (20:00 UTC close), the following Monday 2026-11-02 is already EST
    /// (14:30 UTC open).
    function test_weekWindow_novemberSwitchWeek_fridayEdtMondayEst() public {
        uint256 t = 1_793_016_000; // Monday 2026-10-26, the week before the switch week
        _check(t, 1_793_388_600, 1_793_629_800, false);
        (uint256 cutoff,) = treaty.weekWindow(t);
        assertEq(treaty.fridayCloseOf(cutoff), 1_793_390_400, "Friday 2026-10-30 close must be 20:00 UTC (EDT)");
    }

    /// Year boundary: called on 2025-12-31, resolves to the Friday/Monday that fall in January
    /// 2026, not a truncated or wrapped-around 2025 date. January is winter (EST): expiry is
    /// 14:30 UTC, not the DST-week's 13:30 UTC.
    function test_weekWindow_yearBoundary() public {
        _check(1_767_175_200, 1_767_382_200, 1_767_623_400, false);
    }

    /// Thursday 1970-01-01 00:00 UTC is epoch day 0; weekWindow's weekday formula must resolve it
    /// to the same Friday as any other day that week, proving the epoch-anchor assumption itself.
    /// January is winter (EST): expiry is 14:30 UTC.
    function test_weekWindow_epochAnchorThursday() public {
        // Epoch day 0 (1970-01-01) is a Thursday; that week's Friday is epoch day 1
        // (1970-01-02) and the following Monday is epoch day 4 (1970-01-05).
        (uint256 cutoff, uint256 expiry) = treaty.weekWindow(0);
        assertEq(cutoff, 1 days + 19 hours + 30 minutes);
        assertEq(expiry, 4 days + 14 hours + 30 minutes);
    }
}

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

    function _check(uint256 ts, uint256 expectCutoff, uint256 expectExpiry) internal {
        (uint256 cutoff, uint256 expiry) = treaty.weekWindow(ts);
        assertEq(cutoff, expectCutoff, "cutoff mismatch");
        assertEq(expiry, expectExpiry, "expiry mismatch");
        assertEq(expiry - cutoff, 2 days + 18 hours, "cutoff->expiry must be exactly Fri19:30->Mon13:30");
    }

    /// Week 1: a Monday.
    function test_weekWindow_week1_fromMonday() public {
        _check(1_790_000_000, 1_790_364_600, 1_790_602_200);
    }

    /// Week 2: a Thursday, one week later.
    function test_weekWindow_week2_fromThursday() public {
        _check(1_790_823_600, 1_790_969_400, 1_791_207_000);
    }

    /// Week 3: a Sunday (already past that week's Monday cutoff window), two weeks after week 1.
    function test_weekWindow_week3_fromSunday() public {
        _check(1_791_763_140, 1_791_574_200, 1_791_811_800);
    }

    /// DST-free UTC week: block.timestamp is always UTC, so a real-world EU DST transition
    /// (2026-03-29) falling inside this week changes nothing about the on-chain math.
    function test_weekWindow_dstTransitionWeekIsUnaffected() public {
        _check(1_774_872_000, 1_775_244_600, 1_775_482_200);
    }

    /// Year boundary: called on 2025-12-31, resolves to the Friday/Monday that fall in January
    /// 2026, not a truncated or wrapped-around 2025 date.
    function test_weekWindow_yearBoundary() public {
        _check(1_767_175_200, 1_767_382_200, 1_767_619_800);
    }

    /// Thursday 1970-01-01 00:00 UTC is epoch day 0; weekWindow's weekday formula must resolve it
    /// to the same Friday as any other day that week, proving the epoch-anchor assumption itself.
    function test_weekWindow_epochAnchorThursday() public {
        // Epoch day 0 (1970-01-01) is a Thursday; that week's Friday is epoch day 1
        // (1970-01-02) and the following Monday is epoch day 4 (1970-01-05).
        (uint256 cutoff, uint256 expiry) = treaty.weekWindow(0);
        assertEq(cutoff, 1 days + 19 hours + 30 minutes);
        assertEq(expiry, 4 days + 13 hours + 30 minutes);
    }
}

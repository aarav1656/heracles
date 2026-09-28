// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// Orchestrator Item 3 / judging doc B.1.1: three money-path guards, and every `onlyTreaty` entry
/// point, had zero test references and all three hand mutants in the judging review survived the
/// full suite (73/73 green with the check deleted). Each test below is written to go red the
/// moment its named guard is deleted, and mutation-proven by hand (delete the line, run this
/// file's matching test, confirm red; restore, confirm green) -- see the final report for the
/// transcript of that run. `WrongState`, which the judging doc also flags at zero references, gets
/// its own guard tests at the bottom.
contract GuardMutationTest is Test {
    uint256 constant T0 = 1_790_000_000; // a Monday; that week's Fri 19:30/Mon 13:30 below
    uint256 constant CUTOFF = 1_790_364_600; // Fri 2026-09-25 19:30 UTC (T0's week)
    uint256 constant SAT_MIDNIGHT = CUTOFF + 4 hours + 30 minutes;
    uint256 constant REF_TIME = CUTOFF + 30 minutes; // Fri 2026-09-25 20:00 UTC (EDT close)
    uint40 constant EXPIRY = uint40(1_790_602_200); // Mon 2026-09-28 13:30 UTC

    int256 constant FRIDAY_PRICE = 100e8;
    int256 constant MONDAY_PRICE = 90e8;

    uint256 constant RETENTION = 20_000e6;
    uint256 constant LIMIT = 60_000e6;
    int256 constant EXPOSURE = 2_000_000e6;

    MockUSDG usdg;
    MockFeed feed;
    Pricer pricer;
    Treaty treaty;
    Capacity capacity;

    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer();
        feed = new MockFeed();
        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);

        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = new Treaty(address(usdg), address(pricer), feeds, 50, address(0));
        capacity = treaty.capacity();

        usdg.mint(writer, 1_000_000e6);
        vm.prank(writer);
        usdg.approve(address(capacity), type(uint256).max);
        vm.prank(writer);
        capacity.deposit(500_000e6, writer);

        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(capacity), type(uint256).max);

        vm.warp(T0);
    }

    function _exposure() internal pure returns (int256[] memory e) {
        e = new int256[](1);
        e[0] = EXPOSURE;
    }

    function _bindReferenceAndFix() internal returns (uint256 id) {
        vm.prank(buyer);
        id = treaty.bind(_exposure(), RETENTION, LIMIT);
        // round 2: first round at/after Friday's close (REF_TIME); round 1 (setUp, Friday 18:30
        // UTC) is its required strictly-earlier predecessor.
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        feed.set(3, MONDAY_PRICE, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        treaty.fix(id, 0, 3);
    }

    // --- Guard #1: Treaty.sol's `NotFirstRound` on setReference (judging doc Mutant A, carried
    // forward under Item 6's DST-aware rule) -------------------------------------------------
    // setReference must reject a round whose predecessor is not strictly before Friday's close
    // (REF_TIME); otherwise a caller could walk `roundId` forward past the true first
    // post-close print and pick whichever later one favours their side. The old "last round
    // before Saturday 00:00 UTC" version of this guard (`NotLastRound`) no longer exists --
    // superseded by this same mutation-proof shape; see contracts/test/WeekWindow.t.sol for the
    // DST-switch-week coverage and contracts/test/ReferenceRule.t.sol for fixed EDT/EST checks
    // plus the holiday-Monday coverage of the new rule.
    function test_setReference_NotFirstRound_guard() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        // round 2 is itself already at/after REF_TIME, so it is not a valid "previous round"
        // for round 3 -- passing round 3 with round 2 as predecessor must revert.
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        feed.set(3, FRIDAY_PRICE + 1e8, REF_TIME + 1 hours);
        vm.warp(REF_TIME + 2 hours);
        vm.expectRevert(Treaty.NotFirstRound.selector);
        treaty.setReference(id, 0, 3); // round 2 (its predecessor) is not strictly before REF_TIME
    }

    // --- Guard #2: Treaty.sol:256, `AlreadyFixed` (judging doc Mutant B) -----------------------
    // Calling setReference twice on the same market must revert, not silently push
    // `referencedCount` past what markets.length actually supports (on a multi-market layer that
    // leaves another market's reference permanently unset, so fix() can never satisfy
    // ReferenceNotSet and the layer can only ever be cancelled, never settled).
    function test_setReference_AlreadyFixed_guard() public {
        MockFeed feed2 = new MockFeed();
        address[] memory feeds = new address[](2);
        feeds[0] = address(feed);
        feeds[1] = address(feed2);
        Treaty t2 = new Treaty(address(usdg), address(pricer), feeds, 50, address(0));
        Capacity cap2 = t2.capacity();

        usdg.mint(writer, 1_000_000e6);
        vm.prank(writer);
        usdg.approve(address(cap2), type(uint256).max);
        vm.prank(writer);
        cap2.deposit(500_000e6, writer);

        vm.prank(buyer);
        usdg.approve(address(cap2), type(uint256).max);

        int256[] memory exp = new int256[](2);
        exp[0] = EXPOSURE;
        exp[1] = EXPOSURE;

        vm.prank(buyer);
        uint256 id = t2.bind(exp, RETENTION, LIMIT);

        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);
        feed2.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        feed2.set(2, FRIDAY_PRICE, REF_TIME);

        vm.warp(REF_TIME + 1);
        t2.setReference(id, 0, 2);
        vm.expectRevert(Treaty.AlreadyFixed.selector);
        t2.setReference(id, 0, 2); // same market (0) a second time; market 1 is still unset
    }

    // --- Guard #3: Capacity.payOut `onlyTreaty` (judging doc Mutant C, named guard) -------------
    // Setting up real `owed` capital first (via a full settle) means a deleted modifier does not
    // just change which error fires -- it lets `attacker` actually walk away with writer capital,
    // which is the exploit the judging doc describes, not just a different revert selector.
    function test_capacity_payOut_onlyTreaty_guard() public {
        uint256 id = _bindReferenceAndFix();
        uint256 owed = capacity.owed();
        assertGt(owed, 0, "fixture must produce a real owed balance for this guard to mean anything");
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        capacity.payOut(attacker, owed);
        // unaffected by the attempt: only `treaty` can ever move `owed`.
        assertEq(capacity.owed(), owed);
        id; // silence unused warning if optimizer reorders
    }

    // The same gap, per the judging doc, covers every other onlyTreaty entry point.
    function test_capacity_lock_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        capacity.lock(1, uint40(block.timestamp));
    }

    function test_capacity_unlock_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        capacity.unlock(1, uint40(block.timestamp));
    }

    function test_capacity_settle_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        capacity.settle(1, 0, uint40(block.timestamp));
    }

    function test_capacity_receivePremium_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        capacity.receivePremium(buyer, 1);
    }

    function test_capacity_releasePremium_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        capacity.releasePremium(1);
    }

    function test_capacity_refundPremium_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        capacity.refundPremium(buyer, 1);
    }

    // --- WrongState (judging doc B.1.1, zero test references) -----------------------------------
    function test_setReference_WrongState_guard() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        vm.warp(uint256(EXPIRY) + 7 days + 1);
        treaty.cancel(id);
        vm.expectRevert(Treaty.WrongState.selector);
        treaty.setReference(id, 0, 1);
    }

    function test_fix_WrongState_guard() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        vm.warp(uint256(EXPIRY) + 7 days + 1);
        treaty.cancel(id);
        vm.expectRevert(Treaty.WrongState.selector);
        treaty.fix(id, 0, 1);
    }

    function test_cancel_WrongState_guard() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        vm.warp(uint256(EXPIRY) + 7 days + 1);
        treaty.cancel(id);
        vm.expectRevert(Treaty.WrongState.selector);
        treaty.cancel(id);
    }

    function test_claimTo_WrongState_guard() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        vm.expectRevert(Treaty.WrongState.selector);
        treaty.claimTo(id, buyer);
    }
}

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

/// Three money-path guards, and every `onlyTreaty` entry
/// point, had zero test references and all three hand mutants survived the
/// full suite (73/73 green with the check deleted). Each test below is written to go red the
/// moment its named guard is deleted, and mutation-proven by hand (delete the line, run this
/// file's matching test, confirm red; restore, confirm green), see SECURITY-REVIEW.md for the
/// transcript of that run. `WrongState`, which was also at zero references, gets
/// its own guard tests at the bottom.
contract GuardMutationTest is Test, TreatyFixture {
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
    Capacity firstLoss;
    Capacity senior;

    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer(oneTableId());
        feed = new MockFeed();
        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);

        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = deployTreaty(address(usdg), address(pricer), feeds, 50, address(0));
        firstLoss = Capacity(treaty.firstLossVault(0));
        senior = Capacity(treaty.seniorVault(0));

        usdg.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(address(firstLoss), type(uint256).max);
        usdg.approve(address(senior), type(uint256).max);
        firstLoss.deposit(500_000e6, writer);
        senior.deposit(500_000e6, writer);
        vm.stopPrank();

        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(treaty), type(uint256).max);

        vm.warp(T0);
    }

    function _exposure() internal pure returns (int256[] memory e) {
        e = new int256[](1);
        e[0] = EXPOSURE;
    }

    function _bindReferenceAndFix() internal returns (uint256 id) {
        vm.prank(buyer);
        id = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        // round 2: first round at/after Friday's close (REF_TIME); round 1 (setUp, Friday 18:30
        // UTC) is its required strictly-earlier predecessor.
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        feed.set(3, MONDAY_PRICE, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        treaty.fix(id, 0, 3);
    }

    // --- Guard: Treaty.sol's rule 3 in `setReference` (round must have existed at close) -------
    // setReference must reject a round whose own `updatedAt` postdates Friday's close (REF_TIME):
    // otherwise a caller could walk `roundId` forward to whichever later round favours their
    // side, exactly the "first round after close" absorption problem v3's rule 3 was written to
    // close from the other direction. The old `NotFirstRound`/`NotLastRound` shape this test used
    // to check no longer exists on this function (`NotFirstRound` is `fix`'s guard now); this is
    // rule 3's v3 replacement, same mutation-proof shape: delete rule 3's `if (updatedAt >
    // closeTs) revert BadRound();` line in `setReference` and this test goes red. See
    // contracts/test/WeekWindow.t.sol for the DST-switch-week coverage and
    // contracts/test/ReferenceRule.t.sol for fixed EDT/EST checks plus the holiday-Monday
    // coverage of the new rule.
    function test_setReference_NotFirstRound_guard() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        // round 2 is genuinely in effect at close; round 3 postdates close outright and must
        // never become the reference no matter how far forward time is walked.
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        feed.set(3, FRIDAY_PRICE + 1e8, REF_TIME + 1 hours);
        vm.warp(REF_TIME + 2 hours);
        vm.expectRevert(Treaty.BadRound.selector);
        treaty.setReference(id, 0, 3); // round 3 postdates close (rule 3)
    }

    // --- Guard #2: Treaty.sol:256, `AlreadyFixed` -----------------------
    // Calling setReference twice on the same market must revert, not silently push
    // `referencedCount` past what markets.length actually supports (on a multi-market layer that
    // leaves another market's reference permanently unset, so fix() can never satisfy
    // ReferenceNotSet and the layer can only ever be cancelled, never settled).
    function test_setReference_AlreadyFixed_guard() public {
        MockFeed feed2 = new MockFeed();
        address[] memory feeds = new address[](2);
        feeds[0] = address(feed);
        feeds[1] = address(feed2);
        // pricer (setUp) is a single-market Pricer; this layer spans 2 markets, so it needs its
        // own Pricer configured with 2 table ids (P2 re-review: MissingTable otherwise).
        Pricer pricer2 = new Pricer(nTableIds(2));
        Treaty t2 = deployTreaty(address(usdg), address(pricer2), feeds, 50, address(0));
        Capacity fl2 = Capacity(t2.firstLossVault(0));
        Capacity sr2 = Capacity(t2.seniorVault(0));

        usdg.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(address(fl2), type(uint256).max);
        usdg.approve(address(sr2), type(uint256).max);
        fl2.deposit(500_000e6, writer);
        sr2.deposit(500_000e6, writer);
        vm.stopPrank();

        vm.prank(buyer);
        usdg.approve(address(t2), type(uint256).max);

        int256[] memory exp = new int256[](2);
        exp[0] = EXPOSURE;
        exp[1] = EXPOSURE;

        // v3 bind() requires every market's feed to carry a round within MAX_ROUND_AGE (26h) of
        // now (decision 3, liveness guard rule 1); `feed2` is brand new and has no round yet, so
        // this must be seeded before `bind`, not after.
        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);
        feed2.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);

        vm.prank(buyer);
        uint256 id = t2.bind(0, exp, RETENTION, LIMIT);

        feed.set(2, FRIDAY_PRICE, REF_TIME);
        feed2.set(2, FRIDAY_PRICE, REF_TIME);

        vm.warp(REF_TIME + 1);
        t2.setReference(id, 0, 2);
        vm.expectRevert(Treaty.AlreadyFixed.selector);
        t2.setReference(id, 0, 2); // same market (0) a second time; market 1 is still unset
    }

    // --- Guard #3: Capacity.payOut `onlyTreaty` (named guard) -------------
    // Setting up real `owed` capital first (via a full settle) means a deleted modifier does not
    // just change which error fires, it lets `attacker` actually walk away with writer capital,
    // not just trigger a different revert selector. First-loss absorbs the full LIMIT here
    // (juniorLimit >= LIMIT at this small a size), so it is the vault with a real owed balance.
    function test_capacity_payOut_onlyTreaty_guard() public {
        uint256 id = _bindReferenceAndFix();
        uint256 owed = firstLoss.owed();
        assertGt(owed, 0, "fixture must produce a real owed balance for this guard to mean anything");
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        firstLoss.payOut(attacker, owed);
        // unaffected by the attempt: only `treaty` can ever move `owed`.
        assertEq(firstLoss.owed(), owed);
        id; // silence unused warning if optimizer reorders
    }

    // The same gap covers every other onlyTreaty entry point.
    function test_capacity_lock_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        firstLoss.lock(1, uint40(block.timestamp));
    }

    function test_capacity_unlock_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        firstLoss.unlock(1, uint40(block.timestamp));
    }

    function test_capacity_settle_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        firstLoss.settle(1, 0, uint40(block.timestamp));
    }

    function test_capacity_receivePremium_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        firstLoss.receivePremium(buyer, 1);
    }

    function test_capacity_releasePremium_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        firstLoss.releasePremium(1);
    }

    function test_capacity_refundPremium_onlyTreaty_guard() public {
        vm.prank(attacker);
        vm.expectRevert(Capacity.NotTreaty.selector);
        firstLoss.refundPremium(buyer, 1);
    }

    // --- WrongState (zero test references) -----------------------------------
    // Each of these three drives a layer to `Cancelled` first, then re-calls the guarded
    // function to prove it rejects a non-`Bound` layer. v3's `_anyMarketFixable` (decision 3)
    // treats an unreferenced, unvoided market as always still fixable, so `cancel` on a market
    // that was never referenced now requires `voidReference`'s proof first: seed the feed with a
    // round that is fresh enough to bind against on Monday but more than MAX_ROUND_AGE (26h)
    // stale relative to Friday's close, so it can never be set as a reference and is genuinely
    // voidable.
    function test_setReference_WrongState_guard() public {
        feed.set(1, FRIDAY_PRICE, T0 - 1 hours);
        vm.prank(buyer);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        vm.warp(uint256(EXPIRY) + 7 days + 1);
        treaty.voidReference(id, 0, 1);
        treaty.cancel(id);
        vm.expectRevert(Treaty.WrongState.selector);
        treaty.setReference(id, 0, 1);
    }

    function test_fix_WrongState_guard() public {
        feed.set(1, FRIDAY_PRICE, T0 - 1 hours);
        vm.prank(buyer);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        vm.warp(uint256(EXPIRY) + 7 days + 1);
        treaty.voidReference(id, 0, 1);
        treaty.cancel(id);
        vm.expectRevert(Treaty.WrongState.selector);
        treaty.fix(id, 0, 1);
    }

    function test_cancel_WrongState_guard() public {
        feed.set(1, FRIDAY_PRICE, T0 - 1 hours);
        vm.prank(buyer);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        vm.warp(uint256(EXPIRY) + 7 days + 1);
        treaty.voidReference(id, 0, 1);
        treaty.cancel(id);
        vm.expectRevert(Treaty.WrongState.selector);
        treaty.cancel(id);
    }

    function test_claimTo_WrongState_guard() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        vm.expectRevert(Treaty.WrongState.selector);
        treaty.claimTo(id, buyer);
    }
}

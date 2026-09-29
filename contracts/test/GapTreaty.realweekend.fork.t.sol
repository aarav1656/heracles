// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// The full bind -> setReference -> fix -> claim lifecycle,
/// replayed on a fork of Arbitrum One against the real SPY/USD Chainlink feed's real recorded
/// rounds for a real past weekend (2026-09-25 close to 2026-09-28 open), not a MockFeed. Every
/// round id, price and timestamp below was read live off `0x46306F3795342117721D8DEd50fbcF6DF2b3cc10`
/// via `cast call getRoundData(uint80)` on 2026-09-29 (see the command block in
/// docs/e2e/heracles.md); nothing here is synthesised.
///
/// Round layout found on-chain (phase 2, 8 decimals):
///   round 358  answer 76874000000  updatedAt 1790337627 (Fri 2026-09-25 12:00:27 UTC, pre-close)
///   round 359  answer 77134250000  updatedAt 1790424033 (Sat 2026-09-26 12:00:33 UTC)
///   round 361  answer 77134250000  updatedAt 1790596846 (Mon 2026-09-28 12:00:46 UTC, pre-open)
///   round 362  answer 76748000000  updatedAt 1790602546 (Mon 2026-09-28 13:35:46 UTC) <- Monday fix
/// v3 (docs/design/v3.md, decision 3): the Friday reference is the round already in effect at
/// close, not the first round to print after it. Round 358, printed pre-close, is that round: its
/// successor (359) only prints Saturday, so 358 is still what a trader watching the tape at close
/// would have seen. `setReference` accepts 358 because round 359's own `updatedAt` (1790424033) is
/// itself after `fridayCloseOf` (1790366400), so it does not disqualify 358 under rule 4. Round
/// 359 itself is never a valid reference (it postdates close outright, rule 3) regardless of round
/// 358's presence. Round 362 is still the first round with `updatedAt >= expiry` (1790602200, Mon
/// 13:30 UTC EDT open) whose predecessor (361) is strictly earlier, satisfying `fix`'s
/// NotFirstRound guard; `fix` is unchanged by v3. At the pinned fork block this real weekend's
/// Monday round (362) is also the feed's actual `latestRoundData()`, so `_latestInPhase` accepts
/// both round ids without any phase change.
///
/// Real gap off the correct reference: (76748000000 - 76874000000) / 76874000000 = -0.16391%,
/// noticeably smaller than the gap round 359 would have shown (-0.50072%) precisely because round
/// 358 already reflects most of Friday's late move. The exact payout is derived on-chain inside
/// the test from the fetched round data via `_settle`'s own
/// `(exposure * (monday - friday)) / friday` formula, not hardcoded.
contract GapTreatyRealWeekendForkTest is Test, TreatyFixture {
    string constant RPC = "https://arb1.arbitrum.io/rpc";
    // `cast block-number` on 2026-09-29 was 509,951,410; pinned 2,000 blocks back for the same
    // reorg/archive-depth safety margin as GapTreaty.fork.t.sol. Its timestamp (1,790,663,892) is
    // ~17h after round 362's updatedAt, so both rounds already sit in the feed's on-chain history
    // at this pin; the timeline below is walked by `vm.warp`, not by moving the fork block.
    uint256 constant FORK_BLOCK = 509_949_410;

    address constant SPY = 0x46306F3795342117721D8DEd50fbcF6DF2b3cc10;
    IERC20 constant USDG = IERC20(0x004B506865409877C9fA29bfb1ebA929984B9bbC);
    uint8 constant SPY_TABLE_ID = 2; // evidence/gap-tables: NVDA 0, AAPL 1, SPY 2, TSLA 3

    // Real round ids (phase 2 << 64 | aggregatorRoundId).
    uint80 constant ROUND_FRI_PRE = (uint80(2) << 64) | 358;
    uint80 constant ROUND_FRI_LATE = (uint80(2) << 64) | 359; // first round after close: never valid
    uint80 constant ROUND_MON_PRE = (uint80(2) << 64) | 361;
    uint80 constant ROUND_MON_FIX = (uint80(2) << 64) | 362;

    uint256 constant FRIDAY_CUTOFF = 1_790_364_600; // Fri 2026-09-25 19:30 UTC (bind deadline)
    uint256 constant FRIDAY_CLOSE = 1_790_366_400; // Fri 2026-09-25 20:00 UTC EDT
    uint256 constant MONDAY_EXPIRY = 1_790_602_200; // Mon 2026-09-28 13:30 UTC EDT
    // setReference/fix both revert BadRound if `updatedAt > block.timestamp` (a round from "the
    // future" relative to the call), so block.timestamp must be walked forward to each real
    // round's own updatedAt, not just past the boundary it satisfies.
    uint256 constant ROUND_MON_FIX_UPDATED_AT = 1_790_602_546; // round 362

    uint256 constant EXPOSURE = 2_000_000e6; // long SPY: loses when Monday prints below Friday
    // Small enough that the real (correct) gap off round 358 still clears it and pays out
    // something; a 5,000 USDG retention would swallow this particular weekend's real move
    // entirely, which is itself the point (a v2-style reference off round 359 overstated the gap
    // enough to pay out even through that much retention: see the comment block above).
    uint256 constant RETENTION = 1_000e6;
    uint256 constant LIMIT = 60_000e6;

    Treaty treaty;
    Capacity capacity;
    address writer = makeAddr("real-weekend-writer");
    address buyer = makeAddr("real-weekend-buyer");

    // Gated on FORK_TESTS so a plain `forge test` (CI default, no env var) skips this whole
    // file instead of hitting a public RPC on every run, same as GapTreaty.fork.t.sol and
    // GapTreatyFork.lifecycle.t.sol. Checked before `createSelectFork` runs, so with
    // `FORK_TESTS=1` set an unreachable RPC still fails setUp, never silently skipped.
    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(RPC, FORK_BLOCK);

        address[] memory feeds = new address[](1);
        feeds[0] = SPY;
        uint8[] memory tableIds = new uint8[](1);
        tableIds[0] = SPY_TABLE_ID;
        // sequencerUptimeFeed left at address(0): the real Arbitrum One sequencer feed's own
        // `startedAt` sits near the fork's actual current timestamp, and every step below
        // `vm.warp`s block.timestamp backward to the real Sep 25-28 weekend, which would underflow
        // `_requireSequencerUp`'s `block.timestamp - startedAt` and revert for a reason that has
        // nothing to do with this test (item 7 tracks the mainnet sequencer-feed wiring
        // separately; this test is about the settlement math against real feed data).
        treaty = deployTreaty(address(USDG), address(new Pricer(tableIds)), feeds, 50, address(0));
        capacity = treaty.capacity();

        deal(address(USDG), writer, 1_000_000e6);
        vm.prank(writer);
        USDG.approve(address(capacity), type(uint256).max);
        vm.prank(writer);
        capacity.deposit(500_000e6, writer);

        deal(address(USDG), buyer, 1_000_000e6);
        vm.prank(buyer);
        USDG.approve(address(capacity), type(uint256).max);
    }

    function _layerState(uint256 id) internal view returns (Treaty.State s) {
        (,,,,, s,,,,,) = treaty.layers(id);
    }

    function _layerPayout(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,,, p) = treaty.layers(id);
    }

    function test_realWeekend_bindReferenceFixAndClaim() public {
        vm.warp(FRIDAY_CUTOFF - 1 hours);

        int256[] memory exposure = new int256[](1);
        exposure[0] = int256(EXPOSURE);
        vm.prank(buyer);
        uint256 id = treaty.bind(exposure, RETENTION, LIMIT);
        assertEq(capacity.locked(), LIMIT);

        (address l_buyer,,, uint8 referencedCount,,,,,, uint256 premium,) = treaty.layers(id);
        assertEq(l_buyer, buyer);
        assertGt(premium, 0);
        assertEq(referencedCount, 0);
        console.log("real-weekend premium against live SPY vol (USDG, 6dp)", premium);

        // The late round (359, first to print after close) must never become the reference, no
        // matter how far forward time is walked: it postdates close outright (rule 3).
        vm.warp(FRIDAY_CLOSE + 1 hours);
        vm.expectRevert(Treaty.BadRound.selector);
        treaty.setReference(id, 0, ROUND_FRI_LATE);
        assertFalse(treaty.referenceSet(id, 0));

        // Friday reference: round 358, the round genuinely in effect at close (round 359 only
        // prints Saturday). Round 358's own updatedAt already precedes close, so `block.timestamp`
        // only needs to stay past `closeTs` (already true above); no further forward warp needed,
        // and warping back toward round 358's own updatedAt would land before close and revert
        // BadTiming instead.
        int256 fridayAnswer = _feedAnswer(ROUND_FRI_PRE);
        treaty.setReference(id, 0, ROUND_FRI_PRE);
        assertTrue(treaty.referenceSet(id, 0));
        assertEq(int256(uint256(treaty.fridayPrice(id, 0))), fridayAnswer);

        // Monday fix: round 362, the real first fresh round at/after expiry, round 361 its
        // required predecessor. This is the same call that settles the layer. Same "not from the
        // future" constraint as setReference above. `fix` itself is unchanged by v3.
        int256 mondayAnswer = _feedAnswer(ROUND_MON_FIX);
        vm.warp(ROUND_MON_FIX_UPDATED_AT + 1);
        treaty.fix(id, 0, ROUND_MON_FIX);

        // The exact payout `_settle` must have produced, derived here from the same two fetched
        // rounds via `_settle`'s own `(exposure * (monday - friday)) / friday` then
        // `max(0, loss - retention)` clamped to `limit`, not hardcoded independently.
        int256 pnl = (int256(EXPOSURE) * (mondayAnswer - fridayAnswer)) / fridayAnswer;
        int256 lossMinusRetention = (pnl < 0 ? -pnl : int256(0)) - int256(RETENTION);
        uint256 expectedPayout = lossMinusRetention < 0 ? 0 : uint256(lossMinusRetention);
        if (expectedPayout > LIMIT) expectedPayout = LIMIT;
        assertGt(expectedPayout, 0, "this real weekend's gap must clear retention for the test to mean anything");

        assertEq(uint8(_layerState(id)), uint8(Treaty.State.Settled));
        assertEq(_layerPayout(id), expectedPayout, "payout must match _settle's real-price math");
        console.log("real-weekend payout off the correct (round 358) reference, USDG 6dp", expectedPayout);

        // `_settle` (inside fix, above) already moved the layer's reservation out of `locked`
        // entirely (C1: the unused remainder frees immediately, `payout` moves into `owed`), so
        // `locked` is already 0 here; `claim` only moves `owed` capital to the buyer.
        assertEq(capacity.locked(), 0, "settle must have already released the full reserved limit");
        uint256 owedBefore = capacity.owed();
        assertEq(owedBefore, expectedPayout, "settle must have earmarked exactly the payout as owed");
        uint256 buyerBefore = USDG.balanceOf(buyer);
        vm.prank(buyer);
        treaty.claim(id);
        assertEq(USDG.balanceOf(buyer), buyerBefore + expectedPayout, "claim must move exactly the settled payout");
        assertEq(capacity.owed(), owedBefore - expectedPayout, "claim must clear what it paid out of owed");
    }

    function _feedAnswer(uint80 roundId) internal view returns (int256 answer) {
        (, answer,,) = _feedRound(roundId);
    }

    /// Sanity check on the round selection itself, independent of the Treaty: proves round 358 is
    /// really the round in effect at close (its own updatedAt strictly before close, its
    /// successor 359 strictly after, so nothing supersedes it before the boundary), and that the
    /// Monday fix rounds sit strictly on the correct side of expiry, straight off the forked feed.
    function test_realWeekend_predecessorRoundsAreCorrectlyOrdered() public view {
        (,,, uint256 friPreUpdatedAt) = _feedRound(ROUND_FRI_PRE);
        (,,, uint256 friLateUpdatedAt) = _feedRound(ROUND_FRI_LATE);
        (,,, uint256 monPreUpdatedAt) = _feedRound(ROUND_MON_PRE);
        (,,, uint256 monFixUpdatedAt) = _feedRound(ROUND_MON_FIX);

        assertLt(friPreUpdatedAt, FRIDAY_CLOSE, "round 358 must be strictly before Friday close");
        assertGe(friLateUpdatedAt, FRIDAY_CLOSE, "round 359 must be at/after Friday close, so it never disqualifies 358");
        assertLt(monPreUpdatedAt, MONDAY_EXPIRY, "round 361 must be strictly before Monday expiry");
        assertGe(monFixUpdatedAt, MONDAY_EXPIRY, "round 362 must be at/after Monday expiry");
    }

    function _feedRound(uint80 roundId)
        internal
        view
        returns (uint80 rid, int256 answer, uint256 startedAt, uint256 updatedAt)
    {
        (bool ok, bytes memory data) =
            SPY.staticcall(abi.encodeWithSignature("getRoundData(uint80)", roundId));
        require(ok, "getRoundData failed");
        uint80 answeredInRound;
        (rid, answer, startedAt, updatedAt, answeredInRound) =
            abi.decode(data, (uint80, int256, uint256, uint256, uint80));
    }
}

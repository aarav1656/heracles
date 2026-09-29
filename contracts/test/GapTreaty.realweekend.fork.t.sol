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
///   round 359  answer 77134250000  updatedAt 1790424033 (Sat 2026-09-26 12:00:33 UTC) <- Friday reference
///   round 361  answer 77134250000  updatedAt 1790596846 (Mon 2026-09-28 12:00:46 UTC, pre-open)
///   round 362  answer 76748000000  updatedAt 1790602546 (Mon 2026-09-28 13:35:46 UTC) <- Monday fix
/// Round 359 is the first round with `updatedAt >= fridayCloseOf` (1790366400, Fri 20:00 UTC EDT
/// close) whose predecessor (358) is strictly earlier, satisfying `setReference`'s NotFirstRound
/// guard; round 362 is the first round with `updatedAt >= expiry` (1790602200, Mon 13:30 UTC EDT
/// open) whose predecessor (361) is strictly earlier, satisfying `fix`'s NotFirstRound guard.
/// Both sit inside `REFERENCE_MAX_DELAY` (36h) of their boundary. At the pinned fork block this
/// real weekend's Monday round (362) is also the feed's actual `latestRoundData()`, so
/// `_latestInPhase` accepts both round ids without any phase change.
///
/// Real gap: (76748000000 - 77134250000) / 77134250000 = -0.50072% (SPY opened Monday about half
/// a percent below Friday's official close). At 2,000,000 USDG long exposure that is a real loss
/// of 10,015.006303 USDG; with a 5,000 USDG retention and a 60,000 USDG limit the layer owes the
/// buyer 5,015.006303 USDG, the exact number asserted below, computed by `_settle`'s own
/// `(exposure * (monday - friday)) / friday` formula, not restated independently.
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
    uint80 constant ROUND_FRI_REF = (uint80(2) << 64) | 359;
    uint80 constant ROUND_MON_PRE = (uint80(2) << 64) | 361;
    uint80 constant ROUND_MON_FIX = (uint80(2) << 64) | 362;

    uint256 constant FRIDAY_CUTOFF = 1_790_364_600; // Fri 2026-09-25 19:30 UTC (bind deadline)
    uint256 constant FRIDAY_CLOSE = 1_790_366_400; // Fri 2026-09-25 20:00 UTC EDT
    uint256 constant MONDAY_EXPIRY = 1_790_602_200; // Mon 2026-09-28 13:30 UTC EDT
    // setReference/fix both revert BadRound if `updatedAt > block.timestamp` (a round from "the
    // future" relative to the call), so block.timestamp must be walked forward to each real
    // round's own updatedAt, not just past the boundary it satisfies.
    uint256 constant ROUND_FRI_REF_UPDATED_AT = 1_790_424_033; // round 359
    uint256 constant ROUND_MON_FIX_UPDATED_AT = 1_790_602_546; // round 362

    uint256 constant EXPOSURE = 2_000_000e6; // long SPY: loses when Monday prints below Friday
    uint256 constant RETENTION = 5_000e6;
    uint256 constant LIMIT = 60_000e6;
    // The exact number `_settle`'s own division produces for the real prices above; see the
    // Python cross-check transcript in docs/e2e/heracles.md.
    uint256 constant EXPECTED_PAYOUT = 5_015_006_303;

    Treaty treaty;
    Capacity capacity;
    address writer = makeAddr("real-weekend-writer");
    address buyer = makeAddr("real-weekend-buyer");

    function setUp() public {
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

        // Friday reference: round 359, the real first fresh round at/after the official close,
        // with round 358 (already stored on the fork, no MockFeed) as its required predecessor.
        // block.timestamp must reach round 359's own updatedAt, not just FRIDAY_CLOSE, or
        // setReference reverts BadRound (a round timestamped after "now").
        vm.warp(ROUND_FRI_REF_UPDATED_AT + 1);
        treaty.setReference(id, 0, ROUND_FRI_REF);
        assertTrue(treaty.referenceSet(id, 0));
        assertEq(treaty.fridayPrice(id, 0), 77_134_250_000 / 1); // uint64(answer), raw 8dp

        // Monday fix: round 362, the real first fresh round at/after expiry, round 361 its
        // required predecessor. This is the same call that settles the layer. Same "not from the
        // future" constraint as setReference above.
        vm.warp(ROUND_MON_FIX_UPDATED_AT + 1);
        treaty.fix(id, 0, ROUND_MON_FIX);

        assertEq(uint8(_layerState(id)), uint8(Treaty.State.Settled));
        assertEq(_layerPayout(id), EXPECTED_PAYOUT, "payout must match _settle's real-price math");

        // `_settle` (inside fix, above) already moved the layer's reservation out of `locked`
        // entirely (C1: the unused remainder frees immediately, `payout` moves into `owed`), so
        // `locked` is already 0 here; `claim` only moves `owed` capital to the buyer.
        assertEq(capacity.locked(), 0, "settle must have already released the full reserved limit");
        uint256 owedBefore = capacity.owed();
        assertEq(owedBefore, EXPECTED_PAYOUT, "settle must have earmarked exactly the payout as owed");
        uint256 buyerBefore = USDG.balanceOf(buyer);
        vm.prank(buyer);
        treaty.claim(id);
        assertEq(USDG.balanceOf(buyer), buyerBefore + EXPECTED_PAYOUT, "claim must move exactly the settled payout");
        assertEq(capacity.owed(), owedBefore - EXPECTED_PAYOUT, "claim must clear what it paid out of owed");
    }

    /// Sanity check on the round selection itself, independent of the Treaty: proves the
    /// predecessor rounds this test relies on for NotFirstRound really do sit strictly on the
    /// correct side of each boundary, straight off the forked feed.
    function test_realWeekend_predecessorRoundsAreCorrectlyOrdered() public view {
        (,,, uint256 friPreUpdatedAt) = _feedRound(ROUND_FRI_PRE);
        (,,, uint256 friRefUpdatedAt) = _feedRound(ROUND_FRI_REF);
        (,,, uint256 monPreUpdatedAt) = _feedRound(ROUND_MON_PRE);
        (,,, uint256 monFixUpdatedAt) = _feedRound(ROUND_MON_FIX);

        assertLt(friPreUpdatedAt, FRIDAY_CLOSE, "round 358 must be strictly before Friday close");
        assertGe(friRefUpdatedAt, FRIDAY_CLOSE, "round 359 must be at/after Friday close");
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

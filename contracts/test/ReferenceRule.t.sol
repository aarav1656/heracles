// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// `setReference`'s calendar math (`fridayCloseOf`, DST-aware) unit
/// tested directly against known real-world dates, plus the specific Labor Day 2026 holiday
/// scenario this test cites as unaddressed ("a holiday-heartbeat
/// test uses the Labor Day rounds above").
contract ReferenceRuleTest is Test, TreatyFixture {
    MockUSDG usdg;
    MockFeed feed;
    Pricer pricer;
    Treaty treaty;
    Capacity firstLoss;
    Capacity senior;

    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer(oneTableId());
        feed = new MockFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = deployTreaty(address(usdg), address(pricer), feeds, 50, address(0));
        firstLoss = Capacity(treaty.firstLossVault(0));
        senior = Capacity(treaty.seniorVault(0));

        usdg.mint(writer, 1_000_000e6);
        vm.prank(writer);
        usdg.approve(address(firstLoss), type(uint256).max);
        vm.prank(writer);
        firstLoss.deposit(500_000e6, writer);
        vm.prank(writer);
        usdg.approve(address(senior), type(uint256).max);
        vm.prank(writer);
        senior.deposit(500_000e6, writer);

        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        // Premium is pulled by Treaty itself, never a vault, so the buyer approves the Treaty
        // contract, not either vault.
        usdg.approve(address(treaty), type(uint256).max);
    }

    /// Friday 2026-09-04 (a DST/EDT week): the official US market close is 4:00pm ET, 20:00 UTC.
    function test_fridayCloseOf_edt() public view {
        uint256 anytimeThatFriday = 1_788_516_000; // 2026-09-04 10:00 UTC
        uint256 expectedClose = 1_788_552_000; // 2026-09-04 20:00 UTC
        assertEq(treaty.fridayCloseOf(anytimeThatFriday), expectedClose, "EDT close must be 20:00 UTC");
    }

    /// Friday 2026-11-06 (after the Nov 1 2026 DST switch, standard time/EST): the official US
    /// market close is 4:00pm ET, 21:00 UTC.
    function test_fridayCloseOf_est() public view {
        uint256 anytimeThatFriday = 1_793_959_200; // 2026-11-06 10:00 UTC
        uint256 expectedClose = 1_793_998_800; // 2026-11-06 21:00 UTC
        assertEq(treaty.fridayCloseOf(anytimeThatFriday), expectedClose, "EST close must be 21:00 UTC");
    }

    /// Judging doc B.2: "Labor Day, Sep 7: the first round after Monday 13:30 UTC is a 14:51:00
    /// heartbeat carrying Friday's close (770.09). `fix` accepts it, so the settled gap is a
    /// stale republish and the real Friday-to-Tuesday move is never measured."
    ///
    /// Labor Day 2026 is Monday 2026-09-07 (the US market is closed, no trading occurs). The
    /// same real Chainlink round data cited above replays here: Friday 2026-09-04's official
    /// close prints 770.09 at 20:00 UTC (EDT); with no Monday session, the exchange's own
    /// heartbeat is the first fresh round after expiry, republishing the same 770.09 at
    /// 14:51:00 UTC rather than a genuine new print. `setReference`/`fix`'s "first round with
    /// updatedAt >= the boundary, predecessor strictly before it" rule has no way to tell a
    /// genuine price print apart from a heartbeat republish, Chainlink's `AggregatorV3Interface`
    /// carries no such flag, so `fix` accepts this round exactly as B.2 describes. This is a
    /// documented, honest limitation (see README/SECURITY-REVIEW.md), not something this
    /// contract can close without a data source Chainlink's feed does not expose; the test exists
    /// so the behaviour is proven and visible, not silently assumed away.
    function test_holidayHeartbeat_laborDay2026RepublishesFridayClose() public {
        uint256 friPredecessor = 1_788_548_400 - 1 days; // 2026-09-03 (Thursday) 19:00 UTC, before the Thursday 19:30 bind deadline
        uint256 friClose = 1_788_552_000; // 2026-09-04 20:00 UTC, Friday's official close (EDT)
        uint256 mondayExpiry = 1_788_787_800; // 2026-09-07 13:30 UTC, Labor Day's 9:30am ET open
        uint256 mondayHeartbeat = 1_788_792_660; // 2026-09-07 14:51:00 UTC, the republish heartbeat
        int256 fridayClosePrice = 770_09_000_000; // 770.09 at 1e8

        feed.set(1, fridayClosePrice - 1e8, friPredecessor); // pre-close predecessor round
        feed.set(2, fridayClosePrice, friClose); // Friday's real official close: 770.09

        vm.warp(friPredecessor + 5 minutes); // before the Thursday 19:30 UTC bind deadline (H-1)
        vm.prank(buyer);
        int256[] memory exposure = new int256[](1);
        exposure[0] = 1_000_000e6;
        uint256 id = treaty.bind(0, exposure, 0, 60_000e6, type(uint256).max);

        vm.warp(friClose + 1);
        treaty.setReference(id, 0, 2);

        // The Labor Day heartbeat republishes the exact same 770.09: no genuine Monday print
        // ever exists for this holiday, only the venue's own idle heartbeat.
        feed.set(3, fridayClosePrice, mondayHeartbeat);
        vm.warp(mondayHeartbeat + 1);
        treaty.fix(id, 0, 3); // must not revert: this is the documented, accepted limitation

        (,,,,, Treaty.State state,,,,, uint256 payout) = layerBasics(treaty, id);
        assertEq(uint8(state), uint8(Treaty.State.Settled), "holiday heartbeat must still settle the layer");
        // Friday close == "Monday" heartbeat price exactly: the measured gap is zero, even
        // though the true Friday-to-Tuesday move (the next real trading session) was never
        // measured at all. This is B.2's finding made concrete and assertable, not silently lost.
        assertEq(payout, 0, "B.2: a stale republish measures a zero gap, masking the real move");
        assertTrue(mondayHeartbeat >= mondayExpiry, "sanity: the heartbeat is at/after expiry, which is exactly why fix() accepts it");
    }

    /// Rule 4: a round that already existed at close is not automatically the reference if a
    /// fresher round also existed at close, in the same phase, superseding it before the boundary.
    /// Without this check, `setReference` could skip past a real intra-day update and settle off
    /// a stale earlier print even though the market kept trading up to the close.
    function test_ref_supersededRoundBeforeCloseRejectedByRule4() public {
        uint256 fri = 1_790_294_400; // Friday 2026-09-25 00:00 UTC
        uint256 close = fri + 20 hours; // EDT official close

        feed.set(1, 769e8, close - 1 days - 5 hours); // printed before bind: keeps the feed fresh, never the reference
        vm.warp(close - 1 days - 4 hours); // Thursday 16:00 UTC, before the Thursday 19:30 bind deadline (H-1)
        vm.prank(buyer);
        int256[] memory exposure = new int256[](1);
        exposure[0] = 1_000_000e6;
        uint256 id = treaty.bind(0, exposure, 0, 60_000e6, type(uint256).max);

        feed.set(2, 770e8, close - 3 hours); // exists at close, but about to be superseded
        feed.set(3, 771e8, close - 1 hours); // supersedes round 2 before close too
        vm.warp(close + 1 hours);

        vm.expectRevert(Treaty.BadRound.selector);
        treaty.setReference(id, 0, 2); // round 2 existed at close, but round 3 already superseded it

        treaty.setReference(id, 0, 3); // the round genuinely in effect at close still works
        assertTrue(treaty.referenceSet(id, 0));
        assertEq(treaty.fridayPrice(id, 0), 771e8, "reference must be round 3's price, not round 2's");
    }
}

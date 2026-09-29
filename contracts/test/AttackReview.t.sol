// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MockSequencerFeed} from "./mocks/MockSequencerFeed.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// Adversarial review (SECURITY-REVIEW.md), post-fix. Each test now asserts the FIXED behaviour:
/// green here means the finding is closed. Where the original attack is now structurally
/// impossible (e.g. H1's caller-chosen expiry), the test instead proves the replacement invariant
/// (expiry is always the following Monday 13:30 UTC) and/or that the old attack call now reverts.
contract AttackReviewTest is Test, TreatyFixture {
    uint256 constant FRI_CLOSE = 1_790_366_400; // Fri 2026-09-25 20:00 UTC
    uint256 constant FRI_1900 = FRI_CLOSE - 1 hours; // bind time, before the 19:30 cutoff
    uint256 constant CUTOFF = FRI_CLOSE - 30 minutes; // Fri 19:30 UTC
    uint256 constant SAT_MIDNIGHT = CUTOFF + 4 hours + 30 minutes; // Sat 00:00 UTC
    uint40 constant MONDAY = uint40(FRI_CLOSE + 2 days + 17 hours + 30 minutes); // Mon 13:30 UTC

    MockUSDG usdg;
    MockFeed feed;
    Pricer pricer;
    Treaty treaty;
    Capacity capacity;

    address writerA = makeAddr("writerA");
    address writerB = makeAddr("writerB");
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer(oneTableId());
        feed = new MockFeed();
        feed.set(1, 100e8, FRI_1900 - 10 minutes); // Friday reference round
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = deployTreaty(address(usdg), address(pricer), feeds, 50, address(0));
        capacity = treaty.capacity();
        _deposit(writerA, 100_000e6);
        _deposit(writerB, 100_000e6);
        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(capacity), type(uint256).max);
        vm.warp(FRI_1900);
    }

    function _deposit(address who, uint256 amt) internal {
        usdg.mint(who, amt);
        vm.startPrank(who);
        usdg.approve(address(capacity), type(uint256).max);
        capacity.deposit(amt, who);
        vm.stopPrank();
    }

    function _deposit2(Capacity cap, address who, uint256 amt) internal {
        usdg.mint(who, amt);
        vm.startPrank(who);
        usdg.approve(address(cap), type(uint256).max);
        cap.deposit(amt, who);
        vm.stopPrank();
    }

    function _one(int256 e) internal pure returns (int256[] memory x) {
        x = new int256[](1);
        x[0] = e;
    }

    function _expiry(uint256 id) internal view returns (uint40 e) {
        (,, e,,,,,,,,) = treaty.layers(id);
    }

    function _premium(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,, p,) = treaty.layers(id);
    }

    function _payout(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,,, p) = treaty.layers(id);
    }

    /// Binds, sets the Friday reference and (if warped past expiry) fixes Monday's price so a
    /// layer settles. Mirrors the real flow: bind before cutoff, reference after Saturday
    /// midnight, fix after expiry.
    function _bindReferenceAndFix(address who, int256[] memory exposure, uint256 retention, uint256 limit, int256 monday)
        internal
        returns (uint256 id)
    {
        vm.prank(who);
        id = treaty.bind(exposure, retention, limit);
        // setReference now waits for `fridayCloseOf` (FRI_CLOSE), not Saturday midnight;
        // round 1 (set in setUp, FRI_1900 - 10 minutes) is its required strictly-earlier
        // predecessor, round 2 is the first fresh round at/after FRI_CLOSE.
        feed.set(2, 100e8, FRI_CLOSE);
        vm.warp(FRI_CLOSE + 1);
        treaty.setReference(id, 0, 2);
        feed.set(3, monday, MONDAY + 1);
        vm.warp(uint256(MONDAY) + 60);
        treaty.fix(id, 0, 3);
    }

    /// C1 (fixed): a bind with zero exposure is rejected outright, so writer capital can never be
    /// frozen for free. Previously: an address holding zero USDG could bind zero exposure for the
    /// whole free capacity with an unbounded expiry.
    function test_C1_zeroExposureBindReverts() public {
        uint256 free = capacity.totalAssets();
        assertEq(usdg.balanceOf(attacker), 0);
        vm.prank(attacker);
        vm.expectRevert(Treaty.BadParams.selector);
        treaty.bind(_one(0), 0, free);
    }

    /// H1a (fixed): expiry is never caller-chosen, it is always exactly the following Monday
    /// 13:30 UTC computed from block.timestamp, so a weekend premium can no longer buy a month of
    /// cover.
    function test_H1a_expiryIsAlwaysNextMonday() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_one(1_000_000e6), 20_000e6, 60_000e6);
        assertEq(_expiry(id), MONDAY, "H1a: expiry must be exactly the following Monday 13:30 UTC");
    }

    /// H1b (fixed): bind strictly after Friday 19:30 UTC now reverts outright (BadTiming), so a
    /// bind can no longer be timed to weekend news that is already public.
    function test_H1b_bindAfterFridayCloseReverts() public {
        vm.warp(FRI_CLOSE + 22 hours); // Sat 18:00 UTC
        vm.prank(buyer);
        vm.expectRevert(Treaty.BadTiming.selector);
        treaty.bind(_one(1_000_000e6), 20_000e6, 60_000e6);
    }

    /// H2 (fixed): a retention above the worst historical scenario loss can no longer quote a
    /// zero premium; the minRateOnLineBps floor guarantees a non-zero premium on any layer that
    /// can pay.
    function test_H2_premiumFloorPreventsZeroPremiumLayer() public {
        int256 e = 1_000_000e6;
        uint256 retention = 147_500e6;
        uint256 limit = 100_000e6;
        uint256 id = _bindReferenceAndFix(buyer, _one(e), retention, limit, 80e8);
        assertEq(_payout(id), 52_500e6);
        uint256 floor_ = limit * treaty.minRateOnLineBps() / 1e4;
        assertGt(_premium(id), 0, "H2: layer that can pay must never be bound for zero premium");
        assertGe(_premium(id), floor_, "H2: premium must never sit below the minRateOnLineBps floor");
    }

    /// H3 (fixed): Capacity.totalAssets() nets out locked/owed capital, so both writers share the
    /// realized loss pro rata regardless of withdrawal order; the first writer out no longer
    /// escapes at a stale, unmarked price.
    function test_H3_lossSharedProRataRegardlessOfWithdrawOrder() public {
        uint256 id = _bindReferenceAndFix(buyer, _one(1_000_000e6), 0, 100_000e6, 80e8);
        assertEq(_payout(id), 100_000e6);

        uint256 max = capacity.maxWithdraw(writerA);
        vm.prank(writerA);
        capacity.withdraw(max, writerA, writerA);
        vm.prank(buyer);
        treaty.claim(id);
        uint256 bLeft = capacity.previewRedeem(capacity.balanceOf(writerB));

        assertApproxEqRel(usdg.balanceOf(writerA), bLeft, 0.01e18, "H3: loss must be shared pro rata");
    }

    /// M1 (fixed): a bind's premium is withheld from share pricing (Capacity.pendingPremium) until
    /// the layer settles, so a depositor who enters right before bind and exits right after gets
    /// none of it.
    ///
    /// the re-review's H1 fix: the epoch gate now keys on the layer's own cutoff, not on aggregate
    /// `locked != 0`. `bind` happens 30 minutes before CUTOFF here, so the gate is not yet active
    /// and a redeem is allowed (capped at free capacity), but that redeem still cannot skim any
    /// part of the pending premium (proven below); once the layer's own cutoff actually arrives,
    /// the gate closes outright, so the JIT-around-settle path stays closed the same as before.
    function test_M1_jitDepositCannotSkimPremium() public {
        usdg.mint(attacker, 1_000_000e6);
        vm.startPrank(attacker);
        usdg.approve(address(capacity), type(uint256).max);
        uint256 shares = capacity.deposit(1_000_000e6, attacker);
        vm.stopPrank();
        vm.prank(buyer);
        treaty.bind(_one(-2_000_000e6), 20_000e6, 60_000e6);
        // M1 in substance still holds: the premium stays excluded from totalAssets() (pending
        // until the layer settles), so even priced, the JIT depositor's shares are worth at most
        // what they put in.
        assertLe(
            capacity.previewRedeem(shares),
            1_000_000e6,
            "M1: premium must stay excluded from share price while the layer is live"
        );
        // H1: before the layer's own cutoff (still 30 minutes away), the gate is not active, so an
        // exit is allowed; it is still bounded by the M1 assertion above, no premium skim either way.
        assertGt(capacity.maxRedeem(attacker), 0, "H1: gate must not be active before the layer's own cutoff");

        // Once the layer's own cutoff arrives, the gate closes outright (C1): no exit at all until
        // this layer settles or is cancelled.
        vm.warp(CUTOFF);
        assertEq(capacity.maxRedeem(attacker), 0, "C1: no exit is allowed once the layer's cutoff has arrived");
        vm.prank(attacker);
        vm.expectRevert();
        capacity.redeem(shares, attacker, attacker);
    }

    /// M2 (fixed), part 1: setReference still rejects a round older than REF_WINDOW (24h).
    function test_M2_staleReferenceRoundReverts() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_one(1_000_000e6), 20_000e6, 60_000e6);
        // v3 rule 5: the round in effect at close must itself be within MAX_ROUND_AGE (26h) of
        // FRI_CLOSE. 27h before close is unambiguously stale under the new rule (the old 25h
        // offset was calibrated against the pre-v3 boundary and now falls inside the 26h window).
        feed.set(2, 100e8, FRI_CLOSE - 27 hours);
        vm.warp(SAT_MIDNIGHT + 1);
        vm.expectRevert(Treaty.BadRound.selector);
        treaty.setReference(id, 0, 2);
    }

    /// M2 (fixed), part 2: a downed L2 sequencer blocks bind/setReference/fix outright, closing
    /// the force-inclusion window the original finding described. Uses a second Treaty deployed
    /// with a live sequencer feed (the main suite's `treaty` uses address(0), matching the
    /// Arbitrum Sepolia deploy, which has no such feed at all).
    function test_M2_sequencerDownBlocksBind() public {
        MockSequencerFeed seq = new MockSequencerFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        Treaty guarded = deployTreaty(address(usdg), address(pricer), feeds, 50, address(seq));
        Capacity gCap = guarded.capacity();
        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(gCap), type(uint256).max);
        _deposit2(gCap, writerA, 200_000e6);

        vm.warp(CUTOFF - 3 hours); // leave room for the grace-period warp below, still pre-cutoff
        seq.setDown();
        vm.prank(buyer);
        vm.expectRevert(Treaty.SequencerDown.selector);
        guarded.bind(_one(1_000_000e6), 20_000e6, 60_000e6);

        // Back up, but still inside the grace period: still blocked.
        seq.setUp(block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(Treaty.SequencerDown.selector);
        guarded.bind(_one(1_000_000e6), 20_000e6, 60_000e6);

        // Past the grace period: bind succeeds.
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(buyer);
        guarded.bind(_one(1_000_000e6), 20_000e6, 60_000e6);
    }

    /// M3 (fixed): a Chainlink phase change after expiry still makes every settling round
    /// unfixable, but cancel() after the grace period now refunds the buyer's premium instead of
    /// leaving writers holding an owed payout they never have to pay.
    function test_M3_phaseChangeCancelRefundsBuyerPremium() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_one(1_000_000e6), 0, 100_000e6);
        uint256 premium = _premium(id);
        feed.set(2, 100e8, FRI_CLOSE);
        vm.warp(FRI_CLOSE + 1);
        treaty.setReference(id, 0, 2);

        uint80 p2 = uint80((uint256(2) << 64) | 1);
        feed.set(p2, 80e8, MONDAY + 1); // first Monday round, published in a new phase
        vm.warp(uint256(MONDAY) + 60);
        vm.expectRevert(); // BadRound (phase) or NotFirstRound: no round is fixable
        treaty.fix(id, 0, p2);

        vm.warp(uint256(MONDAY) + 8 days);
        uint256 buyerBefore = usdg.balanceOf(buyer);
        treaty.cancel(id);
        assertEq(usdg.balanceOf(buyer) - buyerBefore, premium, "M3: cancel must refund the buyer's premium");

        vm.prank(buyer);
        vm.expectRevert(); // no payout was ever settled: nothing to claim
        treaty.claim(id);
    }

    /// L1: Solidity Pricer reverts on exposure*gap overflow; the Stylus Pricer previously wrapped
    /// silently (fixed in pricer/src/lib.rs via checked_mul/checked_add, see
    /// pricer::test::test_overflow_reverts). This documents the Solidity side of the interface.
    function test_L1_solidityPricerRevertsOnOverflow() public {
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        vm.expectRevert();
        pricer.quote(_one(-(type(int256).max / 1000)), feeds, 0, 40e6);
    }

    /// L4 (fixed): a buyer can redirect their payout to another address; only the buyer who owns
    /// the claim can call claimTo.
    function test_L4_claimToRedirectsPayoutToChosenAddress() public {
        uint256 id = _bindReferenceAndFix(buyer, _one(1_000_000e6), 0, 100_000e6, 80e8);
        address elsewhere = makeAddr("elsewhere");
        vm.prank(attacker);
        vm.expectRevert(Treaty.NothingToClaim.selector);
        treaty.claimTo(id, elsewhere);

        vm.prank(buyer);
        treaty.claimTo(id, elsewhere);
        assertEq(usdg.balanceOf(elsewhere), _payout(id));
    }
}

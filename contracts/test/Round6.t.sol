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

/// 6-decimal token with an issuer freeze list, the shape of Circle USDC's `blacklist` and Paxos
/// USDG's asset-protection freeze: any transfer to or from a frozen address reverts.
contract FreezableToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public frozen;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function freeze(address who) external {
        frozen[who] = true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        require(!frozen[f] && !frozen[to], "frozen");
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// Chainlink-shaped feed whose reads can be switched to revert, the shape of a decommissioned proxy.
contract BreakableFeed {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) public rounds;
    uint80 public latestId;
    uint8 public constant decimals = 8;
    bool public broken;

    function breakIt() external {
        broken = true;
    }

    function set(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds[roundId] = Round(answer, updatedAt);
        if (roundId > latestId) latestId = roundId;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "decommissioned");
        Round memory r = rounds[latestId];
        return (latestId, r.answer, r.updatedAt, r.updatedAt, latestId);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "decommissioned");
        Round memory r = rounds[roundId];
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }
}

contract Round6Test is Test, TreatyFixture {
    uint256 constant FRI = 1_790_294_400; // Fri 2026-09-25 00:00 UTC
    uint256 constant THU_HB = FRI - 7 hours - 42 minutes; // Thu 16:18 UTC, Sepolia-style heartbeat
    uint256 constant BIND_AT = FRI - 7 hours; // Thu 17:00 UTC
    uint256 constant CUTOFF = FRI + 19 hours + 30 minutes;
    uint256 constant CLOSE = FRI + 20 hours; // EDT close
    uint256 constant EXPIRY = FRI + 3 days + 13 hours + 30 minutes; // Mon 13:30 UTC

    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    Treaty t;
    Capacity fl;
    Capacity sr;
    MockFeed feed;
    MockFeed live;

    function _deploy(address asset, address feed_, address liveness) internal {
        feed = MockFeed(feed_);
        address[] memory feeds = new address[](1);
        feeds[0] = feed_;
        t = deployTreaty(asset, address(new Pricer(oneTableId())), feeds, 50, address(0), liveness);
        fl = Capacity(t.firstLossVault(0));
        sr = Capacity(t.seniorVault(0));
    }

    function _fund(address asset) internal {
        MockUSDG(asset).mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        MockUSDG(asset).approve(address(fl), type(uint256).max);
        MockUSDG(asset).approve(address(sr), type(uint256).max);
        fl.deposit(300_000e6, writer);
        sr.deposit(700_000e6, writer);
        vm.stopPrank();
        MockUSDG(asset).mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        MockUSDG(asset).approve(address(t), type(uint256).max);
    }

    function _bind() internal returns (uint256 id) {
        int256[] memory e = new int256[](1);
        e[0] = 1_000_000e6;
        vm.warp(BIND_AT);
        vm.prank(buyer);
        id = t.bind(0, e, 20_000e6, 60_000e6, type(uint256).max);
    }

    function _state(uint256 id) internal view returns (Treaty.State s) {
        (,,,,, s,,,,,) = layerBasics(t, id);
    }

    // ------------------------------------------------------------------------------------------
    // L6-1. Issuer freeze of the buyer used to brick cancel and the whole book forever. Now
    // `cancel` never pushes a transfer to the buyer, so a frozen buyer cannot block it; the
    // buyer's own recovery is `claimTo` redirecting the pull to an address the issuer never froze.
    // ------------------------------------------------------------------------------------------

    function _deadFeedLayer(FreezableToken tok) internal returns (uint256 id) {
        live = new MockFeed();
        _deploy(address(tok), address(new MockFeed()), address(live));
        _fund(address(tok));
        feed.set(1, 770e8, THU_HB);
        id = _bind();
        feed.set(2, 771e8, FRI + 19 hours); // in effect at close, fresh
        vm.warp(CLOSE + 1);
        t.setReference(id, 0, 2);
        // the equity feed dies after Friday: no Monday round ever prints
        live.set(1, 1e8, EXPIRY + 3 days + 29 days);
        vm.warp(EXPIRY + 3 days + 30 days);
    }

    function test_L6_1_control_cancelWorksWhenBuyerNotFrozen() public {
        FreezableToken tok = new FreezableToken();
        uint256 id = _deadFeedLayer(tok);
        t.cancel(id);
        assertEq(uint256(_state(id)), uint256(Treaty.State.Cancelled));
        assertGt(fl.maxRedeem(writer), 0);
    }

    function test_L6_1_frozenBuyerCancelSucceedsAndClaimToRedirects() public {
        FreezableToken tok = new FreezableToken();
        uint256 id = _deadFeedLayer(tok);
        tok.freeze(buyer); // issuer freezes the buyer after bind (Circle blacklist, Paxos freeze)

        t.cancel(id); // cancel moves premium into `owed`, no transfer, so the freeze cannot block it
        assertEq(uint256(_state(id)), uint256(Treaty.State.Cancelled));
        assertGt(fl.maxRedeem(writer), 0, "first-loss writer can exit after cancel");
        assertGt(sr.maxRedeem(writer), 0, "senior writer can exit after cancel");

        vm.prank(buyer);
        vm.expectRevert(); // the frozen buyer still cannot receive a transfer directly
        t.claim(id);

        address rescue = makeAddr("rescue");
        vm.prank(buyer);
        t.claimTo(id, rescue); // buyer redirects the pull to an address the issuer never froze
        assertGt(tok.balanceOf(rescue), 0, "buyer's premium reached the rescue address");
    }

    // ------------------------------------------------------------------------------------------
    // L6-2. No time-bounded exit used to leave an unfixable layer Bound forever with both gates
    // shut once a stopped liveness feed or a reverting market feed made `StillFixable` unresolvable.
    // `CANCEL_BACKSTOP` (30 days past expiry) lifts the liveness-feed check only; the independent
    // v3 review's L-1 made the `_anyMarketFixable` check unconditional, and `_isMarketDead` reads
    // every market feed through try/catch so a reverting feed counts as dead instead of blocking.
    // ------------------------------------------------------------------------------------------

    function _stuckSetup(address feed_, uint256 livenessLastPrint) internal returns (uint256 id) {
        MockUSDG usdg = new MockUSDG();
        live = new MockFeed();
        _deploy(address(usdg), feed_, address(live));
        _fund(address(usdg));
        live.set(1, 1e8, livenessLastPrint);
        feed.set(1, 770e8, THU_HB);
        id = _bind();
        feed.set(2, 771e8, FRI + 19 hours);
        vm.warp(CLOSE + 1);
        t.setReference(id, 0, 2);
    }

    function test_L6_2_control_cancelWorksWhileLivenessFeedPrints() public {
        uint256 id = _stuckSetup(address(new MockFeed()), EXPIRY + 2 days);
        vm.warp(EXPIRY + 3 days);
        t.cancel(id);
        assertGt(fl.maxRedeem(writer), 0);
    }

    function test_L6_2a_backstopUnsticksStoppedLivenessFeed() public {
        // USDC/USD liveness feed's last print is Friday 11:39 UTC, then it is deprecated
        uint256 id = _stuckSetup(address(new MockFeed()), FRI + 11 hours + 39 minutes);
        vm.warp(EXPIRY + 365 days);
        t.cancel(id); // CANCEL_BACKSTOP has long passed; the dead liveness feed no longer blocks cancel
        assertEq(uint256(_state(id)), uint256(Treaty.State.Cancelled));
        assertGt(fl.maxRedeem(writer), 0, "book reopens a year after expiry even with a stopped liveness feed");
    }

    function test_L6_2b_backstopUnsticksRevertingMarketFeed() public {
        BreakableFeed bf = new BreakableFeed();
        uint256 id = _stuckSetup(address(bf), EXPIRY + 40 days);
        bf.breakIt(); // proxy decommissioned after the reference was set
        vm.warp(EXPIRY + 365 days);
        t.cancel(id); // past CANCEL_BACKSTOP the liveness check is skipped; the reverting feed reads as dead (try/catch), so nothing is fixable
        assertEq(uint256(_state(id)), uint256(Treaty.State.Cancelled));
        assertGt(sr.maxRedeem(writer), 0, "book reopens a year after expiry even with a reverting market feed");
    }

    // ------------------------------------------------------------------------------------------
    // L6-3. A fresh in-effect round with an out-of-range answer can be neither referenced nor
    // voided, so the layer can never settle. Round 6 said the 30-day backstop covered it. The
    // independent v3 review's L-1 made the `_anyMarketFixable` check unconditional (a layer that
    // fix could still settle must never cancel for a full refund), which removes that cover:
    // these two tests now PIN the residual, accepted in docs/security/capacity-review.md
    // (Independent v3 review, resolution). They go red the day a third void proof or a Monday
    // bad-answer detector lands, and must then be flipped to assert the cancel.
    // ------------------------------------------------------------------------------------------

    function test_L6_3_residual_badAnswerInEffectRoundStaysBoundPastBackstop() public {
        MockUSDG usdg = new MockUSDG();
        live = new MockFeed();
        _deploy(address(usdg), address(new MockFeed()), address(live));
        _fund(address(usdg));
        live.set(1, 1e8, EXPIRY + 40 days);
        feed.set(1, 770e8, THU_HB);
        uint256 id = _bind();
        feed.set(2, 0, FRI + 19 hours + 45 minutes); // in effect at close, fresh, answer 0
        feed.set(3, 772e8, FRI + 3 days + 4 minutes); // Sunday-night reopen
        feed.set(4, 760e8, EXPIRY + 1 hours); // Monday, first after open
        vm.warp(EXPIRY + 3 days + 30 days);

        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 0, 2); // rule 2, answer
        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 0, 1); // rule 4, superseded before close
        vm.expectRevert(Treaty.BadTiming.selector);
        t.voidReference(id, 0, 2); // not stale
        vm.expectRevert(Treaty.BadRound.selector);
        t.voidReference(id, 0, 1); // rule 4

        vm.expectRevert(Treaty.StillFixable.selector); // L-1: the fixable check is unconditional
        t.cancel(id);
        assertEq(uint256(_state(id)), uint256(Treaty.State.Bound), "accepted residual: layer stays Bound");
        assertEq(fl.maxRedeem(writer), 0, "accepted residual: first-loss gate stays shut");
    }

    /// Same class on the Monday side (unchanged from v2): the first round after expiry carries an
    /// out-of-range answer, a good round follows it, so `fix` rejects both and `_isMarketDead`
    /// (which only reads the latest round) calls the market live.
    function test_L6_3b_residual_badFirstMondayRoundStaysBoundPastBackstop() public {
        MockUSDG usdg = new MockUSDG();
        live = new MockFeed();
        _deploy(address(usdg), address(new MockFeed()), address(live));
        _fund(address(usdg));
        live.set(1, 1e8, EXPIRY + 40 days);
        feed.set(1, 770e8, THU_HB);
        uint256 id = _bind();
        feed.set(2, 771e8, FRI + 19 hours);
        vm.warp(CLOSE + 1);
        t.setReference(id, 0, 2);
        feed.set(3, 0, EXPIRY + 10 minutes);
        feed.set(4, 760e8, EXPIRY + 1 hours);
        vm.warp(EXPIRY + 3 days + 30 days);

        vm.expectRevert(Treaty.BadRound.selector);
        t.fix(id, 0, 3);
        vm.expectRevert(Treaty.NotFirstRound.selector);
        t.fix(id, 0, 4);
        vm.expectRevert(Treaty.StillFixable.selector); // L-1: the fixable check is unconditional
        t.cancel(id);
        assertEq(uint256(_state(id)), uint256(Treaty.State.Bound), "accepted residual: layer stays Bound");
        assertEq(fl.maxRedeem(writer), 0, "accepted residual: first-loss gate stays shut");
    }

    // ------------------------------------------------------------------------------------------
    // L6-4. Holiday-Friday week: the in-effect round is >26h old, so the layer voids and cancels
    // with a full refund. The buyer shut both gates for ~90h at negligible net premium. Accepted
    // for this deploy (docs/security/capacity-review.md Round 6 Resolution): a holiday calendar
    // is later work.
    // ------------------------------------------------------------------------------------------

    function test_L6_4_holidayFridayVoidShutsGatesForFree() public {
        MockUSDG usdg = new MockUSDG();
        live = new MockFeed();
        _deploy(address(usdg), address(new MockFeed()), address(live));
        _fund(address(usdg));
        // Feed pauses on the exchange holiday: last print Thursday 16:18 UTC, next Sunday night.
        feed.set(1, 770e8, THU_HB);
        uint256 before = usdg.balanceOf(buyer);
        uint256 id = _bind(); // Thursday 17:00 UTC, feed 42 min old: bind freshness passes
        feed.set(2, 700e8, FRI + 3 days + 4 minutes); // Sunday-night reopen, 9% gap
        feed.set(3, 690e8, EXPIRY + 5 minutes);

        vm.warp(CLOSE + 1);
        assertTrue(fl.gateActive() && sr.gateActive());
        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 0, 1); // rule 5: 27h42m before close
        t.voidReference(id, 0, 1);

        vm.warp(EXPIRY + 6 hours); // a settled week would have reopened by now
        assertTrue(fl.gateActive() && sr.gateActive(), "gates still shut Monday evening");
        live.set(1, 1e8, FRI + 5 days + 11 hours + 39 minutes); // Wed 11:39 heartbeat
        vm.warp(EXPIRY + 3 days - 1);
        assertTrue(fl.gateActive(), "gates still shut Thursday morning");
        vm.warp(EXPIRY + 3 days);
        t.cancel(id);

        // cancel no longer pushes the refund; the buyer must claim it, same pull as any other
        // Cancelled layer, to actually realize how little this cost them net.
        vm.prank(buyer);
        t.claim(id);
        uint256 netPremium = before - usdg.balanceOf(buyer);
        assertEq(netPremium, 0, "both gates shut Fri 19:30 to Thu 13:30 at zero net premium: accepted (L6-4)");
    }

    // ------------------------------------------------------------------------------------------
    // Info. T5 holds for Treaty's own flows only: a direct transfer leaves a balance with no sweep.
    // ------------------------------------------------------------------------------------------

    function test_L6_info_T5_donationStrandsBalance() public {
        MockUSDG usdg = new MockUSDG();
        _deploy(address(usdg), address(new MockFeed()), address(0));
        usdg.mint(address(this), 1e6);
        usdg.transfer(address(t), 1e6);
        // I-1, accepted: a plain transfer straight to Treaty (not through `bind`) is never swept
        // by any Treaty function; it just sits there. Only the sender of that stray transfer
        // loses, nothing else in the accounting reads Treaty's own balance.
        assertEq(usdg.balanceOf(address(t)), 1e6, "stray transfer strands its balance on Treaty");
    }

    // ------------------------------------------------------------------------------------------
    // Holding: T1, T3 (locked/owed/pending), gate-together, T5 over random settle outcomes.
    // ------------------------------------------------------------------------------------------

    function testFuzz_L6_holding_T1_gateTogether_T5(uint64 mondayBps, uint96 retentionSeed, uint96 limitSeed)
        public
    {
        MockUSDG usdg = new MockUSDG();
        live = new MockFeed();
        _deploy(address(usdg), address(new MockFeed()), address(live));
        _fund(address(usdg));
        live.set(1, 1e8, EXPIRY + 40 days);
        feed.set(1, 770e8, THU_HB);
        uint256 retention = bound(retentionSeed, 0, 100_000e6);
        uint256 limit = bound(limitSeed, 10_000e6, 200_000e6);
        int256[] memory e = new int256[](1);
        e[0] = 2_000_000e6;
        vm.warp(BIND_AT);
        vm.prank(buyer);
        uint256 id = t.bind(0, e, retention, limit, type(uint256).max);
        assertEq(usdg.balanceOf(address(t)), 0, "T5 after bind");

        (,,,,,,,,,, uint256 J, uint256 prem, uint256 pJ, uint256 pS,,,) = t.layers(id);
        assertEq(pJ + pS, prem, "T2 sum");
        assertEq(fl.locked(), J);
        assertEq(sr.locked(), limit - J);
        assertEq(fl.pendingPremium(), pJ);
        assertEq(sr.pendingPremium(), pS);

        feed.set(2, 770e8, FRI + 19 hours);
        vm.warp(CUTOFF);
        assertTrue(fl.gateActive() && sr.gateActive(), "gates shut together");
        vm.warp(CLOSE + 1);
        t.setReference(id, 0, 2);
        uint256 m = bound(mondayBps, 7_000, 13_000);
        feed.set(3, int256(770e8 * m / 10_000), EXPIRY + 1 minutes);
        vm.warp(EXPIRY + 2 minutes);
        t.fix(id, 0, 3);
        assertTrue(!fl.gateActive() && !sr.gateActive(), "gates open together");

        (,,,,,,,,,,,,,, uint256 p, uint256 pj, uint256 ps) = t.layers(id);
        assertEq(pj + ps, p, "T1 sum");
        assertLe(pj, J, "T1 junior cap");
        assertLe(ps, limit - J, "T1 senior cap");
        if (ps > 0) assertEq(pj, J, "T1 senior pays only after junior exhausted");
        assertEq(fl.locked() + sr.locked(), 0, "T3 locked drained");
        assertEq(fl.owed(), pj);
        assertEq(sr.owed(), ps);
        assertEq(fl.pendingPremium() + sr.pendingPremium(), 0, "M1 released");
        if (p > 0) {
            uint256 b0 = usdg.balanceOf(buyer);
            vm.prank(buyer);
            t.claim(id);
            assertEq(usdg.balanceOf(buyer) - b0, p, "claim pays both slices");
            assertEq(fl.owed() + sr.owed(), 0, "claim drains only this layer's owed");
            vm.prank(buyer);
            vm.expectRevert(Treaty.NothingToClaim.selector);
            t.claim(id);
        }
        assertEq(usdg.balanceOf(address(t)), 0, "T5 after settle/claim");
    }
}

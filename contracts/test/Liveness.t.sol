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

/// Decision 3's liveness guard (docs/design/v3.md): bind freshness, warp-safety of that check,
/// the two voidReference proofs, mutual exclusivity of setReference/voidReference, and cancel's
/// livenessFeed gate.
contract LivenessTest is Test, TreatyFixture {
    MockUSDG usdg;
    MockFeed feed;
    MockFeed feedB;
    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");
    uint256 constant FRI = 1_790_294_400; // Fri 2026-09-25 00:00 UTC
    uint256 constant CLOSE = FRI + 20 hours; // DST close
    uint256 constant EXPIRY = FRI + 3 days + 13 hours + 30 minutes;
    uint80 constant P1 = uint80(uint256(1) << 64);
    uint80 constant P2 = uint80(uint256(2) << 64);

    function _deploy(uint256 n, address livenessFeed) internal returns (Treaty t, Capacity firstLoss, Capacity senior) {
        usdg = new MockUSDG();
        feed = new MockFeed();
        feedB = new MockFeed();
        address[] memory feeds = new address[](n);
        feeds[0] = address(feed);
        if (n > 1) feeds[1] = address(feedB);
        t = deployTreaty(
            address(usdg), address(new Pricer(n == 1 ? oneTableId() : nTableIds(n))), feeds, 50, address(0), livenessFeed
        );
        firstLoss = Capacity(t.firstLossVault(0));
        senior = Capacity(t.seniorVault(0));
        usdg.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(address(firstLoss), type(uint256).max);
        firstLoss.deposit(500_000e6, writer);
        usdg.approve(address(senior), type(uint256).max);
        senior.deposit(500_000e6, writer);
        vm.stopPrank();
        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(t), type(uint256).max);
    }

    function _bind(Treaty t, uint256 n) internal returns (uint256 id) {
        int256[] memory e = new int256[](n);
        for (uint256 i; i < n; i++) e[i] = 1_000_000e6;
        vm.prank(buyer);
        id = t.bind(0, e, 0, 60_000e6);
    }

    function _layerState(Treaty t, uint256 id) internal view returns (Treaty.State s) {
        (,,,,, s,,,,,) = layerBasics(t, id);
    }

    /// Liveness guard rule 1: every market's feed must have a round within MAX_ROUND_AGE (26h) of
    /// `block.timestamp`, or bind must reject a layer priced off a feed that is already dead.
    function test_bind_revertsOnStaleFeed() public {
        (Treaty t,,) = _deploy(1, address(0));
        uint256 bindTime = FRI + 10 hours;
        feed.set(1, 770e8, bindTime - 26 hours - 1 seconds); // 26h + 1s old at bind time
        vm.warp(bindTime);
        vm.prank(buyer);
        int256[] memory e = new int256[](1);
        e[0] = 1_000_000e6;
        vm.expectRevert(Treaty.BadRound.selector);
        t.bind(0, e, 0, 60_000e6);
    }

    /// Same check, written as `updatedAt + MAX_ROUND_AGE >= block.timestamp` (addition), must not
    /// underflow when a feed's round timestamp sits ahead of `block.timestamp` (a fork's real
    /// latest round is fixed at a wall-clock time later than a local `vm.warp` has reached). A
    /// subtraction-based check (`block.timestamp - updatedAt`) would revert with an arithmetic
    /// panic here instead of evaluating the freshness condition normally.
    function test_bind_warpSafe() public {
        (Treaty t,,) = _deploy(1, address(0));
        uint256 bindTime = FRI + 10 hours;
        feed.set(1, 770e8, bindTime + 5 hours); // round's own timestamp is ahead of block.timestamp
        vm.warp(bindTime);
        uint256 id = _bind(t, 1);
        assertEq(uint8(_layerState(t, id)), uint8(Treaty.State.Bound), "bind must succeed, not panic");
    }

    /// voidReference's stale proof: the round in effect at close is real (correct phase, correct
    /// timing relative to close) but was already silent for more than MAX_ROUND_AGE before close.
    function test_void_stale() public {
        (Treaty t,,) = _deploy(1, address(0));
        feed.set(P1 | 1, 770e8, CLOSE - 27 hours); // in effect at close, but stale by 1h
        vm.warp(CLOSE - 1 hours);
        uint256 id = _bind(t, 1);
        vm.warp(CLOSE + 1 hours);
        vm.expectRevert(Treaty.BadRound.selector); // rule 5: too stale to be a reference
        t.setReference(id, 0, P1 | 1);
        t.voidReference(id, 0, P1 | 1);
        assertTrue(t.referenceVoid(id, 0));
    }

    /// voidReference's phase proof: the aggregator's phase changed after close, so the round that
    /// was actually in effect at close now sits in an older, unreachable phase; the new phase's
    /// own first round already prints after close, proving the crossing happened too late.
    function test_void_phase() public {
        (Treaty t,,) = _deploy(1, address(0));
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours); // would have been in effect at close...
        vm.warp(CLOSE - 1 hours);
        uint256 id = _bind(t, 1);
        feed.set(P1 | 2, 771e8, CLOSE + 1 hours); // ...but the phase already crossed
        feed.set(P2 | 1, 771e8, CLOSE + 2 hours); // phase 2's own first round prints after close
        vm.warp(CLOSE + 3 hours);
        t.voidReference(id, 0, P2 | 1);
        assertTrue(t.referenceVoid(id, 0));
    }

    /// setReference and voidReference must be permanently mutually exclusive per market: whichever
    /// runs first locks the outcome, and the other reverts unconditionally afterward regardless of
    /// which round id it is called with (both guards run before either function reads the feed).
    function testFuzz_setAndVoidExclusive(bool voidFirst, uint80 laterRoundId) public {
        (Treaty t,,) = _deploy(1, address(0));
        feed.set(P1 | 1, 770e8, CLOSE - 27 hours); // in effect at close, stale: valid for voidReference
        vm.warp(CLOSE - 1 hours);
        uint256 id = _bind(t, 1);
        vm.warp(CLOSE + 1 hours);

        if (voidFirst) {
            t.voidReference(id, 0, P1 | 1);
            vm.expectRevert(Treaty.ReferenceIsVoid.selector);
            t.setReference(id, 0, laterRoundId);
        } else {
            feed.set(P1 | 2, 770e8, CLOSE - 1 hours); // a fresh, referenceable round instead
            t.setReference(id, 0, P1 | 2);
            vm.expectRevert(Treaty.AlreadyFixed.selector);
            t.voidReference(id, 0, laterRoundId);
        }
        assertTrue(t.referenceSet(id, 0) != t.referenceVoid(id, 0), "exactly one outcome, never both, never neither");
    }

    /// Liveness guard rule 3: cancel requires livenessFeed's own latest round to prove the chain
    /// itself kept receiving writes through `expiry + MAX_ROUND_AGE`, or "no fresh equity round"
    /// cannot be told apart from a halted chain starving every feed at once. A liveness round that
    /// stops short of that boundary must block cancel even though the equity market itself is
    /// genuinely dead (no round past expiry at all).
    function test_cancel_revertsWhileChainNotProvenLive() public {
        MockFeed liveness = new MockFeed();
        (Treaty t,,) = _deploy(1, address(liveness));
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours);
        vm.warp(CLOSE - 1 hours);
        uint256 id = _bind(t, 1);
        vm.warp(CLOSE + 1 hours);
        t.setReference(id, 0, P1 | 1);
        liveness.set(1, 1, EXPIRY - 1 hours); // last liveness checkpoint is before expiry

        vm.warp(EXPIRY + 3 days + 1); // past GRACE; equity feed has nothing after EXPIRY at all
        vm.expectRevert(Treaty.StillFixable.selector);
        t.cancel(id);
        assertEq(uint8(_layerState(t, id)), uint8(Treaty.State.Bound));
    }

    /// G3's analogue on RHC settings (CapacityReReview4.t.sol's test_G3_cancelIgnoresSequencerGrace
    /// on Arbitrum): there, cancel stays permanently `Bound` once the sequencer-down window opens,
    /// because the sequencer-uptime feed never participates in proving a market dead, only in
    /// blocking `fix`, so nothing in that test ever demonstrates cancel recovering. RHC carries no
    /// sequencer feed at all (`_requireSequencerUp` is a no-op with `sequencerUptimeFeed ==
    /// address(0)`); its livenessFeed plays the equivalent role but, unlike the sequencer feed,
    /// participates directly in cancel's own aliveness proof, so the same "chain looks halted"
    /// moment does resolve: once the liveness feed itself prints past `expiry + MAX_ROUND_AGE`,
    /// cancel succeeds instead of staying stuck.
    function test_cancel_G3AnalogueOnRHCSettings() public {
        MockFeed liveness = new MockFeed();
        (Treaty t, Capacity firstLoss, Capacity senior) = _deploy(1, address(liveness));
        feed.set(P1 | 1, 770e8, CLOSE - 3 hours);
        vm.warp(CLOSE - 1 hours);
        uint256 id = _bind(t, 1);
        uint256 premium;
        (,,,,,,,,, premium,) = layerBasics(t, id);
        uint256 buyerBefore = usdg.balanceOf(buyer);
        vm.warp(CLOSE + 1 hours);
        t.setReference(id, 0, P1 | 1);
        liveness.set(1, 1, EXPIRY - 1 hours); // liveness stalls right before expiry, same shape as G3

        vm.warp(EXPIRY + 3 days + 1); // GRACE elapsed, chain "looks" halted: no proof of life yet
        vm.expectRevert(Treaty.StillFixable.selector);
        t.cancel(id);
        assertEq(uint8(_layerState(t, id)), uint8(Treaty.State.Bound), "ambiguous moment: cannot yet tell dead market from halted chain");

        liveness.set(2, 1, uint256(EXPIRY) + 3 days + 1); // liveness feed finally proves the chain stayed live, past GRACE too
        vm.warp(uint256(EXPIRY) + 3 days + 2);
        t.cancel(id); // now resolvable, unlike G3's Arbitrum case
        assertEq(uint8(_layerState(t, id)), uint8(Treaty.State.Cancelled));
        assertEq(usdg.balanceOf(buyer), buyerBefore + premium, "premium refunded once the chain is proven live");
        assertEq(firstLoss.locked() + senior.locked(), 0);
    }
}

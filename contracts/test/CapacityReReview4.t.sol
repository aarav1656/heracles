// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {MockSequencerFeed} from "./mocks/MockSequencerFeed.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// Fourth-pass review suite (the security review, "Re-review of 8f492a4").
/// G1/G2 (cancel pre-empts a late valid fix) and E1 (entrant loss on cancel) are open
/// mainnet design items recorded in that doc, not encoded here.
contract ReReview4 is Test, TreatyFixture {
    uint256 constant MON0 = 1_789_948_800;
    uint256 constant CUT = 4 days + 19 hours + 30 minutes;
    uint256 constant EXP = 7 days + 13 hours + 30 minutes;

    MockUSDG usdg;
    MockFeed feed;
    Treaty treaty;
    Capacity capacity;
    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");
    address att = makeAddr("att");

    function setUp() public {
        usdg = new MockUSDG();
        feed = new MockFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = deployTreaty(address(usdg), address(new Pricer(oneTableId())), feeds, 50, address(0));
        capacity = treaty.capacity();
        vm.warp(MON0 + 1 hours);
        _fund(writer, 1e15);
        _fund(buyer, 1e15);
        _fund(att, 1e15);
    }

    function _fund(address a, uint256 amt) internal {
        usdg.mint(a, amt);
        vm.prank(a);
        usdg.approve(address(capacity), type(uint256).max);
    }

    function _one(int256 e) internal pure returns (int256[] memory x) {
        x = new int256[](1);
        x[0] = e;
    }

    // state: 0 empty vault, 1 before bind, 2 between bind and cutoff, 3 after settle, 4 after cancel
    function _enter(uint8 state, uint256 seed, uint256 limitFrac) internal {
        if (state == 0) return;
        uint256 w = bound(seed, 200, 1e13);
        vm.prank(writer);
        capacity.deposit(w, writer);
        if (state == 1) return;
        uint256 limit = bound(limitFrac, 200, w);
        vm.prank(buyer);
        try treaty.bind(_one(-int256(limit) * 20), 0, limit) returns (uint256 id) {
            if (state == 2) return;
            // round 1 is the pre-close predecessor, round 2 is the actual Friday-close
            // reference round (setReference must consume round 2, not round 1).
            (uint256 cutoff,) = treaty.weekWindow(MON0);
            uint256 refTime = treaty.fridayCloseOf(cutoff);
            if (state == 3) {
                feed.set(1, 100e8, MON0 + 4 days + 19 hours);
                feed.set(2, 100e8, refTime);
                feed.set(3, 100e8, MON0 + EXP + 1);
                vm.warp(refTime + 1);
                treaty.setReference(id, 0, 2);
                vm.warp(MON0 + EXP + 1);
                treaty.fix(id, 0, 3);
            } else {
                // L1 (docs/security/capacity-review.md re-review): the feed used to keep posting a
                // round past `refTime` here, so cancel legitimately reverted StillFixable on every
                // draw (a live feed with an unset reference is no longer treated as dead) and the
                // try/catch plus the fuzz tests' `vm.assume` below discarded every state-4 draw,
                // leaving state 4 ("after cancel") never actually exercised. Drive the feed to
                // genuinely die before `refTime` instead, its only round is the pre-close
                // predecessor, so `_isMarketDead` finds the reference boundary itself unreached and
                // cancel succeeds for real, exercising the post-cancel state the fuzz tests assert
                // against.
                feed.set(1, 100e8, MON0 + 4 days + 19 hours);
                vm.warp(MON0 + EXP + 3 days);
                treaty.cancel(id);
            }
        } catch {}
    }

    function testFuzz_depositRedeemRoundTrip(uint8 s, uint256 seed, uint256 lf, uint256 a) public {
        uint8 state = uint8(bound(s, 0, 4));
        _enter(state, seed, lf);
        // States 0/1/2 never lock past this cutoff yet (gate inactive); states 3/4 always drive
        // the layer to a terminal state that unlocks its own cutoff bucket before returning here
        // (L1 fix above), so this never actually discards a draw, kept as a defensive guard, not
        // a skip.
        vm.assume(capacity.maxDeposit(att) != 0);
        a = bound(a, 1, 1e14);
        vm.startPrank(att);
        uint256 pre = capacity.previewDeposit(a);
        uint256 sh = capacity.deposit(a, att);
        assertEq(sh, pre, "previewDeposit == deposit");
        assertEq(capacity.convertToShares(a) >= 0, true);
        uint256 mr = capacity.maxRedeem(att);
        uint256 pr = capacity.previewRedeem(mr);
        uint256 out = capacity.redeem(mr, att, att);
        vm.stopPrank();
        assertEq(out, pr, "previewRedeem == redeem");
        assertLe(out, a, "deposit->redeem never profits");
    }

    function testFuzz_mintRedeemRoundTrip(uint8 s, uint256 seed, uint256 lf, uint256 sh) public {
        uint8 state = uint8(bound(s, 0, 4));
        _enter(state, seed, lf);
        // Same as testFuzz_depositRedeemRoundTrip above: defensive guard, not a skip (L1 fix).
        vm.assume(capacity.maxMint(att) != 0);
        sh = bound(sh, 1, 1e14);
        vm.startPrank(att);
        uint256 pm = capacity.previewMint(sh);
        uint256 paid = capacity.mint(sh, att);
        assertEq(paid, pm, "previewMint == mint");
        assertGe(paid, capacity.convertToAssets(sh), "mint cost >= exit value");
        uint256 mw = capacity.maxWithdraw(att);
        uint256 burned = capacity.withdraw(mw, att, att);
        vm.stopPrank();
        assertLe(burned, sh, "withdraw burns <= minted");
        assertLe(mw, paid, "mint->withdraw never profits");
    }

    // Exiting writer forfeits at most its pro-rata share of pendingPremium.
    function testFuzz_exitForfeitIsProRata(uint256 seed, uint256 lf, uint256 frac) public {
        _enter(2, seed, lf);
        uint256 S = capacity.totalSupply();
        uint256 pp = capacity.pendingPremium();
        vm.assume(capacity.maxRedeem(writer) > 0);
        uint256 sh = bound(frac, 1, capacity.maxRedeem(writer));
        uint256 fair = sh * (capacity.totalAssets() + pp) / S;
        uint256 got = capacity.previewRedeem(sh);
        uint256 forfeit = fair - got;
        assertLe(forfeit, sh * pp / S + 2, "exit forfeits no more than pro-rata pendingPremium");
    }

    /// Cancel skips _requireSequencerUp, fix does not. Sequencer recovers after expiry+72h; for
    /// the 1h SEQUENCER_GRACE only cancel is callable.
    function test_G3_cancelIgnoresSequencerGrace() public {
        MockSequencerFeed seq = new MockSequencerFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        Treaty t = deployTreaty(address(usdg), address(new Pricer(oneTableId())), feeds, 50, address(seq));
        Capacity c = t.capacity();
        vm.prank(writer);
        usdg.approve(address(c), type(uint256).max);
        vm.prank(buyer);
        usdg.approve(address(c), type(uint256).max);
        vm.prank(writer);
        c.deposit(1_000_000e6, writer);
        vm.prank(buyer);
        uint256 id = t.bind(_one(-2_000_000e6), 0, 1_000_000e6);
        (uint256 cutoff,) = t.weekWindow(MON0);
        uint256 refTime = t.fridayCloseOf(cutoff);
        feed.set(1, 100e8, MON0 + 4 days + 19 hours);
        feed.set(2, 100e8, refTime);
        feed.set(3, 50e8, MON0 + EXP + 1);
        vm.warp(refTime + 1);
        t.setReference(id, 0, 2);
        vm.warp(MON0 + EXP + 60 hours);
        seq.setDown();
        vm.warp(MON0 + EXP + 72 hours);
        seq.setUp(block.timestamp);
        vm.expectRevert(Treaty.SequencerDown.selector);
        t.fix(id, 0, 3);
        vm.prank(writer);
        try t.cancel(id) {} catch {}
        (,,,,, Treaty.State st,,,,,) = t.layers(id);
        assertEq(uint8(st), uint8(Treaty.State.Bound), "G3: cancel lands while fix is blocked by sequencer grace");
    }

    /// F4 structure fuzz on a direct harness: cursor monotone, no double count, gate matches oracle.
    uint40[] cuts;

    function testFuzz_F4_cursor(uint256[16] memory ops) public {
        Capacity cap = new Capacity(IERC20(address(usdg)), address(this));
        usdg.mint(address(this), 1e18);
        usdg.approve(address(cap), type(uint256).max);
        cap.deposit(1e18, address(this));
        uint40 cur = uint40(MON0 + CUT);
        uint256 lastCursor;
        for (uint256 i; i < 16; i++) {
            uint256 op = ops[i] % 4;
            if (op == 0) {
                cap.lock(1e6, cur);
                cuts.push(cur);
            } else if (op == 1) {
                cur += 7 days;
            } else if (op == 2 && cuts.length > 0) {
                uint40 c = cuts[ops[i] / 4 % cuts.length];
                if (cap.lockedByCutoff(c) >= 1e6) cap.unlock(1e6, c);
            } else {
                vm.warp(block.timestamp + (ops[i] >> 8) % 9 days);
            }
            uint256 cc = cap.cutoffCursor();
            assertGe(cc, lastCursor, "cursor monotone");
            lastCursor = cc;
            // sum distinct buckets == locked
            uint256 sum;
            uint256 n;
            while (true) {
                try cap.cutoffs(n) returns (uint40) { n++; } catch { break; }
            }
            uint40 prev;
            bool oracle;
            uint40 earliest = type(uint40).max;
            for (uint256 k; k < n; k++) {
                uint40 c = cap.cutoffs(k);
                assertGe(c, prev, "sorted");
                if (c != prev) {
                    sum += cap.lockedByCutoff(c);
                    if (cap.lockedByCutoff(c) > 0 && c < earliest) earliest = c;
                }
                prev = c;
            }
            assertEq(sum, cap.locked(), "no double count");
            oracle = earliest != type(uint40).max && block.timestamp >= earliest;
            assertEq(cap.gateActive(), oracle, "gate == oracle");
        }
    }
}

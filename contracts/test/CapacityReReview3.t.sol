// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PermitUSDG} from "./CapacityReReview.t.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";

/// Re-review of 96309c8. Every test here is red on 96309c8 (the security review
/// "Re-review of 96309c8"). F1 and F4 are ported unmodified and green after Resolution 3 (GRACE
/// lowered, refilled-drained-bucket guard). F2, F3 and F5 are rewritten to assert the fixed
/// contract's actual, intended behaviour rather than the reviewer's literal pre-fix assertions,
/// per Resolution 3's own note on each:
/// - F2's fix rejects the poisoning exposure at `bind` instead of letting it in and later panic at
///   `fix`, so there is no unfixable layer left to observe; the test now asserts the revert.
/// - F3's fix makes the JIT depositor's entry price include `pendingPremium`, so their previewed
///   redemption is at or fractionally below what they deposited (floor-rounding dust), not above
///   it; the original subtraction underflows on that dust, so the test compares absolute amounts.
/// - F5 is deliberately not fixed on-chain (Resolution 3): the test now documents the accepted
///   behaviour (permit still wipes a standing allowance) instead of asserting the un-chosen fix.
contract ReReview3Findings is Test {
    uint256 constant MON0 = 1_789_948_800; // Monday 00:00 UTC, week 0
    uint256 constant CUT = 4 days + 19 hours + 30 minutes; // Fri 19:30 offset in a week
    uint256 constant EXP = 7 days + 13 hours + 30 minutes; // following Mon 13:30

    MockUSDG usdg;
    MockFeed feed;
    Treaty treaty;
    Capacity capacity;
    address writer = makeAddr("writer");
    address griefer = makeAddr("griefer");

    function setUp() public {
        usdg = new MockUSDG();
        feed = new MockFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = new Treaty(address(usdg), address(new Pricer(oneTableId())), feeds, 50, address(0));
        capacity = treaty.capacity();
        vm.warp(MON0 + 1 hours);
        _fund(writer, 100_000e6);
        vm.prank(writer);
        capacity.deposit(100_000e6, writer);
        _fund(griefer, 1_000_000e6);
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

    /// MEDIUM F1. Feed stops producing Monday rounds (deprecation, phase change, outage). `bind`
    /// never looks at the feed, so one dust bind per week keeps a past-cutoff bucket nonzero at
    /// every instant: layer k is cancellable at C_k + 66h + 7d = C_k + 234h, which is exactly
    /// expiry of layer k+1, whose cutoff C_k + 168h has already closed the gate. Writers cancel at
    /// the first legal second and still never see the gate open. Premium is refunded on cancel,
    /// so the griefer's net USDG cost is 0; only bind gas.
    function test_F1_deadFeedPlusWeeklyDustBindFreezesForever() public {
        // Only week 0 has a Friday round; no Monday round ever arrives.
        feed.set(1, 100e8, MON0 + 4 days + 19 hours);
        uint256 start = usdg.balanceOf(griefer);
        uint256[] memory ids = new uint256[](12);
        uint256 nIds;
        uint256 openHours;
        uint256 sampled;
        for (uint256 t = MON0 + 1 hours + 1; t < MON0 + 10 weeks; t += 1 hours) {
            vm.warp(t);
            uint256 inWeek = (t - MON0) % 7 days;
            // griefer: one 200-unit layer each Monday 00:00-01:00 (weeks 0..9)
            if (inWeek < 1 hours || (t - MON0) < 2 hours) {
                (uint256 c,) = treaty.weekWindow(t);
                if (nIds == 0 || _cutoff(ids[nIds - 1]) != c) {
                    vm.prank(griefer);
                    ids[nIds++] = treaty.bind(_one(1e6), 1_000_000e6, 200);
                }
            }
            // writers: cancel every layer at the first legal moment
            for (uint256 i; i < nIds; i++) {
                try treaty.cancel(ids[i]) {} catch {}
            }
            if (t >= MON0 + CUT && t < MON0 + 9 weeks) {
                sampled++;
                if (capacity.maxRedeem(writer) > 0) openHours++;
            }
        }
        console2.log("hours sampled after first cutoff", sampled);
        console2.log("hours with gate open", openHours);
        console2.log("griefer net USDG spend (base units)", start - usdg.balanceOf(griefer));
        assertGt(openHours, 0, "F1: dead feed + weekly dust bind freezes writers for 9 weeks straight");
    }

    function _cutoff(uint256 id) internal view returns (uint256 c) {
        (, uint40 cc,,,,,,,,,) = treaty.layers(id);
        c = cc;
    }

    /// LOW F2. `_settle` does `exposure[i] * gapBps` in checked int256. The Pricer only ever
    /// multiplies by the table's gaps (|gap| <= 1474), so an exposure near int256.max / 1474
    /// quotes fine, but a real weekend move beyond 14.74% makes the last `fix` panic forever. The
    /// layer can only be cancelled after 7 days, the gate stays shut from Friday cutoff to
    /// expiry + 7d (234h instead of ~66h), and the griefer gets the premium back.
    ///
    /// Resolution 3 fixes this at the source: `bind` now bounds `|exposure[i]|` and `retention`,
    /// so the poisoning exposure below can never be bound in the first place, and there is no
    /// unfixable layer left for the rest of the reviewer's scenario to observe. Rewritten to
    /// assert the revert.
    function test_F2_overflowExposureMakesLayerUnfixable() public {
        int256 e = type(int256).max / 1474;
        uint256 retention = uint256(e) * 1474 / 10000 + 1; // above every Pricer scenario loss
        vm.prank(griefer);
        vm.expectRevert(Treaty.BadParams.selector);
        treaty.bind(_one(e), retention, 200);
    }

    /// MEDIUM F3. Between bind and cutoff the gate is open and deposits price at face value with
    /// the bound layer's premium excluded (pendingPremium). A depositor arriving Friday 19:29,
    /// after the layer is fully backed by existing writers, takes a pro-rata cut of that premium
    /// at settle. Risk is also pro rata, so this is not theft of principal, but premium is priced
    /// at 1.25 EL + 0.5 TVaR95 > EL, so the load (writers' expected profit) moves from the writers
    /// whose capacity was reserved all week to capital that contributed none of it. Under b71cf94
    /// the same deposit reverted (gate closed from bind).
    function test_F3_jitDepositAfterBindDilutesPremium() public {
        address buyer = makeAddr("buyer");
        _fund(buyer, 10_000_000e6);
        vm.prank(buyer);
        uint256 id = treaty.bind(_one(-2_000_000e6), 0, 100_000e6); // fully uses writer's capacity
        (,,,,,,,,, uint256 premium,) = treaty.layers(id);
        assertEq(capacity.totalAssets() - capacity.locked(), 0, "writer's capacity fully reserved");

        address jit = makeAddr("jit");
        _fund(jit, 900_000e6);
        vm.warp(MON0 + CUT - 1); // Friday 19:29:59
        vm.prank(jit);
        uint256 jitShares = capacity.deposit(900_000e6, jit);

        // round 2: first round at/after Friday's close (MON0's week is Sept 2026, DST/EDT, so
        // close = Friday 20:00 UTC = MON0 + 4 days + 20 hours); round 1 (pre-close, 19:00 UTC)
        // is its required strictly-earlier predecessor.
        feed.set(1, 100e8, MON0 + 4 days + 19 hours);
        feed.set(2, 100e8, MON0 + 4 days + 20 hours);
        feed.set(3, 100e8, MON0 + EXP + 1); // flat weekend, payout 0
        vm.warp(MON0 + 5 days + 1);
        treaty.setReference(id, 0, 2);
        vm.warp(MON0 + EXP + 1);
        treaty.fix(id, 0, 3);

        uint256 writerRedeem = capacity.previewRedeem(capacity.balanceOf(writer));
        uint256 jitRedeem = capacity.previewRedeem(jitShares);
        console2.log("premium", premium);
        console2.log("writer redeem (deposited 100_000e6)", writerRedeem);
        console2.log("JIT redeem (deposited 900_000e6, 66h in, zero capacity contributed)", jitRedeem);
        // Resolution 3 prices the JIT deposit against totalAssets() + pendingPremium, so the
        // entrant pays for the premium already earned instead of buying at a discount. The writer
        // still captures essentially all of it (own capital plus premium, less the JIT's own
        // pro-rata share of the now fairly-priced pool), and the JIT depositor gets back at most
        // what it put in, never a cut of premium it did not underwrite (comparing absolute
        // amounts, not a difference, since floor-rounding can put the JIT's redeem fractionally
        // below its deposit).
        assertGe(writerRedeem, 100_000e6 + premium * 99 / 100, "F3: writer captures the premium it alone underwrote");
        assertLe(jitRedeem, 900_000e6, "F3: JIT depositor never redeems more than it deposited");
    }

    /// INFO F4 (latent). `lock` only pushes a cutoff if it differs from the last entry. If the last
    /// bucket drained (cursor == cutoffs.length) and a later lock reuses that same cutoff, the
    /// bucket refills without a push, the cursor sits past it, and gateActive() stays false through
    /// that cutoff. Unreachable through today's Treaty (a bucket only drains after expiry, and bind
    /// reverts after cutoff), so this is a guard for any future Treaty that can release a layer
    /// before its cutoff (buyer cancel, early close).
    function test_F4_refilledDrainedBucketNeverClosesGate() public {
        Capacity cap = new Capacity(IERC20(address(usdg)), address(this));
        usdg.mint(address(this), 1_000e6);
        usdg.approve(address(cap), type(uint256).max);
        cap.deposit(1_000e6, address(this));
        uint40 c = uint40(MON0 + CUT);
        cap.lock(100e6, c);
        cap.unlock(100e6, c); // drained before its cutoff
        cap.lock(100e6, c); // refilled, same cutoff, no push
        vm.warp(c + 1);
        assertEq(cap.lockedByCutoff(c), 100e6);
        assertTrue(cap.gateActive(), "F4: live bucket past its cutoff but gate reports open");
    }

    /// INFO F5 (L1 reopened by design). depositWithPermit always runs permit, so a writer with a
    /// standing max approval (also a premium payer) ends the call with allowance 0. Mitigated only
    /// in the web hook, and only when the standing allowance already covers `assets`.
    ///
    /// Resolution 3 keeps this as is (no funds at risk, UX only, and always-consuming the permit
    /// is what closes L1r, the security review "Re-review of b71cf94"): the
    /// contract-level trade-off is unchanged. Rewritten to assert the accepted, documented
    /// behaviour instead of the reviewer's finding-style assertion of the un-chosen fix.
    function test_F5_permitStillWipesStandingAllowance() public {
        PermitUSDG pu = new PermitUSDG();
        Capacity cap = new Capacity(pu, address(this));
        uint256 pk = 0xB0B;
        address w = vm.addr(pk);
        pu.mint(w, 10_000e6);
        vm.prank(w);
        pu.approve(address(cap), type(uint256).max);
        uint256 assets = 1_000e6;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                pu.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        w,
                        address(cap),
                        assets,
                        pu.nonces(w),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        vm.prank(w);
        cap.depositWithPermit(assets, w, deadline, v, r, s);
        assertEq(pu.allowance(w, address(cap)), 0, "F5 (accepted, not fixed on-chain): permit always wipes a standing allowance");
    }
}

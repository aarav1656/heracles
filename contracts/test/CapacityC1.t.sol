// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// the security review's Critical C1 and Low L2. Ported from the
/// reviewer's scratch suite at the reviewer's own scratch copy. These tests are red against the code
/// they were written against: `Capacity.totalAssets()` marked every locked USDG down to zero, so
/// a deposit made while a layer is live bought the pool at a near-zero share price and could
/// redeem the writers' capital after settle. Green once `Capacity` counts active `locked`
/// capital at face value, tracks a settled-but-unclaimed payout separately in `owed`, and closes
/// deposits/withdrawals while any layer is live.
contract CapacityC1Test is Test {
    uint256 constant FRI_CLOSE = 1_790_366_400;
    uint256 constant FRI_1900 = FRI_CLOSE - 1 hours;
    uint256 constant CUTOFF = FRI_CLOSE - 30 minutes;
    uint256 constant SAT_MIDNIGHT = CUTOFF + 4 hours + 30 minutes;
    uint40 constant MONDAY = uint40(FRI_CLOSE + 2 days + 17 hours + 30 minutes);

    MockUSDG usdg;
    MockFeed feed;
    Treaty treaty;
    Capacity capacity;

    address writer = makeAddr("writer");
    address writerB = makeAddr("writerB");
    address attacker = makeAddr("attacker");

    function setUp() public {
        usdg = new MockUSDG();
        feed = new MockFeed();
        feed.set(1, 100e8, FRI_1900 - 10 minutes);
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = new Treaty(address(usdg), address(new Pricer()), feeds, 50, address(0));
        capacity = treaty.capacity();
        _deposit(writer, 100_000e6);
        _deposit(writerB, 100_000e6);
        vm.warp(FRI_1900);
    }

    function _deposit(address who, uint256 amt) internal {
        usdg.mint(who, amt);
        vm.startPrank(who);
        usdg.approve(address(capacity), type(uint256).max);
        capacity.deposit(amt, who);
        vm.stopPrank();
    }

    function _one(int256 e) internal pure returns (int256[] memory x) {
        x = new int256[](1);
        x[0] = e;
    }

    function _settleNoLoss(uint256 id) internal {
        // Item 6: setReference now waits for `fridayCloseOf` (FRI_CLOSE), not Saturday midnight;
        // round 1 (set in setUp, FRI_1900 - 10 minutes) is its required strictly-earlier
        // predecessor, round 2 is the first fresh round at/after FRI_CLOSE.
        feed.set(2, 100e8, FRI_CLOSE);
        vm.warp(FRI_CLOSE + 1);
        treaty.setReference(id, 0, 2);
        feed.set(3, 100e8, MONDAY + 1); // flat weekend, zero payout
        vm.warp(uint256(MONDAY) + 60);
        treaty.fix(id, 0, 3);
    }

    /// CRITICAL. Attacker is both buyer and depositor. Binds a layer that locks all free capacity
    /// (retention far above any loss, so it can never pay), deposits a small amount while
    /// totalAssets() == 0, waits for a zero-payout settle, redeems. Correct behaviour: the attacker
    /// ends with at most what they put in (premium + deposit). Buggy behaviour: they walk off with
    /// the writers' 200k.
    function test_C1_depositWhileLockedStealsWriterCapital() public {
        uint256 free = capacity.totalAssets();
        assertEq(free, 200_000e6);

        usdg.mint(attacker, 2_000e6);
        vm.startPrank(attacker);
        usdg.approve(address(capacity), type(uint256).max);
        uint256 id = treaty.bind(_one(1e6), 1_000_000e6, free); // payout always 0, premium = floor
        uint256 shares;
        try capacity.deposit(1_000e6, attacker) returns (uint256 sh) {
            shares = sh;
        } catch {}
        vm.stopPrank();

        _settleNoLoss(id);

        vm.prank(attacker);
        if (shares != 0) capacity.redeem(shares, attacker, attacker);
        assertLe(
            usdg.balanceOf(attacker), 2_000e6, "C1: depositor during a live layer must not capture writers' locked capital"
        );
    }

    /// Same root cause, honest-user side: a writer who redeems while a layer is live must not be
    /// paid as if the locked capital were already lost. The epoch gate that closes C1 also closes
    /// the exit itself while the layer is live (a bounded, weekend-length window); the value
    /// behind the shares must stay intact either way.
    function test_C1b_redeemWhileLockedForfeitsLockedCapital() public {
        usdg.mint(attacker, 10_000e6);
        vm.startPrank(attacker);
        usdg.approve(address(capacity), type(uint256).max);
        treaty.bind(_one(1e6), 1_000_000e6, 100_000e6); // half the pool locked, cannot pay
        vm.stopPrank();
        uint256 shares = capacity.balanceOf(writerB);
        vm.prank(writerB);
        try capacity.redeem(shares, writerB, writerB) returns (uint256 out) {
            assertGe(out, 99_000e6, "C1b: a writer exiting before a zero-loss settle should get ~their 100k back");
        } catch {
            assertGe(capacity.previewRedeem(shares), 99_000e6, "C1b: exit blocked but value intact");
        }
    }

    /// LOW (L2). The H2 premium floor (limit * 50 / 1e4) rounds to zero under 200 base units, so a
    /// free layer binds. Harmless alone; once C1's epoch gate closes deposits and withdrawals
    /// while a layer is live, a zero-cost dust bind becomes a repeatable weekly griefing lock on
    /// every writer's capital. Chosen fix: revert instead of binding for zero premium.
    function test_L2_dustLimitCannotBindForZeroPremium() public {
        address griefer = makeAddr("griefer");
        vm.prank(griefer);
        vm.expectRevert(Treaty.BadParams.selector);
        treaty.bind(_one(1e6), 1_000_000e6, 199);
    }
}

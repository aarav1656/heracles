// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

contract TreatyTest is Test {
    uint256 constant T0 = 1_790_000_000; // a Monday; that week's Fri 19:30/Mon 13:30 below
    uint256 constant CUTOFF = 1_790_364_600; // Fri 2026-09-25 19:30 UTC (T0's week)
    uint256 constant SAT_MIDNIGHT = CUTOFF + 4 hours + 30 minutes;
    uint40 constant EXPIRY = uint40(1_790_602_200); // Mon 2026-09-28 13:30 UTC

    int256 constant FRIDAY_PRICE = 100e8;
    int256 constant MONDAY_PRICE = 90e8; // -10% weekend gap

    uint256 constant RETENTION = 20_000e6;
    uint256 constant LIMIT = 60_000e6;
    int256 constant EXPOSURE = 2_000_000e6;

    MockUSDG usdg;
    MockFeed feed;
    Pricer pricer;
    Treaty treaty;
    Capacity capacity;

    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer();
        feed = new MockFeed();
        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);

        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = new Treaty(address(usdg), address(pricer), feeds, 50, address(0));
        capacity = treaty.capacity();

        usdg.mint(writer, 1_000_000e6);
        vm.prank(writer);
        usdg.approve(address(capacity), type(uint256).max);
        vm.prank(writer);
        capacity.deposit(500_000e6, writer);

        usdg.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(capacity), type(uint256).max);

        vm.warp(T0);
    }

    function _exposure() internal pure returns (int256[] memory e) {
        e = new int256[](1);
        e[0] = EXPOSURE;
    }

    function _layerBuyer(uint256 id) internal view returns (address b) {
        (b,,,,,,,,,,) = treaty.layers(id);
    }

    function _layerRetention(uint256 id) internal view returns (uint256 r) {
        (,,,,,,, r,,,) = treaty.layers(id);
    }

    function _layerLimit(uint256 id) internal view returns (uint256 l) {
        (,,,,,,,, l,,) = treaty.layers(id);
    }

    function _layerPremium(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,, p,) = treaty.layers(id);
    }

    function _layerState(uint256 id) internal view returns (Treaty.State s) {
        (,,,,,s,,,,,) = treaty.layers(id);
    }

    function _layerPayout(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,,, p) = treaty.layers(id);
    }

    function test_bindLocksCapacityAndPullsPremium() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);

        assertEq(_layerBuyer(id), buyer);
        assertEq(_layerRetention(id), RETENTION);
        assertEq(_layerLimit(id), LIMIT);
        assertGt(_layerPremium(id), 0);
        assertEq(capacity.locked(), LIMIT);
        assertEq(usdg.balanceOf(address(capacity)), 500_000e6 + _layerPremium(id));
    }

    function test_bindRevertsOnBadTiming() public {
        vm.warp(CUTOFF); // exactly at cutoff: no longer strictly before it
        vm.prank(buyer);
        vm.expectRevert(Treaty.BadTiming.selector);
        treaty.bind(_exposure(), RETENTION, LIMIT);
    }

    function test_bindRevertsOnZeroExposure() public {
        int256[] memory zero = new int256[](1);
        vm.prank(buyer);
        vm.expectRevert(Treaty.BadParams.selector);
        treaty.bind(zero, RETENTION, LIMIT);
    }

    function test_bindRevertsOnZeroLimit() public {
        vm.prank(buyer);
        vm.expectRevert(Treaty.BadParams.selector);
        treaty.bind(_exposure(), RETENTION, 0);
    }

    function test_setReferenceRevertsIfFridayRoundTooOld() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        feed.set(1, FRIDAY_PRICE, SAT_MIDNIGHT - 25 hours); // older than REF_WINDOW (24h)
        vm.warp(SAT_MIDNIGHT + 1);
        vm.expectRevert(Treaty.BadRound.selector);
        treaty.setReference(id, 0, 1);
    }

    function test_setReferenceRevertsBeforeSaturday() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        vm.expectRevert(Treaty.BadTiming.selector);
        treaty.setReference(id, 0, 1);
    }

    function _bindReferenceAndFix() internal returns (uint256 id) {
        vm.prank(buyer);
        id = treaty.bind(_exposure(), RETENTION, LIMIT);

        vm.warp(SAT_MIDNIGHT + 1);
        treaty.setReference(id, 0, 1);

        feed.set(2, MONDAY_PRICE, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        treaty.fix(id, 0, 2);
    }

    function test_fixBeforeExpiryReverts() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        vm.warp(SAT_MIDNIGHT + 1);
        treaty.setReference(id, 0, 1);
        feed.set(2, MONDAY_PRICE, uint256(EXPIRY) + 10);
        // Still before expiry: the deliberate-failure demo path.
        vm.warp(uint256(EXPIRY) - 1);
        vm.expectRevert(Treaty.EarlyFix.selector);
        treaty.fix(id, 0, 2);
    }

    function test_fixRevertsIfReferenceNotSet() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        feed.set(2, MONDAY_PRICE, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        vm.expectRevert(Treaty.ReferenceNotSet.selector);
        treaty.fix(id, 0, 2);
    }

    function test_fixSettlesAndClampsPayoutAtLimit() public {
        uint256 id = _bindReferenceAndFix();
        assertEq(uint8(_layerState(id)), uint8(Treaty.State.Settled));
        // Real loss is 180_000e6 (10% of 2,000,000e6 exposure, less 20,000e6 retention); the
        // layer only locked 60_000e6, so payout must clamp there, not at the uncapped loss.
        assertEq(_layerPayout(id), LIMIT);
        assertGt(_layerPremium(id), 0);
        // the C1 fix: settle moves the whole layer (unused + payout) out of `locked`; a full-
        // limit payout (unused == 0 here) now sits in `owed` until claimed, not in `locked`.
        assertEq(capacity.locked(), 0);
        assertEq(capacity.owed(), LIMIT); // payout stays reserved (owed), not locked, until claimed
    }

    function test_claimPaysBuyerAndReleasesLock() public {
        uint256 id = _bindReferenceAndFix();
        uint256 before = usdg.balanceOf(buyer);
        vm.prank(buyer);
        treaty.claim(id);
        assertEq(usdg.balanceOf(buyer), before + LIMIT);
        assertEq(capacity.locked(), 0);
    }

    function test_claimTwiceReverts() public {
        uint256 id = _bindReferenceAndFix();
        vm.prank(buyer);
        treaty.claim(id);
        vm.prank(buyer);
        vm.expectRevert(Treaty.NothingToClaim.selector);
        treaty.claim(id);
    }

    function test_claimByNonBuyerReverts() public {
        uint256 id = _bindReferenceAndFix();
        vm.expectRevert(Treaty.NothingToClaim.selector);
        treaty.claim(id); // called by the test contract, not `buyer`
    }

    function test_cancelAfterGraceRefundsPremiumAndReleasesFullLimit() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        uint256 premium = _layerPremium(id);
        uint256 buyerBefore = usdg.balanceOf(buyer);
        vm.warp(uint256(EXPIRY) + 7 days + 1);
        treaty.cancel(id);
        assertEq(capacity.locked(), 0);
        assertEq(usdg.balanceOf(buyer), buyerBefore + premium);
    }

    function test_cancelBeforeGraceReverts() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(_exposure(), RETENTION, LIMIT);
        vm.warp(uint256(EXPIRY) + 1);
        vm.expectRevert(Treaty.BadTiming.selector);
        treaty.cancel(id);
    }

    /// H1 fix: bind happens at T0, more than 4 days before this layer's own cutoff, so the gate
    /// itself is still open (this is not testing C1's gate closure, WeekWindow/AttackReview cover
    /// that). What must still hold at all times, gate open or closed, is the free-capacity cap:
    /// a withdrawal can never reach the capital this layer reserved.
    function test_writerCannotWithdrawLockedCapacity() public {
        vm.prank(buyer);
        treaty.bind(_exposure(), RETENTION, LIMIT);
        uint256 totalBefore = capacity.totalAssets();
        uint256 freeCap = totalBefore - capacity.locked();
        uint256 maxRedeemable = capacity.maxRedeem(writer);
        vm.prank(writer);
        uint256 assetsOut = capacity.redeem(maxRedeemable, writer, writer);
        assertLe(assetsOut, freeCap + 1, "writer must never redeem more than free capacity"); // +1 floor slack
        assertLt(assetsOut, totalBefore, "redeem must be capped below the live layer's own reservation");
    }
}

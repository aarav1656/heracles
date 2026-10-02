// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {IPricer} from "../src/IPricer.sol";
import {OIGuard} from "../src/OIGuard.sol";
import {VaultCover} from "../src/VaultCover.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";
import {LinearPricer} from "./OIGuard.t.sol";

/// VaultCover on the real Treaty, Capacity vaults and Solidity pricer, with the OIGuard on the
/// linear test pricer (premium = 1% of gross book + 0.1% of the guard's limit) so every guard
/// number is written down by hand. Book markets: 0, 1, 2; the Treaty's one market covers book
/// market 1.
contract VaultCoverTest is Test, TreatyFixture {
    uint256 constant T0 = 1_790_000_000; // Monday; that week's Friday cutoff is CUTOFF
    uint256 constant CUTOFF = 1_790_364_600; // Fri 2026-09-25 19:30 UTC
    uint256 constant REF_TIME = CUTOFF + 30 minutes;
    uint256 constant EXPIRY = 1_790_602_200; // Mon 2026-09-28 13:30 UTC
    int256 constant FRIDAY_PRICE = 100e8;
    int256 constant MONDAY_PRICE = 90e8;
    uint256 constant RETENTION = 20_000e6;
    uint256 constant LIMIT = 60_000e6;
    uint256 constant GUARD_LIMIT = 200_000e6; // fixed part of the guard premium: 200e6

    MockUSDG usdg;
    MockFeed feed;
    Treaty treaty;
    LinearPricer linear;
    OIGuard guard;
    VaultCover cover;

    address owner = makeAddr("vaultTreasury");
    address venue = makeAddr("venue");
    address keeper = makeAddr("keeper");
    address writer = makeAddr("writer");

    function setUp() public {
        usdg = new MockUSDG();
        feed = new MockFeed();
        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = deployTreaty(address(usdg), address(new Pricer(oneTableId())), feeds, 50, address(0));

        usdg.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(treaty.firstLossVault(0), type(uint256).max);
        usdg.approve(treaty.seniorVault(0), type(uint256).max);
        Capacity(treaty.firstLossVault(0)).deposit(500_000e6, writer);
        Capacity(treaty.seniorVault(0)).deposit(500_000e6, writer);
        vm.stopPrank();

        linear = new LinearPricer();
        address[] memory guardFeeds = new address[](3);
        (guardFeeds[0], guardFeeds[1], guardFeeds[2]) = (address(1), address(2), address(3));
        guard = new OIGuard(linear, guardFeeds, owner, 0, GUARD_LIMIT, 1_200e6);

        uint256[] memory idx = new uint256[](1);
        idx[0] = 1;
        cover = new VaultCover(treaty, guard, 0, idx, owner);
        vm.startPrank(owner);
        cover.setVenue(venue, true);
        cover.setKeeper(keeper, true);
        cover.setTerms(RETENTION, LIMIT, 15_000e6);
        vm.stopPrank();
        usdg.mint(address(cover), 30_000e6);
        vm.warp(T0);
    }

    function _open(uint256 market, int256 delta) internal returns (uint256) {
        vm.prank(venue);
        return cover.open(market, delta);
    }

    function _close(uint256 market, int256 delta) internal {
        vm.prank(venue);
        cover.close(market, delta);
    }

    /// Lift the guard budget so a full-size book opens; the guard itself is tested in OIGuard.t.sol.
    function _bigBudget() internal {
        vm.prank(owner);
        guard.setTerms(0, GUARD_LIMIT, type(uint256).max);
    }

    function test_openRecordsWhatTheGuardAccepts() public {
        assertEq(_open(1, 60_000e6), 800e6); // 1% of 60k + 200
        assertEq(_open(0, -40_000e6), 1_200e6); // gross 100k: exactly the budget
        int256[] memory n = cover.net();
        assertEq(n[0], -40_000e6);
        assertEq(n[1], 60_000e6);
        assertEq(n[2], 0);
    }

    function test_openOverBudgetRevertsWithTheNumbersAndLeavesTheBook() public {
        _open(1, 60_000e6);
        vm.prank(venue);
        vm.expectRevert(abi.encodeWithSelector(OIGuard.PremiumOverBudget.selector, 2_200e6, 1_200e6, 800e6));
        cover.open(2, 140_000e6);
        assertEq(cover.net()[2], 0);
    }

    function test_closeMovesTowardZeroOnly() public {
        _open(1, 60_000e6);
        _open(0, -30_000e6);
        _close(1, -20_000e6);
        assertEq(cover.net()[1], 40_000e6);
        vm.startPrank(venue);
        vm.expectRevert(VaultCover.NotReducing.selector);
        cover.close(1, -50_000e6); // would cross to short
        vm.expectRevert(VaultCover.NotReducing.selector);
        cover.close(1, 1); // grows the long
        vm.expectRevert(VaultCover.NotReducing.selector);
        cover.close(0, -1); // grows the short
        vm.expectRevert(VaultCover.NotReducing.selector);
        cover.close(2, 1); // nothing open
        vm.stopPrank();
        _close(0, 30_000e6);
        assertEq(cover.net()[0], 0);
    }

    /// A pricer that stops answering blocks new open interest, never closing it.
    function test_closeWorksWhenThePricerIsDown() public {
        _open(1, 60_000e6);
        vm.mockCallRevert(address(linear), abi.encodeWithSelector(IPricer.quote.selector), "pricer down");
        vm.prank(venue);
        vm.expectRevert(bytes("pricer down"));
        cover.open(1, 1e6);
        _close(1, -60_000e6);
        assertEq(cover.net()[1], 0);
    }

    function test_onlyVenueMovesTheBookOnlyKeeperOrOwnerRenews() public {
        vm.expectRevert(VaultCover.NotVenue.selector);
        cover.open(1, 1e6);
        vm.expectRevert(VaultCover.NotVenue.selector);
        cover.close(1, 0);
        vm.expectRevert(VaultCover.NotKeeper.selector);
        cover.renewCover();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        cover.setTerms(0, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        cover.setVenue(address(this), true);
    }

    function test_renewCoverBindsTheBookAndPaysFromItsBalance() public {
        _bigBudget();
        _open(1, 2_000_000e6);
        _open(0, -500_000e6); // a leg the Treaty does not list stays out of the layer
        uint256 before = usdg.balanceOf(address(cover));

        vm.prank(keeper);
        uint256 id = cover.renewCover();

        (address buyer,,,,,,,, uint256 ret, uint256 lim,, uint256 premium,,,,,) = treaty.layers(id);
        assertEq(buyer, address(cover));
        assertEq(ret, RETENTION);
        assertEq(lim, LIMIT);
        int256[] memory e = treaty.exposureOf(id);
        assertEq(e.length, 1);
        assertEq(e[0], 2_000_000e6);
        assertGt(premium, 0);
        assertLe(premium, 15_000e6);
        assertEq(before - usdg.balanceOf(address(cover)), premium);
        assertEq(usdg.allowance(address(cover), address(treaty)), 0);
        assertEq(cover.lastCutoff(), CUTOFF);
        assertEq(cover.layers().length, 1);
    }

    function test_oneLayerPerWeekThenTheNextWeekRenews() public {
        _bigBudget();
        _open(1, 2_000_000e6);
        vm.prank(keeper);
        cover.renewCover();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultCover.AlreadyCovered.selector, CUTOFF));
        cover.renewCover();

        vm.warp(T0 + 7 days);
        feed.set(2, FRIDAY_PRICE, T0 + 7 days - 1 hours);
        vm.prank(keeper);
        uint256 id = cover.renewCover();
        assertEq(cover.lastCutoff(), CUTOFF + 7 days);
        assertEq(id, 1);
    }

    function test_renewAboveTheCeilingRevertsAndKeepsTheWeekOpen() public {
        _bigBudget();
        _open(1, 2_000_000e6);
        vm.prank(owner);
        cover.setTerms(RETENTION, LIMIT, 1);
        vm.prank(keeper);
        vm.expectRevert(Treaty.PremiumTooHigh.selector);
        cover.renewCover();
        assertEq(cover.lastCutoff(), 0);
    }

    function test_renewAfterTheBindDeadlineReverts() public {
        _bigBudget();
        _open(1, 2_000_000e6);
        vm.warp(CUTOFF - 1 days); // Thursday 19:30 UTC
        vm.prank(keeper);
        vm.expectRevert(Treaty.BadTiming.selector);
        cover.renewCover();
    }

    function test_claimCoverPaysTheOwnerAfterSettlement() public {
        _bigBudget();
        _open(1, 2_000_000e6);
        vm.prank(keeper);
        uint256 id = cover.renewCover();

        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        feed.set(3, MONDAY_PRICE, EXPIRY + 10);
        vm.warp(EXPIRY + 20);
        treaty.fix(id, 0, 3);

        uint256 before = usdg.balanceOf(owner);
        cover.claimCover(id); // anyone may trigger it; the payout goes to the owner
        assertEq(usdg.balanceOf(owner), before + LIMIT); // -10% on 2M less 20k retention, capped at the limit
        vm.expectRevert(Treaty.NothingToClaim.selector);
        cover.claimCover(id);
    }

    /// After a renew, the covered leg stays inside what the layer bound until its Monday expiry.
    function test_openAfterRenewCannotGrowTheCoveredLegPastTheBound() public {
        _bigBudget();
        _open(1, 2_000_000e6);
        vm.prank(keeper);
        cover.renewCover();
        assertEq(cover.coveredUntil(), EXPIRY);
        assertEq(cover.bound()[1], 2_000_000e6);

        vm.prank(venue);
        vm.expectRevert(abi.encodeWithSelector(VaultCover.BeyondCover.selector, 1, int256(2_000_000e6 + 1), int256(2_000_000e6)));
        cover.open(1, 1);
        _open(1, -500_000e6); // a reduction through open is free
        _open(1, 500_000e6); // and so is growing back up to the bound
        vm.prank(venue);
        vm.expectRevert(abi.encodeWithSelector(VaultCover.BeyondCover.selector, 1, -int256(500_000e6), int256(2_000_000e6)));
        cover.open(1, -2_500_000e6); // flipping to the uncovered side
        _open(0, 300_000e6); // a leg the Treaty does not list answers to the guard only
        assertEq(cover.net()[1], 2_000_000e6);
    }

    function test_theCoveredLegIsFreeAgainAfterExpiry() public {
        _bigBudget();
        _open(1, 2_000_000e6);
        vm.prank(keeper);
        cover.renewCover();
        vm.warp(EXPIRY - 1);
        vm.prank(venue);
        vm.expectRevert(abi.encodeWithSelector(VaultCover.BeyondCover.selector, 1, int256(2_000_000e6 + 1), int256(2_000_000e6)));
        cover.open(1, 1);
        vm.warp(EXPIRY);
        _open(1, 1);
        assertEq(cover.net()[1], 2_000_000e6 + 1);
    }

    function test_claimCoverOnALayerItDidNotBuyReverts() public {
        usdg.mint(address(this), 100_000e6);
        usdg.approve(address(treaty), type(uint256).max);
        int256[] memory e = new int256[](1);
        e[0] = 2_000_000e6;
        uint256 id = treaty.bind(0, e, RETENTION, LIMIT, type(uint256).max);
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        feed.set(3, MONDAY_PRICE, EXPIRY + 10);
        vm.warp(EXPIRY + 20);
        treaty.fix(id, 0, 3);
        vm.expectRevert(Treaty.NothingToClaim.selector);
        cover.claimCover(id);
    }

    function test_withdrawReturnsPremiumFundsToTheOwner() public {
        vm.prank(owner);
        cover.withdraw(4_000e6);
        assertEq(usdg.balanceOf(owner), 4_000e6);
        assertEq(usdg.balanceOf(address(cover)), 26_000e6);
    }

    function test_constructorRejectsAMismatchedCoverIndex() public {
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(VaultCover.BadParams.selector);
        new VaultCover(treaty, guard, 0, two, owner);
        uint256[] memory outOfRange = new uint256[](1);
        outOfRange[0] = 3;
        vm.expectRevert(VaultCover.BadParams.selector);
        new VaultCover(treaty, guard, 0, outOfRange, owner);
        uint256[] memory ok = new uint256[](1);
        vm.expectRevert(VaultCover.BadParams.selector);
        new VaultCover(treaty, guard, 1, ok, owner);
    }
}

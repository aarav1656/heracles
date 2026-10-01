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

/// A token whose `decimals()` reads something other than 6: only `decimals()` is ever called on
/// it, the constructor reverts before deploying either vault, so nothing else needs to work.
contract BadDecimalsToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// T4 (a layer in book `a` never changes any state or balance of a vault in book `b`) and T5
/// (Treaty's balance of every book asset is zero after every external call), plus the
/// constructor's `decimals() != 6` guard.
contract BooksTest is Test, TreatyFixture {
    uint256 constant T0 = 1_790_000_000; // a Monday; that week's Fri 19:30/Mon 13:30 below
    uint256 constant CUTOFF = 1_790_364_600; // Fri 2026-09-25 19:30 UTC (T0's week)
    uint256 constant REF_TIME = CUTOFF + 30 minutes; // Fri 2026-09-25 20:00 UTC (EDT close)
    uint40 constant EXPIRY = uint40(1_790_602_200); // Mon 2026-09-28 13:30 UTC

    int256 constant FRIDAY_PRICE = 100e8;
    int256 constant MONDAY_PRICE = 90e8; // -10% weekend gap, clamps payout at LIMIT

    uint256 constant RETENTION = 20_000e6;
    uint256 constant LIMIT = 60_000e6;
    int256 constant EXPOSURE = 2_000_000e6;

    MockUSDG usdg; // book 0
    MockUSDG usdc; // book 1
    MockFeed feed;
    Pricer pricer;
    Treaty treaty;
    Capacity firstLoss0;
    Capacity senior0;
    Capacity firstLoss1;
    Capacity senior1;

    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    function setUp() public {
        usdg = new MockUSDG();
        usdc = new MockUSDG();
        pricer = new Pricer(oneTableId());
        feed = new MockFeed();
        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);

        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        address[] memory assets = new address[](2);
        assets[0] = address(usdg);
        assets[1] = address(usdc);
        treaty = deployTreaty(assets, address(pricer), feeds, 50, address(0), address(0));
        firstLoss0 = Capacity(treaty.firstLossVault(0));
        senior0 = Capacity(treaty.seniorVault(0));
        firstLoss1 = Capacity(treaty.firstLossVault(1));
        senior1 = Capacity(treaty.seniorVault(1));

        usdg.mint(writer, 1_000_000e6);
        usdc.mint(writer, 1_000_000e6);
        vm.startPrank(writer);
        usdg.approve(address(firstLoss0), type(uint256).max);
        usdg.approve(address(senior0), type(uint256).max);
        firstLoss0.deposit(500_000e6, writer);
        senior0.deposit(500_000e6, writer);
        usdc.approve(address(firstLoss1), type(uint256).max);
        usdc.approve(address(senior1), type(uint256).max);
        firstLoss1.deposit(500_000e6, writer);
        senior1.deposit(500_000e6, writer);
        vm.stopPrank();

        usdg.mint(buyer, 1_000_000e6);
        usdc.mint(buyer, 1_000_000e6);
        vm.prank(buyer);
        usdg.approve(address(treaty), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(treaty), type(uint256).max);

        vm.warp(T0);
    }

    function _exposure() internal pure returns (int256[] memory e) {
        e = new int256[](1);
        e[0] = EXPOSURE;
    }

    /// Every observable piece of book 1's (USDC) state that a layer bound, settled, cancelled or
    /// claimed in book 0 (USDG) could possibly disturb, snapshotted together so a single equality
    /// check on the tuple stands in for "byte-identical".
    function _book1Snapshot()
        internal
        view
        returns (
            uint256 flTotalAssets,
            uint256 flLocked,
            uint256 flOwed,
            uint256 flPendingPremium,
            uint256 flBalance,
            uint256 srTotalAssets,
            uint256 srLocked,
            uint256 srOwed,
            uint256 srPendingPremium,
            uint256 srBalance,
            uint256 writerFlShares,
            uint256 writerSrShares
        )
    {
        flTotalAssets = firstLoss1.totalAssets();
        flLocked = firstLoss1.locked();
        flOwed = firstLoss1.owed();
        flPendingPremium = firstLoss1.pendingPremium();
        flBalance = usdc.balanceOf(address(firstLoss1));
        srTotalAssets = senior1.totalAssets();
        srLocked = senior1.locked();
        srOwed = senior1.owed();
        srPendingPremium = senior1.pendingPremium();
        srBalance = usdc.balanceOf(address(senior1));
        writerFlShares = firstLoss1.balanceOf(writer);
        writerSrShares = senior1.balanceOf(writer);
    }

    function _assertBook1Unchanged(
        uint256 flTotalAssets,
        uint256 flLocked,
        uint256 flOwed,
        uint256 flPendingPremium,
        uint256 flBalance,
        uint256 srTotalAssets,
        uint256 srLocked,
        uint256 srOwed,
        uint256 srPendingPremium,
        uint256 srBalance,
        uint256 writerFlShares,
        uint256 writerSrShares
    ) internal view {
        assertEq(firstLoss1.totalAssets(), flTotalAssets, "T4: firstLoss1.totalAssets must be untouched");
        assertEq(firstLoss1.locked(), flLocked, "T4: firstLoss1.locked must be untouched");
        assertEq(firstLoss1.owed(), flOwed, "T4: firstLoss1.owed must be untouched");
        assertEq(firstLoss1.pendingPremium(), flPendingPremium, "T4: firstLoss1.pendingPremium must be untouched");
        assertEq(usdc.balanceOf(address(firstLoss1)), flBalance, "T4: firstLoss1's USDC balance must be untouched");
        assertEq(senior1.totalAssets(), srTotalAssets, "T4: senior1.totalAssets must be untouched");
        assertEq(senior1.locked(), srLocked, "T4: senior1.locked must be untouched");
        assertEq(senior1.owed(), srOwed, "T4: senior1.owed must be untouched");
        assertEq(senior1.pendingPremium(), srPendingPremium, "T4: senior1.pendingPremium must be untouched");
        assertEq(usdc.balanceOf(address(senior1)), srBalance, "T4: senior1's USDC balance must be untouched");
        assertEq(firstLoss1.balanceOf(writer), writerFlShares, "T4: writer's firstLoss1 shares must be untouched");
        assertEq(senior1.balanceOf(writer), writerSrShares, "T4: writer's senior1 shares must be untouched");
    }

    /// T4 isolation across bind, setReference, fix (settle) and claim, all against book 0 only:
    /// book 1 never moves.
    function test_T4_book0LayerLeavesBook1Untouched() public {
        (
            uint256 flTotalAssets,
            uint256 flLocked,
            uint256 flOwed,
            uint256 flPendingPremium,
            uint256 flBalance,
            uint256 srTotalAssets,
            uint256 srLocked,
            uint256 srOwed,
            uint256 srPendingPremium,
            uint256 srBalance,
            uint256 writerFlShares,
            uint256 writerSrShares
        ) = _book1Snapshot();

        vm.prank(buyer);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT, type(uint256).max);
        _assertBook1Unchanged(
            flTotalAssets,
            flLocked,
            flOwed,
            flPendingPremium,
            flBalance,
            srTotalAssets,
            srLocked,
            srOwed,
            srPendingPremium,
            srBalance,
            writerFlShares,
            writerSrShares
        );

        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        _assertBook1Unchanged(
            flTotalAssets,
            flLocked,
            flOwed,
            flPendingPremium,
            flBalance,
            srTotalAssets,
            srLocked,
            srOwed,
            srPendingPremium,
            srBalance,
            writerFlShares,
            writerSrShares
        );

        feed.set(3, MONDAY_PRICE, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        treaty.fix(id, 0, 3); // settles: book 0's own vaults move, book 1 must not
        _assertBook1Unchanged(
            flTotalAssets,
            flLocked,
            flOwed,
            flPendingPremium,
            flBalance,
            srTotalAssets,
            srLocked,
            srOwed,
            srPendingPremium,
            srBalance,
            writerFlShares,
            writerSrShares
        );

        vm.prank(buyer);
        treaty.claim(id);
        _assertBook1Unchanged(
            flTotalAssets,
            flLocked,
            flOwed,
            flPendingPremium,
            flBalance,
            srTotalAssets,
            srLocked,
            srOwed,
            srPendingPremium,
            srBalance,
            writerFlShares,
            writerSrShares
        );
    }

    /// T5: after bind and after fix (settle), Treaty's own balance of both book assets is zero;
    /// the whole premium/payout passes through to the vaults in the same transaction.
    function test_T5_treatyBalanceZeroAfterBindAndSettle() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT, type(uint256).max);
        assertEq(usdg.balanceOf(address(treaty)), 0, "T5: Treaty's USDG balance must be zero after bind");
        assertEq(usdc.balanceOf(address(treaty)), 0, "T5: Treaty's USDC balance must be zero after bind");

        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        assertEq(usdg.balanceOf(address(treaty)), 0, "T5: Treaty's USDG balance must be zero after setReference");

        feed.set(3, MONDAY_PRICE, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        treaty.fix(id, 0, 3);
        assertEq(usdg.balanceOf(address(treaty)), 0, "T5: Treaty's USDG balance must be zero after fix/settle");
        assertEq(usdc.balanceOf(address(treaty)), 0, "T5: Treaty's USDC balance must be zero after fix/settle");

        vm.prank(buyer);
        treaty.claim(id);
        assertEq(usdg.balanceOf(address(treaty)), 0, "T5: Treaty's USDG balance must be zero after claim");
    }

    /// T5 on the cancel path: bind, then void the (now-stale) reference and cancel, refunding
    /// both slices' premium; Treaty's balance still returns to zero.
    function test_T5_treatyBalanceZeroAfterCancel() public {
        feed.set(1, FRIDAY_PRICE, T0 - 1 hours); // stale by the time of voidReference below
        vm.prank(buyer);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT, type(uint256).max);
        assertEq(usdg.balanceOf(address(treaty)), 0, "T5: Treaty's USDG balance must be zero after bind");

        vm.warp(uint256(EXPIRY) + 7 days + 1);
        treaty.voidReference(id, 0, 1);
        treaty.cancel(id);
        assertEq(usdg.balanceOf(address(treaty)), 0, "T5: Treaty's USDG balance must be zero after cancel");

        vm.prank(buyer);
        treaty.claim(id);
        assertEq(usdg.balanceOf(address(treaty)), 0, "T5: Treaty's USDG balance must be zero after claim");
    }

    /// Decision 1: every book asset must read the same 6 decimals every stored amount assumes.
    function test_constructorRevertsOnNonSixDecimalAsset() public {
        BadDecimalsToken bad = new BadDecimalsToken();
        address[] memory assets = new address[](1);
        assets[0] = address(bad);
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);

        vm.expectRevert(Treaty.BadParams.selector);
        deployTreaty(assets, address(pricer), feeds, 50, address(0), address(0));
    }
}

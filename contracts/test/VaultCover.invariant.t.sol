// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {OIGuard} from "../src/OIGuard.sol";
import {VaultCover} from "../src/VaultCover.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";
import {LinearPricer} from "./OIGuard.t.sol";

/// Drives VaultCover with random opens, closes, renews and clock moves on the real Treaty and
/// vaults. Records every accepted move so the invariants can check the book against it.
contract VaultCoverHandler is Test {
    VaultCover public cover;
    MockFeed public feed;
    address venue;
    address keeper;
    int256[3] public ghostNet;
    uint256 public closeGrewBook;
    uint256 public renews;
    uint256 public refusedBeyondCover;
    uint80 nextRound = 2;
    bytes4 public lastRenewError;
    uint256 public renewCalls;

    constructor(VaultCover c, MockFeed f, address v, address k) {
        (cover, feed, venue, keeper) = (c, f, v, k);
    }

    function open(uint256 market, int256 delta) external {
        market = bound(market, 0, 2);
        delta = bound(delta, -3_000_000e6, 3_000_000e6);
        vm.prank(venue);
        try cover.open(market, delta) {
            ghostNet[market] += delta;
        } catch (bytes memory err) {
            if (bytes4(err) == VaultCover.BeyondCover.selector) refusedBeyondCover++;
        }
    }

    /// Any delta, so a close that would grow the book is attempted and must be refused.
    function close(uint256 market, int256 delta) external {
        market = bound(market, 0, 2);
        int256 cur = cover.net()[market];
        delta = bound(delta, -3_000_000e6, 3_000_000e6);
        vm.prank(venue);
        try cover.close(market, delta) {
            int256 next = cover.net()[market];
            if ((next < 0 ? -next : next) > (cur < 0 ? -cur : cur)) closeGrewBook++;
            ghostNet[market] += delta;
        } catch {}
    }

    /// The usual close: part of what is open, toward zero.
    function closePart(uint256 market, uint256 pct) external {
        market = bound(market, 0, 2);
        int256 cur = cover.net()[market];
        int256 delta = -cur * int256(bound(pct, 0, 100)) / 100;
        vm.prank(venue);
        try cover.close(market, delta) {
            ghostNet[market] += delta;
        } catch {}
    }

    function renew() external {
        Treaty t = cover.treaty();
        (uint256 cutoff,) = t.weekWindow(block.timestamp);
        // outside Monday to Thursday 19:30 UTC, move to the next Monday after that week's expiry
        if (block.timestamp >= cutoff - 1 days) vm.warp(cutoff + 2 days + 19 hours);
        if (cover.net()[1] == 0) {
            vm.prank(venue);
            try cover.open(1, 100_000e6) {
                ghostNet[1] += 100_000e6;
            } catch {}
        }
        // contiguous round ids: the pricer reads the rounds just before the latest for its volatility scale
        feed.set(nextRound++, 100e8, block.timestamp - 1 hours);
        renewCalls++;
        vm.prank(keeper);
        try cover.renewCover() {
            renews++;
        } catch (bytes memory err) {
            lastRenewError = bytes4(err);
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 3 days));
    }
}

contract VaultCoverInvariantTest is Test, TreatyFixture {
    uint256 constant T0 = 1_790_000_000; // a Monday

    VaultCover cover;
    VaultCoverHandler h;

    function setUp() public {
        MockUSDG usdg = new MockUSDG();
        MockFeed feed = new MockFeed();
        feed.set(1, 100e8, T0 - 1 hours);
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        Treaty treaty = deployTreaty(address(usdg), address(new Pricer(oneTableId())), feeds, 50, address(0));

        address writer = makeAddr("writer");
        usdg.mint(writer, 100_000_000e6);
        vm.startPrank(writer);
        usdg.approve(treaty.firstLossVault(0), type(uint256).max);
        usdg.approve(treaty.seniorVault(0), type(uint256).max);
        Capacity(treaty.firstLossVault(0)).deposit(50_000_000e6, writer);
        Capacity(treaty.seniorVault(0)).deposit(50_000_000e6, writer);
        vm.stopPrank();

        address owner = makeAddr("owner");
        address[] memory guardFeeds = new address[](3);
        (guardFeeds[0], guardFeeds[1], guardFeeds[2]) = (address(1), address(2), address(3));
        OIGuard guard = new OIGuard(new LinearPricer(), guardFeeds, owner, 0, 200_000e6, 60_000e6);

        uint256[] memory idx = new uint256[](1);
        idx[0] = 1;
        cover = new VaultCover(treaty, guard, 0, idx, owner);
        address venue = makeAddr("venue");
        address keeper = makeAddr("keeper");
        vm.startPrank(owner);
        cover.setVenue(venue, true);
        cover.setKeeper(keeper, true);
        cover.setTerms(20_000e6, 60_000e6, 1_000_000e6);
        vm.stopPrank();
        usdg.mint(address(cover), 100_000_000e6);
        vm.warp(T0);

        h = new VaultCoverHandler(cover, feed, venue, keeper);
        // every run starts inside a covered week: a long book on the covered leg, bound by a layer
        h.open(1, 1_000_000e6);
        h.renew();
        require(h.renews() == 1 && cover.coveredUntil() > block.timestamp, "setUp must bind a layer");
        targetContract(address(h));
    }

    /// Until the layer's Monday open, the covered leg stays on the side and within the size it bound.
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 60
    function invariant_coveredLegStaysWithinItsLayer() public view {
        if (block.timestamp >= cover.coveredUntil()) return;
        int256 b = cover.bound()[1];
        int256 n = cover.net()[1];
        if (b >= 0) assertTrue(n >= 0 && n <= b, "covered leg left its long bound");
        else assertTrue(n <= 0 && n >= b, "covered leg left its short bound");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 60
    function invariant_closeNeverGrowsTheBook() public view {
        assertEq(h.closeGrewBook(), 0);
    }

    /// The book is exactly the sum of the moves VaultCover accepted.
    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 60
    function invariant_bookMatchesAcceptedMoves() public view {
        int256[] memory n = cover.net();
        for (uint256 i; i < 3; i++) {
            assertEq(n[i], h.ghostNet(i));
        }
    }

    /// Every run started from a bound layer (setUp); report how far the run took the book.
    function afterInvariant() external view {
        assertGe(cover.layers().length, 1);
    }
}

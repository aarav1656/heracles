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

/// Attack surface: drain across layers, stale round, phase change, early fix, payout cap.
/// Every test here is a check that can fail: each one is paired with the exploit it defeats,
/// not just a happy path re-run.
contract AttackTest is Test, TreatyFixture {
    uint256 constant T0 = 1_790_000_000; // a Monday
    uint256 constant CUTOFF = 1_790_364_600; // that week's Fri 19:30 UTC
    uint256 constant SAT_MIDNIGHT = CUTOFF + 4 hours + 30 minutes;
    // setReference now waits for `fridayCloseOf(fridayCutoff)` (Friday's official US
    // market close), not "Saturday 00:00 UTC". T0's week is DST (EDT), so close = CUTOFF + 30
    // minutes.
    uint256 constant REF_TIME = CUTOFF + 30 minutes;
    uint40 constant EXPIRY = uint40(1_790_602_200); // that week's Mon 13:30 UTC
    int256 constant FRIDAY_PRICE = 100e8;

    uint256 constant RETENTION = 20_000e6;
    uint256 constant LIMIT = 60_000e6;
    int256 constant EXPOSURE = 2_000_000e6;

    MockUSDG usdg;
    MockFeed feed;
    Pricer pricer;
    Treaty treaty;
    Capacity firstLoss;
    Capacity senior;

    address writer = makeAddr("writer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer(oneTableId());
        feed = new MockFeed();
        feed.set(1, FRIDAY_PRICE, CUTOFF - 1 hours);

        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        treaty = deployTreaty(address(usdg), address(pricer), feeds, 50, address(0));
        firstLoss = Capacity(treaty.firstLossVault(0));
        senior = Capacity(treaty.seniorVault(0));

        usdg.mint(writer, 400_000e6);
        vm.prank(writer);
        usdg.approve(address(firstLoss), type(uint256).max);
        vm.prank(writer);
        firstLoss.deposit(200_000e6, writer); // exactly two layers' worth of limit
        vm.prank(writer);
        usdg.approve(address(senior), type(uint256).max);
        vm.prank(writer);
        senior.deposit(200_000e6, writer); // exactly two layers' worth of limit

        usdg.mint(alice, 1_000_000e6);
        vm.prank(alice);
        // Premium is pulled by Treaty itself, never a vault, so the buyer approves the Treaty
        // contract, not either vault.
        usdg.approve(address(treaty), type(uint256).max);
        usdg.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdg.approve(address(treaty), type(uint256).max);

        vm.warp(T0);
    }

    function _exposure() internal pure returns (int256[] memory e) {
        e = new int256[](1);
        e[0] = EXPOSURE;
    }

    function _payout(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,,, p) = layerBasics(treaty, id);
    }

    /// Attack: bind two layers against the same pool, settle one for its full limit, then try to
    /// have that one claim drain capital reserved for the OTHER, still-live layer. Defeated by
    /// `Capacity.locked` only ever holding this layer's own reservation and `payOut` refusing to
    /// pay more than is locked.
    function test_cannotDrainAcrossLayers() public {
        vm.prank(alice);
        uint256 idA = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        vm.prank(bob);
        uint256 idB = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        assertEq(firstLoss.locked() + senior.locked(), 2 * LIMIT); // pool fully committed, zero free capacity

        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(idA, 0, 2);
        treaty.setReference(idB, 0, 2);

        feed.set(3, 90e8, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        treaty.fix(idA, 0, 3); // settles A only; B is still Bound

        uint256 poolBefore = usdg.balanceOf(address(firstLoss)) + usdg.balanceOf(address(senior));
        vm.prank(alice);
        treaty.claim(idA);
        // Pool must still hold at least layer B's full locked limit: A's claim never touched it.
        assertGe(usdg.balanceOf(address(firstLoss)) + usdg.balanceOf(address(senior)), poolBefore - LIMIT);
        assertGe(usdg.balanceOf(address(firstLoss)) + usdg.balanceOf(address(senior)), LIMIT); // B's reservation is intact

        // B still settles and claims in full against the same Monday round: the drain attempt
        // cost it nothing.
        treaty.fix(idB, 0, 3);
        vm.prank(bob);
        treaty.claim(idB);
        assertEq(firstLoss.locked() + senior.locked(), 0);
    }

    /// Attack: a stale round (updatedAt far in the past) presented as the Monday fix.
    function test_staleRoundRejected() public {
        vm.prank(alice);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        // Round 3 is stale: updatedAt is before expiry, not a fresh Monday print.
        feed.set(3, 90e8, uint256(EXPIRY) - 1 hours);
        vm.warp(uint256(EXPIRY) + 20);
        vm.expectRevert(Treaty.BadRound.selector);
        treaty.fix(id, 0, 3);
    }

    /// Attack: present a round from a different Chainlink phase (proxy upgrade) as if it were
    /// the latest round. `_latestInPhase` must reject any roundId whose phase bits differ from
    /// the feed's current phase.
    function test_phaseChangeRejected() public {
        vm.prank(alice);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        // The aggregator proxy upgrades: the feed's real latest round moves into a new phase
        // (phaseId 1 << 64 | 1), leaving old phase-0 round ids (like 3) behind.
        uint80 newPhaseRound = uint80((uint256(1) << 64) | 1);
        feed.set(newPhaseRound, 90e8, uint256(EXPIRY) + 10);
        // Attacker submits a phase-0 round id, no longer the feed's current phase.
        feed.set(3, 200e8, uint256(EXPIRY) + 10);
        vm.warp(uint256(EXPIRY) + 20);
        vm.expectRevert(Treaty.BadRound.selector);
        treaty.fix(id, 0, 3);
    }

    /// Attack: fix before expiry to lock in a favorable price before the real Monday print
    /// exists. Must revert unconditionally, regardless of what round is supplied.
    function test_earlyFixRejected() public {
        vm.prank(alice);
        uint256 id = treaty.bind(0, _exposure(), RETENTION, LIMIT);
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        feed.set(3, 200e8, uint256(EXPIRY) - 1); // an attacker-favorable round updated just before expiry
        vm.warp(uint256(EXPIRY) - 1);
        vm.expectRevert(Treaty.EarlyFix.selector);
        treaty.fix(id, 0, 3);
    }

    /// Attack: engineer a catastrophic loss (extreme exposure vs. a real historical gap) and
    /// confirm the payout never exceeds the layer's own locked limit, no matter how large the
    /// realized loss is. This is the mutation target: `Treaty._settle`'s `if (payout > L.limit)
    /// payout = L.limit;` line.
    function test_catastrophicLossNeverExceedsLimit() public {
        int256[] memory hugeExposure = new int256[](1);
        hugeExposure[0] = 100_000_000e6; // far beyond what any premium was priced for
        vm.prank(alice);
        uint256 id = treaty.bind(0, hugeExposure, RETENTION, LIMIT);
        feed.set(2, FRIDAY_PRICE, REF_TIME);
        vm.warp(REF_TIME + 1);
        treaty.setReference(id, 0, 2);
        feed.set(3, 1e8, uint256(EXPIRY) + 10); // price collapses 99%
        vm.warp(uint256(EXPIRY) + 20);
        treaty.fix(id, 0, 3);
        assertEq(_payout(id), LIMIT);
        assertEq(usdg.balanceOf(address(firstLoss)) + usdg.balanceOf(address(senior)) >= LIMIT, true);
    }
}

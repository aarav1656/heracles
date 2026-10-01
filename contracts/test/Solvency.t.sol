// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";
import {nTableIds} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// Solvency fuzz: across many layers spanning multiple markets, with randomized exposures and
/// randomized Monday prices, the pool must never be asked to pay out more than it holds, and
/// `locked` must never exceed `totalAssets()`. This is the property the per-layer limit clamp
/// and `Capacity.locked` bookkeeping exist to guarantee; the fuzz explores paths a handful of
/// hand-written unit tests would not reach.
contract SolvencyTest is Test, TreatyFixture {
    uint256 constant T0 = 1_790_000_000; // a Monday
    uint256 constant CUTOFF = 1_790_364_600; // that week's Fri 19:30 UTC
    uint256 constant SAT_MIDNIGHT = CUTOFF + 4 hours + 30 minutes;
    // setReference now waits for `fridayCloseOf` (T0's week is DST/EDT, so close =
    // CUTOFF + 30 minutes), not Saturday midnight.
    uint256 constant REF_TIME = CUTOFF + 30 minutes;
    uint40 constant EXPIRY = uint40(1_790_602_200); // that week's Mon 13:30 UTC
    uint256 constant N_MARKETS = 3;
    uint256 constant N_LAYERS = 5;
    uint256 constant POOL = 10_000_000e6;

    MockUSDG usdg;
    MockFeed[N_MARKETS] feeds;
    Pricer pricer;
    Treaty treaty;
    Capacity firstLoss;
    Capacity senior;
    address writer = makeAddr("writer");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer(nTableIds(N_MARKETS));

        address[] memory feedAddrs = new address[](N_MARKETS);
        for (uint256 i; i < N_MARKETS; i++) {
            feeds[i] = new MockFeed();
            // Round 1: the pre-close predecessor, strictly before REF_TIME (T0 is a Monday, over
            // 4 days before that week's Friday close). Round 2: the actual Friday reference round.
            feeds[i].set(1, 100e8, CUTOFF - 1 hours);
            feeds[i].set(2, 100e8, REF_TIME);
            feedAddrs[i] = address(feeds[i]);
        }
        treaty = deployTreaty(address(usdg), address(pricer), feedAddrs, 50, address(0));
        firstLoss = Capacity(treaty.firstLossVault(0));
        senior = Capacity(treaty.seniorVault(0));

        usdg.mint(writer, POOL * 2);
        vm.startPrank(writer);
        usdg.approve(address(firstLoss), type(uint256).max);
        firstLoss.deposit(POOL, writer);
        usdg.approve(address(senior), type(uint256).max);
        senior.deposit(POOL, writer);
        vm.stopPrank();

        vm.warp(T0);
    }

    function _layerPayout(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,,, p) = layerBasics(treaty, id);
    }

    /// `seed` drives per-layer exposure/limit sizing and per-market Monday prices; every layer
    /// binds, every market fixes, and after each settle the pool's solvency invariant is checked.
    function testFuzz_solvencyAcrossLayersAndMarkets(uint256 seed) public {
        uint256[] memory limits = new uint256[](N_LAYERS);
        address[] memory buyers = new address[](N_LAYERS);
        uint256[] memory ids = new uint256[](N_LAYERS);
        uint256 totalLimit;

        for (uint256 l; l < N_LAYERS; l++) {
            buyers[l] = address(uint160(uint256(keccak256(abi.encode("buyer", seed, l)))));
            usdg.mint(buyers[l], 1_000_000e6);
            vm.prank(buyers[l]);
            usdg.approve(address(treaty), type(uint256).max);
            int256[] memory exposure = new int256[](N_MARKETS);
            for (uint256 m; m < N_MARKETS; m++) {
                int256 mag = int256(bound(uint256(keccak256(abi.encode(seed, l, m, "exp"))), 0, 500_000e6));
                bool short_ = uint256(keccak256(abi.encode(seed, l, m, "sign"))) % 2 == 0;
                exposure[m] = short_ ? -mag : mag;
            }
            uint256 limit = bound(uint256(keccak256(abi.encode(seed, l, "limit"))), 1e6, 50_000e6);
            uint256 retention = bound(uint256(keccak256(abi.encode(seed, l, "retention"))), 0, 20_000e6);

            // Only bind if the pool still has free capacity; a pool that's out of capacity must
            // reject the bind, not silently under-reserve it.
            uint256 free = firstLoss.totalAssets() + senior.totalAssets();
            if (limit > free) {
                vm.expectRevert(Capacity.CapacityExceeded.selector);
                vm.prank(buyers[l]);
                treaty.bind(0, exposure, retention, limit, type(uint256).max);
                limits[l] = 0;
                ids[l] = type(uint256).max;
                continue;
            }

            vm.prank(buyers[l]);
            ids[l] = treaty.bind(0, exposure, retention, limit, type(uint256).max);
            limits[l] = limit;
            totalLimit += limit;
            assertLe(firstLoss.locked() + senior.locked(), usdg.balanceOf(address(firstLoss)) + usdg.balanceOf(address(senior)));
        }

        // Set every market's Friday reference for every bound layer (round 2, at/after REF_TIME).
        vm.warp(REF_TIME + 1);
        for (uint256 l; l < N_LAYERS; l++) {
            if (ids[l] == type(uint256).max) continue;
            for (uint256 m; m < N_MARKETS; m++) {
                treaty.setReference(ids[l], m, 2);
            }
        }

        // Fix every market for every bound layer with a randomized Monday price (round 3).
        for (uint256 m; m < N_MARKETS; m++) {
            int256 price = int256(bound(uint256(keccak256(abi.encode(seed, m, "monday"))), 1e8, 300e8));
            feeds[m].set(3, price, uint256(EXPIRY) + 10);
        }
        vm.warp(uint256(EXPIRY) + 20);
        for (uint256 l; l < N_LAYERS; l++) {
            if (ids[l] == type(uint256).max) continue;
            for (uint256 m; m < N_MARKETS; m++) {
                treaty.fix(ids[l], m, 3);
            }
            assertLe(firstLoss.locked() + senior.locked(), usdg.balanceOf(address(firstLoss)) + usdg.balanceOf(address(senior)));
        }

        // Every settled layer's buyer can claim in full, and the pool never goes net negative.
        for (uint256 l; l < N_LAYERS; l++) {
            if (ids[l] == type(uint256).max) continue;
            uint256 payout = _layerPayout(ids[l]);
            uint256 poolBefore = usdg.balanceOf(address(firstLoss)) + usdg.balanceOf(address(senior));
            assertLe(payout, poolBefore); // the core solvency assertion: never owe more than held
            if (payout == 0) continue; // no loss this weekend, nothing to pull
            uint256 buyerBefore = usdg.balanceOf(buyers[l]);
            vm.prank(buyers[l]);
            treaty.claim(ids[l]);
            assertEq(usdg.balanceOf(buyers[l]), buyerBefore + payout);
        }
        assertLe(firstLoss.locked() + senior.locked(), usdg.balanceOf(address(firstLoss)) + usdg.balanceOf(address(senior)));
    }
}

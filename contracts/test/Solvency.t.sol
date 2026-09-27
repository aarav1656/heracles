// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// Solvency fuzz: across many layers spanning multiple markets, with randomized exposures and
/// randomized Monday prices, the pool must never be asked to pay out more than it holds, and
/// `locked` must never exceed `totalAssets()`. This is the property the per-layer limit clamp
/// and `Capacity.locked` bookkeeping exist to guarantee; the fuzz explores paths a handful of
/// hand-written unit tests would not reach.
contract SolvencyTest is Test {
    uint256 constant T0 = 1_790_000_000; // a Monday
    uint256 constant CUTOFF = 1_790_364_600; // that week's Fri 19:30 UTC
    uint256 constant SAT_MIDNIGHT = CUTOFF + 4 hours + 30 minutes;
    uint40 constant EXPIRY = uint40(1_790_602_200); // that week's Mon 13:30 UTC
    uint256 constant N_MARKETS = 3;
    uint256 constant N_LAYERS = 5;
    uint256 constant POOL = 10_000_000e6;

    MockUSDG usdg;
    MockFeed[N_MARKETS] feeds;
    Pricer pricer;
    Treaty treaty;
    Capacity capacity;
    address writer = makeAddr("writer");

    function setUp() public {
        usdg = new MockUSDG();
        pricer = new Pricer();

        address[] memory feedAddrs = new address[](N_MARKETS);
        for (uint256 i; i < N_MARKETS; i++) {
            feeds[i] = new MockFeed();
            // Must land within REF_WINDOW (24h) of Saturday 00:00 UTC, not merely before bind
            // time (T0 is a Monday, over 4 days before that week's Saturday).
            feeds[i].set(1, 100e8, CUTOFF - 1 hours);
            feedAddrs[i] = address(feeds[i]);
        }
        treaty = new Treaty(address(usdg), address(pricer), feedAddrs, 50, address(0));
        capacity = treaty.capacity();

        usdg.mint(writer, POOL);
        vm.prank(writer);
        usdg.approve(address(capacity), type(uint256).max);
        vm.prank(writer);
        capacity.deposit(POOL, writer);

        vm.warp(T0);
    }

    function _layerPayout(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,,, p) = treaty.layers(id);
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
            usdg.approve(address(capacity), type(uint256).max);
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
            uint256 free = capacity.totalAssets();
            if (limit > free) {
                vm.expectRevert(Capacity.CapacityExceeded.selector);
                vm.prank(buyers[l]);
                treaty.bind(exposure, retention, limit);
                limits[l] = 0;
                ids[l] = type(uint256).max;
                continue;
            }

            vm.prank(buyers[l]);
            ids[l] = treaty.bind(exposure, retention, limit);
            limits[l] = limit;
            totalLimit += limit;
            assertLe(capacity.locked(), usdg.balanceOf(address(capacity)));
        }

        // Set every market's Friday reference for every bound layer (Saturday, before Monday's fix).
        vm.warp(SAT_MIDNIGHT + 1);
        for (uint256 l; l < N_LAYERS; l++) {
            if (ids[l] == type(uint256).max) continue;
            for (uint256 m; m < N_MARKETS; m++) {
                treaty.setReference(ids[l], m, 1);
            }
        }

        // Fix every market for every bound layer with a randomized Monday price.
        for (uint256 m; m < N_MARKETS; m++) {
            int256 price = int256(bound(uint256(keccak256(abi.encode(seed, m, "monday"))), 1e8, 300e8));
            feeds[m].set(2, price, uint256(EXPIRY) + 10);
        }
        vm.warp(uint256(EXPIRY) + 20);
        for (uint256 l; l < N_LAYERS; l++) {
            if (ids[l] == type(uint256).max) continue;
            for (uint256 m; m < N_MARKETS; m++) {
                treaty.fix(ids[l], m, 2);
            }
            assertLe(capacity.locked(), usdg.balanceOf(address(capacity)));
        }

        // Every settled layer's buyer can claim in full, and the pool never goes net negative.
        for (uint256 l; l < N_LAYERS; l++) {
            if (ids[l] == type(uint256).max) continue;
            uint256 payout = _layerPayout(ids[l]);
            uint256 poolBefore = usdg.balanceOf(address(capacity));
            assertLe(payout, poolBefore); // the core solvency assertion: never owe more than held
            if (payout == 0) continue; // no loss this weekend, nothing to pull
            uint256 buyerBefore = usdg.balanceOf(buyers[l]);
            vm.prank(buyers[l]);
            treaty.claim(ids[l]);
            assertEq(usdg.balanceOf(buyers[l]), buyerBefore + payout);
        }
        assertLe(capacity.locked(), usdg.balanceOf(address(capacity)));
    }
}

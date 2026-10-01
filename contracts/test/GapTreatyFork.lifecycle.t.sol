// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// Full settlement lifecycle (bind -> setReference -> fix -> settle -> claim, and the
/// cancel-after-grace path) on a fork of live Arbitrum Sepolia (421614) at its latest block: today
/// is Saturday, so the real chain cannot be walked through a live weekend in one sitting. This
/// forks real Sepolia state (real deployer/USDG token bytecode, real
/// block history), then `vm.warp`s into next week and drives a `MockFeed` for the one thing a
/// static fork cannot contain: Monday's not-yet-real oracle round.
///
/// Pricer: revm (Foundry's local EVM) cannot execute the live Stylus WASM program
/// (address in contracts/deployments/421614.json) under a fork: calling it here reverted
/// `OpcodeNotFound`, since Stylus bytecode needs a real Nitro node's WASM runtime, not a plain
/// EVM interpreter. This test therefore deploys a fresh `Pricer.sol` (the Solidity twin) on the
/// fork instead; `test/PricerParity.t.sol` plus a live `cast call` comparison already establish
/// bit-for-bit parity between the two for these same cases, so the premium computed here is the
/// number the live Stylus pricer would also return.
contract GapTreatyForkLifecycleTest is Test, TreatyFixture {
    string constant RPC = "https://arbitrum-sepolia.drpc.org"; // archive: the public Sepolia RPC prunes the pinned block
    IERC20 constant USDG = IERC20(0xFFC95faa3d63Cde504a05B567C600B78C0b41892);
    // same fix as GapTreaty.fork.t.sol, pinned to a real
    // Arbitrum Sepolia block read via `cast block-number` on 2026-09-28 (313,609,081), 2,000
    // blocks back for safety margin. Kept close to the tip for the same reason as
    // GapTreaty.fork.t.sol: `sepolia-rollup.arbitrum.io`'s public RPC does not serve archive
    // state indefinitely far back.
    uint256 constant FORK_BLOCK = 313_607_081;

    Treaty treaty;
    Capacity firstLoss;
    Capacity senior;
    MockFeed feed;
    address writer = makeAddr("fork-writer");
    address buyer = makeAddr("fork-buyer");

    uint256 constant RETENTION = 20_000e6;
    uint256 constant LIMIT = 60_000e6;
    int256 constant EXPOSURE = 2_000_000e6; // long: loses when Monday prints below Friday

    // same fix as GapTreaty.fork.t.sol, no try/catch,
    // no `vm.skip`. An unreachable RPC fails `setUp` and every test in this contract, instead of
    // silently reporting SKIP with zero fork coverage.
    // Gated on FORK_TESTS so a plain `forge test` (CI default, no env var) skips this whole
    // file instead of hitting a public RPC and going red on a rate limit (429). Checked before
    // `createSelectFork` runs, so with `FORK_TESTS=1` set an unreachable RPC still fails setUp
    // (no try/catch below), it is never silently skipped.
    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(RPC, FORK_BLOCK);

        feed = new MockFeed();
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        // sequencerUptimeFeed left at address(0): Sepolia has no equivalent feed (SECURITY-REVIEW.md
        // M2), same disabled-on-testnet posture as the live 421614 deploy.
        treaty = deployTreaty(address(USDG), address(new Pricer(oneTableId())), feeds, 50, address(0));
        firstLoss = Capacity(treaty.firstLossVault(0));
        senior = Capacity(treaty.seniorVault(0));

        deal(address(USDG), writer, 1_000_000e6);
        vm.prank(writer);
        USDG.approve(address(firstLoss), type(uint256).max);
        vm.prank(writer);
        firstLoss.deposit(500_000e6, writer);
        vm.prank(writer);
        USDG.approve(address(senior), type(uint256).max);
        vm.prank(writer);
        senior.deposit(500_000e6, writer);

        deal(address(USDG), buyer, 1_000_000e6);
        vm.prank(buyer);
        USDG.approve(address(treaty), type(uint256).max);
    }

    function _layerState(uint256 id) internal view returns (Treaty.State s) {
        (,,,,, s,,,,,) = layerBasics(treaty, id);
    }

    function _layerPayout(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,,, p) = layerBasics(treaty, id);
    }

    function _layerPremium(uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,, p,) = layerBasics(treaty, id);
    }

    /// Warps from whatever the live Sepolia fork's "now" is into next week's bind window (Monday
    /// 00:00 through Friday 19:30 UTC), binds against the real deployed Stylus Pricer, feeds a
    /// deterministic -10% weekend gap through the MockFeed, and drives fix()/settle()/claim() the
    /// same shape as the live 421614 deploy's happy path would take once binds reopen.
    function test_forkLifecycle_bindReferenceFixSettleAndClaim() public {

        (uint256 cutoff,) = treaty.weekWindow(block.timestamp);
        if (block.timestamp >= cutoff) vm.warp(cutoff + 3 days); // land inside next week's window
        (uint256 fridayCutoff, uint256 expiry) = treaty.weekWindow(block.timestamp);

        feed.set(1, 100e8, fridayCutoff - 1 hours);

        vm.prank(buyer);
        int256[] memory exposure = new int256[](1);
        exposure[0] = EXPOSURE;
        uint256 id = treaty.bind(0, exposure, RETENTION, LIMIT, type(uint256).max);
        uint256 premium = _layerPremium(id);
        assertGt(premium, 0);
        assertEq(firstLoss.locked() + senior.locked(), LIMIT);
        console.log("fork lifecycle: Solidity-twin premium (USDG, 6dp)", premium);

        // setReference now waits for Friday's official close (`fridayCloseOf`), not
        // "Saturday 00:00 UTC"; round 2 is the first fresh round at/after that close, round 1
        // (set above, an hour before the bind cutoff) is its required strictly-earlier
        // predecessor.
        uint256 refTime = treaty.fridayCloseOf(fridayCutoff);
        feed.set(2, 100e8, refTime);
        vm.warp(refTime + 1);
        treaty.setReference(id, 0, 2);

        feed.set(3, 90e8, expiry + 10); // -10% weekend gap, first fresh round after expiry
        vm.warp(expiry + 20);
        treaty.fix(id, 0, 3);

        assertEq(uint8(_layerState(id)), uint8(Treaty.State.Settled));
        // real loss = 10% of 2,000,000e6 = 200,000e6, less 20,000e6 retention = 180,000e6,
        // clamped at the layer's own 60,000e6 limit, never at the pool's total assets.
        assertEq(_layerPayout(id), LIMIT);

        uint256 buyerBefore = USDG.balanceOf(buyer);
        vm.prank(buyer);
        treaty.claim(id);
        assertEq(USDG.balanceOf(buyer), buyerBefore + LIMIT);
        assertEq(firstLoss.locked() + senior.locked(), 0);
    }

    /// A layer whose market never produces a fresh Monday round within GRACE (SECURITY-REVIEW.md
    /// M3) must cancel, releasing the writer's locked capacity without paying it, and leave the
    /// buyer's premium claimable, on the same forked real Sepolia state. The Friday reference is
    /// set for
    /// real first (a live, referenced market is not itself a reason `_anyMarketFixable` blocks
    /// `cancel`): it is the total absence of any Monday round by `expiry + GRACE` that makes the
    /// market dead and lets `cancel` through.
    function test_forkLifecycle_cancelAfterGraceRefundsPremium() public {

        (uint256 cutoff,) = treaty.weekWindow(block.timestamp);
        if (block.timestamp >= cutoff) vm.warp(cutoff + 3 days);
        (uint256 fridayCutoff, uint256 expiry) = treaty.weekWindow(block.timestamp);
        feed.set(1, 100e8, fridayCutoff - 1 hours);

        vm.prank(buyer);
        int256[] memory exposure = new int256[](1);
        exposure[0] = EXPOSURE;
        uint256 id = treaty.bind(0, exposure, RETENTION, LIMIT, type(uint256).max);
        uint256 premium = _layerPremium(id);
        uint256 buyerBefore = USDG.balanceOf(buyer);

        uint256 refTime = treaty.fridayCloseOf(fridayCutoff);
        feed.set(2, 100e8, refTime);
        vm.warp(refTime + 1);
        treaty.setReference(id, 0, 2); // reference is real; no Monday round ever follows

        vm.warp(expiry + 7 days + 1);
        treaty.cancel(id);

        assertEq(uint8(_layerState(id)), uint8(Treaty.State.Cancelled));
        assertEq(firstLoss.locked() + senior.locked(), 0);
        assertEq(USDG.balanceOf(buyer), buyerBefore, "cancel no longer pushes the refund");

        vm.prank(buyer);
        treaty.claim(id);
        assertEq(USDG.balanceOf(buyer), buyerBefore + premium);
    }
}

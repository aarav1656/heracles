// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {AggregatorV3Interface} from "../src/Treaty.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// Replays the real 2026-09-25/28 weekend on Robinhood Chain mainnet (4663) against live
/// Chainlink SPY/AAPL feeds, proving decision 3's "round in effect at close" reference rule on
/// the exact real-world case that motivated it (docs/design/v3.md, "the finding that shapes
/// decision 3": RHC's equity feeds are silent 52-56h every weekend, so "first round after close"
/// is always the reopen, already carrying the weekend's news).
///
/// Deploys the Solidity twin `Pricer.sol`, the same choice `GapTreatyFork.lifecycle.t.sol` makes:
/// the deployed RHC pricer is Stylus (WASM), which revm cannot execute under a fork
/// (`OpcodeNotFound`); `PricerParity.t.sol` plus a live `cast call` comparison already establish
/// bit-for-bit parity between the two, so premiums quoted here match what the live Stylus pricer
/// would also return.
contract RobinhoodWeekendForkTest is Test, TreatyFixture {
    string constant RPC = "https://rpc.mainnet.chain.robinhood.com";
    // No fixed block pin, deliberately: RHC's public RPC only serves account/contract state for a
    // shallow, sliding recent window behind its own tip (measured empirically via `cast call
    // ... --block`: ~5,000 blocks back still reachable, ~20,000 blocks back already errors
    // "historical state ... is not available"). At RHC's sub-second block time that window is a
    // few minutes of wall-clock time, so any block number fixed at write time falls out of range
    // by the time this suite actually runs; the spec's own cited block (75,602,686, right after
    // round148/round673 first appeared) is already unreachable this way. Checked for a real
    // archive alternative first (Alchemy/getblock.io both need a paid key; Blockscout's
    // `/api/eth-rpc` is behind a Cloudflare challenge to `curl`/`cast`) and found none free and
    // keyless, so this forks at the real tip instead. This does not weaken the assertions below:
    // every round this suite reads (146/147/148, 671/672/673) is already-printed Chainlink
    // history, permanently stored in the aggregator's own contract state and identical no matter
    // which later tip this pins at; `block.timestamp` itself is immediately overridden by
    // `vm.warp` against the fixed real-weekend constants below, never read from the fork's "now".

    // Chainlink `<ticker> / USD` proxies on Robinhood Chain mainnet, resolved from
    // docs/research/chainlink-feeds-robinhood-mainnet.json, live-verified below via
    // `description()`/`getRoundData()` against the real chain.
    address constant SPY = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address constant AAPL = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    // USDC / USD, decision 3's liveness guard feed for RHC (no sequencer-uptime feed exists on
    // this chain at all, unlike Arbitrum).
    address constant LIVENESS_FEED = 0x9e6f4605992a899eE2999999F3Ec80C41F452546;

    // Real RHC USDG ERC20 (docs/research/lane-official.md, cross-confirmed in lane-github.md;
    // not the USDG/USD price feed, a different address). 6dp, `symbol()`/`decimals()` verified live.
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);

    // Gap-table ids (evidence/gap-tables/): SPY 2, AAPL 1, matching GapTreaty.fork.t.sol's mapping.
    uint8 constant SPY_TABLE = 2;
    uint8 constant AAPL_TABLE = 1;

    // The real Friday 2026-09-25 close (20:00 UTC, EDT) and Monday 2026-09-28 expiry (13:30 UTC,
    // EDT), independently reproduced from `fridayCloseOf`/`weekWindow`'s own DST math, not
    // hand-picked: FRI 00:00 UTC + 20h, and FRI + 3 days + 13h30m.
    uint256 constant FRI_MIDNIGHT = 1_790_294_400;
    uint256 constant FRI_CLOSE = FRI_MIDNIGHT + 20 hours;
    uint256 constant FRI_CUTOFF = FRI_MIDNIGHT + 19 hours + 30 minutes;
    uint256 constant EXPIRY = FRI_MIDNIGHT + 3 days + 13 hours + 30 minutes;

    address writer = makeAddr("rhc-writer");
    address buyer = makeAddr("rhc-buyer");

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(RPC);
    }

    function _deploy(address feed, uint8 tableId) internal returns (Treaty t, Capacity c) {
        address[] memory feeds = new address[](1);
        feeds[0] = feed;
        uint8[] memory tableIds = new uint8[](1);
        tableIds[0] = tableId;
        // RHC settings: no sequencer-uptime feed (RHC has none), liveness feed wired for real.
        t = deployTreaty(address(USDG), address(new Pricer(tableIds)), feeds, 50, address(0), LIVENESS_FEED);
        c = t.capacity();
        deal(address(USDG), writer, 1_000_000e6);
        vm.prank(writer);
        USDG.approve(address(c), type(uint256).max);
        vm.prank(writer);
        c.deposit(500_000e6, writer);
        deal(address(USDG), buyer, 1_000_000e6);
        vm.prank(buyer);
        USDG.approve(address(c), type(uint256).max);
    }

    function _bind(Treaty t, int256 exposure, uint256 retention, uint256 limit) internal returns (uint256 id) {
        vm.warp(FRI_CUTOFF - 1 hours); // strictly before this week's real bind cutoff
        int256[] memory e = new int256[](1);
        e[0] = exposure;
        vm.prank(buyer);
        id = t.bind(e, retention, limit);
    }

    function _layerState(Treaty t, uint256 id) internal view returns (Treaty.State s) {
        (,,,,, s,,,,,) = t.layers(id);
    }

    function _layerPayout(Treaty t, uint256 id) internal view returns (uint256 p) {
        (,,,,,,,,,, p) = t.layers(id);
    }

    /// setReference now takes the round already in effect the instant Friday's close happened
    /// (SPY round 146, `updatedAt` ~3.95h before close), never the first round after it (round
    /// 147, which prints ~52h after close carrying the weekend's move): round 147 must revert
    /// `BadRound` regardless of round 146's presence, and round 146 must succeed at the live
    /// answer Chainlink actually recorded.
    function test_ref_takesRoundInEffectAtClose() public {
        (Treaty t,) = _deploy(SPY, SPY_TABLE);
        uint256 id = _bind(t, 2_000_000e6, 5_000e6, 60_000e6);
        vm.warp(FRI_CLOSE + 1);

        uint80 round147 = uint80((uint256(1) << 64) | 147);
        vm.expectRevert(Treaty.BadRound.selector);
        t.setReference(id, 0, round147);
        assertFalse(t.referenceSet(id, 0));

        uint80 round146 = uint80((uint256(1) << 64) | 146);
        (, int256 answer146,,,) = AggregatorV3Interface(SPY).getRoundData(round146);
        t.setReference(id, 0, round146);
        assertTrue(t.referenceSet(id, 0));
        assertEq(uint256(t.fridayPrice(id, 0)), uint256(answer146));
        assertEq(uint256(answer146), 77_232_802_713, "must be the live round 146 answer Chainlink actually recorded");
    }

    /// The real weekend's payout end to end: long 2,000,000 USDG SPY, 5,000 USDG retention,
    /// reference round 146 (close), fix round 148 (first fresh round at/after expiry). The
    /// expected payout is derived here from the two fetched rounds using the same formula
    /// `_settle` uses, not hardcoded to the spec's cited figure, and then cross-checked against
    /// it: both must agree, or either the live chain state or the spec's own worked example is
    /// wrong.
    function test_rhc_realWeekendPayout() public {
        (Treaty t, Capacity c) = _deploy(SPY, SPY_TABLE);
        int256 exposure = 2_000_000e6;
        uint256 retention = 5_000e6;
        uint256 limit = 60_000e6;
        uint256 id = _bind(t, exposure, retention, limit);

        vm.warp(FRI_CLOSE + 1);
        uint80 round146 = uint80((uint256(1) << 64) | 146);
        t.setReference(id, 0, round146);
        (, int256 fridayAnswer,,,) = AggregatorV3Interface(SPY).getRoundData(round146);

        uint80 round148 = uint80((uint256(1) << 64) | 148);
        (, int256 mondayAnswer,, uint256 mondayUpdatedAt,) = AggregatorV3Interface(SPY).getRoundData(round148);
        vm.warp(mondayUpdatedAt + 1);
        t.fix(id, 0, round148);

        assertEq(uint8(_layerState(t, id)), uint8(Treaty.State.Settled));

        int256 pnl = (exposure * (mondayAnswer - fridayAnswer)) / fridayAnswer;
        int256 loss = pnl < 0 ? -pnl : int256(0);
        int256 net = loss - int256(retention);
        uint256 expectedPayout = net < 0 ? 0 : uint256(net);
        if (expectedPayout > limit) expectedPayout = limit;
        assertGt(expectedPayout, 0, "the real weekend's SPY gap must clear retention for this test to mean anything");
        assertEq(_layerPayout(t, id), expectedPayout);
        assertEq(expectedPayout, 9_470_492_960, "must match the spec's own worked figure, derived independently here");

        uint256 buyerBefore = USDG.balanceOf(buyer);
        vm.prank(buyer);
        t.claim(id);
        assertEq(USDG.balanceOf(buyer), buyerBefore + expectedPayout, "claim must move exactly the derived payout");
        assertEq(c.locked(), 0);
    }

    /// Same real weekend, AAPL rounds 671/672/673: AAPL's price rose over the weekend
    /// (341.45 -> 342.43), so a long position pays out zero, an uninteresting check; a short
    /// 2,000,000 USDG position is the side that actually loses and exercises a real payout.
    /// Round 673 (the fix round) prints 453 seconds after expiry, the spec's own cited timing,
    /// reproduced here from the live `updatedAt`, not hardcoded.
    function test_rhc_realWeekendPayout_AAPL() public {
        (Treaty t, Capacity c) = _deploy(AAPL, AAPL_TABLE);
        int256 exposure = -2_000_000e6; // short
        uint256 retention = 5_000e6;
        uint256 limit = 60_000e6;
        uint256 id = _bind(t, exposure, retention, limit);

        vm.warp(FRI_CLOSE + 1);
        uint80 round671 = uint80((uint256(1) << 64) | 671);
        t.setReference(id, 0, round671);
        (, int256 fridayAnswer,,,) = AggregatorV3Interface(AAPL).getRoundData(round671);

        uint80 round673 = uint80((uint256(1) << 64) | 673);
        (, int256 mondayAnswer,, uint256 mondayUpdatedAt,) = AggregatorV3Interface(AAPL).getRoundData(round673);
        assertEq(mondayUpdatedAt - EXPIRY, 453, "round 673 must print exactly 453s after expiry, the spec's own timing");
        vm.warp(mondayUpdatedAt + 1);
        t.fix(id, 0, round673);

        assertEq(uint8(_layerState(t, id)), uint8(Treaty.State.Settled));

        int256 pnl = (exposure * (mondayAnswer - fridayAnswer)) / fridayAnswer;
        int256 loss = pnl < 0 ? -pnl : int256(0);
        int256 net = loss - int256(retention);
        uint256 expectedPayout = net < 0 ? 0 : uint256(net);
        if (expectedPayout > limit) expectedPayout = limit;
        assertGt(expectedPayout, 0, "the short AAPL position must clear retention for this test to mean anything");
        assertEq(_layerPayout(t, id), expectedPayout);

        uint256 buyerBefore = USDG.balanceOf(buyer);
        vm.prank(buyer);
        t.claim(id);
        assertEq(USDG.balanceOf(buyer), buyerBefore + expectedPayout);
        assertEq(c.locked(), 0);
    }
}

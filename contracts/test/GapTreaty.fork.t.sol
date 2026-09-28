// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer} from "../src/Pricer.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";

/// Proves the multi-market mechanism against live Arbitrum One state, pinned to a fixed block
/// (Item 3: an unreachable RPC now fails the suite, it does not skip it). Arbitrum Sepolia has
/// only one live equity feed (SPY), so this fork test is the only place several markets are
/// exercised together against real oracle state; the Sepolia deploy binds SPY alone.
///
/// L2 (re-review of 23e632f, docs/security/capacity-review.md "Re-review (2026-09-28)"): this
/// suite used to bind all 9 real Chainlink equity feeds through `nTableIds(9)`, which assigns
/// table id 0 (NVDA) to every market, including SPY -- the exact P2 mapping error, just written
/// explicitly instead of relying on position. `evidence/gap-tables/` only sources four tables
/// (NVDA 0, AAPL 1, SPY 2, TSLA 3); MSFT, AMZN, GOOGL, META and COIN have no table at all. Since
/// `Pricer`'s constructor now requires an explicit, valid table id per market (P2 fix, `BadTableId`
/// on any id > 3), this suite can only honestly construct a `Treaty`/`Pricer` for the four markets
/// that actually have a table, each pinned to its own id. The other five live Chainlink feeds
/// (MSFT, AMZN, GOOGL, META, COIN) remain a mainnet blocker: mainnet cannot bind them until their
/// gap tables are sourced and added to the Pricer, and the addresses stay below purely as a record
/// of the live feeds this treaty cannot yet price.
contract GapTreatyForkTest is Test {
    string constant RPC = "https://arb1.arbitrum.io/rpc";
    // Judging doc B.1.3 / orchestrator Item 3: forking at "latest" with no pinned block meant this
    // suite's result silently depended on whatever round Arbitrum One's live feeds happened to be
    // on when CI ran, and reproducing a failure required forking at the same unrecorded moment.
    // Pinned to a real Arbitrum One block read via `cast block-number` on 2026-09-28
    // (509,707,336), 2,000 blocks back for safety margin against reorgs at the tip. Kept close to
    // the tip deliberately: `arb1.arbitrum.io`'s public RPC is not a full archive node and
    // returns `missing trie node`/`historical state is not available` for account state much
    // further back than this (confirmed empirically -- ~16,000 blocks back already fails, ~2,000
    // blocks back is reliable) -- a pin has to be both fixed and within what the RPC actually
    // still serves.
    uint256 constant FORK_BLOCK = 509_705_336;

    // Chainlink `<ticker> / USD` proxies on Arbitrum One, from Chainlink's own reference-data
    // directory (reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json),
    // live-verified via cast call decimals()/latestRoundData() before use here.
    address constant SPY = 0x46306F3795342117721D8DEd50fbcF6DF2b3cc10;
    address constant NVDA = 0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F;
    address constant AAPL = 0x8d0CC5f38f9E802475f2CFf4F9fc7000C2E1557c;
    address constant TSLA = 0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3;
    // MAINNET BLOCKER (L2): these 5 live Arbitrum One Chainlink feeds have no sourced gap table
    // (`evidence/gap-tables/` only has NVDA/AAPL/SPY/TSLA), so `Pricer` cannot be given a valid
    // table id for them and this treaty cannot bind them on mainnet until that data is sourced.
    // Kept here, unused, as the record of which live feeds still need one.
    address constant MSFT = 0xDde33fb9F21739602806580bdd73BAd831DcA867;
    address constant AMZN = 0xd6a77691f071E98Df7217BED98f38ae6d2313EBA;
    address constant GOOGL = 0x1D1a83331e9D255EB1Aaf75026B60dFD00A252ba;
    address constant META = 0xcd1bd86fDc33080DCF1b5715B6FCe04eC6F85845;
    address constant COIN = 0x950DC95D4E537A14283059bADC2734977C454498;

    IERC20 constant USDG = IERC20(0x004B506865409877C9fA29bfb1ebA929984B9bbC);
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // 6dp, wrong decimals for a feed

    // M2: mainnet must wire the real Arbitrum One L2 Sequencer Uptime Status Feed (verified live
    // via cast call decimals()/latestRoundData() against arb1.arbitrum.io on 2026-09-26).
    address constant SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    Treaty treaty;
    Capacity capacity;
    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    // Judging doc B.1.3 / orchestrator Item 3: this suite used to `vm.skip(true)` when the RPC
    // was unreachable, so CI stayed green with zero fork coverage. `vm.createSelectFork` is now
    // called directly, with no try/catch: an unreachable RPC reverts `setUp` and every test in
    // this contract reports FAIL, not SKIP, which is the outcome that actually surfaces the
    // missing coverage instead of hiding it.
    function setUp() public {
        vm.createSelectFork(RPC, FORK_BLOCK);

        // L2: only the 4 markets `evidence/gap-tables/` actually sources, each on its own table
        // id (NVDA 0, AAPL 1, SPY 2, TSLA 3) -- matching feed order to table id order, not the old
        // "table 0 for everyone" bug.
        address[] memory feeds = new address[](4);
        (feeds[0], feeds[1], feeds[2], feeds[3]) = (NVDA, AAPL, SPY, TSLA);
        uint8[] memory tableIds = new uint8[](4);
        (tableIds[0], tableIds[1], tableIds[2], tableIds[3]) = (0, 1, 2, 3);
        treaty = new Treaty(address(USDG), address(new Pricer(tableIds)), feeds, 50, SEQUENCER_FEED);
        capacity = treaty.capacity();
    }

    function test_fork_allowlistAcceptsFourTabledRealFeeds() public {
        assertEq(treaty.marketsLength(), 4);
        assertEq(address(treaty.markets(0)), NVDA);
        assertEq(address(treaty.markets(1)), AAPL);
        assertEq(address(treaty.markets(2)), SPY);
        assertEq(address(treaty.markets(3)), TSLA);
    }

    /// A feed with the wrong decimals (real USDC, 6dp not 8dp) must be refused at construction:
    /// the same fix this treaty applies ("writer picks the oracle").
    function test_fork_rejectsNonEightDecimalFeed() public {
        address[] memory bad = new address[](1);
        bad[0] = USDC;
        address pricerAddr = address(new Pricer(oneTableId()));
        vm.expectRevert(Treaty.BadParams.selector);
        new Treaty(address(USDG), pricerAddr, bad, 50, SEQUENCER_FEED);
    }

    /// Binds real exposure across the 4 tabled live markets in one layer, reading each market's
    /// actual current round as the Friday reference and pulling a real premium quote from the
    /// Pricer; proves the multi-market path end to end against live oracle state. Does not
    /// fix/settle: that needs a real weekend gap to pass on-chain, which the Sepolia live-cycle
    /// run covers for the single SPY market instead.
    function test_fork_bindsRealExposureAcrossFourTabledMarkets() public {

        int256[] memory exposure = new int256[](4);
        for (uint256 i; i < 4; i++) {
            exposure[i] = i % 2 == 0 ? int256(100_000e6) : -int256(100_000e6);
        }

        // bind() only accepts binds strictly before this week's Friday 19:30 UTC; land inside
        // that window regardless of when this fork test actually runs.
        (uint256 cutoff,) = treaty.weekWindow(block.timestamp);
        if (block.timestamp >= cutoff) {
            vm.warp(cutoff + 7 days - 1 hours);
        }

        deal(address(USDG), buyer, 1_000_000e6);
        vm.prank(buyer);
        USDG.approve(address(capacity), type(uint256).max);
        deal(address(USDG), writer, 1_000_000e6);
        vm.prank(writer);
        USDG.approve(address(capacity), type(uint256).max);
        vm.prank(writer);
        capacity.deposit(1_000_000e6, writer);

        vm.prank(buyer);
        uint256 id = treaty.bind(exposure, 10_000e6, 50_000e6);

        (address l_buyer,,,,,,,,, uint256 premium,) = treaty.layers(id);
        assertEq(l_buyer, buyer);
        assertGt(premium, 0);
        assertEq(capacity.locked(), 50_000e6);
        console.log("live 4-market premium (USDG, 6dp)", premium);
    }
}

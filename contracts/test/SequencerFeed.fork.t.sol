// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treaty} from "../src/Treaty.sol";
import {Pricer} from "../src/Pricer.sol";
import {AggregatorV3Interface} from "../src/Pricer.sol";
import {TreatyFixture} from "./utils/TreatyFixture.sol";

/// The Treaty's sequencer gate against Arbitrum One's real L2 Sequencer Uptime Status Feed at a
/// pinned block. With the feed as it stands (answer 0, up since startedAt) a bind clears the gate
/// and stops at the next check, the Thursday bind deadline. With the feed reporting the sequencer
/// down, or back up for less than the one-hour grace, the same bind reverts SequencerDown.
/// Gated on FORK_TESTS like the other fork suites; with it set, an unreachable RPC fails setUp.
contract SequencerFeedForkTest is Test, TreatyFixture {
    string constant RPC = "https://arbitrum.gateway.tenderly.co";
    /// Arbitrum One, Fri 2026-10-02 14:27:14 UTC, read with cast block-number.
    uint256 constant FORK_BLOCK = 511_011_337;
    address constant SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    address constant SPY = 0x46306F3795342117721D8DEd50fbcF6DF2b3cc10;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    /// latestRoundData().startedAt at FORK_BLOCK: the sequencer has been up since this second.
    uint256 constant UP_SINCE = 1_779_307_607;

    Treaty treaty;
    int256[] exposure;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(RPC, FORK_BLOCK);
        address[] memory feeds = new address[](1);
        feeds[0] = SPY;
        uint8[] memory ids = new uint8[](1);
        ids[0] = 2;
        treaty = deployTreaty(USDC, address(new Pricer(ids)), feeds, 50, SEQUENCER_FEED);
        exposure.push(100_000e6);
    }

    function test_fork_liveFeedReportsUpPastGrace() public view {
        (, int256 answer, uint256 startedAt,,) = AggregatorV3Interface(SEQUENCER_FEED).latestRoundData();
        assertEq(answer, 0, "0 means up");
        assertEq(startedAt, UP_SINCE);
        assertGt(block.timestamp - startedAt, 1 hours);
        assertEq(treaty.sequencerUptimeFeed(), SEQUENCER_FEED);
    }

    /// The pinned block is a Friday after the Thursday 19:30 UTC deadline, so a bind that clears
    /// the sequencer gate reverts on the clock instead.
    function test_fork_bindClearsTheGateOnTheLiveFeed() public {
        vm.expectRevert(Treaty.BadTiming.selector);
        treaty.bind(0, exposure, 1_000e6, 10_000e6, type(uint256).max);
    }

    function test_fork_sequencerDownRevertsBind() public {
        _feedSays(1, block.timestamp - 2 hours);
        vm.expectRevert(Treaty.SequencerDown.selector);
        treaty.bind(0, exposure, 1_000e6, 10_000e6, type(uint256).max);
    }

    function test_fork_insideGraceHourRevertsBind() public {
        _feedSays(0, block.timestamp - 30 minutes);
        vm.expectRevert(Treaty.SequencerDown.selector);
        treaty.bind(0, exposure, 1_000e6, 10_000e6, type(uint256).max);
    }

    function _feedSays(int256 answer, uint256 startedAt) internal {
        vm.mockCall(
            SEQUENCER_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), answer, startedAt, startedAt, uint80(1))
        );
    }
}

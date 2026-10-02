// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Treaty} from "../src/Treaty.sol";
import {Capacity} from "../src/Capacity.sol";
import {Pricer, AggregatorV3Interface} from "../src/Pricer.sol";
import {OIGuard} from "../src/OIGuard.sol";
import {VaultCover} from "../src/VaultCover.sol";
import {DeployArbitrumOne} from "../script/DeployArbitrumOne.s.sol";

/// Rehearses script/DeployArbitrumOne.s.sol on a fork of Arbitrum One at the latest block, through the
/// script's own `deploy`, against the real Chainlink feeds, the real sequencer uptime feed and real
/// USDG. Forge's EVM cannot run the Stylus pricer, so the Solidity twin with the same six table ids
/// stands in for it (PricerParity.t.sol holds the two equal). Gated on FORK_TESTS; ARB1_RPC_URL
/// overrides the endpoint.
contract ArbitrumOneRehearsalForkTest is Test {
    address constant USDG = 0x004B506865409877C9fA29bfb1ebA929984B9bbC;
    address constant SEQ = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    /// Thu 2026-10-01 12:00 UTC: inside that week's bind window (it closes Thursday 19:30 UTC).
    uint256 constant BIND_OPEN = 1_790_856_000;

    DeployArbitrumOne script;
    Treaty treaty;
    OIGuard guard;
    VaultCover cover;
    address owner = makeAddr("owner");
    address writer = makeAddr("writer");
    address buyer = makeAddr("buyer");

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envOr("ARB1_RPC_URL", string("https://arb1.arbitrum.io/rpc")));
        script = new DeployArbitrumOne();
        uint8[] memory ids = new uint8[](6);
        for (uint8 i; i < 6; i++) ids[i] = i;
        (treaty, guard, cover) = script.deploy(address(new Pricer(ids)), owner);
        vm.warp(BIND_OPEN);

        deal(USDG, writer, 1_000e6);
        deal(USDG, buyer, 1_000e6);
        vm.startPrank(writer);
        IERC20(USDG).approve(treaty.firstLossVault(0), type(uint256).max);
        IERC20(USDG).approve(treaty.seniorVault(0), type(uint256).max);
        Capacity(treaty.firstLossVault(0)).deposit(30e6, writer);
        Capacity(treaty.seniorVault(0)).deposit(70e6, writer);
        vm.stopPrank();
        vm.prank(buyer);
        IERC20(USDG).approve(address(treaty), type(uint256).max);
    }

    function _exposure() internal pure returns (int256[] memory e) {
        e = new int256[](6);
        e[2] = 10_000e6; // long 10,000 USDG of SPY
    }

    function test_rehearsal_wiresTheRealFeedsAndUSDG() public view {
        address[] memory f = script.feeds();
        assertEq(treaty.marketsLength(), 6);
        for (uint256 i; i < 6; i++) assertEq(address(treaty.markets(i)), f[i]);
        assertEq(treaty.sequencerUptimeFeed(), SEQ, "the sequencer gate is live on Arbitrum One");
        assertEq(treaty.bookAsset(0), USDG);
        assertEq(Capacity(treaty.firstLossVault(0)).totalAssets(), 30e6);
        assertEq(guard.feeds().length, 6);
        assertEq(cover.coverIndex().length, 6);
        (, int256 answer, uint256 startedAt,,) = AggregatorV3Interface(SEQ).latestRoundData();
        assertEq(answer, 0, "sequencer up at the fork block");
        assertGt(startedAt, 0);
    }

    function test_rehearsal_bindPassesOnTheRealSequencerFeed() public {
        vm.prank(buyer);
        uint256 id = treaty.bind(0, _exposure(), 100e6, 100e6, 10e6);
        (,,,,,, Treaty.State st,,,,, uint256 premium,,,,,) = treaty.layers(id);
        assertEq(uint8(st), uint8(Treaty.State.Bound));
        emit log_named_decimal_uint("premium, USDG", premium, 6);
        assertGe(premium, 100e6 * 50 / 10_000, "at least the 50 bps floor");
        assertLe(premium, 10e6);
    }

    function test_rehearsal_bindRevertsWhenTheSequencerIsDown() public {
        vm.mockCall(SEQ, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), abi.encode(uint80(1), int256(1), block.timestamp - 2 hours, block.timestamp - 2 hours, uint80(1)));
        vm.prank(buyer);
        vm.expectRevert(Treaty.SequencerDown.selector);
        treaty.bind(0, _exposure(), 100e6, 100e6, 10e6);
    }

    function test_rehearsal_bindRevertsInsideTheGraceHour() public {
        vm.mockCall(SEQ, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), abi.encode(uint80(1), int256(0), block.timestamp - 30 minutes, block.timestamp - 30 minutes, uint80(1)));
        vm.prank(buyer);
        vm.expectRevert(Treaty.SequencerDown.selector);
        treaty.bind(0, _exposure(), 100e6, 100e6, 10e6);
    }

    function test_rehearsal_vaultCoverRenewsOnTheRealTreaty() public {
        vm.startPrank(owner);
        cover.setVenue(owner, true);
        cover.setKeeper(owner, true);
        cover.setTerms(100e6, 100e6, 10e6);
        cover.open(2, 10_000e6);
        vm.stopPrank();
        deal(USDG, address(cover), 10e6);
        vm.prank(owner);
        uint256 id = cover.renewCover();
        assertEq(treaty.exposureOf(id)[2], 10_000e6);
        assertEq(cover.layers().length, 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Treaty} from "../src/Treaty.sol";

/// Deploys Treaty (which deploys its own Capacity vault) on Arbitrum Sepolia (421614), wired to
/// the live Paxos testnet USDG, the already-deployed Stylus Pricer, and the one live equity feed
/// Arbitrum Sepolia carries (SPY/USD). PRIVATE_KEY is read from the environment only; never
/// printed. Addresses come from a live cast call against each contract, not a doc citation:
/// - USDG (Paxos testnet, 6dp): 0xFFC95faa3d63Cde504a05B567C600B78C0b41892
/// - SPY/USD (Chainlink, 8dp, verified live via decimals()/latestRoundData() before this deploy):
///   0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06
/// - Pricer (Stylus, deployed+activated via `cargo stylus deploy` before this script runs): passed
///   in as PRICER env var so this script never hardcodes a value from a prior run by hand.
///
/// H2: `MIN_RATE_ON_LINE_BPS = 50` (0.50%) is the premium floor, immutable at deploy.
/// M2: Arbitrum Sepolia (421614) has no L2 Sequencer Uptime Status Feed (verified empty at the
/// mainnet feed's address via `cast code` against the Sepolia RPC on 2026-09-26, and confirmed
/// absent from Chainlink's own L2 feeds list; smartcontractkit/chainlink#10699 is still open
/// asking for one). `SEQUENCER_FEED = address(0)` disables the check here; a mainnet deploy must
/// pass the real feed, `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` (verified live on Arbitrum One
/// via `cast call`).
contract Deploy is Script {
    address constant USDG = 0xFFC95faa3d63Cde504a05B567C600B78C0b41892;
    address constant SPY_FEED = 0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06;
    uint256 constant MIN_RATE_ON_LINE_BPS = 50;
    address constant SEQUENCER_FEED = address(0); // no Arbitrum Sepolia equivalent exists

    function run() external returns (Treaty treaty) {
        address pricer = vm.envAddress("PRICER");
        address[] memory feeds = new address[](1);
        feeds[0] = SPY_FEED;

        vm.startBroadcast();
        treaty = new Treaty(USDG, pricer, feeds, MIN_RATE_ON_LINE_BPS, SEQUENCER_FEED);
        vm.stopBroadcast();

        console.log("Treaty", address(treaty));
        console.log("Capacity", address(treaty.capacity()));
        console.log("Pricer", pricer);
        console.log("USDG", USDG);
        console.log("SPY feed", SPY_FEED);
    }
}

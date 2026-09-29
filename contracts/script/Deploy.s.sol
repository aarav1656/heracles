// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Treaty} from "../src/Treaty.sol";

/// Minimal view of the deployed Pricer's `tableIdAt`/`table_id_at` getter (Solidity and Stylus
/// both expose it under this same camelCase selector), used only for the deploy-time sanity check
/// below; not part of IPricer since it is Pricer-specific configuration, not pricing behaviour.
interface ITableId {
    function tableIdAt(uint256 i) external view returns (uint8);
}

/// Deploys Treaty (which deploys its own four Capacity vaults, a first-loss and a senior vault
/// per book asset) on Arbitrum Sepolia (421614), wired to two books, USDG and USDC, the
/// already-deployed Stylus Pricer, and the one live equity feed Arbitrum Sepolia carries
/// (SPY/USD). PRIVATE_KEY is read from the environment only; never printed. Addresses come from a
/// live cast call against each contract, not a doc citation:
/// - USDG (Paxos testnet, 6dp): 0xFFC95faa3d63Cde504a05B567C600B78C0b41892
/// - USDC (Circle testnet, 6dp): 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
/// - SPY/USD (Chainlink, 8dp, verified live via decimals()/latestRoundData() before this deploy):
///   0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06
/// - Pricer (Stylus, already deployed and activated, reused unchanged across this redeploy):
///   0xBE99217180A5Fcb83372375b0928c971dFa71f88, `tableIdAt(0) == 2` (SPY), verified live.
///
/// H2: `MIN_RATE_ON_LINE_BPS = 50` (0.50%) is the premium floor, immutable at deploy.
/// Every layer's first-loss sub-limit is `JUNIOR_SHARE_BPS = 3_000` (30%) of its own limit,
/// immutable at deploy.
/// M2: Arbitrum Sepolia (421614) has no L2 Sequencer Uptime Status Feed (verified empty at the
/// mainnet feed's address via `cast code` against the Sepolia RPC on 2026-09-26, and confirmed
/// absent from Chainlink's own L2 feeds list; smartcontractkit/chainlink#10699 is still open
/// asking for one). `SEQUENCER_FEED = address(0)` disables the check here; a mainnet deploy must
/// pass the real feed, `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` (verified live on Arbitrum One
/// via `cast call`).
/// `cancel`'s liveness guard: real Arbitrum Sepolia USDC/USD Chainlink feed, verified live via
/// `cast call description()/decimals()/latestRoundData()` against sepolia-rollup.arbitrum.io on
/// 2026-09-29 ("USDC / USD", 8dp, `updatedAt` 1790681980, about 5h before this deploy script was
/// written).
contract Deploy is Script {
    address constant USDG = 0xFFC95faa3d63Cde504a05B567C600B78C0b41892;
    address constant USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address constant PRICER = 0xBE99217180A5Fcb83372375b0928c971dFa71f88;
    address constant SPY_FEED = 0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06;
    uint256 constant MIN_RATE_ON_LINE_BPS = 50;
    uint256 constant JUNIOR_SHARE_BPS = 3_000;
    address constant SEQUENCER_FEED = address(0); // no Arbitrum Sepolia equivalent exists
    address constant LIVENESS_FEED = 0x0153002d20B96532C639313c2d54c3dA09109309;

    function run() external returns (Treaty treaty) {
        // Mainnet sequencer-feed trap: this script
        // hardcodes `SEQUENCER_FEED = address(0)` and `SPY_FEED`'s Sepolia address above. Nothing
        // previously stopped it from being run against a different `--rpc-url` (Arbitrum One,
        // chain id 42161) and silently deploying a mainnet Treaty with the sequencer-downtime
        // check disabled and Sepolia's feed address wired in as the "SPY" market. This script is
        // Sepolia-only; a mainnet deploy needs its own script passing the real
        // `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` sequencer feed and the real Arbitrum One
        // SPY feed, not a copy-paste of this one with the RPC flag changed.
        require(block.chainid == 421614, "Deploy.s.sol is Sepolia-only (chain id 421614)");

        address[] memory feeds = new address[](1);
        feeds[0] = SPY_FEED;

        // P2 deploy-time guard: the single feed above is SPY at index 0, so refuse to wire up a
        // Pricer that was not explicitly configured to price index 0 on the SPY table (id 2).
        // The Pricer constructor already reverts on an empty or invalid tableIds array (P2
        // re-review), so this check only catches the narrower case of a Pricer deployed with a
        // valid but wrong table id (e.g. NVDA, id 0) at index 0.
        // Asked of the live node through vm.rpc rather than called in Forge's local EVM, which
        // cannot execute Stylus (WASM) code and would revert with OpcodeNotFound.
        string memory callParams = string.concat(
            '[{"to":"', vm.toString(PRICER), '","data":"',
            vm.toString(abi.encodeCall(ITableId.tableIdAt, (0))), '"},"latest"]'
        );
        require(abi.decode(vm.rpc("eth_call", callParams), (uint8)) == 2, "PRICER not configured for SPY table at index 0");

        address[] memory assets = new address[](2);
        assets[0] = USDG;
        assets[1] = USDC;
        string[] memory firstLossNames = new string[](2);
        string[] memory firstLossSymbols = new string[](2);
        string[] memory seniorNames = new string[](2);
        string[] memory seniorSymbols = new string[](2);
        firstLossNames[0] = "Heracles First Loss USDG";
        firstLossSymbols[0] = "hFL-USDG";
        seniorNames[0] = "Heracles Senior USDG";
        seniorSymbols[0] = "hSR-USDG";
        firstLossNames[1] = "Heracles First Loss USDC";
        firstLossSymbols[1] = "hFL-USDC";
        seniorNames[1] = "Heracles Senior USDC";
        seniorSymbols[1] = "hSR-USDC";

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        treaty = new Treaty(
            assets,
            firstLossNames,
            firstLossSymbols,
            seniorNames,
            seniorSymbols,
            PRICER,
            feeds,
            MIN_RATE_ON_LINE_BPS,
            SEQUENCER_FEED,
            LIVENESS_FEED,
            JUNIOR_SHARE_BPS
        );
        vm.stopBroadcast();

        console.log("Treaty", address(treaty));
        console.log("Pricer", PRICER);
        console.log("USDG book: asset", USDG);
        console.log("USDG book: first-loss vault", treaty.firstLossVault(0));
        console.log("USDG book: senior vault", treaty.seniorVault(0));
        console.log("USDC book: asset", USDC);
        console.log("USDC book: first-loss vault", treaty.firstLossVault(1));
        console.log("USDC book: senior vault", treaty.seniorVault(1));
        console.log("SPY feed", SPY_FEED);
    }
}

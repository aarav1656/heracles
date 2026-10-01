// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Treaty} from "../src/Treaty.sol";

interface ITableIdRhc {
    function tableIdAt(uint256 i) external view returns (uint8);
}

/// Deploys Treaty on Robinhood Chain mainnet (4663) with one USDG book (a first-loss and a senior
/// vault) and the four equity markets the pricer carries tables for. Contracts only: no deposit,
/// no bind. PRIVATE_KEY and RHC_PRICER are read from the environment; the key is never printed.
///
/// The Stylus pricer is a separate deploy of the same bytecode as Arbitrum Sepolia's, with its
/// table ids in this script's feed order, SPY 2, NVDA 0, AAPL 1, TSLA 3:
///   cd pricer && cargo stylus deploy --endpoint https://rpc.mainnet.chain.robinhood.com \
///     --private-key "$PRIVATE_KEY" --constructor-args "[2,0,1,3]"
/// then pass the printed address as RHC_PRICER. `run` refuses any pricer whose `tableIdAt(i)` does
/// not match the feed at index i.
///
/// Feeds, each read live on chain 4663 at block 75,896,663 with `description()`, `decimals()` and
/// `latestRoundData()` (all 8 decimals, 86,400 s heartbeat, 0.5% deviation):
/// - SPY  "RHSPY / USD"          0x319724394D3A0e3669269846abE664Cd621f9f6A
/// - NVDA "RHNVDA / USD"         0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15
/// - AAPL "Robinhood AAPL / USD" 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0
/// - TSLA "RHTSLA / USD"         0x4A1166a659A55625345e9515b32adECea5547C38
/// `cancel`'s liveness feed is USDC / USD 0x9e6f4605992a899eE2999999F3Ec80C41F452546, which prints
/// through weekends. Robinhood Chain has no L2 sequencer uptime feed, so that check is disabled.
/// USDG 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 is native Paxos USDG (6 decimals, EIP-2612).
/// USDC has no confirmed address on this chain, so there is no USDC book.
contract DeployRobinhood is Script {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant SPY_FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant LIVENESS_FEED = 0x9e6f4605992a899eE2999999F3Ec80C41F452546;
    address constant SEQUENCER_FEED = address(0);
    uint256 constant MIN_RATE_ON_LINE_BPS = 50;
    uint256 constant JUNIOR_SHARE_BPS = 3_000;

    function run() external returns (Treaty treaty) {
        require(block.chainid == 4663, "DeployRobinhood.s.sol is Robinhood Chain only (chain id 4663)");
        address pricer = vm.envAddress("RHC_PRICER");

        address[] memory feeds = new address[](4);
        feeds[0] = SPY_FEED;
        feeds[1] = NVDA_FEED;
        feeds[2] = AAPL_FEED;
        feeds[3] = TSLA_FEED;
        uint8[4] memory tableIds = [uint8(2), 0, 1, 3];

        // Asked of the live node through vm.rpc: Forge's local EVM cannot execute Stylus code.
        for (uint256 i; i < 4; i++) {
            string memory params = string.concat(
                '[{"to":"', vm.toString(pricer), '","data":"',
                vm.toString(abi.encodeCall(ITableIdRhc.tableIdAt, (i))), '"},"latest"]'
            );
            require(abi.decode(vm.rpc("eth_call", params), (uint8)) == tableIds[i], "RHC_PRICER table id mismatch");
        }

        address[] memory assets = new address[](1);
        assets[0] = USDG;
        string[] memory firstLossNames = new string[](1);
        string[] memory firstLossSymbols = new string[](1);
        string[] memory seniorNames = new string[](1);
        string[] memory seniorSymbols = new string[](1);
        firstLossNames[0] = "Heracles First Loss USDG";
        firstLossSymbols[0] = "hFL-USDG";
        seniorNames[0] = "Heracles Senior USDG";
        seniorSymbols[0] = "hSR-USDG";

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        treaty = new Treaty(
            assets,
            firstLossNames,
            firstLossSymbols,
            seniorNames,
            seniorSymbols,
            pricer,
            feeds,
            MIN_RATE_ON_LINE_BPS,
            SEQUENCER_FEED,
            LIVENESS_FEED,
            JUNIOR_SHARE_BPS
        );
        vm.stopBroadcast();

        console.log("Treaty", address(treaty));
        console.log("Pricer", pricer);
        console.log("USDG book: first-loss vault", treaty.firstLossVault(0));
        console.log("USDG book: senior vault", treaty.seniorVault(0));
    }
}

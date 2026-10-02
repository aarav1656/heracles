// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Treaty} from "../src/Treaty.sol";
import {IPricer} from "../src/IPricer.sol";
import {OIGuard} from "../src/OIGuard.sol";
import {VaultCover} from "../src/VaultCover.sol";

interface ITableIds {
    function tableIdAt(uint256 i) external view returns (uint8);
}

/// Heracles on Arbitrum One (42161): one six-table Stylus pricer read by the Treaty, the OIGuard and,
/// through them, VaultCover, so all three share one market order: NVDA, AAPL, SPY, TSLA, EUR/USD,
/// XAU/USD (table ids 0 to 5). One book, settled in Paxos USDG.
///
/// The pricer is a Stylus program deployed first and passed in as ARB1_PRICER:
///   cd pricer && cargo stylus deploy --endpoint https://arb1.arbitrum.io/rpc \
///     --private-key-path <file> --constructor-args "[0,1,2,3,4,5]"
/// `run` reads tableIdAt(0..5) from the live node and refuses a pricer configured any other way.
///
/// Every address below was read live on Arbitrum One at block 511,120,266 (2026-10-02):
/// - Chainlink proxies, all 8 decimals, description() as given: NVDA "NVDA / USD", AAPL "AAPL / USD",
///   SPY "SPY / USD", TSLA "TSLA / USD", EUR "EUR / USD", XAU "XAU / USD".
/// - L2 Sequencer Uptime Status Feed 0xFdB6...697D: the Treaty's sequencer gate is live here.
/// - USDC / USD 0x5083...4aD3: the cancel liveness feed, it prints through weekends.
/// - USDG 0x004B...9bbC: "Global Dollar", USDG, 6 decimals, EIP-2612 domain version "1" (the
///   DOMAIN_SEPARATOR recomputed with version "1" matches the one on chain).
/// PRIVATE_KEY is read from the environment only; never printed.
contract DeployArbitrumOne is Script {
    address constant USDG = 0x004B506865409877C9fA29bfb1ebA929984B9bbC;
    address constant NVDA = 0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F;
    address constant AAPL = 0x8d0CC5f38f9E802475f2CFf4F9fc7000C2E1557c;
    address constant SPY = 0x46306F3795342117721D8DEd50fbcF6DF2b3cc10;
    address constant TSLA = 0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3;
    address constant EUR = 0xA14d53bC1F1c0F31B4aA3BD109344E5009051a84;
    address constant XAU = 0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c;
    address constant SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    address constant LIVENESS_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    uint256 constant MIN_RATE_ON_LINE_BPS = 50;
    uint256 constant JUNIOR_SHARE_BPS = 3_000;

    function feeds() public pure returns (address[] memory f) {
        f = new address[](6);
        (f[0], f[1], f[2], f[3], f[4], f[5]) = (NVDA, AAPL, SPY, TSLA, EUR, XAU);
    }

    /// The whole wiring; `run` broadcasts it, the fork rehearsal calls it directly.
    function deploy(address pricer, address owner) public returns (Treaty treaty, OIGuard guard, VaultCover cover) {
        address[] memory assets = new address[](1);
        assets[0] = USDG;
        string[] memory flNames = new string[](1);
        string[] memory flSymbols = new string[](1);
        string[] memory srNames = new string[](1);
        string[] memory srSymbols = new string[](1);
        (flNames[0], flSymbols[0], srNames[0], srSymbols[0]) =
            ("Heracles First Loss USDG", "hFL-USDG", "Heracles Senior USDG", "hSR-USDG");
        treaty = new Treaty(
            assets, flNames, flSymbols, srNames, srSymbols, pricer, feeds(), MIN_RATE_ON_LINE_BPS, SEQUENCER_FEED, LIVENESS_FEED,
            JUNIOR_SHARE_BPS
        );
        // Guard terms: a weekend layer from 20,000 to 220,000 USDG, at most 4,000 USDG of premium.
        guard = new OIGuard(IPricer(pricer), feeds(), owner, 20_000e6, 200_000e6, 4_000e6);
        uint256[] memory idx = new uint256[](6);
        for (uint256 i; i < 6; i++) {
            idx[i] = i; // the Treaty and the guard list the same six markets in the same order
        }
        cover = new VaultCover(treaty, guard, 0, idx, owner);
    }

    function run() external {
        require(block.chainid == 42161, "DeployArbitrumOne.s.sol is Arbitrum One only (chain id 42161)");
        address pricer = vm.envAddress("ARB1_PRICER");
        for (uint256 i; i < 6; i++) {
            string memory params = string.concat(
                '[{"to":"', vm.toString(pricer), '","data":"', vm.toString(abi.encodeCall(ITableIds.tableIdAt, (i))), '"},"latest"]'
            );
            require(abi.decode(vm.rpc("eth_call", params), (uint8)) == i, "ARB1_PRICER is not configured with table ids 0..5");
        }
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(pk);
        vm.startBroadcast(pk);
        (Treaty treaty, OIGuard guard, VaultCover cover) = deploy(pricer, owner);
        cover.setVenue(owner, true);
        cover.setKeeper(owner, true);
        cover.setTerms(100e6, 100e6, 10e6); // first layer: keep 100, cover 100, pay at most 10 USDG (5.41 measured on a fork, 2026-10-02)
        vm.stopBroadcast();
        console.log("Treaty", address(treaty));
        console.log("USDG first-loss vault", treaty.firstLossVault(0));
        console.log("USDG senior vault", treaty.seniorVault(0));
        console.log("OIGuard", address(guard));
        console.log("VaultCover", address(cover));
    }
}

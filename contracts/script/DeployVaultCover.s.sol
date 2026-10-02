// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Treaty} from "../src/Treaty.sol";
import {OIGuard} from "../src/OIGuard.sol";
import {VaultCover} from "../src/VaultCover.sol";

/// Deploys VaultCover on Arbitrum Sepolia (421614) for the USDG book of Treaty v3, guarded by the
/// deployed OIGuard (six markets in the pricer's table order). The Treaty lists one market,
/// SPY/USD, which covers book market 2 (SPY). The deployer is owner, venue and keeper. Cover terms:
/// a layer from 3,000 to 3,080 USDG of weekend loss on the SPY leg, at most 10 USDG of premium a
/// week, sized to the USDG book's capacity (30 first-loss, 60 senior). PRIVATE_KEY is read from
/// the environment only; never printed.
contract DeployVaultCover is Script {
    Treaty constant TREATY = Treaty(0x95D180568c9FcA8632AF3f8349e1f2A4bA4fb807);
    OIGuard constant GUARD = OIGuard(0x96BE263EfD057167E01a212BBd076904391217Ce);
    uint256 constant USDG_BOOK = 0;
    uint256 constant SPY = 2;

    function run() external returns (VaultCover cover) {
        require(block.chainid == 421614, "DeployVaultCover.s.sol is Sepolia-only (chain id 421614)");
        uint256[] memory idx = new uint256[](1);
        idx[0] = SPY;
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        cover = new VaultCover(TREATY, GUARD, USDG_BOOK, idx, me);
        cover.setVenue(me, true);
        cover.setKeeper(me, true);
        cover.setTerms(3_000e6, 80e6, 10e6);
        vm.stopBroadcast();
        console.log("VaultCover", address(cover));
    }
}

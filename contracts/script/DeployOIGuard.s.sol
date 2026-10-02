// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OIGuard} from "../src/OIGuard.sol";
import {IPricer} from "../src/IPricer.sol";

/// Deploys OIGuard on Arbitrum Sepolia (421614) over the six-table Stylus pricer, markets in its
/// table order (NVDA, AAPL, SPY, TSLA, EUR/USD, XAU/USD). Arbitrum Sepolia carries one live equity
/// feed, SPY/USD, so it is the volatility feed for every market, as on the quote desk. The deployer
/// owns the guard. PRIVATE_KEY is read from the environment only; never printed.
contract DeployOIGuard is Script {
    address constant PRICER = 0x1674ECf8D236A91C484C11Fd11a21601837F7e37;
    address constant SPY_FEED = 0x4fB44FC4FA132d1a846Bd4143CcdC5a9f1870b06;
    uint256 constant RETENTION = 20_000e6;
    uint256 constant LIMIT = 200_000e6;
    uint256 constant BUDGET = 4_000e6;

    function run() external returns (OIGuard guard) {
        require(block.chainid == 421614, "DeployOIGuard.s.sol is Sepolia-only (chain id 421614)");
        address[] memory feeds = new address[](6);
        for (uint256 i; i < 6; i++) {
            feeds[i] = SPY_FEED;
        }
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        guard = new OIGuard(IPricer(PRICER), feeds, vm.addr(pk), RETENTION, LIMIT, BUDGET);
        vm.stopBroadcast();
        console.log("OIGuard", address(guard));
    }
}

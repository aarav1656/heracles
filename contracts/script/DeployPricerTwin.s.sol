// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Pricer} from "../src/Pricer.sol";

/// Deploys the Solidity twin of the Stylus pricer with the same table ids (SPY at index 0), so
/// both `quote()` implementations can be called against the same live feed and their call gas
/// compared on one chain. PRIVATE_KEY is read from the environment only.
contract DeployPricerTwin is Script {
    function run() external returns (Pricer twin) {
        uint8[] memory ids = new uint8[](1);
        ids[0] = 2;
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        twin = new Pricer(ids);
        vm.stopBroadcast();
        console2.log("pricer twin", address(twin));
    }
}

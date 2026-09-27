// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Pricer} from "../src/Pricer.sol";

contract PricerTest is Test {
    Pricer p;

    // (strikeBps, spotE8, ivE6, secondsToExpiry)
    uint32[5] strikeBpsCases = [9700, 9000, 9900, 8500, 9999];
    uint64[5] spotE8Cases = [22540000000, 10000000000, 50000000000, 30000000000, 100000000000];
    uint32[5] ivE6Cases = [253400, 400000, 150000, 600000, 100000];
    uint32[5] secondsCases = [216000, 172800, 259200, 345600, 86400];

    function setUp() public {
        p = new Pricer();
    }

    function test_deploy_size() public {
        console2.log("Pricer deployed codesize (bytes):", address(p).code.length);
    }

    function test_price_5_cases() public {
        for (uint256 i = 0; i < 5; i++) {
            uint256 g = gasleft();
            uint256 premium = p.price(strikeBpsCases[i], spotE8Cases[i], ivE6Cases[i], secondsCases[i]);
            uint256 used = g - gasleft();
            console2.log("case", i + 1);
            console2.log("  premium (WAD):", premium);
            console2.log("  gas used:", used);
        }
    }

    function test_negative_strike_zero_reverts() public {
        vm.expectRevert();
        p.price(0, 22540000000, 253400, 216000);
    }

    function test_negative_spot_zero_reverts() public {
        vm.expectRevert();
        p.price(9700, 0, 253400, 216000);
    }
}

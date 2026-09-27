// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pricer} from "../src/Pricer.sol";

contract PricerTest is Test {
    Pricer pricer;

    function setUp() public {
        pricer = new Pricer();
    }

    function test_revertsOnEmptyExposure() public {
        int256[] memory exposure = new int256[](0);
        vm.expectRevert(Pricer.EmptyExposure.selector);
        pricer.quote(exposure, 20_000e6, 60_000e6);
    }

    function test_zeroExposureQuotesZero() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = 0;
        (uint256 premium, uint256 el, uint256 tvar95) = pricer.quote(exposure, 20_000e6, 60_000e6);
        assertEq(premium, 0);
        assertEq(el, 0);
        assertEq(tvar95, 0);
    }

    function test_tvarNeverBelowEl() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = -2_000_000e6;
        (, uint256 el, uint256 tvar95) = pricer.quote(exposure, 20_000e6, 60_000e6);
        assertGe(tvar95, el);
    }

    function test_payoutClampedByLimit() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = -2_000_000e6;
        // A limit of 1 wei means every scenario's payout clamps to at most 1, so el and tvar95
        // (means of clamped payouts) can never exceed 1.
        (, uint256 el, uint256 tvar95) = pricer.quote(exposure, 0, 1);
        assertLe(el, 1);
        assertLe(tvar95, 1);
    }

    function test_higherRetentionNeverIncreasesPremium() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = -2_000_000e6;
        (uint256 pLow,,) = pricer.quote(exposure, 10_000e6, 60_000e6);
        (uint256 pHigh,,) = pricer.quote(exposure, 50_000e6, 60_000e6);
        assertLe(pHigh, pLow);
    }

    function test_longAndShortExposureBothPriceRisk() public view {
        int256[] memory long_ = new int256[](1);
        long_[0] = 2_000_000e6;
        int256[] memory short_ = new int256[](1);
        short_[0] = -2_000_000e6;
        (uint256 pLong,,) = pricer.quote(long_, 20_000e6, 60_000e6);
        (uint256 pShort,,) = pricer.quote(short_, 20_000e6, 60_000e6);
        // Both directions face real historical gaps in the 504-scenario table, so both must
        // price some non-zero premium; a pricer that only saw one sign would zero the other.
        assertGt(pLong, 0);
        assertGt(pShort, 0);
    }
}

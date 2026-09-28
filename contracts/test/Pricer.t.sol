// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pricer} from "../src/Pricer.sol";

contract PricerTest is Test {
    Pricer pricer;

    function setUp() public {
        pricer = new Pricer();
    }

    // Neutral (1.0x) volScalePpm vector, matching Pricer.PPM (internal, not visible here).
    function _neutral(uint256 n) internal pure returns (uint256[] memory scale) {
        scale = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            scale[i] = 1_000_000;
        }
    }

    function test_revertsOnEmptyExposure() public {
        int256[] memory exposure = new int256[](0);
        uint256[] memory scale = new uint256[](0);
        vm.expectRevert(Pricer.EmptyExposure.selector);
        pricer.priceCore(exposure, scale, 20_000e6, 60_000e6);
    }

    function test_zeroExposureQuotesZero() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = 0;
        (uint256 premium, uint256 el, uint256 tvar95) = pricer.priceCore(exposure, _neutral(1), 20_000e6, 60_000e6);
        assertEq(premium, 0);
        assertEq(el, 0);
        assertEq(tvar95, 0);
    }

    function test_tvarNeverBelowEl() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = -2_000_000e6;
        (, uint256 el, uint256 tvar95) = pricer.priceCore(exposure, _neutral(1), 20_000e6, 60_000e6);
        assertGe(tvar95, el);
    }

    function test_payoutClampedByLimit() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = -2_000_000e6;
        // A limit of 1 wei means every scenario's payout clamps to at most 1, so el and tvar95
        // (means of clamped payouts) can never exceed 1.
        (, uint256 el, uint256 tvar95) = pricer.priceCore(exposure, _neutral(1), 0, 1);
        assertLe(el, 1);
        assertLe(tvar95, 1);
    }

    function test_higherRetentionNeverIncreasesPremium() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = -2_000_000e6;
        (uint256 pLow,,) = pricer.priceCore(exposure, _neutral(1), 10_000e6, 60_000e6);
        (uint256 pHigh,,) = pricer.priceCore(exposure, _neutral(1), 50_000e6, 60_000e6);
        assertLe(pHigh, pLow);
    }

    function test_longAndShortExposureBothPriceRisk() public view {
        int256[] memory long_ = new int256[](1);
        long_[0] = 2_000_000e6;
        int256[] memory short_ = new int256[](1);
        short_[0] = -2_000_000e6;
        (uint256 pLong,,) = pricer.priceCore(long_, _neutral(1), 20_000e6, 60_000e6);
        (uint256 pShort,,) = pricer.priceCore(short_, _neutral(1), 20_000e6, 60_000e6);
        // Both directions face real historical gaps in the 504-scenario table, so both must
        // price some non-zero premium; a pricer that only saw one sign would zero the other.
        assertGt(pLong, 0);
        assertGt(pShort, 0);
    }

    function test_badFeedsLengthReverts() public {
        int256[] memory exposure = new int256[](1);
        exposure[0] = -2_000_000e6;
        uint256[] memory scale = new uint256[](2);
        vm.expectRevert(Pricer.BadFeeds.selector);
        pricer.priceCore(exposure, scale, 20_000e6, 60_000e6);
    }

    function test_perMarketTableSelectionDiffers() public view {
        // index 2 = SPY (calmer historical table), index 0 = NVDA (fallback for >=4 too).
        int256[] memory expNvda = new int256[](1);
        expNvda[0] = -2_000_000e6;
        int256[] memory expSpy = new int256[](2);
        expSpy[0] = 0;
        expSpy[1] = -2_000_000e6;
        (uint256 pNvda,,) = pricer.priceCore(expNvda, _neutral(1), 20_000e6, 60_000e6);
        (uint256 pSpy,,) = pricer.priceCore(expSpy, _neutral(2), 20_000e6, 60_000e6);
        assertTrue(pNvda != pSpy);
    }

    function test_volScaleUpIncreasesPremium() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = -2_000_000e6;
        uint256[] memory neutralScale = _neutral(1);
        uint256[] memory highScale = new uint256[](1);
        highScale[0] = 3_000_000; // 3.0x, matches Pricer.MAX_SCALE_PPM
        (uint256 pNeutral,,) = pricer.priceCore(exposure, neutralScale, 20_000e6, 60_000e6);
        (uint256 pHigh,,) = pricer.priceCore(exposure, highScale, 20_000e6, 60_000e6);
        assertGt(pHigh, pNeutral);
    }
}

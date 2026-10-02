// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pricer} from "../src/Pricer.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";

contract PricerTest is Test {
    Pricer pricer;

    function setUp() public {
        pricer = new Pricer(oneTableId());
    }

    // Neutral (1.0x) volScalePpm vector, matching Pricer.PPM (internal, not visible here).
    function _neutral(uint256 n) internal pure returns (uint256[] memory scale) {
        scale = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            scale[i] = 1_000_000;
        }
    }

    function _ids1(uint8 id) internal pure returns (uint8[] memory ids) {
        ids = new uint8[](1);
        ids[0] = id;
    }

    function _ids3(uint8 a, uint8 b, uint8 c) internal pure returns (uint8[] memory ids) {
        ids = new uint8[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;
    }

    function test_revertsOnEmptyExposure() public {
        int256[] memory exposure = new int256[](0);
        uint256[] memory scale = new uint256[](0);
        vm.expectRevert(Pricer.EmptyExposure.selector);
        pricer.priceCore(exposure, scale, 20_000e6, 60_000e6);
    }

    /// Under the new formula (docs/security/capacity-review.md "Pricing (item 2)") a zero-exposure
    /// layer still charges the capital charge term (CAPITAL_CHARGE_ANNUAL_PPM * limit * LOCK_DAYS /
    /// DAYS_PER_YEAR = 40_000 * 60_000e6 * 7 / (365 * 1e6) = 46_027_397), since collateral is
    /// locked regardless of whether any scenario pays out. el and tvar95 stay zero.
    function test_zeroExposureQuotesCapitalChargeOnly() public view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = 0;
        (uint256 premium, uint256 el, uint256 tvar95) = pricer.priceCore(exposure, _neutral(1), 20_000e6, 60_000e6);
        assertEq(el, 0);
        assertEq(tvar95, 0);
        assertEq(premium, 46_027_397);
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

    /// P2 (docs/security/capacity-review.md): table selection is by explicit `marketTableIds`, not
    /// exposure array position. Two separately constructed pricers, same single-market exposure at
    /// index 0, one explicitly wired to NVDA (id 0) and one explicitly wired to SPY.
    function test_perMarketTableSelectionDiffers() public {
        Pricer spyPricer = new Pricer(_ids1(2));
        int256[] memory exposure = new int256[](1);
        exposure[0] = -2_000_000e6;
        (uint256 pNvda,,) = pricer.priceCore(exposure, _neutral(1), 20_000e6, 60_000e6);
        (uint256 pSpy,,) = spyPricer.priceCore(exposure, _neutral(1), 20_000e6, 60_000e6);
        assertTrue(pNvda != pSpy);
    }

    /// Ports the reviewer's RR3 (docs/security/capacity-review.md P2, test
    /// test_RR3_singleSpyFeedMustPriceOnSpyTable): the testnet deploy has one feed, SPY, at index
    /// 0. Before the fix this priced on the NVDA table (position-based selection); after the fix,
    /// the deployed pricer is constructed with an explicit tableIds=[2] and prices identically to
    /// the same SPY exposure placed at index 2 of a 3-market layer with explicit tableIds=[0,1,2].
    function test_RR3_singleSpyFeedMustPriceOnSpyTable() public {
        Pricer asDeployed = new Pricer(_ids1(2));
        int256[] memory e1 = new int256[](1);
        e1[0] = 2_000_000e6;
        uint256[] memory s1 = new uint256[](1);
        s1[0] = 1e6;
        (uint256 spyAtIndex0,,) = asDeployed.priceCore(e1, s1, 20_000e6, 60_000e6);

        Pricer threeMarket = new Pricer(_ids3(0, 1, 2));
        int256[] memory e3 = new int256[](3);
        e3[2] = 2_000_000e6;
        uint256[] memory s3 = new uint256[](3);
        s3[0] = 1e6;
        s3[1] = 1e6;
        s3[2] = 1e6;
        (uint256 spyAtIndex2,,) = threeMarket.priceCore(e3, s3, 20_000e6, 60_000e6);

        assertEq(spyAtIndex0, spyAtIndex2, "single SPY feed does not price on the SPY table");
    }

    /// Ports the reviewer's RR4 (docs/security/capacity-review.md P4, test
    /// test_RR4_volScaleTimingOption; real SPY/USD Arbitrum Sepolia rounds, phase 1, agg rounds
    /// 2346..2361, read 2026-09-28). Before the fix (MIN_SCALE_PPM = 500_000) the same weekend risk
    /// quoted a >10% swing depending on the round the buyer happened to bind against (a calendar/
    /// heartbeat artefact, not real volatility). After the fix (MIN_SCALE_PPM = 1_000_000, floor
    /// 1.0x) the scale can only raise the price, never cut it, so both moments stay within 10%.
    function test_RR4_volScaleTimingOption() public {
        int64[16] memory a = [
            int64(75766750000),
            76294499999,
            76113000000,
            76169000000,
            76169000000,
            76651999999,
            77048000000,
            77439500000,
            77414500000,
            77328000000,
            76930500000,
            76395000000,
            76814000000,
            77101500000,
            77134250000,
            77134250000
        ];
        MockFeed cheap = new MockFeed();
        MockFeed dear = new MockFeed();
        for (uint80 i; i < 10; i++) cheap.set(2346 + i, a[i], 1); // latest = 2355 (Wed 10:57)
        for (uint80 i; i < 13; i++) dear.set(2346 + i, a[i], 1); // latest = 2358 (Thu 16:18)
        int256[] memory e = new int256[](1);
        e[0] = 2_000_000e6;
        address[] memory f = new address[](1);
        f[0] = address(cheap);
        (uint256 pCheap,,) = pricer.quote(e, f, 20_000e6, 60_000e6);
        f[0] = address(dear);
        (uint256 pDear,,) = pricer.quote(e, f, 20_000e6, 60_000e6);
        assertApproxEqRel(pCheap, pDear, 0.10e18, "same weekend risk, >10% price swing by bind timing");
    }

    /// P4 direct unit check: MIN_SCALE_PPM floors at 1.0x (PPM), so a feed history that would have
    /// scaled the table down under the old 0.5x floor now leaves the table unscaled instead.
    function test_minScaleFloorsAtOneX() public {
        MockFeed quiet = new MockFeed();
        // 8 rounds each moving ~5bps (well below NORMAL_ROUND_MOVE_BPS=50), which pre-fix would
        // have scaled down toward MIN_SCALE_PPM=500_000 (0.5x).
        int256 px = 100e8;
        for (uint80 i; i < 9; i++) {
            quiet.set(i, px, 1);
            px += px / 20000; // ~5bps per round
        }
        int256[] memory e = new int256[](1);
        e[0] = -2_000_000e6;
        address[] memory f = new address[](1);
        f[0] = address(quiet);
        (uint256 pQuiet,,) = pricer.quote(e, f, 20_000e6, 60_000e6);
        (uint256 pNeutral,,) = pricer.priceCore(e, _neutral(1), 20_000e6, 60_000e6);
        assertGe(pQuiet, pNeutral, "MIN_SCALE_PPM floor must never price below the neutral 1.0x table");
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

    /// P2 re-review (docs/security/capacity-review.md "Re-review (2026-09-28)"): an empty
    /// `tableIds` array must revert the constructor, not silently reproduce the old positional
    /// default mapping.
    function test_constructorRevertsOnEmptyTableIds() public {
        vm.expectRevert(Pricer.BadTableId.selector);
        new Pricer(new uint8[](0));
    }

    /// P2 re-review: any configured table id above 5 must revert the constructor, not silently
    /// fall back to pricing that market on NVDA.
    function test_constructorRevertsOnBadTableId() public {
        vm.expectRevert(Pricer.BadTableId.selector);
        new Pricer(_ids1(6));
    }

    /// P2 re-review: `tableIdAt` must revert past the configured array, not fall back to the old
    /// position-only default (0 NVDA, 1 AAPL, 2 SPY, 3 TSLA, else NVDA). pricer (setUp) is
    /// constructed with a single-entry tableIds array, so index 0 is in range and index 1 is not.
    function test_tableIdAtRevertsOutOfRange() public {
        assertEq(pricer.tableIdAt(0), 0);
        vm.expectRevert(Pricer.MissingTable.selector);
        pricer.tableIdAt(1);
    }

    /// P2 re-review: a quote spanning more markets than the deploy configured must revert
    /// (`MissingTable`, via `tableIdAt`), not silently price the uncovered market on NVDA by
    /// falling back to its array position.
    function test_priceCoreRevertsWhenMarketsExceedConfiguredTableIds() public {
        // pricer (setUp) is constructed with a single-entry tableIds array, covering market 0
        // only.
        int256[] memory exposure = new int256[](2);
        exposure[0] = 2_000_000e6;
        exposure[1] = 1_000_000e6;
        vm.expectRevert(Pricer.MissingTable.selector);
        pricer.priceCore(exposure, _neutral(2), 20_000e6, 60_000e6);
    }
}

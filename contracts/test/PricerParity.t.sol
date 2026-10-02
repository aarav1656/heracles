// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pricer} from "../src/Pricer.sol";
import {oneTableId} from "./utils/TableIdsFixture.sol";

/// Bit-for-bit parity between Solidity's Pricer.priceCore and Rust's pricer_core::price_core,
/// the feed-independent core both IPricer implementations share (docs/pricing.md). Uses
/// Foundry's vm.ffi to run the native `pricer_cli` binary (pricer/pricer_cli, a thin CLI over
/// pricer/core/src/lib.rs) and asserts its output exactly equals Solidity's priceCore() for the
/// same fuzzed inputs. Requires `ffi = true` in foundry.toml; local/CI only, no deploy involved.
contract PricerParityTest is Test {
    Pricer pricer;
    Pricer spyPricer;
    Pricer eurPricer;
    Pricer xauPricer;
    Pricer tslaPricer;
    string constant CLI_BIN = "../pricer/pricer_cli/target/release/pricer-cli";

    function setUp() public {
        pricer = new Pricer(oneTableId());
        uint8[] memory spyIds = new uint8[](1);
        spyIds[0] = 2;
        spyPricer = new Pricer(spyIds);
        uint8[] memory eurIds = new uint8[](1);
        eurIds[0] = 4;
        eurPricer = new Pricer(eurIds);
        uint8[] memory xauIds = new uint8[](1);
        xauIds[0] = 5;
        xauPricer = new Pricer(xauIds);
        uint8[] memory tslaIds = new uint8[](1);
        tslaIds[0] = 3;
        tslaPricer = new Pricer(tslaIds);
        string[] memory build = new string[](5);
        build[0] = "cargo";
        build[1] = "build";
        build[2] = "--release";
        build[3] = "--manifest-path";
        build[4] = "../pricer/pricer_cli/Cargo.toml";
        vm.ffi(build);
    }

    function _boundMag(int256 e, int256 maxAbs) internal pure returns (int256) {
        if (e > maxAbs) return maxAbs;
        if (e < -maxAbs) return -maxAbs;
        return e;
    }

    function _runCli(int256 exposure, uint256 volScalePpm, uint256 retention, uint256 limit, string memory tableIdsCsv)
        internal
        returns (uint256 premium, uint256 el, uint256 tvar95)
    {
        string[] memory argv = new string[](6);
        argv[0] = CLI_BIN;
        argv[1] = vm.toString(retention);
        argv[2] = vm.toString(limit);
        argv[3] = vm.toString(exposure);
        argv[4] = vm.toString(volScalePpm);
        argv[5] = tableIdsCsv;
        bytes memory out = vm.ffi(argv);
        (premium, el, tvar95) = abi.decode(out, (uint256, uint256, uint256));
    }

    /// Fixed cases matching the pre-rewrite manual parity table, single market (index 0, table
    /// id 0 NVDA), neutral (1.0x) volatility scale.
    function test_fixedCasesMatchRustExactly() public {
        int256[5] memory exposures =
            [int256(-2_000_000_000_000), int256(2_000_000_000_000), int256(-500_000_000_000), int256(5_000_000_000_000), int256(-100_000_000_000)];
        uint256[5] memory retentions = [uint256(20_000_000_000), 10_000_000_000, 0, 50_000_000_000, 20_000_000_000];
        uint256[5] memory limits = [uint256(60_000_000_000), 60_000_000_000, 5_000_000_000, 100_000_000_000, 1_000_000];

        for (uint256 i = 0; i < 5; i++) {
            int256[] memory exposure = new int256[](1);
            exposure[0] = exposures[i];
            uint256[] memory scale = new uint256[](1);
            scale[0] = 1_000_000;
            (uint256 solPremium, uint256 solEl, uint256 solTvar) =
                pricer.priceCore(exposure, scale, retentions[i], limits[i]);
            (uint256 rsPremium, uint256 rsEl, uint256 rsTvar) =
                _runCli(exposures[i], 1_000_000, retentions[i], limits[i], "0");
            assertEq(solPremium, rsPremium, "premium mismatch");
            assertEq(solEl, rsEl, "el mismatch");
            assertEq(solTvar, rsTvar, "tvar95 mismatch");
        }
    }

    /// P2 table-id parity: an explicit SPY table id (tableIds=[2]) must give bit-identical
    /// Solidity/Rust quotes too, not just the explicit NVDA (tableIds=[0]) path above.
    function test_explicitSpyTableIdMatchesRustExactly() public {
        int256[] memory exposure = new int256[](1);
        exposure[0] = 2_000_000_000_000;
        uint256[] memory scale = new uint256[](1);
        scale[0] = 1_000_000;
        (uint256 solPremium, uint256 solEl, uint256 solTvar) = spyPricer.priceCore(exposure, scale, 20_000_000_000, 60_000_000_000);
        (uint256 rsPremium, uint256 rsEl, uint256 rsTvar) = _runCli(2_000_000_000_000, 1_000_000, 20_000_000_000, 60_000_000_000, "2");
        assertEq(solPremium, rsPremium, "premium mismatch");
        assertEq(solEl, rsEl, "el mismatch");
        assertEq(solTvar, rsTvar, "tvar95 mismatch");
    }

    /// Reviewer acceptance numbers (docs/security/capacity-review.md "Pricing (item 2)", README
    /// example: long $2M, retention $20k, limit $60k, 1.0x scale), Solidity and Rust must agree
    /// bit-for-bit even though neither is tuned to match the reviewer's independently cent-rounded
    /// figures (NVDA 6,576.75, SPY 1,676.72; our exact integers are 6,576.744381 and 1,676.722158,
    /// see docs/pricing.md for the rounding-accumulation explanation on the NVDA side).
    function test_acceptanceNumbersMatchRustExactly() public {
        int256[] memory exposure = new int256[](1);
        exposure[0] = 2_000_000_000_000;
        uint256[] memory scale = new uint256[](1);
        scale[0] = 1_000_000;

        (uint256 nvdaPremium, uint256 nvdaEl, uint256 nvdaTvar) =
            pricer.priceCore(exposure, scale, 20_000_000_000, 60_000_000_000);
        (uint256 rsNvdaPremium, uint256 rsNvdaEl, uint256 rsNvdaTvar) =
            _runCli(2_000_000_000_000, 1_000_000, 20_000_000_000, 60_000_000_000, "0");
        assertEq(nvdaPremium, 6_576_744_381, "NVDA premium acceptance number");
        assertEq(nvdaEl, 5_040_079_365, "NVDA el acceptance number");
        assertEq(nvdaTvar, 54_728_000_000, "NVDA tvar95 acceptance number");
        assertEq(nvdaPremium, rsNvdaPremium, "NVDA Sol/Rust premium mismatch");
        assertEq(nvdaEl, rsNvdaEl, "NVDA Sol/Rust el mismatch");
        assertEq(nvdaTvar, rsNvdaTvar, "NVDA Sol/Rust tvar95 mismatch");

        (uint256 spyPremium, uint256 spyEl, uint256 spyTvar) =
            spyPricer.priceCore(exposure, scale, 20_000_000_000, 60_000_000_000);
        (uint256 rsSpyPremium, uint256 rsSpyEl, uint256 rsSpyTvar) =
            _runCli(2_000_000_000_000, 1_000_000, 20_000_000_000, 60_000_000_000, "2");
        assertEq(spyPremium, 1_676_722_158, "SPY premium acceptance number");
        assertEq(spyEl, 1_051_190_476, "SPY el acceptance number");
        assertEq(spyTvar, 20_368_000_000, "SPY tvar95 acceptance number");
        assertEq(spyPremium, rsSpyPremium, "SPY Sol/Rust premium mismatch");
        assertEq(spyEl, rsSpyEl, "SPY Sol/Rust el mismatch");
        assertEq(spyTvar, rsSpyTvar, "SPY Sol/Rust tvar95 mismatch");
    }

    /// FX and gold tables (ids 4 and 5, centi-bps): Solidity equals Rust exactly, and both equal the
    /// figures scripts/fx_gold_fair_premium.py computes from the .gaps.txt files with no shared code.
    function test_fxAndGoldTablesMatchRustAndPython() public {
        uint256[] memory scale = new uint256[](1);
        scale[0] = 1_000_000;
        int256[] memory exposure = new int256[](1);

        exposure[0] = 2_000_000_000_000;
        (uint256 p, uint256 el, uint256 tv) = eurPricer.priceCore(exposure, scale, 2_000_000_000, 20_000_000_000);
        (uint256 rp, uint256 rel, uint256 rtv) = _runCli(2_000_000_000_000, 1_000_000, 2_000_000_000, 20_000_000_000, "4");
        assertEq(p, 1_977_298_772, "EUR premium vs python");
        assertEq(el, 1_648_960_317, "EUR el vs python");
        assertEq(tv, 12_082_160_000, "EUR tvar95 vs python");
        assertEq(p, rp, "EUR premium Sol/Rust");
        assertEq(el, rel, "EUR el Sol/Rust");
        assertEq(tv, rtv, "EUR tvar95 Sol/Rust");

        exposure[0] = 1_000_000_000_000;
        (p, el, tv) = xauPricer.priceCore(exposure, scale, 5_000_000_000, 30_000_000_000);
        (rp, rel, rtv) = _runCli(1_000_000_000_000, 1_000_000, 5_000_000_000, 30_000_000_000, "5");
        assertEq(p, 1_635_305_987, "XAU premium vs python");
        assertEq(el, 1_173_676_587, "XAU el vs python");
        assertEq(tv, 15_794_200_000, "XAU tvar95 vs python");
        assertEq(p, rp, "XAU premium Sol/Rust");
        assertEq(el, rel, "XAU el Sol/Rust");
        assertEq(tv, rtv, "XAU tvar95 Sol/Rust");
    }

    /// An equity table (TSLA, id 3, whole bps) against the same Python pricer, which reads
    /// evidence/gap-tables/TSLA.gaps.txt directly: pins the equity unit next to the FX unit.
    function test_tslaTableMatchesRustAndPython() public {
        uint256[] memory scale = new uint256[](1);
        scale[0] = 1_000_000;
        int256[] memory exposure = new int256[](1);
        exposure[0] = 500_000_000_000;
        (uint256 p, uint256 el, uint256 tv) = tslaPricer.priceCore(exposure, scale, 5_000_000_000, 30_000_000_000);
        (uint256 rp, uint256 rel, uint256 rtv) = _runCli(500_000_000_000, 1_000_000, 5_000_000_000, 30_000_000_000, "3");
        assertEq(p, 2_398_667_943, "TSLA premium vs python");
        assertEq(el, 1_847_519_841, "TSLA el vs python");
        assertEq(tv, 19_452_000_000, "TSLA tvar95 vs python");
        assertEq(p, rp, "TSLA premium Sol/Rust");
        assertEq(el, rel, "TSLA el Sol/Rust");
        assertEq(tv, rtv, "TSLA tvar95 Sol/Rust");
    }

    /// Fuzzed parity on the FX table at scales other than 1.0x, where the unit division order matters.
    function testFuzz_fxPriceCoreMatchesRustExactly(int256 rawExposure, uint256 volScalePpm, uint256 retention, uint256 limit)
        public
    {
        int256 exposure = _boundMag(rawExposure, 5_000_000_000_000);
        volScalePpm = bound(volScalePpm, 1_000_000, 3_000_000);
        retention = bound(retention, 0, 1_000_000_000_000);
        limit = bound(limit, 0, 1_000_000_000_000);
        int256[] memory expArr = new int256[](1);
        expArr[0] = exposure;
        uint256[] memory scaleArr = new uint256[](1);
        scaleArr[0] = volScalePpm;
        (uint256 a, uint256 b, uint256 c) = xauPricer.priceCore(expArr, scaleArr, retention, limit);
        (uint256 ra, uint256 rb, uint256 rc) = _runCli(exposure, volScalePpm, retention, limit, "5");
        assertEq(a, ra, "premium mismatch");
        assertEq(b, rb, "el mismatch");
        assertEq(c, rc, "tvar95 mismatch");
    }

    /// Fuzzed single-market parity across exposure, retention, limit and volatility scale, bounded
    /// to realistic sizes (up to $5M exposure, matching the treaty's actual notional range) and to
    /// Pricer's documented volatility-scale clamp range [MIN_SCALE_PPM, MAX_SCALE_PPM].
    function testFuzz_priceCoreMatchesRustExactly(int256 rawExposure, uint256 volScalePpm, uint256 retention, uint256 limit)
        public
    {
        int256 exposure = _boundMag(rawExposure, 5_000_000_000_000);
        volScalePpm = bound(volScalePpm, 500_000, 3_000_000);
        retention = bound(retention, 0, 1_000_000_000_000);
        limit = bound(limit, 0, 1_000_000_000_000);

        int256[] memory expArr = new int256[](1);
        expArr[0] = exposure;
        uint256[] memory scaleArr = new uint256[](1);
        scaleArr[0] = volScalePpm;

        (uint256 solPremium, uint256 solEl, uint256 solTvar) = pricer.priceCore(expArr, scaleArr, retention, limit);
        (uint256 rsPremium, uint256 rsEl, uint256 rsTvar) = _runCli(exposure, volScalePpm, retention, limit, "0");

        assertEq(solPremium, rsPremium, "premium mismatch");
        assertEq(solEl, rsEl, "el mismatch");
        assertEq(solTvar, rsTvar, "tvar95 mismatch");
    }
}

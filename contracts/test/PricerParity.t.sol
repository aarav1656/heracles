// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Pricer} from "../src/Pricer.sol";

/// Bit-for-bit parity between Solidity's Pricer.priceCore and Rust's pricer_core::price_core,
/// the feed-independent core both IPricer implementations share (docs/pricing.md). Uses
/// Foundry's vm.ffi to run the native `pricer_cli` binary (pricer/pricer_cli, a thin CLI over
/// pricer/core/src/lib.rs) and asserts its output exactly equals Solidity's priceCore() for the
/// same fuzzed inputs. Requires `ffi = true` in foundry.toml; local/CI only, no deploy involved.
contract PricerParityTest is Test {
    Pricer pricer;
    string constant CLI_BIN = "../pricer/pricer_cli/target/release/pricer-cli";

    function setUp() public {
        pricer = new Pricer();
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

    function _runCli(int256 exposure, uint256 volScalePpm, uint256 retention, uint256 limit)
        internal
        returns (uint256 premium, uint256 el, uint256 tvar95)
    {
        string[] memory argv = new string[](5);
        argv[0] = CLI_BIN;
        argv[1] = vm.toString(retention);
        argv[2] = vm.toString(limit);
        argv[3] = vm.toString(exposure);
        argv[4] = vm.toString(volScalePpm);
        bytes memory out = vm.ffi(argv);
        (premium, el, tvar95) = abi.decode(out, (uint256, uint256, uint256));
    }

    /// Fixed cases matching the pre-rewrite manual parity table, single market (index 0, NVDA
    /// fallback table), neutral (1.0x) volatility scale.
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
                _runCli(exposures[i], 1_000_000, retentions[i], limits[i]);
            assertEq(solPremium, rsPremium, "premium mismatch");
            assertEq(solEl, rsEl, "el mismatch");
            assertEq(solTvar, rsTvar, "tvar95 mismatch");
        }
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
        (uint256 rsPremium, uint256 rsEl, uint256 rsTvar) = _runCli(exposure, volScalePpm, retention, limit);

        assertEq(solPremium, rsPremium, "premium mismatch");
        assertEq(solEl, rsEl, "el mismatch");
        assertEq(solTvar, rsTvar, "tvar95 mismatch");
    }
}

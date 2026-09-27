// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Pricer} from "../src/Pricer.sol";

/// Bit-for-bit parity check: the same 5 (exposure, retention, limit) cases run through the Rust
/// Stylus twin (pricer/src/lib.rs, `parity_test::test_quote_cases_print_for_solidity_parity`,
/// run via `cargo test parity -- --nocapture`) must produce identical (premium, el, tvar95), since
/// both read the same 504-scenario GAPS table and the same formula. Printed here for a manual
/// diff against that Rust output; both sides are logged, not asserted equal in-process, since Rust
/// and Solidity are separate toolchains with no shared test runner.
contract PricerParityTest is Test {
    Pricer pricer;

    function setUp() public {
        pricer = new Pricer();
    }

    function _case(uint256 n, int256 exp, uint256 ret, uint256 lim) internal view {
        int256[] memory exposure = new int256[](1);
        exposure[0] = exp;
        (uint256 premium, uint256 el, uint256 tvar95) = pricer.quote(exposure, ret, lim);
        console.log("case", n);
        console.log("premium", premium);
        console.log("el", el);
        console.log("tvar95", tvar95);
    }

    function test_quoteCasesPrintForRustParity() public view {
        _case(1, -2_000_000_000_000, 20_000_000_000, 60_000_000_000);
        _case(2, 2_000_000_000_000, 10_000_000_000, 60_000_000_000);
        _case(3, -500_000_000_000, 0, 5_000_000_000);
        _case(4, 5_000_000_000_000, 50_000_000_000, 100_000_000_000);
        _case(5, -100_000_000_000, 20_000_000_000, 1_000_000);
    }
}

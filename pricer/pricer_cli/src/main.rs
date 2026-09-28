//! Native CLI wrapping `pricer::price_core`, for Foundry's `vm.ffi` cross-language parity fuzz
//! test (contracts/test/PricerParity.t.sol) against Solidity's `Pricer.priceCore`. Stdlib-only
//! arg parsing (ponytail: this is 4 positional fields, not worth a CLI-parsing or serde
//! dependency).
//!
//! Usage: pricer_cli <retention> <limit> <exposure_csv> <vol_scale_ppm_csv>
//!   retention, limit: non-negative decimal u128
//!   exposure_csv: comma-separated signed i128 (e.g. "-2000000000000,500000000000")
//!   vol_scale_ppm_csv: comma-separated non-negative u128, same length as exposure_csv
//!
//! On success, prints one line to stdout: "0x" followed by the abi encoding (three concatenated
//! 32-byte big-endian words, since all three return values are static uint256) of
//! (premium, el, tvar95), matching what `abi.decode(bytes, (uint256,uint256,uint256))` expects
//! in Solidity. On any pricing error (EmptyExposure, BadFeeds, Overflow, ...) prints the error to
//! stderr and exits 1; the parity fuzz test is expected to only generate inputs that don't
//! trigger these, so a nonzero exit there is a genuine test failure, not an expected case.

use alloy_primitives::{I256, U256};
use pricer_core::price_core;

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

fn parse_i128_csv(s: &str) -> Vec<i128> {
    if s.is_empty() {
        return Vec::new();
    }
    s.split(',').map(|v| v.parse::<i128>().expect("bad i128 in exposure csv")).collect()
}

fn parse_u128_csv(s: &str) -> Vec<u128> {
    if s.is_empty() {
        return Vec::new();
    }
    s.split(',').map(|v| v.parse::<u128>().expect("bad u128 in vol_scale csv")).collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 {
        eprintln!("usage: pricer_cli <retention> <limit> <exposure_csv> <vol_scale_ppm_csv>");
        std::process::exit(2);
    }
    let retention = U256::from(args[1].parse::<u128>().expect("bad retention"));
    let limit = U256::from(args[2].parse::<u128>().expect("bad limit"));
    let exposure: Vec<I256> = parse_i128_csv(&args[3]).into_iter().map(|v| I256::try_from(v).unwrap()).collect();
    let vol_scale_ppm: Vec<U256> = parse_u128_csv(&args[4]).into_iter().map(U256::from).collect();

    match price_core(&exposure, &vol_scale_ppm, retention, limit) {
        Ok((premium, el, tvar95)) => {
            let mut out = [0u8; 96];
            out[0..32].copy_from_slice(&premium.to_be_bytes::<32>());
            out[32..64].copy_from_slice(&el.to_be_bytes::<32>());
            out[64..96].copy_from_slice(&tvar95.to_be_bytes::<32>());
            println!("0x{}", hex_encode(&out));
        }
        Err(e) => {
            eprintln!("price_core error: {}", String::from_utf8_lossy(&e));
            std::process::exit(1);
        }
    }
}

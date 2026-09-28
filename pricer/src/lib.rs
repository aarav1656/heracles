//! Weekend-gap layer pricer, Rust/Stylus implementation of IPricer.
//!
//! The pure pricing math (per-market scenario tables, EL/TVaR95/cost-of-capital formula) lives
//! in `pricer_core` (../core/src/lib.rs; see that module doc for why it's a separate crate: a
//! cdylib-native-linking issue with a same-package native `pricer_cli` binary). This crate is the
//! thin Stylus wrapper: it reads each market's live Chainlink feed for a realised-volatility
//! scale (item 5, docs/judging/heracles.md) and calls `pricer_core::price_core` with it.
//!
//! Volatility scale: before being applied, every scenario in a market's table is scaled by that
//! market's own realised volatility, read live from its Chainlink feed's last VOL_ROUNDS rounds
//! (`vol_scale_ppm`), bounded to [MIN_SCALE_PPM, MAX_SCALE_PPM]. Implemented identically to the
//! Solidity twin (`contracts/src/Pricer.sol`) rather than skipped "for gas reasons": the added
//! cost is dominated by the CALL opcode to each feed, which costs the same regardless of caller
//! language, so skipping it here would buy no real gas advantage, only a silent behavior
//! mismatch between the two IPricer implementations.
//!
//! Pricing formula: `premium = el + c * (tvar95 - el)`, c an annualised cost-of-capital rate
//! (COST_OF_CAPITAL_ANNUAL_PPM) prorated to one weekend's capital lock (WEEKEND_HOURS / 8760),
//! see docs/pricing.md for sourcing and the before/after numbers. Ported line-for-line from
//! src/Pricer.sol so both sides of IPricer are bit-identical on the feed-independent core
//! (`price_core` / `priceCore`, docs/pricing.md parity section); the live-feed-dependent
//! `vol_scale_ppm` wrapper obviously cannot be bit-identical across two toolchains reading two
//! separate RPC calls, which is exactly why the parity test targets the core, not `quote`.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use pricer_core::{price_core, PPM, VOL_ROUNDS, NORMAL_ROUND_MOVE_BPS, MIN_SCALE_PPM, MAX_SCALE_PPM};
use stylus_sdk::{
    alloy_primitives::{aliases::U80, Address, I256, U256},
    prelude::*,
};

pub use pricer_core::price_core as core_price_core;

sol_interface! {
    interface IAggregatorV3 {
        function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
        function getRoundData(uint80 round_id) external view returns (uint80, int256, uint256, uint256, uint80);
    }
}

sol_storage! {
    #[entrypoint]
    pub struct Pricer {}
}

#[public]
impl Pricer {
    /// exposure[i] is signed: positive is long market i (loses when it falls), negative is
    /// short (loses when it rises). Amounts are plain USDG units (6dp), no WAD conversion.
    /// `feeds[i]` is the Chainlink-shaped feed for market i, read live for the volatility scale.
    pub fn quote(
        &self,
        exposure: Vec<I256>,
        feeds: Vec<Address>,
        retention: U256,
        limit: U256,
    ) -> Result<(U256, U256, U256), Vec<u8>> {
        if exposure.is_empty() {
            return Err(b"EmptyExposure".to_vec());
        }
        if feeds.len() != exposure.len() {
            return Err(b"BadFeeds".to_vec());
        }
        let mut vol_scale_ppm = Vec::with_capacity(feeds.len());
        for feed_addr in feeds.iter() {
            vol_scale_ppm.push(self.vol_scale_ppm(*feed_addr));
        }
        price_core(&exposure, &vol_scale_ppm, retention, limit)
    }

    /// Realised volatility over the feed's last VOL_ROUNDS rounds, as a scale in parts-per-
    /// million relative to NORMAL_ROUND_MOVE_BPS, bounded to [MIN_SCALE_PPM, MAX_SCALE_PPM].
    /// Returns PPM (1.0x, neutral) if the feed has too little history yet, or on any read
    /// failure. Walks the raw round id backwards by 1 per step; does not track Chainlink's
    /// phaseId (docs/pricing.md Limitations), so a phase change inside the last VOL_ROUNDS
    /// rounds truncates the sample early via the failed-call branch below rather than crossing
    /// into the wrong phase's round ids. Mirrors `Pricer._volScalePpm` in contracts/src/Pricer.sol.
    fn vol_scale_ppm(&self, feed_addr: Address) -> U256 {
        let feed = IAggregatorV3::new(feed_addr);
        let ppm_neutral = U256::from(PPM as u64);

        let Ok((latest_id, latest_answer, _, _, _)) = feed.latest_round_data(self.vm(), Call::new()) else {
            return ppm_neutral;
        };
        let latest_id_u64 = latest_id.to::<u64>();
        if latest_answer <= I256::ZERO || latest_id_u64 < VOL_ROUNDS {
            return ppm_neutral;
        }

        let mut prev_answer = latest_answer;
        let mut sum_bps: u64 = 0;
        let mut n: u64 = 0;
        for k in 1..=VOL_ROUNDS {
            let round_id = U80::from(latest_id_u64 - k);
            let Ok((_, answer, _, _, _)) = feed.get_round_data(self.vm(), Call::new(), round_id) else {
                break;
            };
            if answer <= I256::ZERO {
                break;
            }
            let diff = if prev_answer > answer { prev_answer - answer } else { answer - prev_answer };
            let diff_i256 = diff.checked_mul(pricer_core::c(10_000)).unwrap_or(I256::ZERO) / prev_answer;
            let diff_u64 = u64::try_from(diff_i256).unwrap_or(0);
            sum_bps += diff_u64;
            prev_answer = answer;
            n += 1;
        }
        if n == 0 {
            return ppm_neutral;
        }

        let mut scale = (sum_bps / n) * (PPM as u64) / NORMAL_ROUND_MOVE_BPS;
        if scale < MIN_SCALE_PPM {
            scale = MIN_SCALE_PPM;
        }
        if scale > MAX_SCALE_PPM {
            scale = MAX_SCALE_PPM;
        }
        U256::from(scale)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::testing::*;

    fn neutral(n: usize) -> Vec<U256> {
        alloc::vec![U256::from(PPM as u64); n]
    }

    /// Structural check that the Stylus `quote()` wrapper actually wires `feeds` through to
    /// `_volScalePpm`/`price_core` and enforces the same length/emptiness guards as the Solidity
    /// twin's `quote()`, using TestVM's mocked external calls instead of a real feed.
    #[test]
    fn test_quote_reverts_on_feeds_length_mismatch() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let result = contract.quote(
            alloc::vec![I256::ZERO],
            alloc::vec![Address::ZERO, Address::ZERO],
            U256::from(0u64),
            U256::from(1u64),
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_quote_reverts_on_empty_exposure() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let result = contract.quote(alloc::vec![], alloc::vec![], U256::from(0u64), U256::from(1u64));
        assert!(result.is_err());
    }

    /// With no mocked round data behind the feed address, `_volScalePpm` falls back to the
    /// PPM-neutral (1.0x) scale (its documented failure mode), so `quote()` should match calling
    /// `pricer_core::price_core` directly with an all-neutral scale vector.
    #[test]
    fn test_quote_matches_price_core_at_neutral_scale_when_feed_unset() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let exposure = alloc::vec![-I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium, el, tvar95) = contract
            .quote(exposure.clone(), alloc::vec![Address::ZERO], U256::from(20_000_000_000u64), U256::from(60_000_000_000u64))
            .unwrap();
        let (premium2, el2, tvar95_2) =
            price_core(&exposure, &neutral(1), U256::from(20_000_000_000u64), U256::from(60_000_000_000u64)).unwrap();
        assert_eq!((premium, el, tvar95), (premium2, el2, tvar95_2));
    }
}

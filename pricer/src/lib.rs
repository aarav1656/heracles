//! Weekend-gap layer pricer, Rust/Stylus implementation of IPricer.
//! Scenario table: the same 504 historical NVDA Friday-close-to-Monday-open weekend gaps
//! (basis points) measured and deployed in spikes/stylus-pricer/rs/src/lib.rs
//! (spikes/stylus-pricer/FINDINGS.md, 2026-09-26), copied verbatim, not regenerated. Same
//! known simplification as src/Pricer.sol (the Solidity twin): one measured NVDA distribution
//! applied as a shared weekend shock to every bound market, disclosed in
//! this product's own blind-spot list.
//!
//! quote() computes, per scenario s: portfolioLoss(s) = sum_i max(0, -(exposure[i] * gaps[s]) /
//! 10000), payout(s) = min(limit, max(0, portfolioLoss(s) - retention)), then
//! el = mean(payout), tvar95 = mean of the worst 5% (25 of 504) of payout(s), and
//! premium = el * 1.25 + tvar95 * 0.5, all in USDG's native 6-decimal fixed point (no WAD).
//! Ported line-for-line from src/Pricer.sol so both sides of IPricer are bit-identical; this is
//! the contract `cargo stylus deploy` ships, measured ~4.06x cheaper total gas per call than the
//! Solidity twin on the same inputs (spikes/stylus-pricer/FINDINGS.md).
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use stylus_sdk::{
    alloy_primitives::{I256, U256},
    prelude::*,
};

const GAPS: [i32; 504] = [0,53,-2,68,33,294,14,78,-31,174,-215,-71,208,-219,39,-42,-20,-76,-33,-20,93,73,-150,42,67,-176,2,3,126,42,46,130,130,131,-46,-249,118,86,34,203,84,17,33,70,238,61,47,-122,113,279,-70,113,82,62,45,0,-71,0,30,16,120,30,86,-115,118,232,48,14,-24,-279,141,37,76,-86,68,-92,216,119,12,31,29,177,60,160,-29,54,-20,-67,-171,-119,121,-45,-43,23,-20,14,-67,44,-19,34,-37,-47,112,-125,-22,92,287,-25,-180,-161,337,561,-123,-82,-238,131,170,-142,-78,-1474,44,-120,-27,212,99,63,75,-92,206,-64,-16,18,-410,-315,-254,49,33,155,-5,57,508,-150,51,51,-17,-458,-136,286,195,-175,70,-166,0,61,144,-19,130,86,161,-1,-15,244,-13,-43,85,48,-37,-159,137,-59,-489,-31,36,-143,-812,253,-983,-1181,-2,104,464,-174,187,-67,-6,318,145,-48,-48,-131,42,16,110,71,37,111,120,248,158,27,-704,753,-217,129,133,165,66,-120,99,-7,-94,64,3,32,57,-149,107,122,51,49,100,69,-102,117,-9,7,52,-15,-77,-236,-53,77,-17,-60,147,16,-4,45,-109,174,122,95,-135,-126,103,39,-26,74,86,-4,92,-344,-168,-115,-123,-52,109,32,133,53,161,274,-265,17,-178,137,-244,-253,-447,150,22,-6,-257,-68,-52,-105,20,23,6,-391,-160,-4,-343,-111,-252,90,224,-574,374,109,-240,-197,343,-173,10,-783,-4,-201,-148,62,-13,-141,-20,171,-32,259,34,-40,51,-67,-170,-150,-117,21,1,-87,162,286,0,126,-204,-139,128,-181,165,0,-93,-43,22,-96,-72,-39,33,-55,59,-116,423,-106,111,72,60,51,36,180,95,1,96,-90,276,101,-59,126,-262,-5,122,-201,-88,-38,145,62,-3,3,5,-147,-3,104,28,-56,85,56,94,33,312,65,-92,112,225,-126,290,-37,79,103,250,-16,68,67,137,355,364,-43,84,-263,-6,132,102,205,56,-1418,150,-24,15,-281,199,-194,47,-255,6,124,9,103,134,71,-175,3,42,-244,-5,117,-159,285,-436,105,-1249,-443,19,174,158,-113,-248,88,185,-414,-726,287,-119,-139,456,-222,218,27,104,97,-94,41,27,20,30,83,-36,8,20,-240,32,-121,-78,125,-113,262,-5,200,276,370,-221,34,-127,13,167,162,-148,154,-89,-233,-27,-206,-62,-58,83,-123,-56,151,264,75,-138,-84,66,53,-54,202,56,217,248,182,69,-115,151,66,-152,-25,36,38,61,119,-323,30];

fn c(v: i128) -> I256 {
    I256::try_from(v).unwrap()
}

sol_storage! {
    #[entrypoint]
    pub struct Pricer {}
}

#[public]
impl Pricer {
    /// exposure[i] is signed: positive is long market i (loses when it falls), negative is
    /// short (loses when it rises). Amounts are plain USDG units (6dp), no WAD conversion.
    /// Reverts (as `Err(b"EmptyExposure")`) on an empty exposure array, matching
    /// `Pricer.EmptyExposure` in src/Pricer.sol.
    pub fn quote(
        &self,
        exposure: Vec<I256>,
        retention: U256,
        limit: U256,
    ) -> Result<(U256, U256, U256), Vec<u8>> {
        if exposure.is_empty() {
            return Err(b"EmptyExposure".to_vec());
        }
        let retention = I256::from_raw(retention);
        let limit = I256::from_raw(limit);
        let bps = c(10_000);
        let overflow = || b"Overflow".to_vec();

        let mut payout = [I256::ZERO; 504];
        let mut sum_payout = I256::ZERO;
        for (s, g) in GAPS.iter().enumerate() {
            let gap = c(*g as i128);
            let mut loss = I256::ZERO;
            for e in exposure.iter() {
                // L1 (SECURITY-REVIEW.md): checked_mul/checked_div/checked_sub instead of raw
                // operators, so a pathological exposure reverts here instead of silently
                // wrapping (the Solidity twin already reverts on this via its own overflow
                // checks; this brought the Stylus side in line, see test_overflow_reverts below).
                let pnl = e.checked_mul(gap).ok_or_else(overflow)?.checked_div(bps).ok_or_else(overflow)?;
                if pnl < I256::ZERO {
                    loss = loss.checked_sub(pnl).ok_or_else(overflow)?;
                }
            }
            let mut p = loss.checked_sub(retention).ok_or_else(overflow)?;
            if p < I256::ZERO {
                p = I256::ZERO;
            }
            if p > limit {
                p = limit;
            }
            payout[s] = p;
            sum_payout = sum_payout.checked_add(p).ok_or_else(overflow)?;
        }
        let el = sum_payout / c(504);

        // Worst-5% tail via partial selection (pull the TAIL largest payouts, not a full sort):
        // matches the Solidity side and the "504 layer evaluations and a TVaR partial sort per
        // quote" workload this product's own research describes.
        let mut used = [false; 504];
        let mut tail_sum = I256::ZERO;
        const TAIL: usize = 25; // ceil(504 * 0.05), the worst 5% of scenarios
        for _ in 0..TAIL {
            let mut best_idx: Option<usize> = None;
            let mut best_val = I256::ZERO;
            for s in 0..504 {
                if used[s] {
                    continue;
                }
                if best_idx.is_none() || payout[s] > best_val {
                    best_val = payout[s];
                    best_idx = Some(s);
                }
            }
            let idx = best_idx.unwrap();
            used[idx] = true;
            tail_sum = tail_sum.checked_add(best_val).ok_or_else(overflow)?;
        }
        let tvar95 = tail_sum / c(TAIL as i128);

        let premium = el
            .checked_mul(c(125))
            .ok_or_else(overflow)?
            .checked_add(tvar95.checked_mul(c(50)).ok_or_else(overflow)?)
            .ok_or_else(overflow)?
            / c(100);

        let premium = U256::try_from(premium).map_err(|_| b"NegativePremium".to_vec())?;
        let el = U256::try_from(el).map_err(|_| b"NegativeEl".to_vec())?;
        let tvar95 = U256::try_from(tvar95).map_err(|_| b"NegativeTvar".to_vec())?;
        Ok((premium, el, tvar95))
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::testing::*;

    #[test]
    fn test_zero_exposure_quotes_zero() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let (premium, el, tvar95) = contract
            .quote(alloc::vec![I256::ZERO], U256::from(20_000_000_000u64), U256::from(60_000_000_000u64))
            .unwrap();
        assert_eq!(premium, U256::ZERO);
        assert_eq!(el, U256::ZERO);
        assert_eq!(tvar95, U256::ZERO);
    }

    #[test]
    fn test_empty_exposure_reverts() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let result = contract.quote(alloc::vec![], U256::from(0u64), U256::from(1u64));
        assert!(result.is_err());
    }

    /// L1: an exposure large enough that exposure*gap overflows I256 must revert, not wrap.
    /// Before the checked-arithmetic fix this wrapped silently and returned a bogus quote (live
    /// cast call against the deployed Stylus pricer with exposure -(2^255/1000) returned premium
    /// 48670633 instead of reverting); the Solidity twin already reverted here.
    #[test]
    fn test_overflow_reverts() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let exposure = alloc::vec![I256::MIN];
        let result = contract.quote(exposure, U256::from(0u64), U256::from(40_000_000u64));
        assert!(result.is_err(), "overflowing exposure must revert, not wrap");
    }

    #[test]
    fn test_short_spy_prices_nonzero_premium() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let exposure = alloc::vec![-I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium, el, tvar95) = contract
            .quote(exposure, U256::from(20_000_000_000u64), U256::from(60_000_000_000u64))
            .unwrap();
        assert!(premium > U256::ZERO);
        assert!(tvar95 >= el);
    }
}

#[cfg(test)]
mod parity_test {
    use super::*;
    use stylus_sdk::testing::*;

    /// Same 5 cases as spikes/stylus-pricer for a Solidity/Rust gas comparison: prints
    /// (premium, el, tvar95) so they can be diffed against Pricer.t.sol's Solidity outputs.
    #[test]
    fn test_quote_cases_print_for_solidity_parity() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let cases: [(i128, u64, u64); 5] = [
            (-2_000_000_000_000, 20_000_000_000, 60_000_000_000),
            (2_000_000_000_000, 10_000_000_000, 60_000_000_000),
            (-500_000_000_000, 0, 5_000_000_000),
            (5_000_000_000_000, 50_000_000_000, 100_000_000_000),
            (-100_000_000_000, 20_000_000_000, 1_000_000),
        ];
        for (i, (exp, ret, lim)) in cases.iter().enumerate() {
            let exposure = alloc::vec![c(*exp)];
            let (premium, el, tvar95) = contract
                .quote(exposure, U256::from(*ret), U256::from(*lim))
                .unwrap();
            println!("case {} premium={} el={} tvar95={}", i + 1, premium, el, tvar95);
        }
    }
}

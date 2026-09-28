//! Pure, feed-independent pricing core for the weekend-gap layer pricer: the per-market
//! scenario tables and the EL/TVaR95/cost-of-capital premium formula, with zero dependency on
//! Stylus, a deployed contract, or any live feed. Depended on by two things:
//! - `pricer` (../Cargo.toml, `heracles-pricer`), the Stylus contract crate, which wraps
//!   `price_core` with a `quote()` entrypoint that reads live Chainlink feeds for the
//!   volatility scale and is what actually deploys.
//! - `pricer_cli` (../pricer_cli), a plain native binary that calls `price_core` directly, used
//!   by contracts/test/PricerParity.t.sol's `vm.ffi` fuzz test to prove Solidity's
//!   `Pricer.priceCore` and this `price_core` are bit-identical.
//!
//! Split out into its own crate (rather than living directly in ../src/lib.rs) specifically so
//! `pricer_cli` never depends on the `heracles-pricer` package: that package's
//! `[lib] crate-type = ["lib", "cdylib"]` makes rustc always attempt to link the cdylib artifact
//! whenever the package is compiled at all (even as an rlib-only dependency), and that link
//! always fails on a native target (the cdylib references WASM-hostio-only symbols like
//! `read_args`/`storage_flush_cache` that only exist when actually running under Stylus). A pure
//! crate with no cdylib target sidesteps that entirely; `cargo stylus check`/deploy still target
//! wasm32 explicitly and are unaffected either way.
//!
//! Per-market scenario tables (docs/judging/heracles.md item 5): four independently sourced
//! 504-scenario Friday-close-to-Monday-open weekend gap tables (basis points), one each for
//! NVDA, AAPL, SPY and TSLA, fetched from api.nasdaq.com's free historical-bars endpoint and
//! re-derivable with `scripts/generate_gap_tables.py` (evidence/gap-tables/{TICKER}.json holds
//! the full detail). `exposure[i]` at position 0 prices against the NVDA table, 1 AAPL, 2 SPY,
//! 3 TSLA; any further market (index >= 4) still shares the NVDA table (a disclosed
//! simplification, see docs/pricing.md Limitations).
//!
//! Pricing formula: `premium = el + c * (tvar95 - el)`, c an annualised cost-of-capital rate
//! (COST_OF_CAPITAL_ANNUAL_PPM) prorated to one weekend's capital lock (WEEKEND_HOURS / 8760),
//! see docs/pricing.md for sourcing and the before/after numbers.
use alloy_primitives::{I256, U256};

extern crate alloc;
use alloc::vec::Vec;

pub const NVDA_GAPS: [i32; 504] = [0,53,-2,68,33,294,14,78,-31,174,-215,-71,208,-219,39,-42,-20,-76,-33,-20,93,73,-150,42,67,-176,2,3,126,42,46,130,130,131,-46,-249,118,86,34,203,84,17,33,70,238,61,47,-122,113,279,-70,113,82,62,45,0,-71,0,30,16,120,30,86,-115,118,232,48,14,-24,-279,141,37,76,-86,68,-92,216,119,12,31,29,177,60,160,-29,54,-20,-67,-171,-119,121,-45,-43,23,-20,14,-67,44,-19,34,-37,-47,112,-125,-22,92,287,-25,-180,-161,337,561,-123,-82,-238,131,170,-142,-78,-1474,44,-120,-27,212,99,63,75,-92,206,-64,-16,18,-410,-315,-254,49,33,155,-5,57,508,-150,51,51,-17,-458,-136,286,195,-175,70,-166,0,61,144,-19,130,86,161,-1,-15,244,-13,-43,85,48,-37,-159,137,-59,-489,-31,36,-143,-812,253,-983,-1181,-2,104,464,-174,187,-67,-6,318,145,-48,-48,-131,42,16,110,71,37,111,120,248,158,27,-704,753,-217,129,133,165,66,-120,99,-7,-94,64,3,32,57,-149,107,122,51,49,100,69,-102,117,-9,7,52,-15,-77,-236,-53,77,-17,-60,147,16,-4,45,-109,174,122,95,-135,-126,103,39,-26,74,86,-4,92,-344,-168,-115,-123,-52,109,32,133,53,161,274,-265,17,-178,137,-244,-253,-447,150,22,-6,-257,-68,-52,-105,20,23,6,-391,-160,-4,-343,-111,-252,90,224,-574,374,109,-240,-197,343,-173,10,-783,-4,-201,-148,62,-13,-141,-20,171,-32,259,34,-40,51,-67,-170,-150,-117,21,1,-87,162,286,0,126,-204,-139,128,-181,165,0,-93,-43,22,-96,-72,-39,33,-55,59,-116,423,-106,111,72,60,51,36,180,95,1,96,-90,276,101,-59,126,-262,-5,122,-201,-88,-38,145,62,-3,3,5,-147,-3,104,28,-56,85,56,94,33,312,65,-92,112,225,-126,290,-37,79,103,250,-16,68,67,137,355,364,-43,84,-263,-6,132,102,205,56,-1418,150,-24,15,-281,199,-194,47,-255,6,124,9,103,134,71,-175,3,42,-244,-5,117,-159,285,-436,105,-1249,-443,19,174,158,-113,-248,88,185,-414,-726,287,-119,-139,456,-222,218,27,104,97,-94,41,27,20,30,83,-36,8,20,-240,32,-121,-78,125,-113,262,-5,200,276,370,-221,34,-127,13,167,162,-148,154,-89,-233,-27,-206,-62,-58,83,-123,-56,151,264,75,-138,-84,66,53,-54,202,56,217,248,182,69,-115,151,66,-152,-25,36,38,61,119,-323,30];
pub const AAPL_GAPS: [i32; 504] = [-30,84,-26,43,-6,114,-66,5,-32,9,-58,-15,0,-2,3,-59,0,-84,4,73,38,35,-30,-21,29,-89,3,18,86,101,5,-6,61,-12,-71,-217,98,61,60,-5,-15,21,27,43,117,0,18,-18,118,14,-125,9,33,58,41,52,-8,-67,8,5,84,-10,52,-241,55,-37,46,-65,-79,-87,134,-22,48,-57,17,-39,190,89,17,67,-12,73,22,91,-52,73,-18,-51,-82,-70,81,10,-40,48,0,8,24,46,34,-16,-76,-39,98,-93,-43,22,134,-153,-268,-182,113,329,-207,-2,-171,147,30,-95,-26,-125,53,38,-42,69,41,149,-17,24,89,-29,-15,5,-352,-480,-290,-3,30,87,8,-12,265,-167,39,52,35,-296,-68,200,159,-111,74,-47,56,95,-33,-55,47,34,59,-71,2,36,1,-26,67,39,-12,-122,42,-48,-259,-168,-183,-295,-504,326,-875,-1296,-51,121,393,-171,-41,3,-65,177,145,-6,-38,-164,46,-11,140,9,118,183,134,101,348,222,-580,243,-215,243,79,264,79,-90,23,152,-29,-14,33,5,16,-129,-217,50,288,136,-53,9,-143,205,-40,31,28,36,-36,-48,38,44,-61,-49,46,38,22,37,-12,23,8,76,-180,-20,34,4,-38,8,27,43,111,-155,-99,-62,-44,-96,-1,-54,9,25,70,163,151,93,-167,15,-179,-90,-147,-10,27,-75,-139,-109,12,-212,-29,-146,15,-81,-41,-60,-150,-106,15,-38,113,-311,141,73,-83,-93,38,-5,-92,62,-34,-107,-151,42,141,-92,-51,1,24,194,-6,-166,-92,-49,-75,-201,-3,38,45,-36,27,65,5,18,-67,-125,-4,-154,68,182,-47,5,-19,-38,-7,-1,-24,-63,34,-67,87,93,17,-28,8,-10,-74,63,77,12,8,10,33,83,-62,106,84,-34,1,-38,-117,-114,48,-15,-31,11,-3,-66,-133,-75,1,-279,50,-202,39,-21,124,-23,-29,-15,-195,129,171,-100,-32,-67,31,240,-56,130,-29,81,34,1,41,11,70,33,258,120,-46,-945,-8,-15,-4,-20,0,-268,-38,99,-101,51,-23,83,-86,-86,11,69,-3,-42,-6,11,-131,39,-140,-260,56,-255,85,-18,-25,-2,-148,-8,125,-41,-593,671,34,-110,627,-159,155,-28,23,43,31,46,-58,44,7,105,-62,5,-56,-124,-16,125,114,-35,-1,168,142,78,2,18,-132,-22,-30,-23,67,-30,-26,-14,-8,-110,139,21,-8,89,-41,-67,-69,79,241,51,-29,4,-183,-17,-46,0,24,-78,46,103,104,54,-7,46,22,-207,9,69,-3,-90,76,-25];
pub const SPY_GAPS: [i32; 504] = [-22,52,-1,48,18,139,28,31,-16,44,-5,9,14,68,-13,-33,-17,-35,-20,25,18,-4,-39,-3,0,-83,3,7,110,25,2,21,25,-15,-8,-12,39,32,45,-7,-4,-4,19,3,60,-3,25,-23,59,17,-12,10,10,10,14,-25,-6,-30,11,2,70,3,60,-17,37,-4,51,-9,-23,-73,89,-40,44,-50,12,-31,158,64,70,24,26,33,18,62,-68,34,9,-59,-47,-65,41,2,-8,3,1,11,18,47,-16,40,-2,-22,48,-27,-14,27,131,20,-21,-25,96,168,-8,-41,-69,73,12,-82,-62,-90,2,27,-32,57,42,29,9,-14,79,-16,3,3,-163,-197,-62,11,1,60,9,8,126,-49,16,15,-4,-155,-57,116,85,-64,37,-42,-24,19,-30,-12,49,44,56,-49,-8,33,9,-14,60,27,3,-60,21,-32,-175,50,-29,-32,-310,66,-745,-1045,-27,90,389,-141,76,-72,-72,236,220,-23,28,-203,-21,45,80,-9,23,55,15,33,78,-7,-171,103,-150,137,66,79,39,-106,112,394,80,55,-23,-22,64,-114,-89,70,21,99,40,34,-76,138,27,7,14,-40,-16,-24,17,51,9,-29,58,60,0,3,45,13,1,-2,-119,-14,42,-1,-31,41,16,-8,72,-148,-25,-29,-16,-43,26,23,25,29,43,111,60,-12,-117,28,-73,-107,-136,-16,18,-12,-54,-131,-14,20,-4,-14,5,-77,-56,2,-152,-43,82,-41,103,-255,165,25,-141,-73,84,17,-69,43,-55,-121,-77,23,54,-86,-42,109,32,178,43,-66,36,-46,-35,-81,-73,21,5,-3,51,59,-1,21,-71,-62,17,-103,88,21,-106,21,60,-13,-2,-5,-11,8,15,0,48,8,24,-46,-14,-8,-8,-3,26,11,43,-21,24,52,-10,61,-7,-29,-20,-46,54,-38,70,18,-31,-6,-14,-76,-11,35,9,-66,11,-30,33,7,-13,-1,-36,9,-16,-24,82,-27,14,84,54,36,48,33,2,16,31,-16,-13,-3,26,14,36,73,29,-399,23,8,19,-57,79,-5,19,-18,-29,28,-13,61,2,27,8,67,7,-2,30,-4,-120,73,-81,52,-216,-152,54,19,35,34,-145,0,121,-105,-318,189,14,-74,304,-103,120,-28,10,57,13,40,-7,19,6,64,4,-9,-20,-117,21,34,-23,38,36,117,44,81,53,93,-33,56,-67,13,58,49,-40,49,-49,-147,18,-35,-17,-24,-23,-106,-89,92,146,95,-30,0,-11,-8,-16,9,59,-15,79,136,103,-33,51,81,32,-9,-2,-12,-26,-15,-69,60];
pub const TSLA_GAPS: [i32; 504] = [405,241,27,46,126,159,-30,1,-59,57,32,0,72,55,-2,-44,46,-17,-13,56,118,-344,-145,46,-34,-97,309,219,118,26,83,-198,63,26,-40,19,97,84,239,-10,-68,56,13,12,189,-47,-22,-45,232,12,59,42,-203,-51,138,-53,30,-94,-40,-73,-1,-16,42,-42,21,-18,39,-18,-88,-168,184,-30,41,-81,44,-151,192,36,-45,36,-16,116,75,163,-12,86,153,-77,-105,499,100,-225,-374,-43,-78,159,-452,-149,-156,381,-175,-21,1549,98,11,26,199,-171,-61,57,-25,272,57,-101,-196,117,127,-141,85,-139,25,190,-43,109,113,-22,21,-182,99,99,35,31,-196,-314,-390,30,19,281,26,62,302,-80,119,22,-42,-202,-86,194,104,-68,112,33,-26,36,-70,0,54,-18,48,202,21,339,-16,21,116,153,-37,-57,321,387,-404,355,694,520,-688,648,-1394,-1411,142,-80,650,-281,172,-5,-353,358,216,275,376,-187,-9,97,740,121,127,129,-32,159,372,44,-1490,221,248,424,199,184,149,-214,154,222,11,284,281,98,148,-414,-348,141,99,262,205,23,-239,216,43,5,454,-50,128,-273,159,-79,-111,-241,12,41,-121,38,19,-3,41,80,-222,118,186,158,-169,76,39,88,54,-328,-16,275,27,104,449,278,-592,-153,222,176,-133,-157,-235,861,-263,-219,-415,311,5,18,-267,63,215,-185,106,539,44,-440,-259,-115,-337,-32,-134,187,419,-390,362,149,-188,53,203,-1,139,237,59,-160,-183,91,35,-107,-127,-405,39,246,-402,-102,57,-163,-241,-159,-278,-165,251,-459,-382,522,269,184,8,159,-126,-159,262,38,-345,-114,210,-364,71,-26,-69,215,-19,31,359,179,145,37,-255,562,74,186,-160,39,-95,-286,281,167,0,635,-118,-61,-216,-200,-43,-94,96,183,44,-11,61,-129,-45,11,77,64,-57,-173,3,130,-194,-75,-191,17,-193,6,394,-121,269,-47,-441,1196,144,91,6,-158,3,-80,-5,107,159,-151,312,209,232,-1081,-49,44,-71,54,260,-43,183,-55,-43,107,-82,30,-178,781,624,215,209,216,111,236,-284,311,-292,144,-290,-443,-150,-23,10,251,-386,-197,377,-540,-654,240,141,-92,796,-391,236,-85,-311,184,167,-115,135,144,76,213,162,-28,-33,-169,108,687,118,90,254,243,104,144,-12,235,-139,283,-113,-166,228,180,-130,226,-85,-186,-90,-212,-29,-122,-110,-296,-168,128,139,111,32,49,-112,-15,-145,-70,100,-190,136,146,55,-77,137,7,-8,-60,-46,-40,-44,85,-155,202];

pub const SCENARIOS: usize = 504;
pub const TAIL: usize = 25; // ceil(504 * 0.05), the worst 5% of scenarios
pub const PPM: i128 = 1_000_000;

/// See contracts/src/Pricer.sol's doc comment for the full sourcing of this rate (Solvency II
/// 6% CoC, cross-checked against Sherlock/Nexus DeFi cover yields); docs/pricing.md restates it.
pub const COST_OF_CAPITAL_ANNUAL_PPM: i128 = 60_000; // 6.00%
pub const WEEKEND_HOURS: i128 = 66; // Friday 19:30 UTC cutoff to Monday 13:30 UTC expiry
pub const HOURS_PER_YEAR: i128 = 8_760;

pub const VOL_ROUNDS: u64 = 8;
pub const NORMAL_ROUND_MOVE_BPS: u64 = 50;
pub const MIN_SCALE_PPM: u64 = 500_000;
pub const MAX_SCALE_PPM: u64 = 3_000_000;

pub fn table_for(i: usize) -> &'static [i32; 504] {
    match i {
        1 => &AAPL_GAPS,
        2 => &SPY_GAPS,
        3 => &TSLA_GAPS,
        _ => &NVDA_GAPS,
    }
}

pub fn c(v: i128) -> I256 {
    I256::try_from(v).unwrap()
}

/// Deterministic pricing core: given exposure and an already-known per-market volatility scale
/// (parts-per-million, 1_000_000 = 1.0x = the stored historical table unscaled), no feed reads
/// happen here at all.
pub fn price_core(
    exposure: &[I256],
    vol_scale_ppm: &[U256],
    retention: U256,
    limit: U256,
) -> Result<(U256, U256, U256), Vec<u8>> {
    if exposure.is_empty() {
        return Err(b"EmptyExposure".to_vec());
    }
    if vol_scale_ppm.len() != exposure.len() {
        return Err(b"BadFeeds".to_vec());
    }
    let retention = I256::from_raw(retention);
    let limit = I256::from_raw(limit);
    let bps = c(10_000);
    let ppm = c(PPM);
    let overflow = || b"Overflow".to_vec();

    let mut payout = [I256::ZERO; SCENARIOS];
    let mut sum_payout = I256::ZERO;
    for s in 0..SCENARIOS {
        let mut loss = I256::ZERO;
        for (i, e) in exposure.iter().enumerate() {
            let raw_gap = c(table_for(i)[s] as i128);
            let scale = I256::from_raw(vol_scale_ppm[i]);
            // L1-style checked arithmetic throughout (SECURITY-REVIEW.md): a pathological
            // exposure or scale reverts here instead of silently wrapping.
            let gap = raw_gap.checked_mul(scale).ok_or_else(overflow)?.checked_div(ppm).ok_or_else(overflow)?;
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
    let el = sum_payout / c(SCENARIOS as i128);

    // Worst-5% tail via partial selection (pull the TAIL largest payouts, not a full sort):
    // matches the Solidity side.
    let mut used = [false; SCENARIOS];
    let mut tail_sum = I256::ZERO;
    for _ in 0..TAIL {
        let mut best_idx: Option<usize> = None;
        let mut best_val = I256::ZERO;
        for s in 0..SCENARIOS {
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

    // premium = el + c * (tvar95 - el); full multiplication before the single final division.
    let load = tvar95
        .checked_sub(el)
        .ok_or_else(overflow)?
        .checked_mul(c(COST_OF_CAPITAL_ANNUAL_PPM))
        .ok_or_else(overflow)?
        .checked_mul(c(WEEKEND_HOURS))
        .ok_or_else(overflow)?
        .checked_div(c(HOURS_PER_YEAR * PPM))
        .ok_or_else(overflow)?;
    let premium = el.checked_add(load).ok_or_else(overflow)?;

    let premium = U256::try_from(premium).map_err(|_| b"NegativePremium".to_vec())?;
    let el = U256::try_from(el).map_err(|_| b"NegativeEl".to_vec())?;
    let tvar95 = U256::try_from(tvar95).map_err(|_| b"NegativeTvar".to_vec())?;
    Ok((premium, el, tvar95))
}

#[cfg(test)]
mod test {
    use super::*;

    fn neutral(n: usize) -> Vec<U256> {
        alloc::vec![U256::from(PPM as u64); n]
    }

    #[test]
    fn test_zero_exposure_quotes_zero() {
        let (premium, el, tvar95) = price_core(
            &[I256::ZERO],
            &neutral(1),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
        )
        .unwrap();
        assert_eq!(premium, U256::ZERO);
        assert_eq!(el, U256::ZERO);
        assert_eq!(tvar95, U256::ZERO);
    }

    #[test]
    fn test_empty_exposure_reverts() {
        let result = price_core(&[], &[], U256::from(0u64), U256::from(1u64));
        assert!(result.is_err());
    }

    #[test]
    fn test_bad_feeds_length_reverts() {
        let result = price_core(&[I256::ZERO], &neutral(2), U256::from(0u64), U256::from(1u64));
        assert!(result.is_err());
    }

    /// L1: an exposure large enough that exposure*gap overflows I256 must revert, not wrap.
    #[test]
    fn test_overflow_reverts() {
        let result = price_core(&[I256::MIN], &neutral(1), U256::from(0u64), U256::from(40_000_000u64));
        assert!(result.is_err(), "overflowing exposure must revert, not wrap");
    }

    #[test]
    fn test_short_spy_prices_nonzero_premium() {
        let exposure = [-I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium, el, tvar95) = price_core(
            &exposure,
            &neutral(1),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
        )
        .unwrap();
        assert!(premium > U256::ZERO);
        assert!(tvar95 >= el);
        // CoC load must sit strictly below the old 1.25*el+0.5*tvar95 load on any layer where
        // tvar95 > el (the new formula charges rent on locked capital for 66 hours, not a full
        // year's worth of tail risk): the old formula priced this exact case's premium far above
        // el, the new one keeps premium close to el.
        assert!(
            premium < el + (el / U256::from(10u64)),
            "CoC-loaded premium should stay close to EL, not multiples of it"
        );
    }

    #[test]
    fn test_per_market_table_selection_differs() {
        // Same exposure/retention/limit, different market index (0=NVDA vs 2=SPY): SPY's
        // materially calmer historical table (evidence/auction-and-pricing.md: SPY std 0.93% vs
        // NVDA 2.12%) must price a lower premium, proving the table selection is actually wired
        // in and not silently falling back to one shared table for every index.
        let exposure = [-I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium_nvda, ..) =
            price_core(&exposure, &neutral(1), U256::from(20_000_000_000u64), U256::from(60_000_000_000u64)).unwrap();
        let exposure3 = [I256::ZERO, I256::ZERO, -I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium_spy, ..) = price_core(
            &exposure3,
            &neutral(3),
            U256::from(20_000_000_000u64),
            U256::from(60_000_000_000u64),
        )
        .unwrap();
        assert!(premium_spy < premium_nvda, "SPY's calmer table must price lower than NVDA's at the same exposure");
    }

    #[test]
    fn test_vol_scale_up_increases_premium() {
        let exposure = [-I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium_neutral, ..) =
            price_core(&exposure, &neutral(1), U256::from(0u64), U256::from(1_000_000_000_000u64)).unwrap();
        let scaled_up = alloc::vec![U256::from(MAX_SCALE_PPM)];
        let (premium_scaled, ..) =
            price_core(&exposure, &scaled_up, U256::from(0u64), U256::from(1_000_000_000_000u64)).unwrap();
        assert!(premium_scaled > premium_neutral, "3x volatility scale must price a higher premium");
    }
}

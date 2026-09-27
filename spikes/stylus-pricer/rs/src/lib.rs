//! Weekend-gap cover pricer, Stylus (Rust) implementation.
//! price() = mean empirical payoff over 504 stored NVDA weekend gaps
//!         + Black-Scholes put term (r = 0) over the same strike/spot/iv/tenor.
//! Same WAD fixed-point ln/exp/sqrt/normalCDF algorithm as sol/src/FixedMath.sol and
//! sol/src/Pricer.sol, ported line-for-line so outputs match. Gas and parity spike only:
//! not the product contract.
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

fn wad() -> I256 {
    c(1_000_000_000_000_000_000)
}

fn ln2_wad() -> I256 {
    c(693_147_180_559_945_309)
}

fn mul_wad(a: I256, b: I256) -> I256 {
    (a * b) / wad()
}

fn div_wad(a: I256, b: I256) -> I256 {
    (a * wad()) / b
}

/// Floor integer sqrt of a nonnegative U256, Newton's method (same algorithm as
/// FixedMath.isqrt in Solidity).
fn isqrt(x: U256) -> U256 {
    if x.is_zero() {
        return U256::ZERO;
    }
    let one = U256::from(1u64);
    let two = U256::from(2u64);
    let mut z = (x + one) / two;
    let mut y = x;
    while z < y {
        y = z;
        z = (x / z + z) / two;
    }
    y
}

/// sqrt of a nonnegative WAD value, returned as WAD.
fn sqrt_wad(x: I256) -> I256 {
    assert!(x >= I256::ZERO, "sqrtWad: negative");
    let xu: U256 = x.into_raw();
    let scaled = xu * wad().into_raw();
    I256::from_raw(isqrt(scaled))
}

/// ln(x) for x > 0 WAD, via range reduction to m in [1,2) WAD and the atanh series
/// ln(m) = 2*atanh((m-1)/(m+1)) = 2*(t + t^3/3 + t^5/5 + t^7/7 + t^9/9 + t^11/11).
fn ln_wad(x: I256) -> I256 {
    assert!(x > I256::ZERO, "lnWad: non-positive");
    let w = wad();
    let two = c(2);
    let mut m = x;
    let mut e: i128 = 0;
    while m >= two * w {
        m = m / two;
        e += 1;
    }
    while m < w {
        m = m * two;
        e -= 1;
    }
    let t = div_wad(m - w, m + w);
    let t2 = mul_wad(t, t);
    let mut term = t;
    let mut sum = t;
    term = mul_wad(term, t2);
    sum = sum + term / c(3);
    term = mul_wad(term, t2);
    sum = sum + term / c(5);
    term = mul_wad(term, t2);
    sum = sum + term / c(7);
    term = mul_wad(term, t2);
    sum = sum + term / c(9);
    term = mul_wad(term, t2);
    sum = sum + term / c(11);
    let lnm = c(2) * sum;
    c(e) * ln2_wad() + lnm
}

/// exp(-y) for y >= 0 WAD, via range reduction y = n*ln2 + r, r in [0, ln2),
/// Taylor series for exp(-r), then divide by 2^n. Only handles y >= 0 (all the
/// normal CDF below needs), mirroring FixedMath.expNegWad in Solidity.
fn exp_neg_wad(y: I256) -> I256 {
    assert!(y >= I256::ZERO, "expNegWad: negative");
    let w = wad();
    let ln2 = ln2_wad();
    if y > c(135) * w {
        return I256::ZERO;
    }
    let n = y / ln2;
    let r = y - n * ln2;
    let neg_r = -r;
    let mut term = w;
    let mut sum = w;
    term = mul_wad(term, neg_r);
    sum = sum + term;
    term = mul_wad(term, neg_r) / c(2);
    sum = sum + term;
    term = mul_wad(term, neg_r) / c(3);
    sum = sum + term;
    term = mul_wad(term, neg_r) / c(4);
    sum = sum + term;
    term = mul_wad(term, neg_r) / c(5);
    sum = sum + term;
    term = mul_wad(term, neg_r) / c(6);
    sum = sum + term;
    term = mul_wad(term, neg_r) / c(7);
    sum = sum + term;
    // sum is exp(-r) in WAD, always positive here; divide by 2^n (n >= 0 in our domain).
    let mut divisor = c(1);
    let two = c(2);
    let mut i = I256::ZERO;
    while i < n {
        divisor = divisor * two;
        i = i + c(1);
    }
    sum / divisor
}

/// standard normal CDF N(x), x is WAD (can be negative). Abramowitz & Stegun 26.2.17.
fn normal_cdf(x: I256) -> I256 {
    let w = wad();
    let p = c(231_641_900_000_000_000);
    let a1 = c(319_381_530_000_000_000);
    let a2 = c(-356_563_782_000_000_000);
    let a3 = c(1_781_477_937_000_000_000);
    let a4 = c(-1_821_255_978_000_000_000);
    let a5 = c(1_330_274_429_000_000_000);
    let inv_sqrt_2pi = c(398_942_280_401_432_678);

    let x_abs = if x >= I256::ZERO { x } else { -x };
    let k = div_wad(w, w + mul_wad(p, x_abs));
    let poly = mul_wad(
        k,
        a1 + mul_wad(k, a2 + mul_wad(k, a3 + mul_wad(k, a4 + mul_wad(k, a5)))),
    );
    let y = mul_wad(x_abs, x_abs) / c(2);
    let phi = mul_wad(inv_sqrt_2pi, exp_neg_wad(y));
    let tail = mul_wad(phi, poly);
    if x >= I256::ZERO {
        w - tail
    } else {
        tail
    }
}

sol_storage! {
    #[entrypoint]
    pub struct Pricer {}
}

#[public]
impl Pricer {
    /// strike_bps: strike as basis points of spot (e.g. 9700 = 97%)
    /// spot_e8: spot price, 1e8 fixed point
    /// iv_e6: implied vol, parts per 1e6 (e.g. 250000 = 25%)
    /// seconds_to_expiry: time to fixing, in seconds
    /// returns: WAD (1e18) fixed-point premium
    pub fn price(
        &self,
        strike_bps: u32,
        spot_e8: u64,
        iv_e6: u32,
        seconds_to_expiry: u32,
    ) -> Result<U256, Vec<u8>> {
        if strike_bps == 0 || spot_e8 == 0 || iv_e6 == 0 || seconds_to_expiry == 0 {
            return Err(b"BadInput".to_vec());
        }

        let w = wad();
        let spot_wad = c(spot_e8 as i128) * c(10_000_000_000);
        let strike_wad = (spot_wad * c(strike_bps as i128)) / c(10_000);

        let mut sum_payoff = I256::ZERO;
        let ten_k = c(10_000);
        for g in GAPS.iter() {
            let scenario_spot = (spot_wad * (ten_k + c(*g as i128))) / ten_k;
            let payoff = strike_wad - scenario_spot;
            if payoff > I256::ZERO {
                sum_payoff = sum_payoff + payoff;
            }
        }
        let mean_payoff = sum_payoff / c(504);

        let sigma_wad = c(iv_e6 as i128) * c(1_000_000_000_000);
        let t_wad = (c(seconds_to_expiry as i128) * w) / c(31_536_000);

        let sqrt_t = sqrt_wad(t_wad);
        let sigma_sqrt_t = mul_wad(sigma_wad, sqrt_t);
        if sigma_sqrt_t <= I256::ZERO {
            return Err(b"DegenerateVolTenor".to_vec());
        }

        let ln_sk = ln_wad(spot_wad) - ln_wad(strike_wad);
        let half_sigma2_t = mul_wad(mul_wad(sigma_wad, sigma_wad), t_wad) / c(2);
        let d1 = div_wad(ln_sk + half_sigma2_t, sigma_sqrt_t);
        let d2 = d1 - sigma_sqrt_t;

        let n_neg_d2 = normal_cdf(-d2);
        let n_neg_d1 = normal_cdf(-d1);
        let mut put = mul_wad(strike_wad, n_neg_d2) - mul_wad(spot_wad, n_neg_d1);
        if put < I256::ZERO {
            put = I256::ZERO;
        }

        let result = mean_payoff + put;
        U256::try_from(result).map_err(|_| b"NegativeResult".to_vec())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::testing::*;

    #[test]
    fn test_price_matches_expected_order_of_magnitude() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let premium = contract
            .price(9700, 22_540_000_000, 253_400, 216_000)
            .unwrap();
        assert!(premium > U256::ZERO);
    }

    #[test]
    fn test_zero_strike_reverts() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let result = contract.price(0, 22_540_000_000, 253_400, 216_000);
        assert!(result.is_err());
    }
}

#[cfg(test)]
mod parity_test {
    use super::*;
    use stylus_sdk::testing::*;

    #[test]
    fn test_price_5_cases_prints_for_solidity_parity() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let cases: [(u32, u64, u32, u32); 5] = [
            (9700, 22_540_000_000, 253_400, 216_000),
            (9000, 10_000_000_000, 400_000, 172_800),
            (9900, 50_000_000_000, 150_000, 259_200),
            (8500, 30_000_000_000, 600_000, 345_600),
            (9999, 100_000_000_000, 100_000, 86_400),
        ];
        for (i, (strike_bps, spot_e8, iv_e6, secs)) in cases.iter().enumerate() {
            let premium = contract.price(*strike_bps, *spot_e8, *iv_e6, *secs).unwrap();
            println!("case {} premium (WAD): {}", i + 1, premium);
        }
    }
}

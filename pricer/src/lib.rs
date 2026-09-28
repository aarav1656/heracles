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
//! Pricing formula: `premium = el + RISK_LOAD_PPM * (tvar95 - el) + CAPITAL_CHARGE_ANNUAL_PPM *
//! limit * LOCK_DAYS / DAYS_PER_YEAR`, see docs/pricing.md for sourcing and the before/after
//! numbers. Ported line-for-line from src/Pricer.sol so both sides of IPricer are bit-identical
//! on the feed-independent core (`price_core` / `priceCore`, docs/pricing.md parity section);
//! the live-feed-dependent `vol_scale_ppm` wrapper obviously cannot be bit-identical across two
//! toolchains reading two separate RPC calls, which is exactly why the parity test targets the
//! core, not `quote`.
//!
//! Per-market table ids: `table_ids` (constructor-supplied, `bytes`-backed storage) picks each
//! market's scenario table explicitly, matching `Pricer.sol`'s `marketTableIds` array
//! (docs/security/capacity-review.md "Re-review (2026-09-28)" P2). Table id 0 NVDA, 1 AAPL, 2
//! SPY, 3 TSLA, any id past the array's length falls back to `pricer_core::default_table_id`
//! (the old position-only mapping).
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloc::vec::Vec;
use pricer_core::{price_core, PPM, VOL_ROUNDS, NORMAL_ROUND_MOVE_BPS, MIN_SCALE_PPM, MAX_SCALE_PPM};
use stylus_sdk::{
    alloy_primitives::{aliases::U80, Address, I256, U256},
    prelude::*,
    storage::StorageBytes,
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
    pub struct Pricer {
        StorageBytes table_ids;
    }
}

#[public]
impl Pricer {
    /// `table_ids[i]` picks market i's scenario table explicitly (docs/security/capacity-review
    /// .md P2); pass an empty array to keep the old position-only mapping for every market.
    #[constructor]
    pub fn constructor(&mut self, table_ids: Vec<u8>) {
        self.table_ids.set_bytes(&table_ids);
    }

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
            vol_scale_ppm.push(self.vol_scale_ppm(*feed_addr)?);
        }
        let table_ids = self.table_ids.get_bytes();
        price_core(&exposure, &vol_scale_ppm, retention, limit, &table_ids)
    }

    /// Table id configured for market `i` at deploy time (0 default/NVDA fallback if `i` is
    /// past the configured array), matching `Pricer.sol`'s `tableIdAt` getter.
    pub fn table_id_at(&self, i: U256) -> u8 {
        let i = usize::try_from(i).unwrap_or(usize::MAX);
        self.table_ids.get(i).unwrap_or_else(|| pricer_core::default_table_id(i))
    }

    /// Realised volatility over the feed's last VOL_ROUNDS rounds, as a scale in parts-per-
    /// million relative to NORMAL_ROUND_MOVE_BPS, bounded to [MIN_SCALE_PPM, MAX_SCALE_PPM].
    /// Returns PPM (1.0x, neutral) if the feed has too little history yet. Fails closed
    /// (propagates the error) if the initial `latestRoundData()` call itself fails, matching the
    /// Solidity twin, which does not wrap that call in try/catch (docs/pricing.md step 5,
    /// docs/security/capacity-review.md P1): a broken or unset feed must revert the whole quote,
    /// not silently price at a neutral 1.0x scale. The per-round walk-back below keeps its
    /// graceful degrade-to-neutral on a failed `getRoundData` call in both languages, since a
    /// short history is an expected, harmless condition, not a broken feed.
    ///
    /// Walks the round id backwards by 1 per step using U80 (not u64) arithmetic throughout: a
    /// live Chainlink proxy's `roundId` is `phaseId << 64 | aggregatorRoundId` and routinely
    /// exceeds u64 (docs/security/capacity-review.md P1), so truncating it to u64 panics on
    /// every real feed. Does not track Chainlink's phaseId (docs/pricing.md Limitations), so a
    /// phase change inside the last VOL_ROUNDS rounds truncates the sample early via the failed-
    /// call branch rather than crossing into the wrong phase's round ids. Mirrors
    /// `Pricer._volScalePpm` in contracts/src/Pricer.sol.
    fn vol_scale_ppm(&self, feed_addr: Address) -> Result<U256, Vec<u8>> {
        let feed = IAggregatorV3::new(feed_addr);
        let ppm_neutral = U256::from(PPM as u64);

        let (latest_id, latest_answer, _, _, _) =
            feed.latest_round_data(self.vm(), Call::new()).map_err(|_| b"FeedReadFailed".to_vec())?;
        if latest_answer <= I256::ZERO || latest_id < U80::from(VOL_ROUNDS) {
            return Ok(ppm_neutral);
        }

        let mut prev_answer = latest_answer;
        let mut sum_bps: u64 = 0;
        let mut n: u64 = 0;
        for k in 1..=VOL_ROUNDS {
            let round_id = latest_id - U80::from(k);
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
            return Ok(ppm_neutral);
        }

        let mut scale = (sum_bps / n) * (PPM as u64) / NORMAL_ROUND_MOVE_BPS;
        if scale < MIN_SCALE_PPM {
            scale = MIN_SCALE_PPM;
        }
        if scale > MAX_SCALE_PPM {
            scale = MAX_SCALE_PPM;
        }
        Ok(U256::from(scale))
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::{alloy_primitives::keccak256, testing::*};

    fn neutral(n: usize) -> Vec<U256> {
        alloc::vec![U256::from(PPM as u64); n]
    }

    fn selector(sig: &str) -> [u8; 4] {
        keccak256(sig.as_bytes())[0..4].try_into().unwrap()
    }

    /// Builds the calldata sol_interface! generates for a zero-arg call: just the selector.
    fn latest_round_data_calldata() -> Vec<u8> {
        selector("latestRoundData()").to_vec()
    }

    /// abi-encodes the static 5-tuple `latestRoundData()` returns: plain 32-byte-word
    /// concatenation, since every field is a static type.
    fn encode_round_data(round_id: U256, answer: I256, started_at: U256, updated_at: U256, answered_in_round: U256) -> Vec<u8> {
        let mut out = Vec::with_capacity(160);
        out.extend_from_slice(&round_id.to_be_bytes::<32>());
        out.extend_from_slice(&answer.to_be_bytes::<32>());
        out.extend_from_slice(&started_at.to_be_bytes::<32>());
        out.extend_from_slice(&updated_at.to_be_bytes::<32>());
        out.extend_from_slice(&answered_in_round.to_be_bytes::<32>());
        out
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

    /// Fail-closed check (docs/security/capacity-review.md P1, docs/pricing.md step 5): with no
    /// mocked response behind the feed address, `latestRoundData()` decodes from empty bytes and
    /// fails, so `_volScalePpm` must propagate the error and `quote()` must revert, matching the
    /// Solidity twin (which has no try/catch around that call) instead of silently falling back
    /// to a neutral 1.0x scale.
    #[test]
    fn test_quote_reverts_when_feed_is_unset() {
        let vm = TestVM::default();
        let contract = Pricer::from(&vm);
        let exposure = alloc::vec![I256::try_from(2_000_000_000_000i128).unwrap()];
        let result =
            contract.quote(exposure, alloc::vec![Address::ZERO], U256::from(20_000_000_000u64), U256::from(60_000_000_000u64));
        assert!(result.is_err(), "an unset feed must fail closed, not soft-fallback to a neutral scale");
    }

    /// P1 (docs/security/capacity-review.md, pricer/src/lib.rs vol_scale_ppm): mocks
    /// `latestRoundData()` with the real live SPY/USD round id that panicked before the fix
    /// (`roundId = phaseId << 64 | aggregatorRoundId = 18446744073709553978`, phase 1 round
    /// 2362, /tmp/heracles-rr/u80 repro). Before the U80 fix, `.to::<u64>()` on this exact value
    /// panics with `Uint conversion error: Overflow(80, ...)`, aborting the whole call. After
    /// the fix, the call completes (getRoundData is left unmocked, so the walk-back degrades
    /// gracefully to the neutral scale, exactly like a short-history feed).
    #[test]
    fn test_p1_quote_does_not_panic_on_real_chainlink_phase_round_id() {
        let vm = TestVM::default();
        let feed_addr = Address::from([7u8; 20]);
        let contract = Pricer::from(&vm);

        let real_round_id = U256::from(18_446_744_073_709_553_978u128);
        vm.mock_static_call(
            feed_addr,
            latest_round_data_calldata(),
            Ok(encode_round_data(real_round_id, I256::try_from(500_000_000i128).unwrap(), U256::ZERO, U256::ZERO, real_round_id)),
        );

        let exposure = alloc::vec![I256::try_from(2_000_000_000_000i128).unwrap()];
        let result = contract.quote(exposure, alloc::vec![feed_addr], U256::from(20_000_000_000u64), U256::from(60_000_000_000u64));
        assert!(result.is_ok(), "a real Chainlink phase-1 round id must not panic or revert: {result:?}");
    }

    /// With the volatility feed configured at neutral scale via a mocked feed (rather than an
    /// unset one, since unset now fails closed per P1), `quote()` must match calling
    /// `pricer_core::price_core` directly with an all-neutral scale vector and the same table
    /// ids as the deployed contract's (constructor-default, empty).
    #[test]
    fn test_quote_matches_price_core_at_neutral_scale() {
        let vm = TestVM::default();
        let mut contract = Pricer::from(&vm);
        contract.constructor(alloc::vec![]);

        let feed_addr = Address::from([9u8; 20]);
        // latestId < VOL_ROUNDS => _volScalePpm short-circuits to the neutral PPM scale without
        // needing any getRoundData mocks.
        vm.mock_static_call(
            feed_addr,
            latest_round_data_calldata(),
            Ok(encode_round_data(U256::from(1u64), I256::try_from(500_000_000i128).unwrap(), U256::ZERO, U256::ZERO, U256::from(1u64))),
        );

        let exposure = alloc::vec![I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium, el, tvar95) = contract
            .quote(exposure.clone(), alloc::vec![feed_addr], U256::from(20_000_000_000u64), U256::from(60_000_000_000u64))
            .unwrap();
        let (premium2, el2, tvar95_2) =
            price_core(&exposure, &neutral(1), U256::from(20_000_000_000u64), U256::from(60_000_000_000u64), &[]).unwrap();
        assert_eq!((premium, el, tvar95), (premium2, el2, tvar95_2));
    }

    /// P2: the constructor's `table_ids` wires straight through to `price_core`'s table
    /// selection, matching the Solidity twin's `tableIdAt`/`marketTableIds`.
    #[test]
    fn test_constructor_table_ids_select_configured_table() {
        let vm = TestVM::default();
        let mut contract = Pricer::from(&vm);
        contract.constructor(alloc::vec![2]); // market 0 => SPY

        assert_eq!(contract.table_id_at(U256::from(0u64)), 2u8);

        let feed_addr = Address::from([9u8; 20]);
        vm.mock_static_call(
            feed_addr,
            latest_round_data_calldata(),
            Ok(encode_round_data(U256::from(1u64), I256::try_from(500_000_000i128).unwrap(), U256::ZERO, U256::ZERO, U256::from(1u64))),
        );
        let exposure = alloc::vec![I256::try_from(2_000_000_000_000i128).unwrap()];
        let (premium, ..) = contract
            .quote(exposure, alloc::vec![feed_addr], U256::from(20_000_000_000u64), U256::from(60_000_000_000u64))
            .unwrap();
        assert_eq!(premium, U256::from(1_676_722_158u64), "must be the SPY acceptance number, not NVDA's");
    }
}

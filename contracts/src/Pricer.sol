// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPricer} from "./IPricer.sol";

/// @notice Local, minimal Chainlink aggregator interface (mirrors Treaty.sol's own local
/// `AggregatorV3Interface`; not imported from Treaty so Pricer has zero dependency on it).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Weekend-gap layer pricer, Solidity implementation of IPricer.
///
/// Per-market scenario tables (evidence/auction-and-pricing.md
/// section 2): six independently sourced 504-scenario Friday-close-to-Monday-open weekend gap
/// tables: NVDA, AAPL, SPY and TSLA (whole basis points, api.nasdaq.com via
/// `scripts/generate_gap_tables.py`), plus EUR/USD and XAU/USD (hundredths of a basis point,
/// Dukascopy 1-minute bars at the contract's fixing minutes via
/// `scripts/generate_fx_gold_gap_tables.py`); evidence/gap-tables/{TICKER}.json holds the full detail
/// including source URL and fetch method for every scenario. Table id 0 is NVDA, 1 AAPL, 2 SPY,
/// 3 TSLA, 4 EUR/USD, 5 XAU/USD. `marketTableIds[i]` (a constructor-supplied array, docs/security/capacity-review.md
/// "Re-review (2026-09-28)" P2) picks market i's table explicitly, so the market a table prices
/// no longer depends on `exposure[i]`/`feeds[i]`'s array position. There is no positional or
/// id-value fallback (P2 re-review, docs/security/capacity-review.md): the constructor reverts
/// `BadTableId()` if `tableIds` is empty or any entry is not 0-3, and `tableIdAt(i)` reverts
/// `MissingTable()` if `i` is past `marketTableIds`'s length, so a quote spanning more markets
/// than the deploy configured reverts instead of silently pricing the extra market on NVDA.
///
/// Volatility scale: before being applied, every scenario in a market's table is
/// scaled by that market's own realised volatility, read live from its Chainlink feed's last
/// `VOL_ROUNDS` rounds (`_volScalePpm`), relative to `NORMAL_ROUND_MOVE_BPS` (the ~0.5% round-
/// to-round deviation threshold measured live against the real Arbitrum One SPY/USD feed),
/// bounded to [`MIN_SCALE_PPM`, `MAX_SCALE_PPM`]. This
/// makes the quote react to current market conditions instead of always replaying the same
/// static historical distribution. It is a relative regime-scaling heuristic (scale the whole
/// historical distribution up or down by how much livelier or calmer the feed has been lately),
/// not a rigorous annualised-vol/Black-Scholes model; see docs/pricing.md Limitations. It is
/// implemented identically here and in the Stylus twin (`pricer/src/lib.rs`) because the added
/// cost is dominated by the `CALL` opcode to each feed, which costs the same in both languages;
/// unlike the historical-scenario loop, this part gives Stylus no advantage, so keeping the
/// Solidity reference twin exact stays cheap and honest.
///
/// Pricing formula (item 2, docs/security/capacity-review.md "Pricing (item 2)"): `premium = el
/// + RISK_LOAD_PPM * (tvar95 - el) + CAPITAL_CHARGE_ANNUAL_PPM * limit * LOCK_DAYS /
/// DAYS_PER_YEAR`, replacing the old `el + c*(tvar95-el)` cost-of-capital-only load, which
/// priced writers a Sharpe ratio near zero. The first term is a flat per-weekend tail-risk load
/// (not prorated by time, since a weekend gap prices as a discrete per-bind event, not a
/// continuous-time process); the second is the risk-free rate on the fully collateralised limit
/// for the real capital-lock duration (see docs/pricing.md for the sourcing and the before/after
/// numbers).
///
/// quote() computes, per scenario s and market i: scaledGap = table[i][s] * volScalePpm[i] /
/// 1e6, portfolioLoss(s) = sum_i max(0, -(exposure[i] * scaledGap) / 10000), payout(s) =
/// min(limit, max(0, portfolioLoss(s) - retention)), then el = mean(payout), tvar95 = mean of
/// the worst 5% (25 of 504) of payout(s), and premium = el + RISK_LOAD_PPM*(tvar95-el) +
/// CAPITAL_CHARGE_ANNUAL_PPM*limit*LOCK_DAYS/DAYS_PER_YEAR, all in USDG's native 6-decimal fixed
/// point (no WAD). This is the reference/fallback implementation; the product path calls the
/// identical algorithm on the Rust/Stylus PricerStylus contract through the same IPricer
/// interface (gas ratio: docs/pricing.md, remeasured at this build's scale).
contract Pricer is IPricer {
    uint256 internal constant SCENARIOS = 504;
    uint256 internal constant TAIL = 25; // ceil(504 * 0.05), the worst 5% of scenarios
    int256 internal constant BPS = 10000;
    uint256 internal constant PPM = 1_000_000;

    /// Per-weekend tail-risk load, docs/security/capacity-review.md "Pricing (item 2)": a flat
    /// 3% of (TVaR95 - EL), not prorated by time.
    uint256 internal constant RISK_LOAD_PPM = 30_000; // 3.00%
    /// Risk-free rate on the fully collateralised limit for the real capital-lock duration
    /// (LOCK_DAYS / DAYS_PER_YEAR), replacing the old cost-of-capital-only load. Capital is
    /// locked for the real bind-to-settlement window (up to about 7.5 days, Treaty.sol's own
    /// bind-to-Monday-expiry cutoff), so LOCK_DAYS = 7 prices the full real lock instead of the
    /// old WEEKEND_HOURS = 66, which undercounted it (docs/security/capacity-review.md Low/Info).
    uint256 internal constant CAPITAL_CHARGE_ANNUAL_PPM = 40_000; // 4.00%
    uint256 internal constant LOCK_DAYS = 7;
    uint256 internal constant DAYS_PER_YEAR = 365;

    /// Realised-volatility scale: sampled over the feed's last VOL_ROUNDS rounds,
    /// relative to NORMAL_ROUND_MOVE_BPS, bounded to [MIN_SCALE_PPM, MAX_SCALE_PPM].
    uint256 internal constant VOL_ROUNDS = 8;
    /// The live-measured Chainlink deviation threshold on the real Arbitrum One SPY/USD feed
    /// ("roughly 0.5%, inferred from consecutive Sep 16
    /// rounds 755.40 to 751.61"): a feed moving at exactly its own deviation threshold per round
    /// is defined as the 1.0x "normal" baseline.
    uint256 internal constant NORMAL_ROUND_MOVE_BPS = 50;
    /// Floors at 1.0x (docs/security/capacity-review.md P4): the vol scale may only raise a
    /// quote above the static historical table, never cut it below, closing the buyer's
    /// bind-timing option (a heartbeat-quiet weekday priced a materially cheaper premium than a
    /// livelier one on the same layer).
    uint256 internal constant MIN_SCALE_PPM = 1_000_000; // floor 1.0x
    uint256 internal constant MAX_SCALE_PPM = 3_000_000; // cap 3.0x

    int32[504] internal gapsNVDA;
    int32[504] internal gapsAAPL;
    int32[504] internal gapsSPY;
    int32[504] internal gapsTSLA;
    /// EUR/USD and XAU/USD, in hundredths of a basis point (FX_UNIT per bp), see pricer/core.
    int32[504] internal gapsEUR;
    int32[504] internal gapsXAU;
    int256 internal constant FX_UNIT = 100;

    /// Explicit per-market table id (docs/security/capacity-review.md P2): `marketTableIds[i]`
    /// picks market i's table by id, not by its position in `exposure`/`feeds`. Any `i` past
    /// this array's length reverts (`tableIdAt`), there is no positional fallback.
    uint8[] internal marketTableIds;

    error EmptyExposure();
    error BadFeeds();
    /// A configured table id is not a real table (must be 0-5). Reverts the constructor.
    error BadTableId();
    /// A market index has no entry in `marketTableIds` (docs/security/capacity-review.md
    /// "Re-review (2026-09-28)" P2): the deploy did not configure a table for every market a
    /// quote spans, so pricing it would have to guess. Reverts `tableIdAt`, and transitively
    /// `_tableFor`/`priceCore`/`quote` for the same index.
    error MissingTable();

    constructor(uint8[] memory tableIds) {
        if (tableIds.length == 0) revert BadTableId();
        for (uint256 i; i < tableIds.length; i++) {
            if (tableIds[i] > 5) revert BadTableId();
        }
        marketTableIds = tableIds;
        gapsNVDA = [int32(0),int32(53),int32(-2),int32(68),int32(33),int32(294),int32(14),int32(78),int32(-31),int32(174),int32(-215),int32(-71),int32(208),int32(-219),int32(39),int32(-42),int32(-20),int32(-76),int32(-33),int32(-20),int32(93),int32(73),int32(-150),int32(42),int32(67),int32(-176),int32(2),int32(3),int32(126),int32(42),int32(46),int32(130),int32(130),int32(131),int32(-46),int32(-249),int32(118),int32(86),int32(34),int32(203),int32(84),int32(17),int32(33),int32(70),int32(238),int32(61),int32(47),int32(-122),int32(113),int32(279),int32(-70),int32(113),int32(82),int32(62),int32(45),int32(0),int32(-71),int32(0),int32(30),int32(16),int32(120),int32(30),int32(86),int32(-115),int32(118),int32(232),int32(48),int32(14),int32(-24),int32(-279),int32(141),int32(37),int32(76),int32(-86),int32(68),int32(-92),int32(216),int32(119),int32(12),int32(31),int32(29),int32(177),int32(60),int32(160),int32(-29),int32(54),int32(-20),int32(-67),int32(-171),int32(-119),int32(121),int32(-45),int32(-43),int32(23),int32(-20),int32(14),int32(-67),int32(44),int32(-19),int32(34),int32(-37),int32(-47),int32(112),int32(-125),int32(-22),int32(92),int32(287),int32(-25),int32(-180),int32(-161),int32(337),int32(561),int32(-123),int32(-82),int32(-238),int32(131),int32(170),int32(-142),int32(-78),int32(-1474),int32(44),int32(-120),int32(-27),int32(212),int32(99),int32(63),int32(75),int32(-92),int32(206),int32(-64),int32(-16),int32(18),int32(-410),int32(-315),int32(-254),int32(49),int32(33),int32(155),int32(-5),int32(57),int32(508),int32(-150),int32(51),int32(51),int32(-17),int32(-458),int32(-136),int32(286),int32(195),int32(-175),int32(70),int32(-166),int32(0),int32(61),int32(144),int32(-19),int32(130),int32(86),int32(161),int32(-1),int32(-15),int32(244),int32(-13),int32(-43),int32(85),int32(48),int32(-37),int32(-159),int32(137),int32(-59),int32(-489),int32(-31),int32(36),int32(-143),int32(-812),int32(253),int32(-983),int32(-1181),int32(-2),int32(104),int32(464),int32(-174),int32(187),int32(-67),int32(-6),int32(318),int32(145),int32(-48),int32(-48),int32(-131),int32(42),int32(16),int32(110),int32(71),int32(37),int32(111),int32(120),int32(248),int32(158),int32(27),int32(-704),int32(753),int32(-217),int32(129),int32(133),int32(165),int32(66),int32(-120),int32(99),int32(-7),int32(-94),int32(64),int32(3),int32(32),int32(57),int32(-149),int32(107),int32(122),int32(51),int32(49),int32(100),int32(69),int32(-102),int32(117),int32(-9),int32(7),int32(52),int32(-15),int32(-77),int32(-236),int32(-53),int32(77),int32(-17),int32(-60),int32(147),int32(16),int32(-4),int32(45),int32(-109),int32(174),int32(122),int32(95),int32(-135),int32(-126),int32(103),int32(39),int32(-26),int32(74),int32(86),int32(-4),int32(92),int32(-344),int32(-168),int32(-115),int32(-123),int32(-52),int32(109),int32(32),int32(133),int32(53),int32(161),int32(274),int32(-265),int32(17),int32(-178),int32(137),int32(-244),int32(-253),int32(-447),int32(150),int32(22),int32(-6),int32(-257),int32(-68),int32(-52),int32(-105),int32(20),int32(23),int32(6),int32(-391),int32(-160),int32(-4),int32(-343),int32(-111),int32(-252),int32(90),int32(224),int32(-574),int32(374),int32(109),int32(-240),int32(-197),int32(343),int32(-173),int32(10),int32(-783),int32(-4),int32(-201),int32(-148),int32(62),int32(-13),int32(-141),int32(-20),int32(171),int32(-32),int32(259),int32(34),int32(-40),int32(51),int32(-67),int32(-170),int32(-150),int32(-117),int32(21),int32(1),int32(-87),int32(162),int32(286),int32(0),int32(126),int32(-204),int32(-139),int32(128),int32(-181),int32(165),int32(0),int32(-93),int32(-43),int32(22),int32(-96),int32(-72),int32(-39),int32(33),int32(-55),int32(59),int32(-116),int32(423),int32(-106),int32(111),int32(72),int32(60),int32(51),int32(36),int32(180),int32(95),int32(1),int32(96),int32(-90),int32(276),int32(101),int32(-59),int32(126),int32(-262),int32(-5),int32(122),int32(-201),int32(-88),int32(-38),int32(145),int32(62),int32(-3),int32(3),int32(5),int32(-147),int32(-3),int32(104),int32(28),int32(-56),int32(85),int32(56),int32(94),int32(33),int32(312),int32(65),int32(-92),int32(112),int32(225),int32(-126),int32(290),int32(-37),int32(79),int32(103),int32(250),int32(-16),int32(68),int32(67),int32(137),int32(355),int32(364),int32(-43),int32(84),int32(-263),int32(-6),int32(132),int32(102),int32(205),int32(56),int32(-1418),int32(150),int32(-24),int32(15),int32(-281),int32(199),int32(-194),int32(47),int32(-255),int32(6),int32(124),int32(9),int32(103),int32(134),int32(71),int32(-175),int32(3),int32(42),int32(-244),int32(-5),int32(117),int32(-159),int32(285),int32(-436),int32(105),int32(-1249),int32(-443),int32(19),int32(174),int32(158),int32(-113),int32(-248),int32(88),int32(185),int32(-414),int32(-726),int32(287),int32(-119),int32(-139),int32(456),int32(-222),int32(218),int32(27),int32(104),int32(97),int32(-94),int32(41),int32(27),int32(20),int32(30),int32(83),int32(-36),int32(8),int32(20),int32(-240),int32(32),int32(-121),int32(-78),int32(125),int32(-113),int32(262),int32(-5),int32(200),int32(276),int32(370),int32(-221),int32(34),int32(-127),int32(13),int32(167),int32(162),int32(-148),int32(154),int32(-89),int32(-233),int32(-27),int32(-206),int32(-62),int32(-58),int32(83),int32(-123),int32(-56),int32(151),int32(264),int32(75),int32(-138),int32(-84),int32(66),int32(53),int32(-54),int32(202),int32(56),int32(217),int32(248),int32(182),int32(69),int32(-115),int32(151),int32(66),int32(-152),int32(-25),int32(36),int32(38),int32(61),int32(119),int32(-323),int32(30)];
        gapsAAPL = [int32(-30),int32(84),int32(-26),int32(43),int32(-6),int32(114),int32(-66),int32(5),int32(-32),int32(9),int32(-58),int32(-15),int32(0),int32(-2),int32(3),int32(-59),int32(0),int32(-84),int32(4),int32(73),int32(38),int32(35),int32(-30),int32(-21),int32(29),int32(-89),int32(3),int32(18),int32(86),int32(101),int32(5),int32(-6),int32(61),int32(-12),int32(-71),int32(-217),int32(98),int32(61),int32(60),int32(-5),int32(-15),int32(21),int32(27),int32(43),int32(117),int32(0),int32(18),int32(-18),int32(118),int32(14),int32(-125),int32(9),int32(33),int32(58),int32(41),int32(52),int32(-8),int32(-67),int32(8),int32(5),int32(84),int32(-10),int32(52),int32(-241),int32(55),int32(-37),int32(46),int32(-65),int32(-79),int32(-87),int32(134),int32(-22),int32(48),int32(-57),int32(17),int32(-39),int32(190),int32(89),int32(17),int32(67),int32(-12),int32(73),int32(22),int32(91),int32(-52),int32(73),int32(-18),int32(-51),int32(-82),int32(-70),int32(81),int32(10),int32(-40),int32(48),int32(0),int32(8),int32(24),int32(46),int32(34),int32(-16),int32(-76),int32(-39),int32(98),int32(-93),int32(-43),int32(22),int32(134),int32(-153),int32(-268),int32(-182),int32(113),int32(329),int32(-207),int32(-2),int32(-171),int32(147),int32(30),int32(-95),int32(-26),int32(-125),int32(53),int32(38),int32(-42),int32(69),int32(41),int32(149),int32(-17),int32(24),int32(89),int32(-29),int32(-15),int32(5),int32(-352),int32(-480),int32(-290),int32(-3),int32(30),int32(87),int32(8),int32(-12),int32(265),int32(-167),int32(39),int32(52),int32(35),int32(-296),int32(-68),int32(200),int32(159),int32(-111),int32(74),int32(-47),int32(56),int32(95),int32(-33),int32(-55),int32(47),int32(34),int32(59),int32(-71),int32(2),int32(36),int32(1),int32(-26),int32(67),int32(39),int32(-12),int32(-122),int32(42),int32(-48),int32(-259),int32(-168),int32(-183),int32(-295),int32(-504),int32(326),int32(-875),int32(-1296),int32(-51),int32(121),int32(393),int32(-171),int32(-41),int32(3),int32(-65),int32(177),int32(145),int32(-6),int32(-38),int32(-164),int32(46),int32(-11),int32(140),int32(9),int32(118),int32(183),int32(134),int32(101),int32(348),int32(222),int32(-580),int32(243),int32(-215),int32(243),int32(79),int32(264),int32(79),int32(-90),int32(23),int32(152),int32(-29),int32(-14),int32(33),int32(5),int32(16),int32(-129),int32(-217),int32(50),int32(288),int32(136),int32(-53),int32(9),int32(-143),int32(205),int32(-40),int32(31),int32(28),int32(36),int32(-36),int32(-48),int32(38),int32(44),int32(-61),int32(-49),int32(46),int32(38),int32(22),int32(37),int32(-12),int32(23),int32(8),int32(76),int32(-180),int32(-20),int32(34),int32(4),int32(-38),int32(8),int32(27),int32(43),int32(111),int32(-155),int32(-99),int32(-62),int32(-44),int32(-96),int32(-1),int32(-54),int32(9),int32(25),int32(70),int32(163),int32(151),int32(93),int32(-167),int32(15),int32(-179),int32(-90),int32(-147),int32(-10),int32(27),int32(-75),int32(-139),int32(-109),int32(12),int32(-212),int32(-29),int32(-146),int32(15),int32(-81),int32(-41),int32(-60),int32(-150),int32(-106),int32(15),int32(-38),int32(113),int32(-311),int32(141),int32(73),int32(-83),int32(-93),int32(38),int32(-5),int32(-92),int32(62),int32(-34),int32(-107),int32(-151),int32(42),int32(141),int32(-92),int32(-51),int32(1),int32(24),int32(194),int32(-6),int32(-166),int32(-92),int32(-49),int32(-75),int32(-201),int32(-3),int32(38),int32(45),int32(-36),int32(27),int32(65),int32(5),int32(18),int32(-67),int32(-125),int32(-4),int32(-154),int32(68),int32(182),int32(-47),int32(5),int32(-19),int32(-38),int32(-7),int32(-1),int32(-24),int32(-63),int32(34),int32(-67),int32(87),int32(93),int32(17),int32(-28),int32(8),int32(-10),int32(-74),int32(63),int32(77),int32(12),int32(8),int32(10),int32(33),int32(83),int32(-62),int32(106),int32(84),int32(-34),int32(1),int32(-38),int32(-117),int32(-114),int32(48),int32(-15),int32(-31),int32(11),int32(-3),int32(-66),int32(-133),int32(-75),int32(1),int32(-279),int32(50),int32(-202),int32(39),int32(-21),int32(124),int32(-23),int32(-29),int32(-15),int32(-195),int32(129),int32(171),int32(-100),int32(-32),int32(-67),int32(31),int32(240),int32(-56),int32(130),int32(-29),int32(81),int32(34),int32(1),int32(41),int32(11),int32(70),int32(33),int32(258),int32(120),int32(-46),int32(-945),int32(-8),int32(-15),int32(-4),int32(-20),int32(0),int32(-268),int32(-38),int32(99),int32(-101),int32(51),int32(-23),int32(83),int32(-86),int32(-86),int32(11),int32(69),int32(-3),int32(-42),int32(-6),int32(11),int32(-131),int32(39),int32(-140),int32(-260),int32(56),int32(-255),int32(85),int32(-18),int32(-25),int32(-2),int32(-148),int32(-8),int32(125),int32(-41),int32(-593),int32(671),int32(34),int32(-110),int32(627),int32(-159),int32(155),int32(-28),int32(23),int32(43),int32(31),int32(46),int32(-58),int32(44),int32(7),int32(105),int32(-62),int32(5),int32(-56),int32(-124),int32(-16),int32(125),int32(114),int32(-35),int32(-1),int32(168),int32(142),int32(78),int32(2),int32(18),int32(-132),int32(-22),int32(-30),int32(-23),int32(67),int32(-30),int32(-26),int32(-14),int32(-8),int32(-110),int32(139),int32(21),int32(-8),int32(89),int32(-41),int32(-67),int32(-69),int32(79),int32(241),int32(51),int32(-29),int32(4),int32(-183),int32(-17),int32(-46),int32(0),int32(24),int32(-78),int32(46),int32(103),int32(104),int32(54),int32(-7),int32(46),int32(22),int32(-207),int32(9),int32(69),int32(-3),int32(-90),int32(76),int32(-25)];
        gapsSPY = [int32(-22),int32(52),int32(-1),int32(48),int32(18),int32(139),int32(28),int32(31),int32(-16),int32(44),int32(-5),int32(9),int32(14),int32(68),int32(-13),int32(-33),int32(-17),int32(-35),int32(-20),int32(25),int32(18),int32(-4),int32(-39),int32(-3),int32(0),int32(-83),int32(3),int32(7),int32(110),int32(25),int32(2),int32(21),int32(25),int32(-15),int32(-8),int32(-12),int32(39),int32(32),int32(45),int32(-7),int32(-4),int32(-4),int32(19),int32(3),int32(60),int32(-3),int32(25),int32(-23),int32(59),int32(17),int32(-12),int32(10),int32(10),int32(10),int32(14),int32(-25),int32(-6),int32(-30),int32(11),int32(2),int32(70),int32(3),int32(60),int32(-17),int32(37),int32(-4),int32(51),int32(-9),int32(-23),int32(-73),int32(89),int32(-40),int32(44),int32(-50),int32(12),int32(-31),int32(158),int32(64),int32(70),int32(24),int32(26),int32(33),int32(18),int32(62),int32(-68),int32(34),int32(9),int32(-59),int32(-47),int32(-65),int32(41),int32(2),int32(-8),int32(3),int32(1),int32(11),int32(18),int32(47),int32(-16),int32(40),int32(-2),int32(-22),int32(48),int32(-27),int32(-14),int32(27),int32(131),int32(20),int32(-21),int32(-25),int32(96),int32(168),int32(-8),int32(-41),int32(-69),int32(73),int32(12),int32(-82),int32(-62),int32(-90),int32(2),int32(27),int32(-32),int32(57),int32(42),int32(29),int32(9),int32(-14),int32(79),int32(-16),int32(3),int32(3),int32(-163),int32(-197),int32(-62),int32(11),int32(1),int32(60),int32(9),int32(8),int32(126),int32(-49),int32(16),int32(15),int32(-4),int32(-155),int32(-57),int32(116),int32(85),int32(-64),int32(37),int32(-42),int32(-24),int32(19),int32(-30),int32(-12),int32(49),int32(44),int32(56),int32(-49),int32(-8),int32(33),int32(9),int32(-14),int32(60),int32(27),int32(3),int32(-60),int32(21),int32(-32),int32(-175),int32(50),int32(-29),int32(-32),int32(-310),int32(66),int32(-745),int32(-1045),int32(-27),int32(90),int32(389),int32(-141),int32(76),int32(-72),int32(-72),int32(236),int32(220),int32(-23),int32(28),int32(-203),int32(-21),int32(45),int32(80),int32(-9),int32(23),int32(55),int32(15),int32(33),int32(78),int32(-7),int32(-171),int32(103),int32(-150),int32(137),int32(66),int32(79),int32(39),int32(-106),int32(112),int32(394),int32(80),int32(55),int32(-23),int32(-22),int32(64),int32(-114),int32(-89),int32(70),int32(21),int32(99),int32(40),int32(34),int32(-76),int32(138),int32(27),int32(7),int32(14),int32(-40),int32(-16),int32(-24),int32(17),int32(51),int32(9),int32(-29),int32(58),int32(60),int32(0),int32(3),int32(45),int32(13),int32(1),int32(-2),int32(-119),int32(-14),int32(42),int32(-1),int32(-31),int32(41),int32(16),int32(-8),int32(72),int32(-148),int32(-25),int32(-29),int32(-16),int32(-43),int32(26),int32(23),int32(25),int32(29),int32(43),int32(111),int32(60),int32(-12),int32(-117),int32(28),int32(-73),int32(-107),int32(-136),int32(-16),int32(18),int32(-12),int32(-54),int32(-131),int32(-14),int32(20),int32(-4),int32(-14),int32(5),int32(-77),int32(-56),int32(2),int32(-152),int32(-43),int32(82),int32(-41),int32(103),int32(-255),int32(165),int32(25),int32(-141),int32(-73),int32(84),int32(17),int32(-69),int32(43),int32(-55),int32(-121),int32(-77),int32(23),int32(54),int32(-86),int32(-42),int32(109),int32(32),int32(178),int32(43),int32(-66),int32(36),int32(-46),int32(-35),int32(-81),int32(-73),int32(21),int32(5),int32(-3),int32(51),int32(59),int32(-1),int32(21),int32(-71),int32(-62),int32(17),int32(-103),int32(88),int32(21),int32(-106),int32(21),int32(60),int32(-13),int32(-2),int32(-5),int32(-11),int32(8),int32(15),int32(0),int32(48),int32(8),int32(24),int32(-46),int32(-14),int32(-8),int32(-8),int32(-3),int32(26),int32(11),int32(43),int32(-21),int32(24),int32(52),int32(-10),int32(61),int32(-7),int32(-29),int32(-20),int32(-46),int32(54),int32(-38),int32(70),int32(18),int32(-31),int32(-6),int32(-14),int32(-76),int32(-11),int32(35),int32(9),int32(-66),int32(11),int32(-30),int32(33),int32(7),int32(-13),int32(-1),int32(-36),int32(9),int32(-16),int32(-24),int32(82),int32(-27),int32(14),int32(84),int32(54),int32(36),int32(48),int32(33),int32(2),int32(16),int32(31),int32(-16),int32(-13),int32(-3),int32(26),int32(14),int32(36),int32(73),int32(29),int32(-399),int32(23),int32(8),int32(19),int32(-57),int32(79),int32(-5),int32(19),int32(-18),int32(-29),int32(28),int32(-13),int32(61),int32(2),int32(27),int32(8),int32(67),int32(7),int32(-2),int32(30),int32(-4),int32(-120),int32(73),int32(-81),int32(52),int32(-216),int32(-152),int32(54),int32(19),int32(35),int32(34),int32(-145),int32(0),int32(121),int32(-105),int32(-318),int32(189),int32(14),int32(-74),int32(304),int32(-103),int32(120),int32(-28),int32(10),int32(57),int32(13),int32(40),int32(-7),int32(19),int32(6),int32(64),int32(4),int32(-9),int32(-20),int32(-117),int32(21),int32(34),int32(-23),int32(38),int32(36),int32(117),int32(44),int32(81),int32(53),int32(93),int32(-33),int32(56),int32(-67),int32(13),int32(58),int32(49),int32(-40),int32(49),int32(-49),int32(-147),int32(18),int32(-35),int32(-17),int32(-24),int32(-23),int32(-106),int32(-89),int32(92),int32(146),int32(95),int32(-30),int32(0),int32(-11),int32(-8),int32(-16),int32(9),int32(59),int32(-15),int32(79),int32(136),int32(103),int32(-33),int32(51),int32(81),int32(32),int32(-9),int32(-2),int32(-12),int32(-26),int32(-15),int32(-69),int32(60)];
        gapsTSLA = [int32(405),int32(241),int32(27),int32(46),int32(126),int32(159),int32(-30),int32(1),int32(-59),int32(57),int32(32),int32(0),int32(72),int32(55),int32(-2),int32(-44),int32(46),int32(-17),int32(-13),int32(56),int32(118),int32(-344),int32(-145),int32(46),int32(-34),int32(-97),int32(309),int32(219),int32(118),int32(26),int32(83),int32(-198),int32(63),int32(26),int32(-40),int32(19),int32(97),int32(84),int32(239),int32(-10),int32(-68),int32(56),int32(13),int32(12),int32(189),int32(-47),int32(-22),int32(-45),int32(232),int32(12),int32(59),int32(42),int32(-203),int32(-51),int32(138),int32(-53),int32(30),int32(-94),int32(-40),int32(-73),int32(-1),int32(-16),int32(42),int32(-42),int32(21),int32(-18),int32(39),int32(-18),int32(-88),int32(-168),int32(184),int32(-30),int32(41),int32(-81),int32(44),int32(-151),int32(192),int32(36),int32(-45),int32(36),int32(-16),int32(116),int32(75),int32(163),int32(-12),int32(86),int32(153),int32(-77),int32(-105),int32(499),int32(100),int32(-225),int32(-374),int32(-43),int32(-78),int32(159),int32(-452),int32(-149),int32(-156),int32(381),int32(-175),int32(-21),int32(1549),int32(98),int32(11),int32(26),int32(199),int32(-171),int32(-61),int32(57),int32(-25),int32(272),int32(57),int32(-101),int32(-196),int32(117),int32(127),int32(-141),int32(85),int32(-139),int32(25),int32(190),int32(-43),int32(109),int32(113),int32(-22),int32(21),int32(-182),int32(99),int32(99),int32(35),int32(31),int32(-196),int32(-314),int32(-390),int32(30),int32(19),int32(281),int32(26),int32(62),int32(302),int32(-80),int32(119),int32(22),int32(-42),int32(-202),int32(-86),int32(194),int32(104),int32(-68),int32(112),int32(33),int32(-26),int32(36),int32(-70),int32(0),int32(54),int32(-18),int32(48),int32(202),int32(21),int32(339),int32(-16),int32(21),int32(116),int32(153),int32(-37),int32(-57),int32(321),int32(387),int32(-404),int32(355),int32(694),int32(520),int32(-688),int32(648),int32(-1394),int32(-1411),int32(142),int32(-80),int32(650),int32(-281),int32(172),int32(-5),int32(-353),int32(358),int32(216),int32(275),int32(376),int32(-187),int32(-9),int32(97),int32(740),int32(121),int32(127),int32(129),int32(-32),int32(159),int32(372),int32(44),int32(-1490),int32(221),int32(248),int32(424),int32(199),int32(184),int32(149),int32(-214),int32(154),int32(222),int32(11),int32(284),int32(281),int32(98),int32(148),int32(-414),int32(-348),int32(141),int32(99),int32(262),int32(205),int32(23),int32(-239),int32(216),int32(43),int32(5),int32(454),int32(-50),int32(128),int32(-273),int32(159),int32(-79),int32(-111),int32(-241),int32(12),int32(41),int32(-121),int32(38),int32(19),int32(-3),int32(41),int32(80),int32(-222),int32(118),int32(186),int32(158),int32(-169),int32(76),int32(39),int32(88),int32(54),int32(-328),int32(-16),int32(275),int32(27),int32(104),int32(449),int32(278),int32(-592),int32(-153),int32(222),int32(176),int32(-133),int32(-157),int32(-235),int32(861),int32(-263),int32(-219),int32(-415),int32(311),int32(5),int32(18),int32(-267),int32(63),int32(215),int32(-185),int32(106),int32(539),int32(44),int32(-440),int32(-259),int32(-115),int32(-337),int32(-32),int32(-134),int32(187),int32(419),int32(-390),int32(362),int32(149),int32(-188),int32(53),int32(203),int32(-1),int32(139),int32(237),int32(59),int32(-160),int32(-183),int32(91),int32(35),int32(-107),int32(-127),int32(-405),int32(39),int32(246),int32(-402),int32(-102),int32(57),int32(-163),int32(-241),int32(-159),int32(-278),int32(-165),int32(251),int32(-459),int32(-382),int32(522),int32(269),int32(184),int32(8),int32(159),int32(-126),int32(-159),int32(262),int32(38),int32(-345),int32(-114),int32(210),int32(-364),int32(71),int32(-26),int32(-69),int32(215),int32(-19),int32(31),int32(359),int32(179),int32(145),int32(37),int32(-255),int32(562),int32(74),int32(186),int32(-160),int32(39),int32(-95),int32(-286),int32(281),int32(167),int32(0),int32(635),int32(-118),int32(-61),int32(-216),int32(-200),int32(-43),int32(-94),int32(96),int32(183),int32(44),int32(-11),int32(61),int32(-129),int32(-45),int32(11),int32(77),int32(64),int32(-57),int32(-173),int32(3),int32(130),int32(-194),int32(-75),int32(-191),int32(17),int32(-193),int32(6),int32(394),int32(-121),int32(269),int32(-47),int32(-441),int32(1196),int32(144),int32(91),int32(6),int32(-158),int32(3),int32(-80),int32(-5),int32(107),int32(159),int32(-151),int32(312),int32(209),int32(232),int32(-1081),int32(-49),int32(44),int32(-71),int32(54),int32(260),int32(-43),int32(183),int32(-55),int32(-43),int32(107),int32(-82),int32(30),int32(-178),int32(781),int32(624),int32(215),int32(209),int32(216),int32(111),int32(236),int32(-284),int32(311),int32(-292),int32(144),int32(-290),int32(-443),int32(-150),int32(-23),int32(10),int32(251),int32(-386),int32(-197),int32(377),int32(-540),int32(-654),int32(240),int32(141),int32(-92),int32(796),int32(-391),int32(236),int32(-85),int32(-311),int32(184),int32(167),int32(-115),int32(135),int32(144),int32(76),int32(213),int32(162),int32(-28),int32(-33),int32(-169),int32(108),int32(687),int32(118),int32(90),int32(254),int32(243),int32(104),int32(144),int32(-12),int32(235),int32(-139),int32(283),int32(-113),int32(-166),int32(228),int32(180),int32(-130),int32(226),int32(-85),int32(-186),int32(-90),int32(-212),int32(-29),int32(-122),int32(-110),int32(-296),int32(-168),int32(128),int32(139),int32(111),int32(32),int32(49),int32(-112),int32(-15),int32(-145),int32(-70),int32(100),int32(-190),int32(136),int32(146),int32(55),int32(-77),int32(137),int32(7),int32(-8),int32(-60),int32(-46),int32(-40),int32(-44),int32(85),int32(-155),int32(202)];
        gapsEUR = [int32(1168),int32(-5197),int32(76),int32(-3309),int32(2711),int32(-5058),int32(-5557),int32(-1824),int32(641),int32(3750),int32(-1225),int32(-2124),int32(987),int32(9543),int32(-544),int32(-642),int32(3213),int32(15538),int32(1469),int32(-5092),int32(4904),int32(3579),int32(474),int32(-2526),int32(2001),int32(-2170),int32(1125),int32(-5428),int32(-1508),int32(-584),int32(-2425),int32(-1250),int32(492),int32(-2985),int32(1590),int32(335),int32(3127),int32(-4066),int32(285),int32(-5534),int32(-5482),int32(60),int32(-1447),int32(-3151),int32(862),int32(-1964),int32(26),int32(-2238),int32(1576),int32(-4054),int32(1785),int32(4237),int32(-5705),int32(7524),int32(2160),int32(-5008),int32(-3451),int32(1079),int32(-2394),int32(643),int32(-941),int32(-788),int32(2124),int32(4618),int32(1104),int32(2629),int32(4166),int32(-3607),int32(-4773),int32(-3370),int32(4211),int32(433),int32(-3782),int32(4848),int32(2958),int32(-990),int32(2462),int32(-6286),int32(2614),int32(2380),int32(-930),int32(2916),int32(-2074),int32(2298),int32(-402),int32(1342),int32(431),int32(3989),int32(5488),int32(4979),int32(-999),int32(-5190),int32(2622),int32(-2164),int32(-2621),int32(-430),int32(-6315),int32(1585),int32(2056),int32(1828),int32(-964),int32(3681),int32(5520),int32(-253),int32(5209),int32(-445),int32(-431),int32(-473),int32(-1815),int32(-3135),int32(1974),int32(2471),int32(-2569),int32(1816),int32(1996),int32(1611),int32(1676),int32(4582),int32(867),int32(507),int32(870),int32(-1277),int32(2591),int32(457),int32(-1704),int32(1969),int32(-1588),int32(2838),int32(906),int32(-2550),int32(-846),int32(-479),int32(214),int32(-108),int32(5509),int32(1303),int32(316),int32(-1894),int32(-2547),int32(2150),int32(-4993),int32(-3267),int32(-4131),int32(528),int32(-1594),int32(-251),int32(993),int32(-1495),int32(1216),int32(624),int32(-1297),int32(2142),int32(1130),int32(2879),int32(515),int32(1754),int32(2983),int32(-45),int32(-838),int32(-308),int32(-3255),int32(-1690),int32(120),int32(-1401),int32(7801),int32(13427),int32(945),int32(8588),int32(-8415),int32(-2849),int32(-2761),int32(-488),int32(4024),int32(-4855),int32(-609),int32(2524),int32(-514),int32(1775),int32(1390),int32(-204),int32(3594),int32(4302),int32(7791),int32(3611),int32(-1128),int32(8040),int32(-5782),int32(-1892),int32(1817),int32(3782),int32(3396),int32(-2035),int32(3049),int32(-6675),int32(3759),int32(4944),int32(-1657),int32(5163),int32(-3591),int32(-1211),int32(3250),int32(-144),int32(3011),int32(3052),int32(808),int32(3251),int32(-2572),int32(-6208),int32(-1076),int32(-1989),int32(-2983),int32(-266),int32(520),int32(2352),int32(-870),int32(-3525),int32(-3236),int32(1260),int32(-831),int32(1828),int32(672),int32(3764),int32(-1876),int32(2504),int32(534),int32(280),int32(2413),int32(443),int32(608),int32(1528),int32(2882),int32(-1692),int32(-354),int32(-1726),int32(949),int32(1410),int32(1416),int32(170),int32(-1492),int32(3273),int32(-229),int32(-993),int32(-1744),int32(-1398),int32(-1664),int32(2725),int32(-86),int32(629),int32(-2757),int32(1367),int32(251),int32(-577),int32(-3960),int32(-4707),int32(-1318),int32(-2209),int32(5046),int32(186),int32(-4386),int32(-6179),int32(-981),int32(-3906),int32(3632),int32(-2558),int32(-2566),int32(1174),int32(-4705),int32(-1033),int32(3795),int32(-823),int32(-2549),int32(-5458),int32(726),int32(-546),int32(-6226),int32(-4057),int32(-427),int32(1990),int32(9018),int32(2730),int32(-914),int32(-5942),int32(2373),int32(2273),int32(2321),int32(-11259),int32(6011),int32(3594),int32(2779),int32(1945),int32(-3733),int32(-3655),int32(3863),int32(-2743),int32(7616),int32(-3556),int32(-3550),int32(-2796),int32(-3810),int32(5602),int32(-2809),int32(-6392),int32(3203),int32(-4760),int32(-7419),int32(2729),int32(2383),int32(2792),int32(1624),int32(1112),int32(-2251),int32(6622),int32(-932),int32(-433),int32(1786),int32(-3752),int32(852),int32(-542),int32(3556),int32(2294),int32(6271),int32(5759),int32(3262),int32(2821),int32(-4650),int32(-4683),int32(2420),int32(508),int32(1770),int32(2506),int32(287),int32(-1594),int32(-2157),int32(2094),int32(-1152),int32(2103),int32(46),int32(-602),int32(-347),int32(-4090),int32(-27),int32(-427),int32(-5472),int32(1849),int32(241),int32(2478),int32(3318),int32(891),int32(-3100),int32(-4673),int32(-4089),int32(2302),int32(812),int32(2866),int32(1538),int32(-936),int32(1256),int32(-1197),int32(-5276),int32(-1477),int32(3259),int32(1481),int32(-858),int32(-330),int32(-4183),int32(-4753),int32(-1632),int32(-872),int32(2569),int32(1218),int32(-841),int32(73),int32(2184),int32(-1094),int32(425),int32(667),int32(-2562),int32(-84),int32(1774),int32(2980),int32(-846),int32(378),int32(92),int32(-5555),int32(1027),int32(4340),int32(4127),int32(277),int32(816),int32(55),int32(-3877),int32(7697),int32(714),int32(907),int32(-2681),int32(1484),int32(-3535),int32(4757),int32(-2625),int32(949),int32(-164),int32(-2085),int32(-1031),int32(1890),int32(6008),int32(-5766),int32(3315),int32(10629),int32(-8354),int32(1458),int32(-610),int32(-2531),int32(-2398),int32(7316),int32(-3299),int32(12126),int32(2049),int32(-10893),int32(-2091),int32(-1754),int32(507),int32(10603),int32(-230),int32(1645),int32(416),int32(-767),int32(2129),int32(-3139),int32(9901),int32(-555),int32(4715),int32(-11824),int32(9911),int32(1426),int32(4658),int32(-35),int32(3957),int32(-3995),int32(982),int32(-3227),int32(-907),int32(3468),int32(-8992),int32(1478),int32(-1830),int32(-2179),int32(-1988),int32(1017),int32(2808),int32(2070),int32(2962),int32(3178),int32(-4472),int32(-3608),int32(-1448),int32(671),int32(-1527),int32(121),int32(-2392),int32(1216),int32(3164),int32(661),int32(971),int32(4074),int32(255),int32(-3328),int32(3550),int32(3095),int32(3900),int32(-3366),int32(7977),int32(-1027),int32(840),int32(-9420),int32(-2421),int32(5200),int32(2526),int32(-3317),int32(3708),int32(-2439),int32(365),int32(2628),int32(-1050),int32(263),int32(2444),int32(3274),int32(-3181),int32(2117),int32(3906),int32(-3425),int32(1563),int32(-1382),int32(771),int32(-1888),int32(827),int32(9),int32(-770),int32(2360),int32(-754),int32(1191),int32(887),int32(-5278),int32(-461),int32(-2580)];
        gapsXAU = [int32(401),int32(8672),int32(-13821),int32(4011),int32(4389),int32(-7523),int32(1324),int32(-6528),int32(-3205),int32(-1939),int32(1798),int32(-2782),int32(-286),int32(-46),int32(-3454),int32(4281),int32(2405),int32(-2847),int32(3633),int32(2900),int32(3653),int32(-573),int32(-13864),int32(-8078),int32(4763),int32(-8245),int32(1675),int32(5267),int32(5601),int32(4059),int32(4191),int32(1317),int32(8071),int32(-7017),int32(1721),int32(228),int32(-1454),int32(-434),int32(2738),int32(9220),int32(-451),int32(-3416),int32(-12352),int32(-4409),int32(578),int32(5940),int32(1955),int32(-276),int32(2550),int32(-1932),int32(-4768),int32(-9760),int32(-12754),int32(-2213),int32(5532),int32(2230),int32(-1450),int32(-1666),int32(-6289),int32(2147),int32(4877),int32(6492),int32(-9710),int32(-6784),int32(-3625),int32(-3497),int32(4540),int32(-296),int32(-5179),int32(298),int32(826),int32(2343),int32(-4436),int32(-3605),int32(-778),int32(3749),int32(-947),int32(2578),int32(676),int32(-3759),int32(3451),int32(3664),int32(-1143),int32(2769),int32(-260),int32(-3990),int32(-113),int32(3625),int32(308),int32(2209),int32(-7959),int32(-8719),int32(-479),int32(1161),int32(-2013),int32(-2036),int32(2841),int32(632),int32(312),int32(-2660),int32(-3617),int32(6622),int32(-515),int32(-2691),int32(-270),int32(-3140),int32(-7673),int32(2489),int32(-85),int32(1157),int32(402),int32(5302),int32(1928),int32(-3138),int32(-13898),int32(7628),int32(-3979),int32(-2839),int32(-3076),int32(-4017),int32(-900),int32(9290),int32(-3247),int32(2350),int32(7187),int32(-198),int32(5653),int32(2940),int32(-880),int32(-785),int32(-4358),int32(-7938),int32(3717),int32(2243),int32(-2808),int32(-2638),int32(2725),int32(4732),int32(3196),int32(8211),int32(-5206),int32(-3950),int32(-527),int32(9941),int32(-1221),int32(895),int32(6438),int32(-8971),int32(1039),int32(5888),int32(-11941),int32(250),int32(-2212),int32(479),int32(3268),int32(14880),int32(2541),int32(-10251),int32(1564),int32(230),int32(3087),int32(10029),int32(1550),int32(-8771),int32(-5207),int32(3076),int32(1809),int32(-4490),int32(-2302),int32(1502),int32(1916),int32(-3071),int32(1668),int32(1027),int32(3093),int32(2006),int32(17482),int32(-3867),int32(1948),int32(8419),int32(-4802),int32(2909),int32(-202),int32(23788),int32(9789),int32(6293),int32(-40488),int32(17990),int32(-809),int32(9990),int32(1491),int32(-4588),int32(2620),int32(-1750),int32(2340),int32(-4271),int32(843),int32(5265),int32(-13661),int32(6815),int32(72),int32(7183),int32(3645),int32(17084),int32(-2327),int32(2117),int32(11855),int32(4654),int32(1947),int32(-2883),int32(6170),int32(-17938),int32(5057),int32(2540),int32(-2826),int32(6398),int32(306),int32(6801),int32(-37070),int32(452),int32(-3446),int32(1602),int32(-3589),int32(-1187),int32(-6768),int32(5487),int32(5453),int32(13792),int32(12828),int32(-1252),int32(9018),int32(7308),int32(-3333),int32(4816),int32(-6301),int32(-4918),int32(-3398),int32(-2602),int32(1527),int32(11890),int32(6775),int32(3667),int32(710),int32(531),int32(-1149),int32(-14362),int32(9700),int32(573),int32(1848),int32(-3086),int32(503),int32(383),int32(-2723),int32(-10186),int32(1889),int32(12545),int32(-2802),int32(-2665),int32(1590),int32(2997),int32(3335),int32(-5315),int32(-1333),int32(628),int32(5544),int32(4549),int32(3703),int32(-1557),int32(-15812),int32(-2861),int32(2122),int32(457),int32(-11983),int32(-2212),int32(2263),int32(4029),int32(4504),int32(3608),int32(-177),int32(-1610),int32(13270),int32(3949),int32(-10930),int32(584),int32(-11147),int32(4624),int32(9755),int32(-17477),int32(-18751),int32(-6893),int32(-2072),int32(6395),int32(3869),int32(1505),int32(-19269),int32(1811),int32(3144),int32(1671),int32(-2271),int32(7286),int32(-299),int32(5118),int32(4680),int32(-11083),int32(-6330),int32(656),int32(1515),int32(7826),int32(-6055),int32(1296),int32(4213),int32(-12548),int32(12972),int32(-4134),int32(-6322),int32(-1356),int32(-2003),int32(-2060),int32(-4062),int32(-3711),int32(-279),int32(5044),int32(-3272),int32(-4989),int32(398),int32(3876),int32(-3921),int32(2454),int32(3021),int32(-1157),int32(16232),int32(2545),int32(-13649),int32(3665),int32(-2434),int32(-847),int32(6628),int32(2012),int32(2541),int32(-1948),int32(138),int32(-1155),int32(-1444),int32(-1592),int32(4669),int32(1769),int32(-1983),int32(-2421),int32(202),int32(3221),int32(-233),int32(-4104),int32(3236),int32(2),int32(-974),int32(5206),int32(2731),int32(-1101),int32(-6926),int32(8796),int32(-5756),int32(-510),int32(-3151),int32(-3553),int32(-770),int32(-7310),int32(-12325),int32(-6052),int32(2566),int32(-11494),int32(2309),int32(-3787),int32(7164),int32(-9160),int32(-5091),int32(2465),int32(-4218),int32(6293),int32(441),int32(-338),int32(4201),int32(4111),int32(4664),int32(-21035),int32(-2547),int32(10177),int32(-7464),int32(898),int32(7067),int32(2562),int32(6822),int32(-3717),int32(3659),int32(1182),int32(-5774),int32(1380),int32(-921),int32(3048),int32(-21118),int32(6937),int32(-7118),int32(5862),int32(-1379),int32(2807),int32(295),int32(3250),int32(-4258),int32(-1697),int32(-1051),int32(6090),int32(-1204),int32(3164),int32(-21204),int32(16467),int32(-22338),int32(13812),int32(3852),int32(-1830),int32(-1155),int32(-4769),int32(-8277),int32(3451),int32(-7350),int32(4812),int32(15263),int32(4345),int32(2689),int32(6703),int32(-2822),int32(1103),int32(1477),int32(12173),int32(-3923),int32(-8082),int32(-1407),int32(26344),int32(-27187),int32(12348),int32(-6799),int32(18449),int32(459),int32(-4714),int32(903),int32(3724),int32(-295),int32(11551),int32(-2683),int32(5484),int32(-14009),int32(1173),int32(-2693),int32(7333),int32(8137),int32(2645),int32(10511),int32(14650),int32(12366),int32(19970),int32(22278),int32(-17162),int32(2202),int32(20596),int32(-5050),int32(2082),int32(1599),int32(5977),int32(20000),int32(-31117),int32(20663),int32(17496),int32(18833),int32(19553),int32(-25801),int32(13645),int32(-8002),int32(13379),int32(13390),int32(-11401),int32(971),int32(-20399),int32(11790),int32(-5526),int32(-6178),int32(-3446),int32(-10758),int32(919),int32(5737),int32(11903),int32(-17679),int32(2997),int32(33911),int32(-8277),int32(-11188),int32(-1664),int32(5496),int32(-4096),int32(-2086),int32(2406),int32(11983),int32(-2725),int32(-6955),int32(-17274),int32(-2811),int32(-34679)];
    }

    /// Table id 0 NVDA, 1 AAPL, 2 SPY, 3 TSLA, 4 EUR/USD, 5 XAU/USD. `marketTableIds` picks market i's table
    /// explicitly (docs/security/capacity-review.md P2); reverts `MissingTable()` if it has no
    /// entry at `i` rather than defaulting by position, closing the single root path every
    /// caller (`_tableFor`, and external callers like Deploy.s.sol's sanity check) routes
    /// through.
    function tableIdAt(uint256 i) public view returns (uint8) {
        if (i >= marketTableIds.length) revert MissingTable();
        return marketTableIds[i];
    }

    function _tableFor(uint256 i) internal view returns (int32[504] storage) {
        uint8 id = tableIdAt(i);
        if (id == 1) return gapsAAPL;
        if (id == 2) return gapsSPY;
        if (id == 3) return gapsTSLA;
        if (id == 4) return gapsEUR;
        if (id == 5) return gapsXAU;
        return gapsNVDA;
    }

    /// Whole-bps equity tables use unit 1, the FX and gold tables are in centi-bps.
    function _unitFor(uint256 i) internal view returns (int256) {
        return tableIdAt(i) >= 4 ? FX_UNIT : int256(1);
    }

    /// Realised volatility over the feed's last VOL_ROUNDS rounds, as a scale in parts-per-
    /// million relative to NORMAL_ROUND_MOVE_BPS, bounded to [MIN_SCALE_PPM, MAX_SCALE_PPM].
    /// Returns PPM (1.0x, neutral) if the feed has too little history yet. Walks the raw round
    /// id backwards by 1 per step; this does not track Chainlink's phaseId the way Treaty's
    /// `_latestInPhase` does (docs/pricing.md Limitations), so a phase change in the last
    /// VOL_ROUNDS rounds truncates the sample early via the try/catch below rather than
    /// crossing into the wrong phase's round ids.
    function _volScalePpm(address feedAddr) internal view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddr);
        (uint80 latestId, int256 latestAnswer,,,) = feed.latestRoundData();
        if (latestAnswer <= 0 || latestId < VOL_ROUNDS) return PPM;

        int256 prevAnswer = latestAnswer;
        uint256 sumBps;
        uint256 n;
        for (uint256 k = 1; k <= VOL_ROUNDS; k++) {
            try feed.getRoundData(latestId - uint80(k)) returns (uint80, int256 answer, uint256, uint256, uint80) {
                if (answer <= 0) break;
                uint256 diff = prevAnswer > answer ? uint256(prevAnswer - answer) : uint256(answer - prevAnswer);
                sumBps += (diff * 10000) / uint256(prevAnswer);
                prevAnswer = answer;
                n++;
            } catch {
                break;
            }
        }
        if (n == 0) return PPM;

        uint256 scale = (sumBps / n) * PPM / NORMAL_ROUND_MOVE_BPS;
        if (scale < MIN_SCALE_PPM) scale = MIN_SCALE_PPM;
        if (scale > MAX_SCALE_PPM) scale = MAX_SCALE_PPM;
        return scale;
    }

    /// Deterministic pricing core: given exposure and an already-known per-market volatility
    /// scale (parts-per-million, 1_000_000 = 1.0x = the stored historical table unscaled), no
    /// feed reads happen here at all. `quote()` is a thin wrapper that reads live feeds to
    /// compute `volScalePpm` and then calls this. Exposed `public` (not `internal`) specifically
    /// so it is a fuzzable, feed-independent parity target: contracts/test/PricerParity.t.sol
    /// fuzzes this function directly against the Rust twin's `price_core` (same split, called
    /// via FFI), which is what makes an exact, feed-independent Solidity == Stylus parity check
    /// possible at all (live feed state can never be made identical across two toolchains).
    function priceCore(int256[] memory exposure, uint256[] memory volScalePpm, uint256 retention, uint256 limit)
        public
        view
        returns (uint256 premium, uint256 el, uint256 tvar95)
    {
        if (exposure.length == 0) revert EmptyExposure();
        if (volScalePpm.length != exposure.length) revert BadFeeds();

        uint256[] memory payout = new uint256[](SCENARIOS);
        uint256 sumPayout;
        for (uint256 s; s < SCENARIOS; s++) {
            int256 loss;
            for (uint256 i; i < exposure.length; i++) {
                int32[504] storage table = _tableFor(i);
                int256 gap = (int256(table[s]) * int256(volScalePpm[i])) / int256(PPM);
                int256 pnl = (exposure[i] * gap) / (BPS * _unitFor(i));
                if (pnl < 0) loss -= pnl;
            }
            int256 p = loss - int256(retention);
            if (p < 0) p = 0;
            uint256 pu = uint256(p);
            if (pu > limit) pu = limit;
            payout[s] = pu;
            sumPayout += pu;
        }
        el = sumPayout / SCENARIOS;

        // Worst-5% tail via partial selection (pull the TAIL largest payouts, not a full sort):
        // matches the Stylus side and the "504 layer evaluations and a TVaR partial sort per
        // quote" workload this product's own research describes.
        bool[] memory used = new bool[](SCENARIOS);
        uint256 tailSum;
        for (uint256 k; k < TAIL; k++) {
            uint256 bestIdx = type(uint256).max;
            uint256 bestVal;
            for (uint256 s; s < SCENARIOS; s++) {
                if (used[s]) continue;
                if (bestIdx == type(uint256).max || payout[s] > bestVal) {
                    bestVal = payout[s];
                    bestIdx = s;
                }
            }
            used[bestIdx] = true;
            tailSum += bestVal;
        }
        tvar95 = tailSum / TAIL;

        // premium = el + RISK_LOAD_PPM * (tvar95 - el) + CAPITAL_CHARGE_ANNUAL_PPM * limit *
        // LOCK_DAYS / DAYS_PER_YEAR; each term fully multiplied before its single final division
        // so neither load is itself divide-before-multiply (the earlier Treaty.sol pnl
        // computation had exactly this anti-pattern before its own fix, see Treaty.sol).
        uint256 riskLoad = ((tvar95 - el) * RISK_LOAD_PPM) / PPM;
        uint256 capitalCharge = (limit * CAPITAL_CHARGE_ANNUAL_PPM * LOCK_DAYS) / (DAYS_PER_YEAR * PPM);
        premium = el + riskLoad + capitalCharge;
    }

    /// @inheritdoc IPricer
    function quote(int256[] calldata exposure, address[] calldata feeds, uint256 retention, uint256 limit)
        external
        view
        returns (uint256 premium, uint256 el, uint256 tvar95)
    {
        if (exposure.length == 0) revert EmptyExposure();
        if (feeds.length != exposure.length) revert BadFeeds();

        uint256[] memory volScalePpm = new uint256[](feeds.length);
        for (uint256 i; i < feeds.length; i++) {
            volScalePpm[i] = _volScalePpm(feeds[i]);
        }
        int256[] memory exposureMem = exposure;
        return priceCore(exposureMem, volScalePpm, retention, limit);
    }
}
